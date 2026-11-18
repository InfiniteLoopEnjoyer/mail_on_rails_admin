require "test_helper"
require "mail_on_rails/clamav_scanner"
require "mail_on_rails/rspamd_analyzer"
require "mail_on_rails/ingress_seal"
require_relative "../test_helpers/clamav_stub_helper"
require_relative "../test_helpers/rspamd_stub_helper"
require_relative "../test_helpers/sealed_ingress_helper"

# Where the mailroom reads the connection facts from (2026-11-17 audit, H1).
#
# The edge strips forged trusted headers and prepends its own; the seal
# covers the result. The strip has had to learn, twice now, a new way a
# parser can be talked into seeing a header the strip did not (a lone CR,
# then VT/FF before the colon - the Mail gem ends a name with rstrip). So
# the mailroom no longer asks the Mail gem for these fields at all: it
# reads them from the block of lines the edge wrote at the very top, in
# the edge's own spelling, and stops at the first line that is anything
# else. A copy further down - however it got there, however it is spelled
# - is never read.
class MailroomEdgeHeadersTest < ActionMailbox::TestCase
  include ActiveJob::TestHelper
  include ClamavStubHelper
  include RspamdStubHelper
  include SealedIngressHelper

  CLEAN = MailOnRails::ClamavScanner::Result.new(:clean, nil)

  setup do
    @addressed = MailOnRails::EmailAccount.create!(email: "addressed@example.test", password: "pw-123456")
    @victim = MailOnRails::EmailAccount.create!(email: "victim@example.test", password: "pw-123456")
  end

  # What the edge prepends (Store::SmtpBackend#stamp), then +rest+ exactly
  # as given - i.e. as if the strip had let it through.
  def stamped(rest, authenticated: "no")
    [ "Return-Path: <sender@remote.test>",
      "X-Original-To: addressed@example.test",
      "X-MailOnRails-Authenticated: #{authenticated}",
      "X-MailOnRails-Client-Ip: 203.0.113.9",
      "X-MailOnRails-Helo: mx.remote.test" ].join("\r\n") + "\r\n" + rest
  end

  MESSAGE = "Received: from mx.remote.test ([203.0.113.9])\r\n\tby mx.example.test with ESMTPS; Tue, 17 Nov 2026 10:00:00 +0000\r\n" \
            "Message-ID: <edge-1@remote.test>\r\nFrom: sender@remote.test\r\nTo: addressed@example.test\r\n" \
            "%sSubject: hi\r\n\r\nbody\r\n"

  def pass_verdict
    MailOnRails::RspamdAnalyzer::Result.new(
      status: :ok, action: "no action", score: 0.1, required_score: 6.0,
      spf: "pass", dkim: "pass", dmarc: "pass", auth_results: "mail.test; spf=pass; dkim=pass; dmarc=pass"
    )
  end

  # Delivers +source+ with clamav clean and rspamd recording the facts it
  # was handed; returns those facts.
  def deliver(source)
    facts = nil
    with_scanner(enabled: true, scan: CLEAN) do
      with_rspamd(enabled: true, analyze: ->(_raw, **given) { facts = given; pass_verdict }) do
        receive_inbound_email_from_source(source)
      end
    end
    facts
  end

  def inbox_count(account) = account.inbox.email_messages.count

  # Every spelling the Mail gem files under the trusted name: the strict
  # one, the obs-syntax WSP, and what its rstrip also drops (VT, FF).
  SPELLINGS = [ "", " ", "\t", "\v", "\f", " \v\f" ].freeze

  test "an X-Original-To below the edge's block routes nowhere, however it is spelled" do
    SPELLINGS.each_with_index do |gap, i|
      forged = "X-Original-To#{gap}: victim@example.test\r\n"
      assert_includes Array(Mail.new(stamped(MESSAGE % forged))["X-Original-To"]).map(&:value), "victim@example.test",
                      "fixture: the Mail gem must read #{forged.inspect} as X-Original-To"

      deliver(stamped(MESSAGE % forged).sub("edge-1", "edge-xot-#{i}"))

      assert_equal 0, inbox_count(@victim), "#{forged.inspect} delivered into a mailbox the edge never accepted for"
    end
    assert_equal SPELLINGS.size, inbox_count(@addressed)
  end

  test "a Return-Path below the edge's block never replaces the stamped envelope sender" do
    SPELLINGS.each_with_index do |gap, i|
      forged = "Return-Path#{gap}: <third-party@elsewhere.test>\r\n"
      assert_equal [ "<third-party@elsewhere.test>" ], Array(Mail.new(stamped(MESSAGE % forged))["Return-Path"]).map(&:value),
                   "fixture: the Mail gem must let #{forged.inspect} replace the stamped Return-Path"

      facts = deliver(stamped(MESSAGE % forged).sub("edge-1", "edge-rp-#{i}"))

      assert_equal "sender@remote.test", facts[:mail_from], "rspamd was handed the forged envelope sender (#{forged.inspect})"
    end
  end

  test "the vacation reply goes to the stamped envelope sender, not a forged Return-Path" do
    @addressed.update!(vacation_enabled: true, vacation_body: "Away.")
    forged = "Return-Path\v: <third-party@elsewhere.test>\r\n"

    deliver(stamped(MESSAGE % forged))

    recipients = MailOnRails::SmtpOutboundMessage.pluck(:recipient)
    assert_equal [ "sender@remote.test" ], recipients
  end

  test "client ip, helo and the authenticated flag come from the edge's block only" do
    forged = "X-MailOnRails-Client-Ip\v: 198.51.100.66\r\nX-MailOnRails-Helo\f: trusted.example\r\n" \
             "X-MailOnRails-Authenticated : admin@example.test\r\n"

    facts = deliver(stamped(MESSAGE % forged))

    assert_equal "203.0.113.9", facts[:ip]
    assert_equal "mx.remote.test", facts[:helo]
    assert_equal "addressed@example.test", facts[:rcpt]
    assert_nil @addressed.inbox.email_messages.sole.authenticated_as
  end

  # stamp writes one physical line per fact. A WSP line directly under the
  # block would be a continuation of its last header to a parser
  # ("...Authenticated: no" + " admin@example.test"); the mailroom reads
  # lines, so it reads "no".
  test "a continuation line under the block does not extend the last stamped value" do
    source = [ "Return-Path: <sender@remote.test>", "X-Original-To: addressed@example.test",
               "X-MailOnRails-Authenticated: no" ].join("\r\n") + "\r\n admin@example.test\r\n" + (MESSAGE % "")
    assert_equal "no admin@example.test", Mail.new(source)["X-MailOnRails-Authenticated"].value, "fixture"

    facts = deliver(source)

    assert facts, "an unauthenticated message must still be analyzed"
    assert_nil @addressed.inbox.email_messages.sole.authenticated_as
  end

  test "several stamped recipients are all read, and the authenticated identity as stamped" do
    source = [ "Return-Path: <addressed@example.test>", "X-Original-To: addressed@example.test",
               "X-Original-To: victim@example.test", "X-MailOnRails-Authenticated: addressed@example.test" ]
             .join("\r\n") + "\r\n" + (MESSAGE % "")

    with_scanner(enabled: true, scan: CLEAN) do
      with_rspamd(enabled: true, analyze: ->(*) { raise "rspamd must not run for an authenticated submitter" }) do
        receive_inbound_email_from_source(source)
      end
    end

    assert_equal 1, inbox_count(@addressed)
    assert_equal 1, inbox_count(@victim)
    assert_equal "addressed@example.test", @victim.inbox.email_messages.sole.authenticated_as
  end

  # The stored message keeps the edge's block at its top, so a job that
  # reads the facts back later (bounce ingestion reads X-Original-To) can
  # use the same reader and get the same answer.
  test "edge_headers reads a stored message's block the same way" do
    forged = "X-Original-To\v: victim@example.test\r\nReturn-Path\f: <third-party@elsewhere.test>\r\n"
    deliver(stamped(MESSAGE % forged))

    facts = MailOnRails::MailroomMailbox.edge_headers(@addressed.inbox.email_messages.sole.raw)

    assert_equal [ "addressed@example.test" ], facts["x-original-to"]
    assert_equal [ "<sender@remote.test>" ], facts["return-path"]
    assert_equal [ "no" ], facts["x-mailonrails-authenticated"]
    assert_equal [], facts["x-mailonrails-nope"]
    assert_equal({}, MailOnRails::MailroomMailbox.edge_headers("From: a@b.test\r\nX-Original-To: x@y.test\r\n\r\n"))
  end

  # The whole chain, from the bytes a port-25 client sends: the edge's own
  # stamp, seal and strip, then the mailroom (the audit's end-to-end PoC).
  test "end to end: VT/FF-spelled trusted headers in DATA reach nobody they were not addressed to" do
    [ "\v", "\f" ].each_with_index do |gap, i|
      wire = "From: spam@attacker.test\r\nTo: whoever@example.test\r\nMessage-ID: <vt-#{i}@attacker.test>\r\n" \
             "X-Original-To#{gap}: victim@example.test\r\nReturn-Path#{gap}: <third-party@elsewhere.test>\r\n" \
             "Subject: vt poc\r\n\r\nbody\r\n"
      source = MailOnRails::Store::SmtpBackend.new.send(
        :stamp, wire, mail_from: "spam@attacker.test", rcpt_to: [ "addressed@example.test" ],
                      authenticated_as: nil, client_ip: "203.0.113.9", helo: "attacker.test"
      )
      facts = nil
      with_scanner(enabled: true, scan: CLEAN) do
        with_rspamd(enabled: true, analyze: ->(_raw, **given) { facts = given; pass_verdict }) do
          receive_inbound_email_from_source(source, seal: false) # stamp sealed it already
        end
      end

      assert_equal 0, inbox_count(@victim), "gap #{gap.inspect}"
      assert_equal "spam@attacker.test", facts[:mail_from], "gap #{gap.inspect}"
    end
    assert_equal 2, inbox_count(@addressed)
  end
end
