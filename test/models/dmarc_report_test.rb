require "test_helper"

class DmarcReportTest < ActiveSupport::TestCase
  setup do
    @domain = MailOnRails::Domain.create!(name: "example.com")
  end

  SAMPLE_XML = <<~XML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <feedback>
      <report_metadata>
        <org_name>google.com</org_name>
        <email>noreply-dmarc-support@google.com</email>
        <report_id>1234567890</report_id>
        <date_range><begin>1753142400</begin><end>1753228800</end></date_range>
      </report_metadata>
      <policy_published>
        <domain>example.com</domain>
        <p>none</p>
      </policy_published>
      <record>
        <row>
          <source_ip>198.51.100.10</source_ip>
          <count>7</count>
          <policy_evaluated>
            <disposition>none</disposition>
            <dkim>pass</dkim>
            <spf>pass</spf>
          </policy_evaluated>
        </row>
        <identifiers><header_from>example.com</header_from></identifiers>
      </record>
      <record>
        <row>
          <source_ip>203.0.113.9</source_ip>
          <count>2</count>
          <policy_evaluated>
            <disposition>none</disposition>
            <dkim>fail</dkim>
            <spf>fail</spf>
          </policy_evaluated>
        </row>
        <identifiers><header_from>example.com</header_from></identifiers>
      </record>
    </feedback>
  XML

  test "ingests plain XML into rows" do
    assert_equal 2, MailOnRails::DmarcReportParser.ingest(SAMPLE_XML)

    rows = @domain.dmarc_reports.order(:source_ip)
    assert_equal %w[198.51.100.10 203.0.113.9], rows.map(&:source_ip)
    assert_equal [ 7, 2 ], rows.map(&:count)
    assert_equal "google.com", rows.first.reporter
    assert rows.first.pass?
    assert_not rows.last.pass?
  end

  test "ingestion is idempotent per report_id" do
    2.times { MailOnRails::DmarcReportParser.ingest(SAMPLE_XML) }
    assert_equal 2, @domain.dmarc_reports.count
  end

  test "ingests gzip and zip wrappings" do
    gz = StringIO.new.tap { |io| Zlib::GzipWriter.wrap(io) { |w| w.write(SAMPLE_XML) } }.string
    assert_equal 2, MailOnRails::DmarcReportParser.ingest(gz)

    buffer = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("google.com!example.com!1753142400!1753228800.xml")
      zip.write(SAMPLE_XML)
    end
    assert_equal 2, MailOnRails::DmarcReportParser.ingest(buffer.string)
    assert_equal 2, @domain.dmarc_reports.count
  end

  # A central-directory record costs the sender ~46 bytes, so a small zip
  # can declare an enormous entry count; the parser must refuse rather
  # than walk it (a real report archive holds one file).
  test "refuses a zip declaring an absurd number of entries" do
    buffer = Zip::OutputStream.write_buffer do |zip|
      (MailOnRails::DmarcReportParser::MAX_ZIP_ENTRIES + 1).times do |i|
        zip.put_next_entry("report-#{i}.xml")
      end
    end
    assert_nil MailOnRails::DmarcReportParser.ingest(buffer.string)
  end

  test "skips reports for unhosted domains and non-reports" do
    assert_nil MailOnRails::DmarcReportParser.ingest(SAMPLE_XML.sub("example.com</domain>", "other.example</domain>"))
    assert_nil MailOnRails::DmarcReportParser.ingest("just some text")
    assert_nil MailOnRails::DmarcReportParser.ingest("<html><body>not a report</body></html>")
    assert_nil MailOnRails::DmarcReportParser.ingest("PK\x03\x04 corrupt zip")
    assert_equal 0, MailOnRails::DmarcReport.count
  end

  test "stats aggregates the last 30 days" do
    MailOnRails::DmarcReportParser.ingest(SAMPLE_XML)
    MailOnRails::DmarcReport.update_all(begin_at: 3.days.ago, end_at: 2.days.ago)
    stats = MailOnRails::DmarcReport.stats(@domain)

    assert_equal 9, stats[:total]
    assert_equal 7, stats[:passed]
    assert_in_delta 77.8, stats[:aligned_pct], 0.1
    assert_equal 2, stats[:sources]
    assert_equal [ { ip: "198.51.100.10", count: 7, passed: 7, dkim_passed: 7, spf_passed: 7, dispositions: [ "none" ] },
                   { ip: "203.0.113.9", count: 2, passed: 0, dkim_passed: 0, spf_passed: 0, dispositions: [ "none" ] } ],
                 stats[:by_source]

    MailOnRails::DmarcReport.update_all(begin_at: 40.days.ago, end_at: 39.days.ago)
    assert_equal 0, MailOnRails::DmarcReport.stats(@domain)[:total]
  end

  test "prune! enforces retention" do
    MailOnRails::DmarcReportParser.ingest(SAMPLE_XML)
    MailOnRails::DmarcReport.update_all(begin_at: 100.days.ago, end_at: 99.days.ago)
    MailOnRails::DmarcReport.prune!
    assert_equal 0, MailOnRails::DmarcReport.count
  end

  test "dmarc_advice escalates only when aligned, aged, and voluminous" do
    stats = { total: 0, aligned_pct: nil, span_days: 0, failing: {} }
    assert_equal :publish, @domain.dmarc_advice(stats, nil).first
    assert_equal :waiting, @domain.dmarc_advice(stats, "v=DMARC1; p=none").first
    assert_equal :done, @domain.dmarc_advice(stats, "v=DMARC1; p=reject").first

    good = { total: 500, aligned_pct: 100.0, span_days: 20, failing: {} }
    key, text = @domain.dmarc_advice(good, "v=DMARC1; p=none")
    assert_equal :ready, key
    assert_match "p=quarantine", text
    assert_match "p=reject", @domain.dmarc_advice(good, "v=DMARC1; p=quarantine").last

    assert_equal :monitoring, @domain.dmarc_advice(good.merge(span_days: 3), "v=DMARC1; p=none").first
    assert_equal :monitoring, @domain.dmarc_advice(good.merge(aligned_pct: 95.0), "v=DMARC1; p=none").first
    assert_equal :monitoring, @domain.dmarc_advice(good.merge(total: 5), "v=DMARC1; p=none").first
  end

  test "domain creation auto-creates the dmarc reports account" do
    account = MailOnRails::EmailAccount.find_by(email: "dmarc@example.com")
    assert account, "dmarc@ account should be auto-created with the domain"
    assert_equal "DMARC reports", account.name
    assert MailOnRails::Domain.dmarc_ingestion_address?("dmarc@example.com")
    assert_not MailOnRails::Domain.dmarc_ingestion_address?("dmarc@other.example")
    assert_not MailOnRails::Domain.dmarc_ingestion_address?("user@example.com")
  end
end
