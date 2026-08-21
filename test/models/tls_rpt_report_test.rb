require "test_helper"
require "zlib"
require_relative "../test_helpers/tls_rpt_report_mail_helper"

class TlsRptReportTest < ActiveSupport::TestCase
  SAMPLE_JSON = TlsRptReportMailHelper::REPORT_JSON

  setup do
    @domain = MailOnRails::Domain.create!(name: "example.test")
  end

  test "ingests plain JSON into a row per policy" do
    assert_equal 1, MailOnRails::TlsRptReportParser.ingest(SAMPLE_JSON)

    report = @domain.tls_rpt_reports.sole
    assert_equal "google.com", report.reporter
    assert_equal "2026-07-22T00:00:00Z_example.test", report.report_id
    assert_equal "sts", report.policy_type
    assert_equal 5, report.success_count
    assert_equal 1, report.failure_count
    assert_equal [ { "result_type" => "starttls-not-supported", "count" => 1,
                     "receiving_mx" => "mx.example.test", "sending_mta_ip" => "198.51.100.20" } ],
                 report.failure_details
  end

  test "ingestion is idempotent per report_id" do
    2.times { MailOnRails::TlsRptReportParser.ingest(SAMPLE_JSON) }
    assert_equal 1, @domain.tls_rpt_reports.count
  end

  test "ingests gzip and zip wrappings" do
    assert_equal 1, MailOnRails::TlsRptReportParser.ingest(Zlib.gzip(SAMPLE_JSON))

    buffer = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("google.com!example.test!1753142400!1753228799.json")
      zip.write(SAMPLE_JSON)
    end
    assert_equal 1, MailOnRails::TlsRptReportParser.ingest(buffer.string)
    assert_equal 1, @domain.tls_rpt_reports.count
  end

  # A central-directory record costs the sender ~46 bytes, so a small zip
  # can declare an enormous entry count; the parser must refuse rather
  # than walk it (a real report archive holds one file).
  test "refuses a zip declaring an absurd number of entries" do
    buffer = Zip::OutputStream.write_buffer do |zip|
      (MailOnRails::TlsRptReportParser::MAX_ZIP_ENTRIES + 1).times do |i|
        zip.put_next_entry("report-#{i}.json")
      end
    end
    assert_nil MailOnRails::TlsRptReportParser.ingest(buffer.string)
  end

  test "skips reports for unhosted domains and non-reports" do
    assert_nil MailOnRails::TlsRptReportParser.ingest(SAMPLE_JSON.gsub("example.test", "other.example"))
    assert_nil MailOnRails::TlsRptReportParser.ingest("just some text")
    assert_nil MailOnRails::TlsRptReportParser.ingest("{\"not\": \"a report\"}")
    assert_nil MailOnRails::TlsRptReportParser.ingest("PK\x03\x04 corrupt zip")
    assert_nil MailOnRails::TlsRptReportParser.ingest("\x1f\x8b corrupt gzip")
    assert_equal 0, MailOnRails::TlsRptReport.count
  end

  test "bounds hostile payloads: depth, policy count, detail count, counts, strings" do
    # Nesting far past any real report is rejected outright.
    deep = "[" * 30 + "]" * 30
    assert_nil MailOnRails::TlsRptReportParser.ingest("{\"policies\": #{deep}}")

    # Policies beyond the cap are dropped; session counts and strings are
    # clamped rather than stored verbatim.
    policy = JSON.parse(SAMPLE_JSON)["policies"].first
    policy["summary"] = { "total-successful-session-count" => 10**15,
                          "total-failure-session-count" => -5 }
    policy["failure-details"] = Array.new(60) do |i|
      { "result-type" => "x" * 500, "failed-session-count" => 1, "receiving-mx-hostname" => i.to_s }
    end
    hostile = JSON.parse(SAMPLE_JSON).merge("policies" => Array.new(120) { policy.dup })
    assert_equal MailOnRails::TlsRptReportParser::MAX_POLICIES, MailOnRails::TlsRptReportParser.ingest(hostile.to_json)

    report = @domain.tls_rpt_reports.first
    assert_equal MailOnRails::TlsRptReportParser::MAX_COUNT, report.success_count
    assert_equal 0, report.failure_count
    assert_equal MailOnRails::TlsRptReportParser::MAX_FAILURE_DETAILS, report.failure_details.size
    assert report.failure_details.first["result_type"].length <= 64
  end

  test "a policy-type outside the RFC vocabulary is stored as other" do
    doctored = SAMPLE_JSON.sub("\"sts\"", "\"<script>alert(1)</script>\"")
    assert_equal 1, MailOnRails::TlsRptReportParser.ingest(doctored)
    assert_equal "other", @domain.tls_rpt_reports.sole.policy_type
  end

  test "stats aggregates the last 30 days" do
    MailOnRails::TlsRptReportParser.ingest(SAMPLE_JSON)
    MailOnRails::TlsRptReport.update_all(begin_at: 3.days.ago, end_at: 2.days.ago)
    stats = MailOnRails::TlsRptReport.stats(@domain)

    assert_equal 6, stats[:sessions]
    assert_equal 1, stats[:failed]
    assert_in_delta 83.3, stats[:success_pct], 0.1
    assert_equal 1, stats[:reporters]
    assert_equal({ "starttls-not-supported" => 1 }, stats[:failure_types])

    MailOnRails::TlsRptReport.update_all(begin_at: 40.days.ago, end_at: 39.days.ago)
    assert_equal 0, MailOnRails::TlsRptReport.stats(@domain)[:sessions]
  end

  test "prune! enforces retention" do
    MailOnRails::TlsRptReportParser.ingest(SAMPLE_JSON)
    MailOnRails::TlsRptReport.update_all(begin_at: 100.days.ago, end_at: 99.days.ago)
    MailOnRails::TlsRptReport.prune!
    assert_equal 0, MailOnRails::TlsRptReport.count
  end
end
