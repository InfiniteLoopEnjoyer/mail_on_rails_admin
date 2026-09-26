require "test_helper"
require "mail_on_rails/clamav_scanner"
require "mail_on_rails/ingress_seal"
require_relative "../test_helpers/clamav_stub_helper"
require_relative "../test_helpers/rspamd_stub_helper"
require_relative "../test_helpers/sealed_ingress_helper"

# End-to-end: mail the Mail gem chokes on must still reach every recipient
# and leave the ActionMailbox::InboundEmail `delivered` (so it gets
# incinerated) - never stuck in `processing` or `failed` for a
# rendering problem. Two shapes from the 2026-09-26 audit: a MIME tree
# thousands of levels deep (SystemStackError inside the routing job, M4)
# and an unparseable To: header (NoMethodError on the raw String the gem
# returns, L1).
class MailroomHostileParseTest < ActionMailbox::TestCase
  include ClamavStubHelper
  include RspamdStubHelper
  include SealedIngressHelper

  CLEAN = MailOnRails::ClamavScanner::Result.new(:clean, nil)

  setup do
    @a = MailOnRails::EmailAccount.create!(email: "a@example.test", password: "pw-123456")
    @b = MailOnRails::EmailAccount.create!(email: "b@example.test", password: "pw-123456")
  end

  def stamped(rest)
    [ "Return-Path: <sender@remote.test>", "X-Original-To: a@example.test", "X-Original-To: b@example.test",
      "X-MailOnRails-Authenticated: no" ].join("\r\n") + "\r\n" + rest
  end

  def nested(depth)
    raw = +"Message-ID: <deep@remote.test>\r\nFrom: x@remote.test\r\nTo: a@example.test\r\nSubject: deep\r\n" \
           "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=b0\r\n\r\n"
    depth.times { |i| raw << "--b#{i}\r\nContent-Type: multipart/mixed; boundary=b#{i + 1}\r\n\r\n" }
    raw << "--b#{depth}\r\nContent-Type: text/plain\r\n\r\nhello\r\n--b#{depth}--\r\n"
    depth.times { |i| raw << "--b#{depth - 1 - i}--\r\n" }
    raw
  end

  def receive(raw)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    inbound = with_scanner(enabled: true, scan: CLEAN) { receive_inbound_email_from_source(raw) }
    [ inbound, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
  end

  test "a depth-5000 MIME tree is delivered to every recipient, opaque, and the inbound email is delivered" do
    inbound, seconds = receive(stamped(nested(5000)))

    assert_equal "delivered", inbound.reload.status
    assert_operator seconds, :<, 2.0, "routing took #{seconds.round(2)}s"
    [ @a, @b ].each do |account|
      message = account.inbox.email_messages.sole
      assert message.mime_too_complex?
      assert_equal "deep", message.subject
      assert_equal "x@remote.test", message.from_address
      assert_equal "", message.body_text
      assert_equal MailOnRails::EmailMessage::TOO_COMPLEX_NOTICE, message.text_body
      assert_nil message.html_body
      assert_equal [], message.attachments
    end
  end

  test "an unparseable To: header delivers to both X-Original-To recipients" do
    raw = stamped("Message-ID: <m1@remote.test>\r\nFrom: x@remote.test\r\nTo: <<<\r\nSubject: hi\r\n\r\nbody\r\n")
    inbound, _seconds = receive(raw)

    assert_equal "delivered", inbound.reload.status
    [ @a, @b ].each do |account|
      message = account.inbox.email_messages.sole
      assert_equal "", message.to_addresses
      assert_equal "x@remote.test", message.from_address
      assert_equal "body", message.body_text.strip
    end
  end

  test "a garbage From: is stored as no sender, not as '<'" do
    raw = stamped("Message-ID: <m2@remote.test>\r\nFrom: <\r\nTo: a@example.test\r\nSubject: hi\r\n\r\nbody\r\n")
    inbound, _seconds = receive(raw)

    assert_equal "delivered", inbound.reload.status
    assert_nil @a.inbox.email_messages.sole.from_address
  end

  test "one recipient's delivery failure is logged and the co-recipient still gets a copy" do
    raw = stamped("Message-ID: <m3@remote.test>\r\nFrom: x@remote.test\r\nTo: a@example.test\r\nSubject: hi\r\n\r\nbody\r\n")
    original = MailOnRails::EmailMessage.method(:deliver_raw)
    failing_account_id = @a.id # the stub's self is the EmailMessage class, not this test
    MailOnRails::EmailMessage.define_singleton_method(:deliver_raw) do |mailbox, *args, **kwargs|
      raise SystemStackError, "stack level too deep" if mailbox.email_account_id == failing_account_id

      original.call(mailbox, *args, **kwargs)
    end
    begin
      inbound, _seconds = receive(raw)
    ensure
      MailOnRails::EmailMessage.define_singleton_method(:deliver_raw, original)
    end

    assert_equal "delivered", inbound.reload.status
    assert_equal 0, @a.inbox.email_messages.count
    assert_equal 1, @b.inbox.email_messages.count
  end

  test "nothing delivered at all is an honest failure, even for a non-StandardError" do
    raw = stamped("Message-ID: <m4@remote.test>\r\nFrom: x@remote.test\r\nTo: a@example.test\r\nSubject: hi\r\n\r\nbody\r\n")
    original = MailOnRails::EmailMessage.method(:deliver_raw)
    MailOnRails::EmailMessage.define_singleton_method(:deliver_raw) { |*| raise SystemStackError, "stack level too deep" }
    begin
      inbound = with_scanner(enabled: true, scan: CLEAN) do
        assert_raises(MailOnRails::MailroomMailbox::DeliveryFailed) { receive_inbound_email_from_source(raw) }
        ActionMailbox::InboundEmail.last
      end
    ensure
      MailOnRails::EmailMessage.define_singleton_method(:deliver_raw, original)
    end

    assert_equal "failed", inbound.reload.status, "never left in processing"
  end
end
