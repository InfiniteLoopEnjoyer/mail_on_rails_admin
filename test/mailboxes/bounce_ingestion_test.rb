require "test_helper"
require "mail_on_rails/clamav_scanner"
require "mail_on_rails/rspamd_analyzer"
require_relative "../test_helpers/clamav_stub_helper"
require_relative "../test_helpers/rspamd_stub_helper"
require_relative "../test_helpers/sealed_ingress_helper"

# VERP bounce routing end to end: a DSN addressed to the signed
# bounce+m<id>-<mac> sub-address resolves into the domain's bounce@
# account, triggers IngestBounceJob, and a hard 5.x.x verdict suppresses
# that (recipient, sender) pair. Forged sub-addresses never resolve.
class BounceIngestionTest < ActionMailbox::TestCase
  include ActiveJob::TestHelper
  include ClamavStubHelper
  include RspamdStubHelper
  include SealedIngressHelper

  CLEAN = MailOnRails::ClamavScanner::Result.new(:clean, nil)

  setup do
    MailOnRails::Domain.create!(name: "example.test")
    @bounce_account = MailOnRails::EmailAccount.find_by!(email: "bounce@example.test")
    @outbound = MailOnRails::SmtpOutboundMessage.create!(
      mail_from: "news@example.test", recipient: "reader@remote.test",
      data: "From: news@example.test\r\nList-ID: <news.example.test>\r\n\r\nhi",
      next_attempt_at: Time.current, status: :sent
    )
    @verp = MailOnRails::VerpAddress.encode(@outbound)
  end

  def bounce_source(to)
    <<~RAW
      Return-Path: <>
      X-Original-To: #{to}
      X-MailOnRails-Authenticated: no
      From: mailer-daemon@remote.test
      To: #{to}
      Subject: Undelivered Mail Returned to Sender
      Message-ID: <dsn-1@remote.test>
      Content-Type: multipart/report; report-type=delivery-status; boundary="b"

      --b
      Content-Type: text/plain

      Delivery failed permanently.
      --b
      Content-Type: message/delivery-status

      Reporting-MTA: dns; mx.remote.test
      Action: failed
      Status: 5.1.1

      --b--
    RAW
  end

  test "a hard DSN to the VERP address lands in bounce@ and suppresses the pair" do
    perform_enqueued_jobs do
      with_scanner(enabled: true, scan: CLEAN) do
        receive_inbound_email_from_source(bounce_source(@verp))
      end
    end

    assert_equal 1, @bounce_account.inbox.email_messages.count, "the raw bounce stays inspectable"
    assert MailOnRails::SuppressedRecipient.suppressed?("reader@remote.test", sender: "news@example.test")
    assert_not MailOnRails::SuppressedRecipient.suppressed?("reader@remote.test", sender: "other@example.test")
  end

  test "a forged VERP sub-address resolves to no account and nothing is suppressed" do
    forged = @verp.sub(/-\h{12}@/, "-000000000000@")
    perform_enqueued_jobs do
      with_scanner(enabled: true, scan: CLEAN) do
        receive_inbound_email_from_source(bounce_source(forged))
      end
    end

    assert_equal 0, @bounce_account.inbox.email_messages.count
    assert_equal 0, MailOnRails::SuppressedRecipient.count
  end
end
