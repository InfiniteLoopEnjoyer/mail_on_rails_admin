require "test_helper"

# The second-factor mandate, on by default: a signed-in user without a
# second factor is parked on 2FA enrollment - only the enrollment
# surfaces (TOTP page, own profile for passkeys) and sign-out stay
# reachable. Users with a factor are unaffected;
# MAIL_ON_RAILS_REQUIRE_2FA=0 is the explicit opt-out (the test harness
# pins it for the rest of the suite).
class RequireTwoFactorTest < ActionDispatch::IntegrationTest
  def with_require_2fa(value = "1")
    previous = ENV["MAIL_ON_RAILS_REQUIRE_2FA"]
    value ? ENV["MAIL_ON_RAILS_REQUIRE_2FA"] = value : ENV.delete("MAIL_ON_RAILS_REQUIRE_2FA")
    yield
  ensure
    previous ? ENV["MAIL_ON_RAILS_REQUIRE_2FA"] = previous : ENV.delete("MAIL_ON_RAILS_REQUIRE_2FA")
  end

  test "an un-enrolled user is redirected to TOTP enrollment everywhere else" do
    sign_in_as users(:one)
    with_require_2fa do
      get root_url
      assert_redirected_to new_two_factor_totp_path

      get audit_events_url
      assert_redirected_to new_two_factor_totp_path
    end
  end

  test "enrollment surfaces and sign-out stay reachable for an un-enrolled user" do
    user = users(:one)
    sign_in_as user
    with_require_2fa do
      get new_two_factor_totp_url
      assert_response :success

      get edit_user_url(user)
      assert_response :success

      # Another user's page is not an enrollment surface.
      get edit_user_url(users(:two))
      assert_redirected_to new_two_factor_totp_path

      delete session_url
      assert_response :see_other
    end
  end

  test "a user with a second factor browses normally" do
    user = users(:one)
    user.update!(otp_secret: ROTP::Base32.random)
    sign_in_as user
    with_require_2fa do
      get root_url
      assert_response :success
    end
  end

  test "unset means required - the mandate is the default, not an opt-in" do
    sign_in_as users(:one)
    with_require_2fa(nil) do
      get root_url
      assert_redirected_to new_two_factor_totp_path
    end
  end

  test "an explicit 0 opts out" do
    sign_in_as users(:one)
    with_require_2fa("0") do
      get root_url
      assert_response :success
    end
  end

  test "unauthenticated endpoints are unaffected by the flag" do
    with_require_2fa do
      get new_session_url
      assert_response :success
    end
  end
end
