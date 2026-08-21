require "test_helper"
require "zlib"
require_relative "../test_helpers/tls_rpt_report_mail_helper"

# Post-delivery parsing of mail landing in a tls-rpt@ inbox. The
# sender-verified gate is the security boundary: anyone can mail a
# well-formed fake report, so only mail that itself passed DMARC (or came
# from an authenticated local submitter) is parsed.
class IngestTlsRptReportJobTest < ActiveSupport::TestCase
  include TlsRptReportMailHelper

  VERIFIED = "mail.test; spf=pass; dkim=pass; dmarc=pass".freeze

  setup do
    @domain = MailOnRails::Domain.create!(name: "example.test")
    @account = MailOnRails::EmailAccount.find_by!(email: "tls-rpt@example.test")
  end

  def deliver(raw, auth_results: nil)
    MailOnRails::EmailMessage.deliver_raw(@account.inbox, raw, auth_results: auth_results)
  end

  test "an unverified sender's report is not ingested" do
    message = deliver(tls_report_mail(@account.email), auth_results: "mail.test; dmarc=fail")

    MailOnRails::IngestTlsRptReportJob.perform_now(message)

    assert_equal 0, MailOnRails::TlsRptReport.count
  end

  test "a verified sender's multipart report ingests its gzipped attachment" do
    message = deliver(tls_report_mail(@account.email), auth_results: VERIFIED)

    MailOnRails::IngestTlsRptReportJob.perform_now(message)

    report = @domain.tls_rpt_reports.sole
    assert_equal 5, report.success_count
    assert_equal 1, report.failure_count
  end

  test "a single-part body carrying the bare JSON is ingested" do
    raw = "From: noreply-smtp-tls-reporting@google.com\r\nTo: #{@account.email}\r\n" \
          "Subject: Report Domain: example.test\r\n\r\n#{TlsRptReportMailHelper::REPORT_JSON}"
    message = deliver(raw, auth_results: VERIFIED)

    MailOnRails::IngestTlsRptReportJob.perform_now(message)

    assert_equal 1, @domain.tls_rpt_reports.count
  end

  test "a garbage payload ingests nothing and does not raise" do
    raw = "From: someone@remote.test\r\nTo: #{@account.email}\r\n" \
          "Subject: not a report\r\n\r\njust some text\r\n"
    message = deliver(raw, auth_results: VERIFIED)

    assert_nothing_raised { MailOnRails::IngestTlsRptReportJob.perform_now(message) }
    assert_equal 0, MailOnRails::TlsRptReport.count
  end
end
