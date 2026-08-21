require "test_helper"

class DomainTest < ActiveSupport::TestCase
  test "normalizes the name" do
    domain = MailOnRails::Domain.create!(name: "  Example.COM.  ")
    assert_equal "example.com", domain.name
  end

  test "rejects names that are not plain FQDNs" do
    [ "", "nodots", "colon:list", "bad domain.com", "*.example.com", "-x.example.com" ].each do |name|
      assert_not MailOnRails::Domain.new(name: name).valid?, "#{name.inspect} should be invalid"
    end
  end

  test "create mints an encrypted DKIM key" do
    domain = MailOnRails::Domain.create!(name: "example.com")

    assert_instance_of OpenSSL::PKey::RSA, OpenSSL::PKey.read(domain.dkim_private_key)
    assert_match(/\Av=DKIM1; k=rsa; p=[A-Za-z0-9+\/]+=*\z/, domain.dkim_txt_value)
    # Stored encrypted: the raw column bytes must not contain the PEM.
    raw = MailOnRails::Domain.connection.select_value("SELECT dkim_private_key FROM #{MailOnRails::Domain.table_name} WHERE id = #{domain.id}")
    assert_not_includes raw.to_s, "PRIVATE KEY"
  end

  test "create keeps a key supplied up front (imports) instead of minting" do
    pem = OpenSSL::PKey::RSA.new(MailOnRails::Domain::DKIM_KEY_BITS).to_pem
    domain = MailOnRails::Domain.create!(name: "example.com", dkim_private_key: pem)
    assert_equal pem, domain.dkim_private_key
  end

  test "the key dies with the domain; re-creating mints a fresh one" do
    domain = MailOnRails::Domain.create!(name: "example.com")
    original = domain.dkim_private_key

    domain.destroy!

    recreated = MailOnRails::Domain.create!(name: "example.com")
    assert recreated.dkim_private_key.present?
    assert_not_equal original, recreated.dkim_private_key
  end

  test "create provisions the dmarc reports account" do
    domain = MailOnRails::Domain.create!(name: "example.com")

    assert MailOnRails::EmailAccount.exists?(email: domain.dmarc_address)
    assert MailOnRails::Domain.dmarc_ingestion_address?(domain.dmarc_address)
  end

  test "create provisions the tls-rpt reports account" do
    domain = MailOnRails::Domain.create!(name: "example.com")

    assert MailOnRails::EmailAccount.exists?(email: domain.tls_rpt_address)
    assert MailOnRails::Domain.tls_rpt_ingestion_address?(domain.tls_rpt_address)
    assert_not MailOnRails::Domain.dmarc_ingestion_address?(domain.tls_rpt_address), "tls-rpt mail must not feed the DMARC parser"
    assert_not MailOnRails::Domain.tls_rpt_ingestion_address?(domain.dmarc_address), "dmarc mail must not feed the TLS-RPT parser"
  end

  test "ingestion_job_for maps report addresses to their parser jobs" do
    domain = MailOnRails::Domain.create!(name: "example.com")

    assert_equal MailOnRails::IngestDmarcReportJob, MailOnRails::Domain.ingestion_job_for(domain.dmarc_address)
    assert_equal MailOnRails::IngestTlsRptReportJob, MailOnRails::Domain.ingestion_job_for(domain.tls_rpt_address)
    assert_nil MailOnRails::Domain.ingestion_job_for("user@example.com")
    assert_nil MailOnRails::Domain.ingestion_job_for("tls-rpt@unhosted.example")
  end
end
