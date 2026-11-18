require "test_helper"
require "mail_on_rails/clamav_scanner"
require "mail_on_rails/rspamd_analyzer"
require_relative "../test_helpers/clamav_stub_helper"
require_relative "../test_helpers/rspamd_stub_helper"
require_relative "../test_helpers/sealed_ingress_helper"

# BIMI evaluation is driven by delivery (2026-11-17 audit, L3). It queries
# the sender's DNS and fetches a logo the sender hosts, so it must happen
# because mail arrived - which the sender knows - and never because the
# recipient opened a message, which they must not learn. The mailroom
# queues it while filing; BimiIndicator.for_message, which the message
# view calls, only reads the cache.
class MailroomBimiRefreshTest < ActionMailbox::TestCase
  include ActiveJob::TestHelper
  include ClamavStubHelper
  include RspamdStubHelper
  include SealedIngressHelper

  CLEAN = MailOnRails::ClamavScanner::Result.new(:clean, nil)
  SVG = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>)

  setup do
    @a = MailOnRails::EmailAccount.create!(email: "a@example.test", password: "pw-123456")
    @b = MailOnRails::EmailAccount.create!(email: "b@example.test", password: "pw-123456")
  end

  def source(message_id: "<bimi-1@brand.test>", from: "news@brand.test")
    [ "Return-Path: <bounce@brand.test>", "X-Original-To: a@example.test", "X-Original-To: b@example.test",
      "X-MailOnRails-Authenticated: no", "X-MailOnRails-Client-Ip: 203.0.113.9",
      "Message-ID: #{message_id}", "From: #{from}", "To: a@example.test", "Subject: hi" ].join("\r\n") + "\r\n\r\nbody\r\n"
  end

  def verdict(dmarc:, action: "no action", score: 0.1)
    MailOnRails::RspamdAnalyzer::Result.new(
      status: :ok, action: action, score: score, required_score: 6.0,
      spf: "pass", dkim: "pass", dmarc: dmarc, auth_results: "mail.test; spf=pass; dkim=pass; dmarc=#{dmarc}"
    )
  end

  def deliver(raw, result)
    with_scanner(enabled: true, scan: CLEAN) do
      with_rspamd(enabled: true, analyze: result) { receive_inbound_email_from_source(raw) }
    end
  end

  def bimi_jobs
    enqueued_jobs.select { |job| job["job_class"] == "MailOnRails::RefreshBimiIndicatorJob" }
  end

  test "delivering DMARC-passing mail queues the sender domain's evaluation once per message" do
    deliver(source, verdict(dmarc: "pass"))

    assert_equal 1, @a.inbox.email_messages.count
    assert_equal 1, @b.inbox.email_messages.count
    assert_equal [ [ "brand.test" ] ], bimi_jobs.map { |job| job["arguments"] }, "two recipients, one lookup"
  end

  test "a fresh indicator is not looked up again, a day-old one is" do
    row = MailOnRails::BimiIndicator.create!(domain: "brand.test", status: "pass", svg: SVG, checked_at: 1.hour.ago)
    deliver(source, verdict(dmarc: "pass"))
    assert_empty bimi_jobs

    row.update!(checked_at: 2.days.ago)
    deliver(source(message_id: "<bimi-2@brand.test>"), verdict(dmarc: "pass"))
    assert_equal 1, bimi_jobs.size
  end

  test "mail that failed DMARC, and mail filed while BIMI is off, queues nothing" do
    deliver(source, verdict(dmarc: "fail"))
    assert_empty bimi_jobs
    assert_equal 0, MailOnRails::BimiIndicator.count

    MailOnRails::Settings.overrides = { bimi: false }
    deliver(source(message_id: "<bimi-3@brand.test>"), verdict(dmarc: "pass"))
    assert_empty bimi_jobs
  ensure
    MailOnRails::Settings.reset!
  end

  test "junk-filed mail that passed DMARC is still evaluated: the reader can open it there" do
    deliver(source, verdict(dmarc: "pass", action: "add header", score: 12.0))

    assert_equal 1, @a.junk_mailbox.email_messages.count
    assert_equal 1, bimi_jobs.size
  end

  # The view-facing call, against real stored messages.
  test "showing a message reads the cache and never queues or creates anything" do
    deliver(source, verdict(dmarc: "pass"))
    message = @a.inbox.email_messages.sole
    clear_enqueued_jobs

    assert_nil MailOnRails::BimiIndicator.for_message(message), "pending: nothing to show yet"
    MailOnRails::BimiIndicator.find_by!(domain: "brand.test").update!(status: "pass", svg: SVG, checked_at: 5.days.ago)
    assert_equal "brand.test", MailOnRails::BimiIndicator.for_message(message).domain, "a stale logo still shows"

    other = MailOnRails::EmailMessage.deliver_raw(@a.inbox, "From: x@never-seen.test\r\nSubject: s\r\n\r\nb\r\n",
                                                  auth_results: "mail.test; dmarc=pass")
    assert_nil MailOnRails::BimiIndicator.for_message(other)

    assert_empty bimi_jobs, "viewing must not trigger a lookup at the sender's DNS"
    assert_equal [ "brand.test" ], MailOnRails::BimiIndicator.pluck(:domain)
  end

  test "a BIMI failure never costs the delivery" do
    singleton = MailOnRails::BimiIndicator.singleton_class
    original = MailOnRails::BimiIndicator.method(:refresh_later_for)
    singleton.define_method(:refresh_later_for) { |_message| raise "queue adapter down" }
    begin
      inbound = deliver(source, verdict(dmarc: "pass"))
      assert_equal "delivered", inbound.reload.status
      assert_equal 1, @a.inbox.email_messages.count
      assert_equal 1, @b.inbox.email_messages.count
    ensure
      singleton.define_method(:refresh_later_for, original)
    end
  end
end
