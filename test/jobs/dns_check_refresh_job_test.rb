require "test_helper"

class DnsCheckRefreshJobTest < ActiveJob::TestCase
  # Lookups may or may not reach real DNS here; either way the checks
  # land (:unknown on failure) and the cache timestamp is stamped.
  test "refreshes every domain's pill cache" do
    domain = MailOnRails::Domain.create!(name: "example.com")
    MailOnRails::DnsCheckRefreshJob.perform_now
    domain.reload
    assert domain.dns_checked_at.present?
    assert_equal %w[MX SPF DKIM DMARC MTA-STS TLS-RPT], domain.cached_dns_checks.map(&:record)
  end

  test "creating a domain enqueues its own refresh" do
    assert_enqueued_with(job: MailOnRails::DnsCheckRefreshJob) do
      MailOnRails::Domain.create!(name: "example.org")
    end
  end
end
