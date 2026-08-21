require "test_helper"

# The MTA-STS sending side (RFC 8461): TXT discovery, HTTPS policy
# parsing, the DB cache that keeps a policy in force for max_age, and MX
# pattern matching.
class MtaStsPolicyTest < ActiveSupport::TestCase
  # Hash-backed stand-in for the SenderAuth Dns client (same seam the
  # verifier tests use); TempError-on-demand via :temperror.
  class FakeDns
    def initialize(txt = {})
      @txt = txt
    end

    def txt(name)
      value = @txt.fetch(name, [])
      raise MailOnRails::SenderAuth::Dns::TempError, "boom" if value == :temperror

      value
    end
  end

  VALID_BODY = "version: STSv1\nmode: enforce\nmx: mx1.example.com\nmx: *.backup.example.com\nmax_age: 86400\n".freeze

  def with_policy_body(result)
    singleton = MailOnRails::MtaStsPolicy.singleton_class
    original = MailOnRails::MtaStsPolicy.method(:fetch_policy_body)
    singleton.define_method(:fetch_policy_body) do |_domain|
      raise MailOnRails::MtaStsPolicy::FetchError, "unreachable" if result == :error

      result
    end
    yield
  ensure
    singleton.define_method(:fetch_policy_body, original)
  end

  def sts_txt(id) = { "_mta-sts.example.com" => [ "v=STSv1; id=#{id}" ] }

  # Pin the SSRF guard's answer so fetch tests never touch real DNS.
  def with_routable_ip(ip = "203.0.114.10")
    singleton = MailOnRails::MtaStsPolicy.singleton_class
    original = MailOnRails::MtaStsPolicy.method(:routable_policy_ip)
    singleton.define_method(:routable_policy_ip) { |_host| ip }
    yield
  ensure
    singleton.define_method(:routable_policy_ip, original)
  end

  # Pin what the policy host resolves to (real Addrinfo objects, no network).
  def with_resolved_addresses(addresses)
    singleton = Addrinfo.singleton_class
    original = Addrinfo.method(:getaddrinfo)
    singleton.define_method(:getaddrinfo) do |*_args|
      addresses.map { |address| Addrinfo.tcp(address, 443) }
    end
    yield
  ensure
    singleton.define_method(:getaddrinfo, original)
  end

  test "parse reads a policy and rejects garbage" do
    fields = MailOnRails::MtaStsPolicy.parse(VALID_BODY)
    assert_equal "enforce", fields[:mode]
    assert_equal 86_400, fields[:max_age]
    assert_equal [ "mx1.example.com", "*.backup.example.com" ], fields[:mx]

    assert_raises(MailOnRails::MtaStsPolicy::FetchError) { MailOnRails::MtaStsPolicy.parse("version: STSv2\nmode: enforce\nmax_age: 1") }
    assert_raises(MailOnRails::MtaStsPolicy::FetchError) { MailOnRails::MtaStsPolicy.parse("version: STSv1\nmode: sideways\nmax_age: 1") }
    assert_raises(MailOnRails::MtaStsPolicy::FetchError) { MailOnRails::MtaStsPolicy.parse("version: STSv1\nmode: enforce\nmax_age: 0\nmx: a") }
    assert_raises(MailOnRails::MtaStsPolicy::FetchError) { MailOnRails::MtaStsPolicy.parse("version: STSv1\nmode: enforce\nmax_age: 60") }
  end

  test "a first lookup fetches and caches the policy" do
    lookup = with_policy_body(VALID_BODY) do
      MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123")))
    end

    assert lookup.policy.enforce?
    assert_not lookup.fetch_error
    assert_equal "abc123", MailOnRails::MtaStsPolicy.find_by(domain: "example.com").sts_id
  end

  test "an unchanged id is served from cache without fetching" do
    with_policy_body(VALID_BODY) { MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123"))) }

    lookup = with_policy_body(:error) do
      MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123")))
    end
    assert lookup.policy.enforce?, "cache must serve without a fetch"
    assert_not lookup.fetch_error
  end

  test "a changed id refetches" do
    with_policy_body(VALID_BODY) { MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123"))) }

    body = VALID_BODY.sub("enforce", "testing")
    lookup = with_policy_body(body) do
      MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("def456")))
    end
    assert_equal "testing", lookup.policy.mode
    assert_equal "def456", lookup.policy.sts_id
  end

  test "a failed refetch keeps the valid cached policy but flags the fetch error" do
    with_policy_body(VALID_BODY) { MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123"))) }

    lookup = with_policy_body(:error) do
      MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("def456")))
    end
    assert lookup.policy.enforce?, "RFC 8461: the cached policy stays in force"
    assert lookup.fetch_error
  end

  test "a vanished TXT record does not drop a still-valid cached policy" do
    with_policy_body(VALID_BODY) { MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123"))) }

    lookup = MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new)
    assert lookup.policy.enforce?, "a DNS-blocking attacker must not downgrade a known domain"
  end

  test "an expired cache with no reachable policy yields none" do
    with_policy_body(VALID_BODY) { MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123"))) }

    travel(2.days) do
      lookup = with_policy_body(:error) do
        MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123")))
      end
      assert_nil lookup.policy
      assert lookup.fetch_error
    end
  end

  test "resolver trouble serves the cache and flags nothing" do
    with_policy_body(VALID_BODY) { MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new(sts_txt("abc123"))) }

    lookup = MailOnRails::MtaStsPolicy.lookup("example.com", dns: FakeDns.new("_mta-sts.example.com" => :temperror))
    assert lookup.policy.enforce?
    assert_not lookup.fetch_error
  end

  test "multiple STSv1 TXT records read as no policy advertised" do
    dns = FakeDns.new("_mta-sts.example.com" => [ "v=STSv1; id=a", "v=STSv1; id=b" ])
    assert_nil MailOnRails::MtaStsPolicy.lookup("example.com", dns: dns).policy
  end

  test "mx_match? does exact and single-label wildcard matching" do
    policy = MailOnRails::MtaStsPolicy.new(mx_patterns: [ "mx1.example.com", "*.backup.example.com" ])

    assert policy.mx_match?("mx1.example.com")
    assert policy.mx_match?("MX1.EXAMPLE.COM.")
    assert policy.mx_match?("a.backup.example.com")
    assert_not policy.mx_match?("backup.example.com"), "wildcard needs exactly one extra label"
    assert_not policy.mx_match?("a.b.backup.example.com"), "wildcard matches only one label"
    assert_not policy.mx_match?("evil.com")
  end

  # A hostile mta-sts.<domain> (an attacker's own recipient domain, valid
  # cert and all) must not be able to stream an unbounded body into a
  # delivery worker: fetch_policy_body reads in chunks and aborts the moment
  # the running total crosses MAX_POLICY_BYTES, rather than buffering the
  # whole response before checking its size.
  test "an oversized policy body is aborted mid-stream, not buffered whole" do
    chunks_yielded = 0
    fake_response = Object.new
    fake_response.define_singleton_method(:is_a?) { |klass| klass == Net::HTTPOK }
    fake_response.define_singleton_method(:read_body) do |&blk|
      loop do
        chunks_yielded += 1
        raise "read streamed past the cap (#{chunks_yielded} chunks)" if chunks_yielded > 100
        blk.call("x" * 16_384)
      end
    end

    fake_http = Object.new
    %i[use_ssl= ipaddr= open_timeout= read_timeout= max_retries=].each do |setter|
      fake_http.define_singleton_method(setter) { |_| }
    end
    fake_http.define_singleton_method(:request_get) { |_path, &blk| blk.call(fake_response) }

    original = Net::HTTP.method(:new)
    Net::HTTP.singleton_class.define_method(:new) { |*_args| fake_http }
    begin
      error = with_routable_ip do
        assert_raises(MailOnRails::MtaStsPolicy::FetchError) { MailOnRails::MtaStsPolicy.fetch_policy_body("example.com") }
      end
      assert_match(/too large/, error.message)
    ensure
      Net::HTTP.singleton_class.define_method(:new, original)
    end

    max_chunks = (MailOnRails::MtaStsPolicy::MAX_POLICY_BYTES / 16_384) + 2
    assert_operator chunks_yielded, :<=, max_chunks,
      "the read must abort near the cap, not stream unboundedly"
  end

  # mta-sts.<domain> is attacker-controlled DNS running on the delivery
  # worker's network position, so the fetch must refuse policy hosts that
  # resolve into private/link-local/loopback space instead of handing the
  # attacker a blind internal connect primitive.
  test "a policy host resolving into non-routable space is refused" do
    %w[10.0.0.1 127.0.0.1 169.254.169.254 172.16.0.9 192.168.1.1 ::1 fe80::1 fc00::1].each do |address|
      error = with_resolved_addresses([ address ]) do
        assert_raises(MailOnRails::MtaStsPolicy::FetchError) do
          MailOnRails::MtaStsPolicy.routable_policy_ip("mta-sts.example.com")
        end
      end
      assert_match(/non-routable/, error.message, address)
    end
  end

  test "a mixed public and private RRset is refused outright, not tie-broken" do
    with_resolved_addresses([ "203.0.114.10", "10.0.0.1" ]) do
      assert_raises(MailOnRails::MtaStsPolicy::FetchError) do
        MailOnRails::MtaStsPolicy.routable_policy_ip("mta-sts.example.com")
      end
    end
  end

  test "a globally-routable policy host pins to its first resolved address" do
    with_resolved_addresses([ "203.0.114.10", "2606:4700::1111" ]) do
      assert_equal "203.0.114.10", MailOnRails::MtaStsPolicy.routable_policy_ip("mta-sts.example.com")
    end
  end
end
