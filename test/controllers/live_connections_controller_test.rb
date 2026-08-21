require "test_helper"
require "mail_on_rails"

class LiveConnectionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:one)
  end

  # What MailOnRails::Runtime.server returns when the in-process servers run;
  # the test process never boots them, so the pages get this stand-in.
  class FakeServer
    def initialize(connections, lockouts: {})
      @connections = connections
      @lockouts = lockouts
    end

    attr_reader :connections, :lockouts

    def max_connections = 100
  end

  # Swaps Boot.server for the block's duration (the repo's hand-rolled
  # stubbing convention - minitest/mock is a separate gem under
  # Minitest 6).
  def with_server(server)
    singleton = MailOnRails::Runtime.singleton_class
    original = MailOnRails::Runtime.method(:server)
    singleton.define_method(:server) { |_protocol| server }
    yield
  ensure
    singleton.define_method(:server, original)
  end

  test "requires a signed-in user" do
    reset!
    get smtp_path
    assert_redirected_to new_session_path
  end

  test "smtp page explains when the server is not running in this process" do
    get smtp_path
    assert_response :success
    assert_select "h1", "SMTP"
    assert_match "not running in this process", response.body
  end

  test "the page subscribes to refresh broadcasts and keeps a backstop poll" do
    get smtp_path

    assert_response :success
    # Signed with the exact streamables LiveConnectionsBroadcaster
    # broadcasts to (the gem hands it a Symbol) - a wrong pairing would
    # fail silently in production (signed names never match).
    assert_select "turbo-cable-stream-source[signed-stream-name=?]",
                  Turbo::StreamsChannel.signed_stream_name([ :smtp, :connections ])
    assert_select "[data-controller=poll]"
    # Refreshes only morph + keep scroll if these metas actually render;
    # turbo_refreshes_with can't emit them from this layout (its
    # `provide :head` lands after the layout's `yield :head` already ran),
    # which once shipped scroll-resetting replace visits unnoticed.
    assert_select "meta[name=turbo-refresh-method][content=morph]"
    assert_select "meta[name=turbo-refresh-scroll][content=preserve]"
    # The wide page column (content_for :page_width beats the layout's
    # 4xl default) - four tables need the room.
    assert_match "max-w-[88rem]", response.body
  end

  test "imap page explains when the server is not running in this process" do
    get imap_path
    assert_response :success
    assert_select "h1", "IMAP"
    assert_match "not running in this process", response.body
  end

  test "smtp page lists live connections with ban buttons" do
    server = FakeServer.new([
      { protocol: "SMTP", peer_ip: "203.0.113.9", port: 1587, role: :submission,
        connected_at: 2.minutes.ago, user: "carol@example.com", helo: "laptop.lan",
        messages: 3, tls: true }
    ])
    with_server(server) { get smtp_path }

    assert_response :success
    assert_match "203.0.113.9", response.body
    assert_match "laptop.lan", response.body
    assert_match "carol@example.com", response.body
    assert_select "form[action=?]", banned_ips_path
    # the ban must come back to this page, not the auth attempts index
    assert_select "input[name=origin][value=smtp]"
  end

  test "imap page lists live connections and their protocol state" do
    server = FakeServer.new([
      { protocol: "IMAP", peer_ip: "203.0.113.9", port: 1993, role: nil,
        connected_at: 2.minutes.ago, user: "carol@example.com",
        state: "IDLE INBOX", tls: true }
    ])
    with_server(server) { get imap_path }

    assert_response :success
    assert_match "IDLE INBOX", response.body
    assert_select "input[name=origin][value=imap]"
  end

  test "a tarpitted connection wears its delay as a badge" do
    server = FakeServer.new([
      { protocol: "SMTP", peer_ip: "203.0.113.9", port: 1025, role: :mx,
        connected_at: 5.seconds.ago, user: nil, helo: nil, messages: 0,
        tls: false, tarpit: 8.0 }
    ])
    with_server(server) { get smtp_path }

    assert_response :success
    assert_match "tarpit 8s", response.body
  end

  test "untarpitted connections show no badge" do
    server = FakeServer.new([
      { protocol: "SMTP", peer_ip: "203.0.113.9", port: 1025, role: :mx,
        connected_at: 5.seconds.ago, user: nil, helo: nil, messages: 0,
        tls: false, tarpit: nil }
    ])
    with_server(server) { get smtp_path }

    assert_response :success
    assert_no_match "tarpit", response.body
  end

  test "locked-out addresses render with their remaining time and a ban button" do
    server = FakeServer.new([], lockouts: { "203.0.113.77" => 240.0 })
    with_server(server) { get imap_path }

    assert_response :success
    assert_select "h2", text: "Locked-out addresses"
    assert_match "203.0.113.77", response.body
    assert_match "4m 0s", response.body
    assert_select "input[name=origin][value=imap]"
  end

  test "omits the locked-out section when nothing is locked" do
    server = FakeServer.new([])
    with_server(server) { get imap_path }

    assert_response :success
    assert_select "h2", text: "Locked-out addresses", count: 0
  end

  # History is DB-backed, so all of these run without a live server
  # (Boot.server is nil in the test process) - which also pins that the
  # history section renders on a web-only boot.
  test "history lists the protocol's closed connections in the window" do
    MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "198.51.100.7", port: 1025, role: "mx",
                             username: "carol@example.com", helo: "laptop.lan", messages: 1,
                             tls: true, duration_seconds: 72.5, tarpit_seconds: 4.0, closed_at: 2.hours.ago)
    MailOnRails::ClosedConnection.create!(protocol: "imap", ip: "198.51.100.8", closed_at: 1.hour.ago)
    MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "198.51.100.9", closed_at: 3.days.ago)

    get smtp_path

    assert_response :success
    assert_select "h2", "Recent connections"
    assert_match "198.51.100.7", response.body
    assert_match "laptop.lan", response.body
    assert_match "1m 13s", response.body
    assert_match "4s", response.body # the tarpit column
    assert_no_match "198.51.100.8", response.body # imap row
    assert_no_match "198.51.100.9", response.body # outside 24h window
    assert_select "input[name=origin][value=smtp]"

    get smtp_path(window: "7d")

    assert_match "198.51.100.9", response.body
  end

  test "cached ip attribution renders under addresses; unknown ips get a lookup" do
    MailOnRails::IpEnrichment.create!(ip: "203.0.113.9", looked_up_at: Time.current,
                                      enrichment: { "rdns" => "scanner.evil.example", "asn" => "64496",
                                                    "as_name" => "EVIL-NET", "country" => "ZZ" })
    MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "203.0.113.9", closed_at: 1.hour.ago)
    MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "198.51.100.7", closed_at: 1.hour.ago)

    assert_enqueued_with(job: MailOnRails::IpEnrichmentJob, args: [ "198.51.100.7" ]) do
      get smtp_path
    end

    assert_response :success
    assert_match "scanner.evil.example", response.body
    assert_match "ZZ · AS64496 · EVIL-NET", response.body
  end

  test "top sources totals include collapsed rollups, busiest first" do
    3.times { MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "203.0.113.9", closed_at: 1.hour.ago) }
    MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "203.0.113.9", rollup: true,
                                          connection_count: 120, closed_at: 2.hours.ago)
    MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "198.51.100.7", username: "carol@example.com",
                                          closed_at: 30.minutes.ago)
    MailOnRails::ClosedConnection.create!(protocol: "imap", ip: "198.51.100.9", closed_at: 10.minutes.ago)

    get smtp_path

    assert_response :success
    assert_select "h2", "Top sources"
    assert_match "123", response.body # 3 rows + 120 collapsed
    # busiest address leads the table
    assert response.body.index("203.0.113.9") < response.body.index("198.51.100.7")
    assert_no_match "198.51.100.9", response.body # other protocol
  end

  test "top sources section is omitted with no history" do
    get smtp_path

    assert_response :success
    assert_select "h2", text: "Top sources", count: 0
  end

  test "rollup rows render as one collapsed line" do
    MailOnRails::ClosedConnection.create!(protocol: "imap", ip: "198.51.100.10", rollup: true,
                             connection_count: 61, closed_at: 10.minutes.ago)

    get imap_path

    assert_response :success
    assert_match "61 connections collapsed", response.body
  end

  test "a connection covered by an existing ban shows the badge instead of a button" do
    MailOnRails::BannedIp.create!(cidr: "203.0.113.0/24", note: "test")
    server = FakeServer.new([
      { protocol: "IMAP", peer_ip: "203.0.113.9", port: 1143, role: nil,
        connected_at: 1.minute.ago, user: nil, state: "pre-auth", tls: false }
    ])
    with_server(server) { get imap_path }

    assert_response :success
    assert_match "banned", response.body
    assert_select "input[name=origin]", count: 0
  end
end
