require "test_helper"
require "zlib"
require_relative "../test_helpers/dmarc_report_mail_helper"

# Post-delivery parsing of mail landing in a dmarc@ inbox. The
# sender-verified gate is the security boundary: anyone can mail a
# well-formed fake report, so only mail that itself passed DMARC (or came
# from an authenticated local submitter) is parsed.
class IngestDmarcReportJobTest < ActiveSupport::TestCase
  include DmarcReportMailHelper

  VERIFIED = "mail.test; spf=pass; dkim=pass; dmarc=pass".freeze

  setup do
    @domain = MailOnRails::Domain.create!(name: "example.test")
    @account = MailOnRails::EmailAccount.find_by!(email: "dmarc@example.test")
  end

  def deliver(raw, auth_results: nil)
    MailOnRails::EmailMessage.deliver_raw(@account.inbox, raw, auth_results: auth_results)
  end

  test "an unverified sender's report is not ingested" do
    message = deliver(report_mail(@account.email), auth_results: "mail.test; dmarc=fail")

    MailOnRails::IngestDmarcReportJob.perform_now(message)

    assert_equal 0, MailOnRails::DmarcReport.count
  end

  test "a verified sender's multipart report ingests its xml attachment" do
    message = deliver(report_mail(@account.email), auth_results: VERIFIED)

    MailOnRails::IngestDmarcReportJob.perform_now(message)

    assert_equal 4, @domain.dmarc_reports.sum(:count)
  end

  test "a gzipped attachment is ingested" do
    mail = Mail.new
    mail.from = "noreply-dmarc-support@google.com"
    mail.to = @account.email
    mail.subject = "Report domain: example.test"
    mail.body = "attached"
    mail.add_file filename: "google.com!example.test!1!2.xml.gz",
                  content: Zlib.gzip(DmarcReportMailHelper::REPORT_XML)
    message = deliver(mail.to_s, auth_results: VERIFIED)

    MailOnRails::IngestDmarcReportJob.perform_now(message)

    assert_equal 4, @domain.dmarc_reports.sum(:count)
  end

  test "a single-part body carrying the bare XML is ingested" do
    raw = "From: noreply-dmarc-support@google.com\r\nTo: #{@account.email}\r\n" \
          "Subject: Report domain: example.test\r\n\r\n#{DmarcReportMailHelper::REPORT_XML}"
    message = deliver(raw, auth_results: VERIFIED)

    MailOnRails::IngestDmarcReportJob.perform_now(message)

    assert_equal 4, @domain.dmarc_reports.sum(:count)
  end

  test "a garbage payload ingests nothing and does not raise" do
    raw = "From: someone@remote.test\r\nTo: #{@account.email}\r\n" \
          "Subject: not a report\r\n\r\njust some text\r\n"
    message = deliver(raw, auth_results: VERIFIED)

    assert_nothing_raised { MailOnRails::IngestDmarcReportJob.perform_now(message) }
    assert_equal 0, MailOnRails::DmarcReport.count
  end
end
