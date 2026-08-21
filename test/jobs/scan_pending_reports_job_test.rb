require "test_helper"
require "mail_on_rails/clamav_scanner"
require_relative "../test_helpers/clamav_stub_helper"
require_relative "../test_helpers/dmarc_report_mail_helper"
require_relative "../test_helpers/tls_rpt_report_mail_helper"

# The catch-up path for reports that arrived while virus scanning was
# disabled (scan_status nil in a dmarc@ inbox): once clamav is back, they
# are scanned, then ingested if clean - never parsed unscanned. Infected
# ones are re-filed into Quarantine; an unavailable scanner leaves them
# pending for the next run.
class ScanPendingReportsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ClamavStubHelper
  include DmarcReportMailHelper
  include TlsRptReportMailHelper

  CLEAN = MailOnRails::ClamavScanner::Result.new(:clean, nil)
  INFECTED = MailOnRails::ClamavScanner::Result.new(:infected, "Eicar-Test")
  UNAVAILABLE = MailOnRails::ClamavScanner::Result.new(:unavailable, nil)

  setup do
    @domain = MailOnRails::Domain.create!(name: "example.test")
    @account = MailOnRails::EmailAccount.find_by!(email: "dmarc@example.test")
    # As the mailroom stores it with scanning off: no scan_status, but the
    # rspamd sender verdict was still recorded at delivery time.
    @message = MailOnRails::EmailMessage.deliver_raw(@account.inbox, report_mail(@account.email),
                                        auth_results: "mail.test; spf=pass; dkim=pass; dmarc=pass")
  end

  test "scans pending report mail, then ingests it" do
    perform_enqueued_jobs do
      with_scanner(enabled: true, scan: CLEAN) { MailOnRails::ScanPendingReportsJob.perform_now }
    end

    assert_equal "clean", @message.reload.scan_status
    assert_equal 4, @domain.dmarc_reports.sum(:count)
  end

  test "an unverified sender is scanned but still not ingested" do
    @message.update!(auth_results: "mail.test; dmarc=fail")
    perform_enqueued_jobs do
      with_scanner(enabled: true, scan: CLEAN) { MailOnRails::ScanPendingReportsJob.perform_now }
    end

    assert_equal "clean", @message.reload.scan_status
    assert_equal 0, MailOnRails::DmarcReport.count
  end

  test "an infected pending report is quarantined, not parsed" do
    assert_no_enqueued_jobs only: MailOnRails::IngestDmarcReportJob do
      with_scanner(enabled: true, scan: INFECTED) { MailOnRails::ScanPendingReportsJob.perform_now }
    end

    @message.reload
    assert_equal MailOnRails::Mailbox::QUARANTINE, @message.mailbox.name
    assert_equal "infected", @message.scan_status
    assert_equal "Eicar-Test", @message.virus_name
    assert_equal 0, MailOnRails::DmarcReport.count
  end

  test "scanner disabled or unavailable leaves the message pending" do
    with_scanner(enabled: false) { MailOnRails::ScanPendingReportsJob.perform_now }
    assert_nil @message.reload.scan_status

    with_scanner(enabled: true, scan: UNAVAILABLE) { MailOnRails::ScanPendingReportsJob.perform_now }
    assert_nil @message.reload.scan_status
    assert_equal 0, MailOnRails::DmarcReport.count
  end

  test "a pending tls-rpt report is scanned and ingested by its own job" do
    tls_account = MailOnRails::EmailAccount.find_by!(email: "tls-rpt@example.test")
    MailOnRails::EmailMessage.deliver_raw(tls_account.inbox, tls_report_mail(tls_account.email),
                             auth_results: "mail.test; spf=pass; dkim=pass; dmarc=pass")

    perform_enqueued_jobs do
      with_scanner(enabled: true, scan: CLEAN) { MailOnRails::ScanPendingReportsJob.perform_now }
    end

    assert_equal 1, @domain.tls_rpt_reports.count
  end

  test "already-scanned and ordinary-inbox mail is untouched" do
    @message.update!(scan_status: "clean")
    other = MailOnRails::EmailAccount.create!(email: "user@example.test", password: "pw-123456")
    pending_elsewhere = MailOnRails::EmailMessage.deliver_raw(other.inbox, report_mail(other.email))

    calls = 0
    with_scanner(enabled: true, scan: ->(_raw) { calls += 1; CLEAN }) { MailOnRails::ScanPendingReportsJob.perform_now }
    assert_equal 0, calls
    assert_nil pending_elsewhere.reload.scan_status
  end
end
