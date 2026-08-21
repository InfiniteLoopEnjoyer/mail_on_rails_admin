require "test_helper"
require "mail_on_rails/smtp/sender_auth/dns"

class OutboundDelivererTest < ActiveSupport::TestCase
  Answer = MailOnRails::Smtp::SenderAuth::Dns::Answer
  Tlsa = MailOnRails::Smtp::SenderAuth::Dns::Tlsa

  # Hash-backed stand-in for the SenderAuth Dns client; records TLSA
  # lookups so tests can assert DANE stayed quiet on insecure paths.
  class FakeDns
    attr_reader :tlsa_calls

    def initialize(mx: {}, tlsa: {}, txt: {})
      @mx, @tlsa, @txt = mx, tlsa, txt
      @tlsa_calls = []
    end

    def mx_answer(name)
      @mx.fetch(name) { Answer.new(records: [], secure: false) }
    end

    def tlsa(name)
      @tlsa_calls << name
      @tlsa.fetch(name) { Answer.new(records: [], secure: false) }
    end

    def txt(name)
      @txt.fetch(name, [])
    end
  end

  setup do
    @deliverer = MailOnRails::OutboundDeliverer.new(dns: FakeDns.new)
  end

  def outbound(mail_from: "user@local.test", from_header: "user@local.test", recipient: "rcpt@remote.test",
               extra_headers: "", **attrs)
    headers = from_header ? "From: #{from_header}\r\n" : ""
    MailOnRails::SmtpOutboundMessage.new(mail_from: mail_from, recipient: recipient,
                            data: "#{headers}#{extra_headers}Subject: hi\r\n\r\nbody\r\n", **attrs)
  end

  # Swap Rails.logger for a capturing one (minitest/mock isn't bundled -
  # same reason the clamav/rspamd stub helpers are hand-rolled).
  def capture_warnings
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  # A deliverer whose network layer is the given block: it receives
  # (host, policy) and its result/raise stands in for the SMTP session.
  def deliverer_with(dns, &network)
    deliverer = MailOnRails::OutboundDeliverer.new(dns: dns)
    deliverer.define_singleton_method(:send_via) do |host, _port, _message, policy:, auth: {}|
      network.call(host, policy)
    end
    deliverer
  end

  def secure_mx(host: "mx.remote.test")
    { "remote.test" => Answer.new(records: [ [ 10, host ] ], secure: true) }
  end

  def usable_tlsa(host: "mx.remote.test")
    { "_25._tcp.#{host}" => Answer.new(records: [ Tlsa.new(usage: 3, selector: 1, matching_type: 1, data: "\xab".b * 32) ], secure: true) }
  end

  def enforce_policy!(mx_patterns: [ "mx.remote.test" ])
    MailOnRails::MtaStsPolicy.create!(domain: "remote.test", sts_id: "id1", mode: "enforce",
                         max_age: 86_400, mx_patterns: mx_patterns, fetched_at: Time.current)
  end

  # --- DKIM signing ---

  test "signs with the From: header domain's DB key, not the envelope domain" do
    MailOnRails::Domain.create!(name: "header.test")
    MailOnRails::Domain.create!(name: "envelope.test")
    signed = @deliverer.send(:signed, outbound(mail_from: "user@envelope.test", from_header: "Sender <user@header.test>"))
    assert_match(/^DKIM-Signature:.*d=header\.test;/m, signed)
  end

  test "falls back to the envelope domain when the From header is missing" do
    MailOnRails::Domain.create!(name: "envelope.test")
    signed = @deliverer.send(:signed, outbound(mail_from: "user@envelope.test", from_header: nil))
    assert_match(/^DKIM-Signature:.*d=envelope\.test;/m, signed)
  end

  test "goes out unsigned, with a warning, when the domain has no Domain record" do
    raw = outbound(mail_from: "user@nokey.test", from_header: "user@nokey.test")
    result = nil
    warnings = capture_warnings do
      result = @deliverer.send(:signed, raw)
    end
    assert result.end_with?(raw.data), "the original message must go out unchanged (past the stamped headers)"
    assert_match(/\AMessage-ID: /, result)
    assert_no_match(/^DKIM-Signature:/, result)
    assert_includes warnings, "UNSIGNED"
    assert_includes warnings, "nokey.test"
  end

  # A HOSTED domain (one with a Domain record) is a DMARC-alignment
  # promise; smtp_dkim_required (default on) defers rather than quietly
  # breaking it, and the queue's backoff/bounce takes it from there.
  test "a hosted domain whose key is blank defers instead of sending unsigned" do
    MailOnRails::Domain.create!(name: "hosted.test").update!(dkim_private_key: "")

    error = assert_raises(MailOnRails::OutboundDeliverer::TransientError) do
      @deliverer.send(:signed, outbound(mail_from: "user@hosted.test", from_header: "user@hosted.test"))
    end
    assert_match(/DKIM signing for hosted\.test is required/, error.message)
  end

  test "a hosted domain whose key is unreadable defers instead of sending unsigned" do
    MailOnRails::Domain.create!(name: "hosted.test").update!(dkim_private_key: "not a valid pem")

    error = assert_raises(MailOnRails::OutboundDeliverer::TransientError) do
      @deliverer.send(:signed, outbound(mail_from: "user@hosted.test", from_header: "user@hosted.test"))
    end
    assert_match(/deferring delivery/, error.message)
  end

  test "SMTP_DKIM_REQUIRED=0 sends unsigned with a warning when signing fails" do
    MailOnRails::Settings.overrides = { smtp_dkim_required: false }
    MailOnRails::Domain.create!(name: "hosted.test").update!(dkim_private_key: "not a valid pem")
    raw = outbound(mail_from: "user@hosted.test", from_header: "user@hosted.test")

    result = nil
    warnings = capture_warnings do
      result = @deliverer.send(:signed, raw)
    end
    assert result.end_with?(raw.data), "the original message must go out unchanged (past the stamped headers)"
    assert_no_match(/^DKIM-Signature:/, result)
    assert_includes warnings, "UNSIGNED"
  ensure
    MailOnRails::Settings.overrides = {}
  end

  # --- MX resolution ---

  test "equal-preference MX records are shuffled, lower preference still first" do
    dns = FakeDns.new(mx: { "example.com" => Answer.new(
      records: [ [ 10, "a.example.com" ], [ 10, "b.example.com" ], [ 20, "backup.example.com" ] ], secure: false) })
    deliverer = MailOnRails::OutboundDeliverer.new(dns: dns)
    orders = Set.new
    20.times do
      hosts = deliverer.send(:mx_hosts, "example.com").hosts.map(&:first)
      assert_equal "backup.example.com", hosts.last, "higher preference must sort last"
      orders << hosts.first(2)
    end
    assert_equal 2, orders.size, "both orderings of the tied pair should occur across runs"
  end

  test "null MX is a permanent error, no MX falls back to the domain's A record" do
    null_dns = FakeDns.new(mx: { "example.com" => Answer.new(records: [ [ 0, "" ] ], secure: false) })
    assert_raises(MailOnRails::OutboundDeliverer::PermanentError) do
      MailOnRails::OutboundDeliverer.new(dns: null_dns).send(:mx_hosts, "example.com")
    end

    resolved = MailOnRails::OutboundDeliverer.new(dns: FakeDns.new).send(:mx_hosts, "example.com")
    assert_equal [ [ "example.com", 25 ] ], resolved.hosts
    assert resolved.fallback
  end

  # --- policy selection and TLS-RPT events ---

  test "a secure MX with secure usable TLSA delivers under DANE and records a tlsa success" do
    seen = nil
    dns = FakeDns.new(mx: secure_mx, tlsa: usable_tlsa)
    deliverer = deliverer_with(dns) { |_host, policy| seen = policy; true }

    assert deliverer.deliver(outbound)
    assert_equal :dane, seen.mode
    assert_equal 1, seen.tlsa_records.size

    event = MailOnRails::TlsRptEvent.sole
    assert_equal [ "remote.test", "tlsa", "mx.remote.test", nil ],
                 [ event.policy_domain, event.policy_type, event.receiving_mx, event.result_type ]
  end

  test "an insecure MX RRset never even looks up TLSA" do
    dns = FakeDns.new(mx: { "remote.test" => Answer.new(records: [ [ 10, "mx.remote.test" ] ], secure: false) })
    deliverer = deliverer_with(dns) { |_host, policy| assert_equal :opportunistic, policy.mode; true }

    assert deliverer.deliver(outbound)
    assert_empty dns.tlsa_calls
  end

  test "insecure TLSA records mean opportunistic delivery" do
    tlsa = { "_25._tcp.mx.remote.test" => Answer.new(
      records: [ Tlsa.new(usage: 3, selector: 1, matching_type: 1, data: "x" * 32) ], secure: false) }
    deliverer = deliverer_with(FakeDns.new(mx: secure_mx, tlsa: tlsa)) do |_host, policy|
      assert_equal :opportunistic, policy.mode
      true
    end

    assert deliverer.deliver(outbound)
  end

  test "a secure TLSA RRset with only unusable records makes the host undeliverable" do
    tlsa = { "_25._tcp.mx.remote.test" => Answer.new(
      records: [ Tlsa.new(usage: 0, selector: 1, matching_type: 1, data: "x" * 32) ], secure: true) }
    deliverer = deliverer_with(FakeDns.new(mx: secure_mx, tlsa: tlsa)) { |_h, _p| flunk "must not connect" }

    assert_raises(MailOnRails::OutboundDeliverer::TransientError) { deliverer.deliver(outbound) }
    assert_equal "tlsa-invalid", MailOnRails::TlsRptEvent.sole.result_type
  end

  test "a DANE TLS failure defers, never falls back, and is reported" do
    dns = FakeDns.new(mx: secure_mx, tlsa: usable_tlsa)
    deliverer = deliverer_with(dns) { |_h, _p| raise OpenSSL::SSL::SSLError, "DANE verification failed" }

    assert_raises(MailOnRails::OutboundDeliverer::TransientError) { deliverer.deliver(outbound) }
    event = MailOnRails::TlsRptEvent.sole
    assert_equal [ "tlsa", "validation-failure" ], [ event.policy_type, event.result_type ]
    assert_includes event.failure_detail, "DANE verification failed"
  end

  test "MTA-STS enforce delivers only to policy-matched MX hosts" do
    enforce_policy!
    mx = { "remote.test" => Answer.new(
      records: [ [ 5, "evil.interceptor.test" ], [ 10, "mx.remote.test" ] ], secure: false) }
    tried = []
    deliverer = deliverer_with(FakeDns.new(mx: mx)) do |host, policy|
      tried << [ host, policy.mode ]
      true
    end

    assert deliverer.deliver(outbound)
    assert_equal [ [ "mx.remote.test", :sts_enforce ] ], tried
    assert_equal [ "sts", nil ], [ MailOnRails::TlsRptEvent.sole.policy_type, MailOnRails::TlsRptEvent.sole.result_type ]
  end

  test "MTA-STS enforce with no matching MX defers and reports" do
    enforce_policy!(mx_patterns: [ "other.remote.test" ])
    deliverer = deliverer_with(FakeDns.new(mx: secure_mx)) { |_h, _p| flunk "must not connect" }

    assert_raises(MailOnRails::OutboundDeliverer::TransientError) { deliverer.deliver(outbound) }
    event = MailOnRails::TlsRptEvent.sole
    assert_equal [ "sts", "validation-failure" ], [ event.policy_type, event.result_type ]
  end

  test "a testing-mode policy observes but does not filter" do
    enforce_policy!(mx_patterns: [ "other.remote.test" ]).update!(mode: "testing")
    deliverer = deliverer_with(FakeDns.new(mx: secure_mx)) do |_host, policy|
      assert_equal :opportunistic, policy.mode
      true
    end

    assert deliverer.deliver(outbound)
    assert_equal [ "sts", nil ], [ MailOnRails::TlsRptEvent.sole.policy_type, MailOnRails::TlsRptEvent.sole.result_type ]
  end

  test "DANE takes precedence over MTA-STS for a host under both" do
    enforce_policy!
    deliverer = deliverer_with(FakeDns.new(mx: secure_mx, tlsa: usable_tlsa)) do |_host, policy|
      assert_equal :dane, policy.mode
      true
    end

    assert deliverer.deliver(outbound)
    assert_equal %w[sts tlsa], MailOnRails::TlsRptEvent.pluck(:policy_type).sort, "success counts under both policies"
  end

  test "a server refusing STARTTLS under a TLS-requiring policy reports starttls-not-supported" do
    enforce_policy!
    fake_smtp = Object.new
    def fake_smtp.open_timeout=(_v); end
    def fake_smtp.read_timeout=(_v); end
    def fake_smtp.start(**) = raise(Net::SMTPUnsupportedCommand, "STARTTLS is not supported on this server")

    deliverer = MailOnRails::OutboundDeliverer.new(dns: FakeDns.new(mx: secure_mx))
    deliverer.define_singleton_method(:build_smtp) { |_h, _p, _policy| fake_smtp }

    assert_raises(MailOnRails::OutboundDeliverer::TransientError) { deliverer.deliver(outbound) }
    event = MailOnRails::TlsRptEvent.sole
    assert_equal "starttls-not-supported", event.result_type
  end

  # Microsoft's block-list rejection: 550 at MAIL FROM, then the
  # connection is slammed shut, so QUIT raises. net-smtp runs QUIT in an
  # ensure, where the read error would replace the in-flight 550 - the
  # queue then saw "SSL_read: unexpected eof" and retried a rejection
  # that will never change. send_via must surface the 550.
  test "a 5xx followed by a slammed connection surfaces the rejection, not the QUIT error" do
    fake_smtp = Object.new
    def fake_smtp.open_timeout=(_v); end
    def fake_smtp.read_timeout=(_v); end
    def fake_smtp.start(**) = self
    def fake_smtp.capabilities = {}
    def fake_smtp.send_message(*) = raise(Net::SMTPFatalError, "550 5.7.1 [203.0.113.9] is on our block list (S3150)")
    def fake_smtp.finish = raise(OpenSSL::SSL::SSLError, "SSL_read: unexpected eof while reading")

    deliverer = MailOnRails::OutboundDeliverer.new(dns: FakeDns.new)
    deliverer.define_singleton_method(:build_smtp) { |_h, _p, _policy| fake_smtp }

    error = assert_raises(MailOnRails::OutboundDeliverer::PermanentError) { deliverer.deliver(outbound) }
    assert_match(/550 5\.7\.1/, error.message)
  end

  test "a QUIT failure after the message was accepted still counts as delivered" do
    fake_smtp = Object.new
    def fake_smtp.open_timeout=(_v); end
    def fake_smtp.read_timeout=(_v); end
    def fake_smtp.start(**) = self
    def fake_smtp.capabilities = {}
    def fake_smtp.send_message(*) = true
    def fake_smtp.finish = raise(OpenSSL::SSL::SSLError, "SSL_read: unexpected eof while reading")

    deliverer = MailOnRails::OutboundDeliverer.new(dns: FakeDns.new)
    deliverer.define_singleton_method(:build_smtp) { |_h, _p, _policy| fake_smtp }

    assert deliverer.deliver(outbound), "an accepted message must not be re-sent because QUIT failed"
  end

  test "build_smtp wires the right client per policy mode" do
    dane = @deliverer.send(:build_smtp, "mx.remote.test", 25,
                           MailOnRails::OutboundDeliverer::HostPolicy.new(mode: :dane, tlsa_records: [ :r ]))
    assert_instance_of MailOnRails::OutboundDeliverer::DaneSmtp, dane
    assert_equal [ :r ], dane.dane_records
    assert_equal "mx.remote.test", dane.dane_hostname

    sts = @deliverer.send(:build_smtp, "mx.remote.test", 25,
                          MailOnRails::OutboundDeliverer::HostPolicy.new(mode: :sts_enforce))
    assert_instance_of Net::SMTP, sts

    plain = @deliverer.send(:build_smtp, "mx.remote.test", 25,
                            MailOnRails::OutboundDeliverer::HostPolicy.new(mode: :opportunistic))
    assert_instance_of Net::SMTP, plain
    assert plain.starttls_always?,
           "verified STARTTLS is the default even on the opportunistic tier"
  end

  # The soak posture: opting out of verified outbound TLS downgrades the
  # opportunistic tier to offered-but-not-required STARTTLS.
  test "SMTP_OUTBOUND_REQUIRE_VERIFIED_TLS=0 makes opportunistic delivery merely offer STARTTLS" do
    policy = MailOnRails::OutboundDeliverer::HostPolicy.new(mode: :opportunistic)
    MailOnRails::Setting.write(:smtp_outbound_require_verified_tls, "0")

    smtp = @deliverer.send(:build_smtp, "mx.remote.test", 25, policy)
    assert smtp.starttls_auto?, "the opt-out must offer, not require, STARTTLS"
    assert_not smtp.starttls_always?
  ensure
    MailOnRails::Setting.where(key: "smtp_outbound_require_verified_tls").delete_all
  end

  # M4: smarthost AUTH credentials must be able to ride verified transport
  # instead of the opportunistic default.
  test "the smarthost transport mode is chosen from MAIL_ON_RAILS_SMARTHOST_TLS" do
    {
      "opportunistic" => :opportunistic,
      "starttls" => :smarthost_starttls,
      "smtps" => :smarthost_smtps
    }.each do |setting, expected_mode|
      with_env("MAIL_ON_RAILS_SMARTHOST" => "relay.test:587", "MAIL_ON_RAILS_SMARTHOST_TLS" => setting) do
        captured = nil
        deliverer = deliverer_with(FakeDns.new) { |_host, policy| captured = policy }
        assert deliverer.deliver(outbound)
        assert_equal expected_mode, captured.mode, "smarthost_tls=#{setting}"
      end
    end
  end

  # AUTH must never ride a transport that skips certificate verification:
  # opportunistic mode gets no credentials once verified TLS is opted out;
  # the verified modes (and the enforcing default) keep them.
  test "smarthost credentials are withheld on an unverified transport" do
    with_env("MAIL_ON_RAILS_SMARTHOST_USER" => "relay-user",
             "MAIL_ON_RAILS_SMARTHOST_PASSWORD" => "relay-secret") do
      MailOnRails::Setting.write(:smtp_outbound_require_verified_tls, "0")
      warnings = capture_warnings do
        assert_equal({}, @deliverer.send(:smarthost_auth, :opportunistic))
      end
      assert_match(/AUTH withheld/, warnings)

      assert_equal "relay-user", @deliverer.send(:smarthost_auth, :smarthost_starttls)[:user]
      assert_equal "relay-user", @deliverer.send(:smarthost_auth, :smarthost_smtps)[:user]
    ensure
      MailOnRails::Setting.where(key: "smtp_outbound_require_verified_tls").delete_all
    end
  end

  test "the default verified outbound TLS makes opportunistic mode safe for smarthost credentials" do
    with_env("MAIL_ON_RAILS_SMARTHOST_USER" => "relay-user",
             "MAIL_ON_RAILS_SMARTHOST_PASSWORD" => "relay-secret") do
      assert_equal "relay-user", @deliverer.send(:smarthost_auth, :opportunistic)[:user]
    end
  end

  # --- REQUIRETLS / TLS-Required: No / DSN relay / SIZE ---
  #
  # A canned SMTP session whose EHLO capabilities the test chooses;
  # records what send_message was given so envelope parameters can be
  # asserted.
  class FakeSession
    attr_reader :sent

    def initialize(capabilities: {})
      @capabilities = capabilities
      @sent = []
    end

    def open_timeout=(_v); end
    def read_timeout=(_v); end
    def start(**) = self
    def capabilities = @capabilities
    def capable?(key) = @capabilities.key?(key) ? true : nil
    def finish = nil

    def send_message(data, from, *rcpts)
      @sent << { data: data, from: from, rcpts: rcpts }
      true
    end
  end

  def deliverer_with_session(session, dns: FakeDns.new, modes: [])
    deliverer = MailOnRails::OutboundDeliverer.new(dns: dns)
    deliverer.define_singleton_method(:build_smtp) do |_h, _p, policy|
      modes << policy.mode
      session
    end
    deliverer
  end

  test "REQUIRETLS upgrades the transport and rides the envelope when the hop advertises it" do
    session = FakeSession.new(capabilities: { "REQUIRETLS" => [] })
    modes = []
    deliverer = deliverer_with_session(session, modes: modes)

    assert_equal :delivered, deliverer.deliver(outbound(requiretls: true))
    assert_equal [ :requiretls ], modes, "the opportunistic tier must be upgraded to verified TLS"
    from = session.sent.sole[:from]
    assert_kind_of Net::SMTP::Address, from
    assert_includes from.parameters, "REQUIRETLS"
  end

  test "REQUIRETLS bounces permanently when no server supports it" do
    session = FakeSession.new # no REQUIRETLS capability
    error = assert_raises(MailOnRails::OutboundDeliverer::PermanentError) do
      deliverer_with_session(session).deliver(outbound(requiretls: true))
    end
    assert_match(/5\.7\.30/, error.message)
    assert_empty session.sent, "the message must never be transmitted to a non-supporting hop"
  end

  test "REQUIRETLS defers on a smarthost that does not advertise it" do
    with_env("MAIL_ON_RAILS_SMARTHOST" => "relay.internal:2525") do
      error = assert_raises(MailOnRails::OutboundDeliverer::TransientError) do
        deliverer_with_session(FakeSession.new).deliver(outbound(requiretls: true))
      end
      assert_match(/REQUIRETLS/, error.message)
    end
  end

  test "TLS-Required: No skips MTA-STS enforcement and rides plain opportunistic TLS" do
    enforce_policy!(mx_patterns: [ "no-such-mx.test" ]) # would filter out every host
    session = FakeSession.new
    modes = []
    deliverer = deliverer_with_session(session, dns: FakeDns.new(mx: secure_mx), modes: modes)

    assert_equal :delivered, deliverer.deliver(outbound(extra_headers: "TLS-Required: No\r\n"))
    assert_equal [ :relaxed ], modes
    assert_equal 1, session.sent.size
  end

  test "the REQUIRETLS envelope beats a TLS-Required: No header" do
    session = FakeSession.new(capabilities: { "REQUIRETLS" => [] })
    modes = []
    deliverer = deliverer_with_session(session, modes: modes)

    deliverer.deliver(outbound(requiretls: true, extra_headers: "TLS-Required: No\r\n"))
    assert_equal [ :requiretls ], modes
  end

  test "DSN requests are forwarded when the next hop advertises DSN" do
    session = FakeSession.new(capabilities: { "DSN" => [] })
    message = outbound(requiretls: false, dsn_ret: "FULL", dsn_envid: "QQ314159",
                       dsn_notify: "SUCCESS,FAILURE", dsn_orcpt: "rfc822;rcpt@remote.test")

    assert_equal :propagated_dsn, deliverer_with_session(session).deliver(message)
    sent = session.sent.sole
    assert_equal [ "RET=FULL", "ENVID=QQ314159" ], sent[:from].parameters
    rcpt = sent[:rcpts].sole
    assert_kind_of Net::SMTP::Address, rcpt
    assert_equal [ "NOTIFY=SUCCESS,FAILURE", "ORCPT=rfc822;rcpt@remote.test" ], rcpt.parameters
  end

  test "DSN requests stay local when the next hop lacks DSN" do
    session = FakeSession.new
    message = outbound(dsn_notify: "SUCCESS")

    assert_equal :delivered, deliverer_with_session(session).deliver(message)
    sent = session.sent.sole
    assert_equal message.mail_from, sent[:from], "no ESMTP parameters may reach a non-DSN hop"
    assert_equal [ message.recipient ], sent[:rcpts]
  end

  test "a message over the server's advertised SIZE fails permanently before the transfer" do
    session = FakeSession.new(capabilities: { "SIZE" => [ "10" ] })
    error = assert_raises(MailOnRails::OutboundDeliverer::PermanentError) do
      deliverer_with_session(session).deliver(outbound)
    end
    assert_match(/SIZE/, error.message)
    assert_empty session.sent
  end

  def with_env(pairs)
    saved = pairs.keys.index_with { |k| ENV.key?(k) ? ENV[k] : :unset }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v == :unset ? ENV.delete(k) : ENV[k] = v }
  end
end
