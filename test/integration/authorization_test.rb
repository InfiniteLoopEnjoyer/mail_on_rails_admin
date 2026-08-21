require "test_helper"

# The RBAC gate (Authorization concern): members are redirected off every
# admin surface, admins are unaffected, and the member self-service paths
# (own profile, 2FA enrollment, sign-out) stay reachable.
class AuthorizationTest < ActionDispatch::IntegrationTest
  ADMIN_SURFACES = %w[
    /domains /users /users/new /settings /smtp /imap /auth_attempts /audit
    /accounts/new
  ].freeze

  test "a member is redirected off every admin surface" do
    sign_in_as users(:member)

    ADMIN_SURFACES.each do |path|
      get path
      assert_redirected_to root_url, "#{path} must redirect a member to root"
    end
  end

  test "an admin reaches the admin surfaces" do
    sign_in_as users(:one)

    get domains_url
    assert_response :success

    get users_url
    assert_response :success

    get settings_url
    assert_response :success
  end

  test "member admin-surface denials cover writes too" do
    sign_in_as users(:member)

    assert_no_difference "User.count" do
      post users_url, params: { user: { email_address: "sneaky@example.com" } }
    end
    assert_redirected_to root_url

    assert_no_difference "MailOnRails::Domain.count" do
      post domains_url, params: { domain: { name: "evil.example" } }
    end
    assert_redirected_to root_url

    assert_no_difference "MailOnRails::EmailAccount.count" do
      post email_accounts_url, params: { email_account: { email: "sneaky@example.com" } }
    end
    assert_redirected_to root_url
  end

  test "a member keeps their self-service surfaces" do
    member = users(:member)
    sign_in_as member

    get root_url
    assert_response :success

    get edit_user_url(member)
    assert_response :success

    get new_two_factor_totp_url
    assert_response :success

    delete session_url
    assert_response :see_other
  end

  test "an un-enrolled member can still reach 2FA enrollment under the mandate" do
    member = users(:member)
    sign_in_as member

    previous = ENV["MAIL_ON_RAILS_REQUIRE_2FA"]
    ENV["MAIL_ON_RAILS_REQUIRE_2FA"] = "1"

    get new_two_factor_totp_url
    assert_response :success

    get edit_user_url(member)
    assert_response :success
  ensure
    previous ? ENV["MAIL_ON_RAILS_REQUIRE_2FA"] = previous : ENV.delete("MAIL_ON_RAILS_REQUIRE_2FA")
  end

  test "unauthenticated endpoints are unaffected by the role gate" do
    get new_session_url
    assert_response :success

    get "/.well-known/mta-sts.txt"
    assert_response :not_found  # no policy configured in test; not a redirect
  end
end
