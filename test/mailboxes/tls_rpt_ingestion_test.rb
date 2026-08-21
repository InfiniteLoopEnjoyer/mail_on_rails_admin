require "test_helper"
require "zlib"
require "mail_on_rails/clamav_scanner"
require "mail_on_rails/rspamd_analyzer"
require_relative "../test_helpers/clamav_stub_helper"
require_relative "../test_helpers/rspamd_stub_helper"
require_relative "../test_helpers/tls_rpt_report_mail_helper"
require_relative "../test_helpers/sealed_ingress_helper"

# Mail delivered to a domain's tls-rpt@ ingestion account is parsed for
# RFC 8460 aggregate reports under the same invariants as dmarc@: only
# after a clean clamav scan AND a verified sender; with scanning disabled
# it is delivered but left unparsed (ScanPendingReportsJob catches up
# later). Ordinary accounts never trigger ingestion.
class TlsRptIngestionTest < ActionMailbox::TestCase
  include ActiveJob::TestHelper
  include ClamavStubHelper
  include RspamdStubHelper
  include TlsRptReportMailHelper
  include SealedIngressHelper

  CLEAN = MailOnRails::ClamavScanner::Result.new(:clean, nil)

  setup do
    @domain = MailOnRails::Domain.create!(name: "example.test")
    @account = MailOnRails::EmailAccount.find_by!(email: "tls-rpt@example.test")
  end

  def rspamd_verdict(dmarc:)
    MailOnRails::RspamdAnalyzer::Result.new(
      status: :ok, action: "no action", score: 0.1, required_score: 6.0,
      spf: "pass", dkim: "pass", dmarc: dmarc,
      auth_results: "mail.test; spf=pass; dkim=pass; dmarc=#{dmarc}"
    )
  end

  def receive_report(to: "tls-rpt@example.test", dmarc: "pass")
    with_scanner(enabled: true, scan: CLEAN) do
      with_rspamd(enabled: true, analyze: rspamd_verdict(dmarc: dmarc)) do
        receive_inbound_email_from_source(tls_report_mail(to))
      end
    end
  end

  test "a scanned-clean report from a DMARC-passing sender is ingested" do
    perform_enqueued_jobs { receive_report }

    assert_equal 1, @account.inbox.email_messages.count
    assert_equal 1, @domain.tls_rpt_reports.count
  end

  test "a report whose own mail fails DMARC is delivered but never parsed" do
    perform_enqueued_jobs { receive_report(dmarc: "fail") }

    assert_equal 1, @account.inbox.email_messages.count
    assert_equal 0, MailOnRails::TlsRptReport.count
  end

  test "with scanning disabled the report is delivered but not enqueued" do
    assert_no_enqueued_jobs only: MailOnRails::IngestTlsRptReportJob do
      with_rspamd(enabled: true, analyze: rspamd_verdict(dmarc: "pass")) do
        receive_inbound_email_from_source(tls_report_mail("tls-rpt@example.test"))
      end
    end
    assert_equal 1, @account.inbox.email_messages.count
    assert_equal 0, MailOnRails::TlsRptReport.count
  end

  test "mail to an ordinary account never triggers ingestion" do
    MailOnRails::EmailAccount.create!(email: "user@example.test", password: "pw-123456")
    assert_no_enqueued_jobs only: MailOnRails::IngestTlsRptReportJob do
      with_scanner(enabled: true, scan: CLEAN) do
        with_rspamd(enabled: true, analyze: rspamd_verdict(dmarc: "pass")) do
          receive_inbound_email_from_source(tls_report_mail("user@example.test"))
        end
      end
    end
    assert_equal 0, MailOnRails::TlsRptReport.count
  end
end
