require "test_helper"

# The webmail-side BIMI logo endpoint: authenticated, and only ever
# serving indicators the receiver-side evaluation marked displayable.
class BimiLogosControllerTest < ActionDispatch::IntegrationTest
  CLEAN_SVG = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="#0c0"/></svg>)

  setup do
    sign_in_as users(:one)
    @indicator = MailOnRails::BimiIndicator.create!(domain: "brand.test", status: "pass",
                                                    svg: CLEAN_SVG, checked_at: Time.current)
  end

  test "requires authentication" do
    sign_out
    get bimi_logo_url("brand.test")
    assert_redirected_to new_session_url
  end

  test "serves a displayable indicator with inert-SVG headers" do
    get bimi_logo_url("brand.test")
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_includes response.body, "<circle"
    assert_match(/default-src 'none'/, response.headers["Content-Security-Policy"])
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  end

  test "non-displayable indicators and unknown domains 404" do
    @indicator.update!(status: "fail", svg: nil, error: "hostile logo")
    get bimi_logo_url("brand.test")
    assert_response :not_found

    get bimi_logo_url("nobody.test")
    assert_response :not_found
  end
end
