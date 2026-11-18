require "test_helper"
require "mail_on_rails/clamav_scanner"
require "mail_on_rails/ingress_seal"
require_relative "../test_helpers/clamav_stub_helper"
require_relative "../test_helpers/rspamd_stub_helper"
require_relative "../test_helpers/sealed_ingress_helper"

# Decoded header values on their way into text columns (2026-11-17 audit,
# Info: "NUL via encoded-word in Subject").
#
# The SMTP edge deletes raw NULs, but an RFC 2047 encoded-word carries any
# byte past it: "=?utf-8?q?hello=00world?=" is seven-bit clean on the wire
# and decodes to a NUL in the Mail gem. PostgreSQL refuses NUL in text, so
# the INSERT raised and the message - already answered 250 at the edge -
# was lost for every recipient. Any sender could do that to any message
# they sent; this suite runs on PostgreSQL to hold the fix to the adapter
# that had the problem.
class MailroomControlBytesTest < ActionMailbox::TestCase
  include ClamavStubHelper
  include RspamdStubHelper
  include SealedIngressHelper

  CLEAN = MailOnRails::ClamavScanner::Result.new(:clean, nil)
  EMAIL = "user@example.test"

  setup do
    @account = MailOnRails::EmailAccount.create!(email: EMAIL, password: "pw-123456")
  end

  def stamped(headers)
    [ "Return-Path: <sender@remote.test>", "X-Original-To: #{EMAIL}", "X-MailOnRails-Authenticated: no" ]
      .join("\r\n") + "\r\n" + headers + "\r\n\r\nbody\r\n"
  end

  def receive(headers)
    with_scanner(enabled: true, scan: CLEAN) { receive_inbound_email_from_source(stamped(headers)) }
  end

  test "a NUL smuggled into Subject by an encoded-word is delivered, without the NUL" do
    inbound = receive("Message-ID: <nul-1@remote.test>\r\nFrom: sender@remote.test\r\nTo: #{EMAIL}\r\n" \
                      "Subject: =?utf-8?q?hello=00world?=")

    assert_equal "delivered", inbound.reload.status
    message = @account.inbox.email_messages.sole
    assert_equal "helloworld", message.subject
  end

  test "base64 encoded-words and other control bytes in Subject are stored printable" do
    encoded = [ "a\x00b\x01c\x08d\x1be\x7ff\u0085g" ].pack("m0")
    receive("Message-ID: <nul-2@remote.test>\r\nFrom: sender@remote.test\r\nTo: #{EMAIL}\r\nSubject: =?utf-8?b?#{encoded}?=")

    message = @account.inbox.email_messages.sole
    assert_equal "abcdefg", message.subject
  end

  test "a tab inside a subject survives as a space, not as a control byte" do
    receive("Message-ID: <nul-3@remote.test>\r\nFrom: sender@remote.test\r\nTo: #{EMAIL}\r\nSubject: =?utf-8?q?one=09two?=")

    assert_equal "one two", @account.inbox.email_messages.sole.subject
  end

  test "NULs smuggled into Message-ID, In-Reply-To and References do not fail the delivery" do
    inbound = receive("Message-ID: <=?utf-8?q?mid=00x?=@remote.test>\r\nFrom: sender@remote.test\r\nTo: #{EMAIL}\r\n" \
                      "In-Reply-To: <=?utf-8?q?parent=00x?=@remote.test>\r\n" \
                      "References: <=?utf-8?q?root=00x?=@remote.test> <=?utf-8?q?parent=00x?=@remote.test>\r\n" \
                      "Subject: threading")

    assert_equal "delivered", inbound.reload.status
    message = @account.inbox.email_messages.sole
    [ message.message_id, message.in_reply_to, message.references_ids, message.thread_id ].each do |value|
      assert_not_includes value.to_s, "\u0000"
    end
  end

  test "NULs in the display names and addresses of From and To do not fail the delivery" do
    inbound = receive("Message-ID: <nul-5@remote.test>\r\n" \
                      "From: =?utf-8?q?Evil=00Name?= <sender@remote.test>\r\n" \
                      "To: =?utf-8?q?You=00?= <#{EMAIL}>, \"=?utf-8?q?x=00y?=\"@remote.test\r\n" \
                      "Subject: names")

    assert_equal "delivered", inbound.reload.status
    message = @account.inbox.email_messages.sole
    assert_equal "sender@remote.test", message.from_address
    assert_not_includes message.to_addresses.to_s, "\u0000"
  end

  # The gem decodes an encoded-word used as a bare local part, so the
  # addr-spec itself comes back with the NUL in it. Dropped, not cleaned:
  # from_address keys the account's sender rules, and "bo\0ss@" must not
  # be filed as "boss@".
  test "an address that decodes to a control character is not stored as an address" do
    inbound = receive("Message-ID: <nul-7@remote.test>\r\nFrom: =?utf-8?q?bo=00ss?=@remote.test\r\n" \
                      "To: =?utf-8?q?us=00er?=@example.test, #{EMAIL}\r\nSubject: addr")

    assert_equal "delivered", inbound.reload.status
    message = @account.inbox.email_messages.sole
    assert_nil message.from_address
    assert_equal EMAIL, message.to_addresses
  end

  test "the stored raw source is untouched: the encoded-word is still there to inspect" do
    receive("Message-ID: <nul-6@remote.test>\r\nFrom: sender@remote.test\r\nTo: #{EMAIL}\r\nSubject: =?utf-8?q?hello=00world?=")

    assert_includes @account.inbox.email_messages.sole.raw, "=?utf-8?q?hello=00world?="
  end
end
