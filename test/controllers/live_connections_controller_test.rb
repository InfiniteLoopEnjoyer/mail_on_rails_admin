require "test_helper"
require "mail_on_rails"

class LiveConnectionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  LISTENER = "11111111-1111-4111-8111-111111111111"

  setup do
    sign_in_as users(:one)
  end

  # What a running server projects into the ops tables every sync tick
  # (MailOnRails::Netserv::OpsSync): its listener row, its live
  # connections, its accept-side lockouts. The test process never boots a
  # listener, so the pages read rows seeded here - exactly as they read
  # rows written by the smtp/imap containers in production.
  def listener!(protocol, ports: [ 1025, 1587, 1465 ], max_connections: 100, heartbeat_at: Time.current, ready: true)
    MailOnRails::Listener.create!(listener_id: LISTENER, protocol: protocol.to_s, pid: 4242, hostname: "mx1",
                                  ports: ports, max_connections: max_connections, ready: ready,
                                  started_at: 1.hour.ago, heartbeat_at: heartbeat_at)
  end

  def connections!(protocol, rows)
    listener!(protocol) unless MailOnRails::Listener.exists?(listener_id: LISTENER)
    MailOnRails::OpenConnection.replace_for!(LISTENER, protocol, rows)
  end

  def lockouts!(protocol, lockouts)
    listener!(protocol) unless MailOnRails::Listener.exists?(listener_id: LISTENER)
    MailOnRails::AcceptLockout.replace_for!(LISTENER, protocol, lockouts)
  end

  test "requires a signed-in user" do
    reset!
    get smtp_path
    assert_redirected_to new_session_path
  end

  test "smtp page explains when no listener has reported in" do
    get smtp_path
    assert_response :success
    assert_select "h1", "SMTP"
    assert_match "No SMTP server is running", response.body
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

  test "imap page explains when no listener has reported in" do
    get imap_path
    assert_response :success
    assert_select "h1", "IMAP"
    assert_match "No IMAP server is running", response.body
  end

  test "a live listener shows its status chip, ports and the connection cap" do
    listener!(:smtp, ports: [ 1025, 1587, 1465 ], max_connections: 250)
    get smtp_path

    assert_response :success
    assert_match "SMTP up", response.body
    assert_match "ports 1025/1587/1465", response.body
    assert_match "mx1", response.body
    assert_match "0 / 250", response.body
  end

  test "a listener whose heartbeat went stale counts as gone" do
    listener!(:smtp, heartbeat_at: 5.minutes.ago)
    connections!(:smtp, [ { connection_id: 1, peer_ip: "203.0.113.9", port: 1025, connected_at: 1.minute.ago } ])
    get smtp_path

    assert_response :success
    assert_match "No SMTP server is running", response.body
    assert_no_match "203.0.113.9", response.body
  end

  test "smtp page lists live connections with ban buttons" do
    connections!(:smtp, [
      { connection_id: 1, protocol: "SMTP", peer_ip: "203.0.113.9", port: 1587, role: :submission,
        connected_at: 2.minutes.ago, user: "carol@example.com", helo: "laptop.lan",
        messages: 3, tls: true }
    ])
    get smtp_path

    assert_response :success
    assert_match "203.0.113.9", response.body
    assert_match "laptop.lan", response.body
    assert_match "carol@example.com", response.body
    assert_match "1 / 100", response.body
    assert_select "form[action=?]", banned_ips_path
    # the ban must come back to this page, not the auth attempts index
    assert_select "input[name=origin][value=smtp]"
  end

  test "imap page lists live connections and their protocol state" do
    connections!(:imap, [
      { connection_id: 1, protocol: "IMAP", peer_ip: "203.0.113.9", port: 1993, role: nil,
        connected_at: 2.minutes.ago, user: "carol@example.com",
        state: "IDLE INBOX", tls: true }
    ])
    get imap_path

    assert_response :success
    assert_match "IDLE INBOX", response.body
    assert_select "input[name=origin][value=imap]"
  end

  test "a tarpitted connection wears its delay as a badge" do
    connections!(:smtp, [
      { connection_id: 1, protocol: "SMTP", peer_ip: "203.0.113.9", port: 1025, role: :mx,
        connected_at: 5.seconds.ago, user: nil, helo: nil, messages: 0,
        tls: false, tarpit: 8.0 }
    ])
    get smtp_path

    assert_response :success
    assert_match "tarpit 8s", response.body
  end

  test "untarpitted connections show no badge" do
    connections!(:smtp, [
      { connection_id: 1, protocol: "SMTP", peer_ip: "203.0.113.9", port: 1025, role: :mx,
        connected_at: 5.seconds.ago, user: nil, helo: nil, messages: 0,
        tls: false, tarpit: nil }
    ])
    get smtp_path

    assert_response :success
    assert_no_match "tarpit", response.body
  end

  test "locked-out addresses render with their remaining time and a ban button" do
    lockouts!(:imap, { "203.0.113.77" => 240.seconds.from_now })
    get imap_path

    assert_response :success
    assert_select "h2", text: "Locked-out addresses"
    assert_match "203.0.113.77", response.body
    assert_match "4m 0s", response.body
    assert_select "input[name=origin][value=imap]"
  end

  test "omits the locked-out section when nothing is locked" do
    listener!(:imap)
    get imap_path

    assert_response :success
    assert_select "h2", text: "Locked-out addresses", count: 0
  end

  # History is DB-backed, so all of these run without a listener row -
  # which also pins that the history section renders on a web-only boot.
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
    connections!(:imap, [
      { connection_id: 1, protocol: "IMAP", peer_ip: "203.0.113.9", port: 1143, role: nil,
        connected_at: 1.minute.ago, user: nil, state: "pre-auth", tls: false }
    ])
    get imap_path

    assert_response :success
    assert_match "banned", response.body
    assert_select "input[name=origin]", count: 0
  end
end
