require "test_helper"
require "net/smtp"
require "net/imap"
require "socket"
require "mail_on_rails"

# The whole unified stack end-to-end, in one process like production:
# Boot.start_servers on ephemeral ports with the real ActiveRecord
# stores, then real Net::SMTP / Net::IMAP clients over loopback sockets.
#
# Transactional tests are off: the servers' connection threads use their
# own database connections and must see the test's rows, so everything
# committed here is cleaned up by hand in teardown.
class InProcessServersTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  EMAIL = "endtoend@example.test"
  PASSWORD = "pw-123456-endtoend"

  setup do
    @env_keys = %w[MAIL_ON_RAILS_HOST MAIL_ON_RAILS_IMAP_PORT MAIL_ON_RAILS_IMAPS_PORT
                   SMTP_PORT SMTP_SUBMISSION_PORT SMTPS_PORT SMTP_HELO_HOST SMTP_SENDER_AUTH]
    @saved_env = @env_keys.to_h { |k| [ k, ENV[k] ] }

    ENV["MAIL_ON_RAILS_HOST"] = "127.0.0.1"
    # Sender verification does live DNS; settings are read per message, so
    # scoping this to the test (not the process) keeps it out of the rest
    # of the suite.
    ENV["SMTP_SENDER_AUTH"] = "0"
    @imap_port, @imaps_port, @smtp_port, @submission_port, @smtps_port = free_ports(5)
    ENV["MAIL_ON_RAILS_IMAP_PORT"] = @imap_port.to_s
    ENV["MAIL_ON_RAILS_IMAPS_PORT"] = @imaps_port.to_s
    ENV["SMTP_PORT"] = @smtp_port.to_s
    ENV["SMTP_SUBMISSION_PORT"] = @submission_port.to_s
    ENV["SMTPS_PORT"] = @smtps_port.to_s
    ENV["SMTP_HELO_HOST"] = "unified.test"

    @account = MailOnRails::EmailAccount.create!(email: EMAIL, password: PASSWORD)

    MailOnRails::Runtime.start_servers
    MailOnRails::Runtime.wait_ready!(10)
  end

  teardown do
    MailOnRails::Runtime.stop_servers(drain: 1)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }

    ActionMailbox::InboundEmail.destroy_all
    MailOnRails::SmtpOutboundMessage.delete_all
    MailOnRails::AuthAttempt.delete_all
    MailOnRails::AuthThrottle.delete_all
    MailOnRails::ClosedConnection.delete_all
    MailOnRails::BannedIp.delete_all
    MailOnRails::ConnectionKick.delete_all
    MailOnRails::OpenConnection.delete_all
    MailOnRails::AcceptLockout.delete_all
    MailOnRails::Listener.delete_all
    MailOnRails::EmailAccount.where(email: EMAIL).destroy_all
  end

  def eventually(timeout, message)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  test "the full stack serves SMTP inbound, submission, and IMAP in one process" do
    assert MailOnRails::Runtime.ready?

    # -- inbound MX: unauthenticated plaintext delivery for a local user --
    raw = "Message-ID: <e2e-#{SecureRandom.hex(4)}@remote.test>\r\n" \
          "From: sender@remote.test\r\nTo: #{EMAIL}\r\nSubject: unified e2e\r\n\r\nhello from the wire\r\n"
    # tls_verify: false because the listener serves the self-signed dev
    # cert; Net::SMTP still upgrades via STARTTLS.
    Net::SMTP.start("127.0.0.1", @smtp_port, helo: "client.test", tls_verify: false) do |smtp|
      smtp.send_message(raw, "sender@remote.test", EMAIL)
    end

    assert_equal 1, ActionMailbox::InboundEmail.count
    source = ActionMailbox::InboundEmail.last.raw_email.download
    assert_includes source, "X-MailOnRails-Client-Ip: 127.0.0.1\r\n"
    assert_includes source, "X-Original-To: #{EMAIL}\r\n"
    # ESMTPS: Net::SMTP upgraded via STARTTLS before sending.
    assert_match(/^Received: from client\.test \(\[127\.0\.0\.1\]\)\r\n\tby unified\.test with ESMTPS;/, source)

    # Route it through the mailroom (Action Mailbox enqueues routing).
    perform_enqueued_jobs

    inbox_message = @account.reload.inbox.email_messages.last
    assert inbox_message, "the mailroom must file the message into INBOX"
    assert_equal "unified e2e", inbox_message.subject

    # -- IMAP over implicit TLS: login and read the message back --
    imap = Net::IMAP.new("127.0.0.1", port: @imaps_port, ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
    begin
      imap.login(EMAIL, PASSWORD)
      imap.select("INBOX")
      uids = imap.uid_search([ "ALL" ])
      assert_equal 1, uids.size
      fetched = imap.uid_fetch(uids, "BODY[]").first.attr["BODY[]"]
      assert_includes fetched, "hello from the wire"
      assert_includes fetched, "X-MailOnRails-Client-Ip: 127.0.0.1"
    ensure
      imap.logout rescue nil
      imap.disconnect rescue nil
    end

    # -- authenticated submission over SMTPS: queued for outbound delivery --
    outbound = "From: #{EMAIL}\r\nTo: friend@elsewhere.test\r\nSubject: outbound e2e\r\n\r\nbye\r\n"
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    smtp = Net::SMTP.new("127.0.0.1", @smtps_port)
    smtp.enable_tls(ctx)
    smtp.start("client.test", EMAIL, PASSWORD, :plain) do |session|
      session.send_message(outbound, EMAIL, "friend@elsewhere.test")
    end

    row = MailOnRails::SmtpOutboundMessage.last
    assert row, "submission must row into the outbound queue"
    assert_equal "friend@elsewhere.test", row.recipient
    assert_equal EMAIL, row.mail_from
    assert_predicate row, :pending?

    # -- a failed AUTH lands in the shared attempt log with source smtp --
    bad = Net::SMTP.new("127.0.0.1", @smtps_port)
    bad.enable_tls(ctx)
    assert_raises(Net::SMTPAuthenticationError) do
      bad.start("client.test", EMAIL, "wrong-password", :plain)
    end
    attempt = MailOnRails::AuthAttempt.last
    assert attempt, "failed SMTP AUTH must be recorded"
    assert_equal "smtp", attempt.source
    assert_equal "127.0.0.1", attempt.ip

    # -- unknown local user vs foreign recipient split --
    Net::SMTP.start("127.0.0.1", @smtp_port, helo: "client.test", tls_verify: false) do |session|
      session.mailfrom("sender@remote.test")
      error = assert_raises(Net::SMTPFatalError) { session.rcptto("nobody@example.test") }
      assert_match(/5\.1\.1 No such user/, error.message)
      error = assert_raises(Net::SMTPFatalError) { session.rcptto("nobody@foreign.test") }
      assert_match(/5\.7\.1 Relaying denied/, error.message)
    end
  end

  # The ops-state projection that makes the admin UI work from any process:
  # each server heartbeats a Listener row and mirrors its live connections;
  # a BannedIp row drops matching live sessions on the next sync tick; a
  # ConnectionKick command does the same without a ban and is acknowledged.
  test "listeners project their live picture and act on bans and kicks through the database" do
    eventually(10, "both listeners heartbeat") do
      MailOnRails::Listener.alive(:smtp).any? && MailOnRails::Listener.alive(:imap).any?
    end
    imap_listener = MailOnRails::Listener.alive(:imap).sole
    assert_includes imap_listener.ports, @imap_port
    assert imap_listener.ready?

    imap = Net::IMAP.new("127.0.0.1", port: @imaps_port, ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
    imap.login(EMAIL, PASSWORD)
    eventually(10, "the IMAP session appears in open_connections") do
      MailOnRails::OpenConnection.live(:imap).exists?(peer_ip: "127.0.0.1", username: EMAIL)
    end
    row = MailOnRails::OpenConnection.live(:imap).find_by(username: EMAIL)
    assert row.tls
    assert_equal @imaps_port, row.port

    # A kick command is processed and acknowledged, and the session is gone.
    kick = MailOnRails::ConnectionKick.request!("127.0.0.1", protocols: [ "imap" ]).sole
    eventually(10, "the kick is acknowledged") { kick.reload.processed_at.present? }
    assert_equal 1, kick.kicked_count
    assert_raises(IOError, EOFError, Errno::ECONNRESET, Net::IMAP::Error) do
      3.times { imap.noop }
    end
    eventually(10, "the kicked session leaves open_connections") do
      MailOnRails::OpenConnection.live(:imap).where(username: EMAIL).none?
    end

    # A ban drops an already-open session too (no kick row needed).
    imap2 = Net::IMAP.new("127.0.0.1", port: @imaps_port, ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
    imap2.login(EMAIL, PASSWORD)
    eventually(10, "the second session appears") do
      MailOnRails::OpenConnection.live(:imap).exists?(username: EMAIL)
    end
    MailOnRails::BannedIp.create!(cidr: "127.0.0.1/32", note: "e2e")
    eventually(10, "the banned session is dropped") do
      MailOnRails::OpenConnection.live(:imap).where(username: EMAIL).none?
    end
    assert_raises(IOError, EOFError, Errno::ECONNRESET, Net::IMAP::Error) do
      3.times { imap2.noop }
    end
    assert_equal 0, MailOnRails::ConnectionKick.where(ip: "127.0.0.1").pending.count
  ensure
    imap&.disconnect rescue nil
    imap2&.disconnect rescue nil
  end

  test "stop_servers drains and unbinds every listener" do
    assert MailOnRails::Runtime.ready?

    MailOnRails::Runtime.stop_servers(drain: 1)

    refute MailOnRails::Runtime.ready?
    [ @imap_port, @imaps_port, @smtp_port, @submission_port, @smtps_port ].each do |port|
      assert_raises(Errno::ECONNREFUSED, "port #{port} must be unbound") { TCPSocket.new("127.0.0.1", port) }
    end
  end

  private

  # All sockets stay bound until every port is issued: bind-then-close one
  # at a time lets the kernel hand the same port out twice, and the daemon
  # refuses duplicate listener ports. The tiny reuse race after close is
  # acceptable on loopback in a test.
  def free_ports(count)
    servers = Array.new(count) { TCPServer.new("127.0.0.1", 0) }
    servers.map { |s| s.addr[1] }
  ensure
    servers&.each(&:close)
  end
end
