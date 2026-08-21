# Phase C of the mail_on_rails gem extraction: move the pre-extraction
# mail tables to the names the gem's models use natively, so the
# table_name_prefix override can go.
#
# ALTER TABLE ... RENAME is a catalog-only, O(1) operation on Postgres:
# indexes, the PK sequence, foreign keys (including the app-side
# email_account_users -> email_accounts one), and the generated tsvector
# column all follow automatically. Index and constraint NAMES keep their
# old, unprefixed spellings - deliberately left alone (they match what the
# gem's consolidated migration creates on fresh installs); do not "fix"
# them during an incident.
class RenameMailTablesForMailOnRailsGem < ActiveRecord::Migration[8.1]
  TABLES = %w[
    auth_attempts auth_throttles banned_ips closed_connections
    dmarc_reports domains email_accounts email_aliases email_messages
    expunged_messages mailboxes mta_sts_policies settings
    smtp_outbound_messages tls_rpt_events tls_rpt_reports vacation_replies
  ].freeze

  # Everything mail that can appear as audit_events.subject_type
  # (polymorphic; rows persist class names).
  SUBJECT_TYPES = %w[
    AuthAttempt AuthThrottle BannedIp ClosedConnection DmarcReport Domain
    EmailAccount EmailAlias EmailMessage ExpungedMessage Mailbox
    MtaStsPolicy Setting SmtpOutboundMessage TlsRptEvent TlsRptReport
    VacationReply
  ].freeze

  # The gem's consolidated create-migration, which these renamed tables
  # already satisfy. Recording it here is load-bearing: without it, the
  # next db:migrate with engine migrations enabled would try to create
  # the live tables again.
  GEM_SCHEMA_VERSION = "20260808000000"

  def up
    # A fresh database never has the pre-extraction tables: the gem's
    # consolidated migration (an earlier version) already created the
    # prefixed set, and there is nothing to rename or rewrite.
    return unless table_exists?("auth_attempts")

    TABLES.each { |t| rename_table t, "mail_on_rails_#{t}" }

    SUBJECT_TYPES.each do |type|
      execute sanitize_sql([ "UPDATE audit_events SET subject_type = ? WHERE subject_type = ?",
                             "MailOnRails::#{type}", type ])
    end

    # Migrations run serially, so a plain check-then-insert is race-free
    # (ON CONFLICT would be Postgres/SQLite-only syntax).
    recorded = select_value(sanitize_sql([ "SELECT 1 FROM schema_migrations WHERE version = ?",
                                           GEM_SCHEMA_VERSION ]))
    unless recorded
      execute sanitize_sql([ "INSERT INTO schema_migrations (version) VALUES (?)", GEM_SCHEMA_VERSION ])
    end
  end

  def down
    execute sanitize_sql([ "DELETE FROM schema_migrations WHERE version = ?", GEM_SCHEMA_VERSION ])

    SUBJECT_TYPES.each do |type|
      execute sanitize_sql([ "UPDATE audit_events SET subject_type = ? WHERE subject_type = ?",
                             type, "MailOnRails::#{type}" ])
    end

    TABLES.each { |t| rename_table "mail_on_rails_#{t}", t }
  end

  private

  def sanitize_sql(array)
    ActiveRecord::Base.sanitize_sql_array(array)
  end
end
