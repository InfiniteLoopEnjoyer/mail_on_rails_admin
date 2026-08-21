require "test_helper"

class HoneypotControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end

  def record(trigger: "canary_auth", ip: "203.0.113.7", **extra)
    MailOnRails::HoneypotEvent.create!({ protocol: "smtp", trigger: trigger, ip: ip,
                                         occurred_at: Time.current }.merge(extra))
  end

  test "requires a signed-in user" do
    reset!
    get honeypot_events_path
    assert_redirected_to new_session_path
  end

  test "renders an empty state with no events" do
    get honeypot_events_path
    assert_response :success
    assert_select "h1", "Honeypot"
    assert_match "No honeypot activity", response.body
  end

  test "lists recent events with source, trigger and response" do
    record(trigger: "canary_auth", ip: "203.0.113.7", username: "admin@example.test")
    record(trigger: "exploit_probe", ip: "198.51.100.9", signature: "exim_run")

    get honeypot_events_path
    assert_response :success
    assert_match "203.0.113.7", response.body
    assert_match "canary auth", response.body
    assert_match "exploit probe", response.body
    assert_match "exim_run", response.body
    assert_match "throttled", response.body
    assert_match "observed", response.body
  end

  test "lists canary accounts" do
    MailOnRails::EmailAccount.create!(email: "canary@example.test", password: "secret123", honeypot: true)
    MailOnRails::EmailAccount.create!(email: "real@example.test", password: "secret123")

    get honeypot_events_path
    assert_match "canary@example.test", response.body
    assert_no_match(/real@example\.test/, response.body)
  end

  test "the window selector narrows the data" do
    old = record(ip: "203.0.113.7")
    old.update_columns(occurred_at: 10.days.ago)
    record(ip: "198.51.100.9")

    get honeypot_events_path(window: "24h")
    assert_match "198.51.100.9", response.body
    assert_no_match(/203\.0\.113\.7/, response.body)
  end

  test "an unknown window falls back to the default rather than erroring" do
    get honeypot_events_path(window: "../../etc")
    assert_response :success
  end

  test "a canary login temporarily throttles the source, never a permanent ban" do
    record(trigger: "canary_auth", ip: "203.0.113.7")

    assert MailOnRails::AuthThrottle.check(ip: "203.0.113.7", email: nil).present?,
           "the source should be temporarily throttled"
    assert_equal 0, MailOnRails::BannedIp.count, "no permanent ban is ever automatic"
  end

  test "kick requires recent re-authentication" do
    delete session_path
    sign_in_as users(:one), step_up: false

    post kick_honeypot_events_path, params: { ip: "203.0.113.7" }
    assert_redirected_to new_reauthentication_path
  end

  # The kick is a command row per protocol: each listener (this process or
  # the smtp/imap containers) drops the source's live connections on its
  # next sync tick and acknowledges with the count. Nothing else persists -
  # in particular no ban.
  test "an admin can kick a source's live connections" do
    record(ip: "203.0.113.7")
    post kick_honeypot_events_path, params: { ip: "203.0.113.7" }
    assert_redirected_to honeypot_events_path
    assert_match(/drop live connections from 203\.0\.113\.7/, flash[:notice])
    kicks = MailOnRails::ConnectionKick.where(ip: "203.0.113.7").order(:protocol)
    assert_equal %w[imap smtp], kicks.map(&:protocol)
    assert kicks.all? { |kick| kick.processed_at.nil? && kick.expires_at > Time.current }
    assert_equal users(:one).email_address, kicks.first.requested_by
    assert_equal 0, MailOnRails::BannedIp.count
    assert_equal "honeypot.kick", AuditEvent.last.action
  end

  test "a kick for something that is not an address is refused" do
    post kick_honeypot_events_path, params: { ip: "not-an-ip" }
    assert_redirected_to honeypot_events_path
    assert_match(/not an IP address/, flash[:alert])
    assert_equal 0, MailOnRails::ConnectionKick.count
  end

  test "the ban button remains for manual escalation" do
    record(ip: "203.0.113.7")
    get honeypot_events_path
    assert_select "form[action=?]", banned_ips_path
  end

  test "the show page renders the transcript and attribution" do
    event = record(ip: "203.0.113.7", username: "admin@example.test",
                   transcript: "<= EHLO evil\n=> 220 Exim 4.80\n<= AUTH PLAIN [redacted]",
                   enrichment: { "asn" => "13335", "country" => "US", "as_name" => "CLOUDFLARENET", "rdns" => "scan.evil.test" })

    get honeypot_event_path(event)
    assert_response :success
    assert_match "AUTH PLAIN [redacted]", response.body
    assert_match "AS13335", response.body
    assert_match "scan.evil.test", response.body
  end
end
