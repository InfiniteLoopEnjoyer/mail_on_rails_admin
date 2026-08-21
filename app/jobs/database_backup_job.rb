# Nightly dump of the primary database (recurring, see
# config/recurring.yml; on demand via bin/db-backup or `bin/kamal backup`).
# Only the primary is dumped - it holds all the mail; the cache/queue/cable
# databases are derived state that db:prepare recreates empty on restore.
#
# The dump tool follows the adapter: pg_dump in custom format (.dump,
# restorable selectively and out of order with pg_restore), mysqldump as
# plain SQL (.sql), or SQLite's own VACUUM INTO (.sqlite3, a ready-to-use
# database file). Dumps land in DB_BACKUP_DIR (default storage/backups -
# in production that is the persistent mail_on_rails_storage volume, so
# backups survive container replacement). Retention is DB_BACKUP_KEEP_DAYS
# (default 14); pruning happens after each successful dump, so a failing
# dump can never age the last good backup out.
#
# With DB_BACKUP_ENCRYPTION_KEY set (64 hex chars: `openssl rand -hex 32`),
# the dump is streamed through AES-256-GCM and written with an .enc
# suffix - never touching disk in the clear (except SQLite's, whose
# VACUUM INTO writes a plain temp file that is encrypted and removed).
# The key lives in the container
# environment (a Kamal secret), the ciphertext on the storage volume, so
# neither a leaked volume snapshot nor a stolen disk yields the mail store
# by itself. bin/db-backup-decrypt (standalone, no Rails) recovers the
# plain dump for pg_restore; losing the key means losing the backups, so
# escrow it wherever the other deploy secrets live.
#
# Copy the directory off the host on your own schedule - a backup on the
# same disk protects against bad deploys and fat fingers, not against
# losing the machine. See docs/backups.md for the restore runbook.
class DatabaseBackupJob < ApplicationJob
  queue_as :default

  KEEP_DAYS = Integer(ENV.fetch("DB_BACKUP_KEEP_DAYS", 14))

  # bin/db-backup-decrypt mirrors these; change them in lockstep.
  MAGIC = "MORBKUP1"
  CIPHER = "aes-256-gcm"

  # Returns the path of the dump it wrote. +config+ overrides the primary
  # connection settings (a test seam).
  def perform(config = nil)
    dir = Pathname(ENV.fetch("DB_BACKUP_DIR") { Rails.root.join("storage/backups").to_s })
    dir.mkpath

    key = encryption_key
    if key.nil? && Rails.env.production? && !ENV["DB_BACKUP_ALLOW_UNENCRYPTED"].present?
      # A plaintext dump of the whole mail store is exactly what an offsite
      # backup must not be. Fail the job (SolidQueue surfaces it) rather than
      # quietly writing one; DB_BACKUP_ALLOW_UNENCRYPTED=1 is the explicit,
      # documented opt-out.
      raise "[mail_on_rails] refusing to write an UNENCRYPTED database backup - " \
            "set DB_BACKUP_ENCRYPTION_KEY (openssl rand -hex 32), or DB_BACKUP_ALLOW_UNENCRYPTED=1 to override"
    end

    config ||= ActiveRecord::Base.connection_db_config.configuration_hash
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    # basename: a SQLite "database" is a path, not a bare name.
    name = File.basename(config[:database].to_s, ".*")
    file = dir.join("#{name}-#{stamp}#{dump_suffix(config)}#{".enc" if key}")

    run_dump(config, file, key)
    prune(dir)

    Rails.logger.info "[mail_on_rails] database backup written: #{file} (#{file.size} bytes)"
    file.to_s
  end

  private

  def dump_suffix(config)
    case config[:adapter].to_s
    when /postg/i then ".dump"
    when /mysql|trilogy/i then ".sql"
    when /sqlite/i then ".sqlite3"
    else raise "no backup strategy for adapter #{config[:adapter].inspect}"
    end
  end

  def run_dump(config, file, key)
    case config[:adapter].to_s
    when /postg/i then run_pg_dump(config, file, key)
    when /mysql|trilogy/i then run_mysqldump(config, file, key)
    when /sqlite/i then run_sqlite_copy(config, file, key)
    end
  end

  def run_pg_dump(config, file, key)
    args = [ "pg_dump", "--format=custom", "--no-password" ]
    # A leading-slash host is a Unix socket directory - pg_dump takes both
    # through --host, exactly like the pg adapter.
    host = config[:host] || config[:socket]
    args += [ "--host", host.to_s ] if host
    args += [ "--username", config[:username].to_s ] if config[:username]
    args << config[:database].to_s

    env = config[:password] ? { "PGPASSWORD" => config[:password].to_s } : {}
    file.open("wb") do |out|
      IO.popen(env, args, "rb") do |dump|
        key ? encrypt_stream(dump, out, key) : IO.copy_stream(dump, out)
      end
    end
    return if $?.success?

    file.delete if file.exist? # never leave a truncated dump looking real
    raise "pg_dump failed for #{config[:database]} (exit #{$?.exitstatus})"
  end

  # --single-transaction: a consistent InnoDB snapshot without locking the
  # tables the mail server is writing to.
  def run_mysqldump(config, file, key)
    args = [ "mysqldump", "--single-transaction", "--no-tablespaces" ]
    args += [ "--host", config[:host].to_s ] if config[:host]
    args += [ "--port", config[:port].to_s ] if config[:port]
    args += [ "--user", config[:username].to_s ] if config[:username]
    args << config[:database].to_s

    env = config[:password] ? { "MYSQL_PWD" => config[:password].to_s } : {}
    file.open("wb") do |out|
      IO.popen(env, args, "rb") do |dump|
        key ? encrypt_stream(dump, out, key) : IO.copy_stream(dump, out)
      end
    end
    return if $?.success?

    file.delete if file.exist?
    raise "mysqldump failed for #{config[:database]} (exit #{$?.exitstatus})"
  end

  # SQLite backs itself up: VACUUM INTO writes a compacted, consistent
  # copy of the live database - no external tool involved. The copy is a
  # plain temp file first; with a key it is streamed into the .enc target
  # and removed.
  def run_sqlite_copy(config, file, key)
    tmp = Pathname("#{file.sub_ext('')}.tmp.sqlite3")
    tmp.delete if tmp.exist? # VACUUM INTO refuses to overwrite
    database = SQLite3::Database.new(config[:database].to_s)
    begin
      database.execute("VACUUM INTO ?", tmp.to_s)
    ensure
      database.close
    end

    if key
      tmp.open("rb") do |dump|
        file.open("wb") { |out| encrypt_stream(dump, out, key) }
      end
      tmp.delete
    else
      File.rename(tmp, file)
    end
  rescue StandardError
    file.delete if file.exist?
    tmp.delete if tmp&.exist?
    raise
  end

  # File layout: MAGIC (8 bytes), IV (12), ciphertext, GCM tag (16). The
  # tag authenticates the whole stream, so pg_restore can only ever see
  # bytes the key holder wrote - truncation or tampering fails decryption.
  def encrypt_stream(dump, out, key)
    cipher = OpenSSL::Cipher.new(CIPHER).encrypt
    cipher.key = key
    out.write(MAGIC, cipher.random_iv)
    while (chunk = dump.read(1 << 20))
      out.write(cipher.update(chunk))
    end
    out.write(cipher.final, cipher.auth_tag)
  end

  # nil when unset (dev default: plain dumps); anything set must be a full
  # 256-bit key - silently deriving from a short passphrase would look
  # encrypted while being guessable.
  def encryption_key
    hex = ENV["DB_BACKUP_ENCRYPTION_KEY"].to_s
    return nil if hex.empty?
    unless hex.match?(/\A\h{64}\z/)
      raise "DB_BACKUP_ENCRYPTION_KEY must be 64 hex characters (openssl rand -hex 32)"
    end

    [ hex ].pack("H*")
  end

  def prune(dir)
    cutoff = Time.now - KEEP_DAYS * 86_400
    dir.glob("*.{dump,sql,sqlite3}{,.enc}").select { |f| f.mtime < cutoff }.each do |stale|
      stale.delete
      Rails.logger.info "[mail_on_rails] pruned database backup #{stale}"
    end
  end
end
