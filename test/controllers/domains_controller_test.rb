require "test_helper"

class DomainsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    # The DKIM key mints into the row on create.
    @domain = MailOnRails::Domain.create!(name: "example.com")
  end

  test "requires authentication" do
    sign_out
    get domains_url
    assert_redirected_to new_session_url
  end

  test "index lists domains" do
    get domains_url
    assert_response :success
    assert_select ".primary", text: @domain.name
  end

  test "creates a domain" do
    assert_difference "MailOnRails::Domain.count", 1 do
      post domains_url, params: { domain: { name: "example.org" } }
    end
    assert_redirected_to domain_url(MailOnRails::Domain.find_by(name: "example.org"))
  end

  test "rejects an invalid name" do
    assert_no_difference "MailOnRails::Domain.count" do
      post domains_url, params: { domain: { name: "not a domain" } }
    end
    assert_response :unprocessable_entity
  end

  test "show renders the DNS records" do
    get domain_url(@domain)
    assert_response :success
    assert_match "rail._domainkey.example.com", response.body
    assert_match "v=spf1 mx -all", response.body
  end

  test "show renders the DMARC and TLS-RPT monitoring breakdowns" do
    MailOnRails::DmarcReport.create!(domain: @domain, reporter: "google.com", report_id: "r1",
                        begin_at: 2.days.ago, end_at: 1.day.ago, source_ip: "203.0.113.9",
                        count: 3, disposition: "none", dkim: "fail", spf: "fail")
    MailOnRails::TlsRptReport.create!(domain: @domain, reporter: "google.com", report_id: "t1",
                         begin_at: 2.days.ago, end_at: 1.day.ago, policy_type: "sts",
                         success_count: 5, failure_count: 1,
                         failure_details: [ { "result_type" => "starttls-not-supported", "count" => 1 } ])

    get domain_url(@domain)
    assert_response :success
    assert_match "TLS-RPT monitoring", response.body
    assert_match "203.0.113.9", response.body
    assert_match "starttls-not-supported", response.body
    assert_match "83.3%", response.body
  end

  test "index renders pills from the cached DNS checks" do
    @domain.update!(dns_checked_at: Time.current, dns_checks: [
      { record: "MX", status: "pass", found: "10 mail.example.com", note: nil },
      { record: "SPF", status: "fail", found: nil, note: "no v=spf1 record published" }
    ])
    get domains_url
    assert_select "span", text: "✓ MX"
    assert_select "span", text: "✗ SPF"
  end

  test "index shows a placeholder before the first DNS check" do
    get domains_url
    assert_select "span", text: "DNS not checked yet"
  end

  test "publish_dns without a Cloudflare token redirects with an alert" do
    post publish_dns_domain_url(@domain)
    assert_redirected_to domain_url(@domain)
    assert_match(/CLOUDFLARE_API_TOKEN/, flash[:alert])
  end

  test "destroys a domain" do
    assert_difference "MailOnRails::Domain.count", -1 do
      delete domain_url(@domain)
    end
    assert_redirected_to domains_url
  end

  test "rotate_dkim stages a new key and refuses double staging" do
    post rotate_dkim_domain_url(@domain)
    assert_redirected_to domain_url(@domain)
    assert @domain.reload.dkim_staged?
    assert_match(/staged under selector #{@domain.dkim_next_selector}/, flash[:notice])

    post rotate_dkim_domain_url(@domain)
    assert_match(/already staged/, flash[:alert])
  end

  test "show renders the staged rotation TXT" do
    @domain.stage_dkim_rotation!
    get domain_url(@domain)
    assert_response :success
    assert_match @domain.dkim_next_txt_name, response.body
    assert_match "rotation staged", response.body
  end

  CLEAN_SVG = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="#c00"/></svg>)

  test "update saves a clean BIMI logo and rejects a hostile one" do
    patch domain_url(@domain), params: { domain: { bimi_svg: CLEAN_SVG } }
    assert_redirected_to domain_url(@domain)
    assert_includes @domain.reload.bimi_svg, "<circle"

    patch domain_url(@domain), params: { domain: { bimi_svg: %(<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>) } }
    assert_match(/rejected/, flash[:alert])
    assert_includes @domain.reload.bimi_svg, "<circle", "the previous logo must survive a rejected replacement"

    patch domain_url(@domain), params: { domain: { bimi_svg: "" } }
    assert_nil @domain.reload.bimi_svg.presence
  end

  test "engine serves the hosted domain's logo anonymously" do
    @domain.update!(bimi_svg: CLEAN_SVG)
    sign_out

    get "/bimi/#{@domain.name}/logo.svg"
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_includes response.body, "<circle"
    assert_match(/default-src 'none'/, response.headers["Content-Security-Policy"])

    get "/bimi/unknown.test/logo.svg"
    assert_response :not_found
  end
end
