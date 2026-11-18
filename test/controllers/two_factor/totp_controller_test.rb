require "test_helper"

class TwoFactor::TotpControllerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires authentication" do
    get new_two_factor_totp_path
    assert_redirected_to new_session_path
  end

  test "enable with a valid code, then disable" do
    sign_in_as(@user)

    get new_two_factor_totp_path
    assert_response :success
    secret = css_select("code").first.text

    post two_factor_totp_path, params: { code: ROTP::TOTP.new(secret).now }
    assert_redirected_to edit_user_path(@user)
    assert @user.reload.otp_enabled?
    assert_equal secret, @user.otp_secret

    reauthenticate
    delete two_factor_totp_path
    assert_redirected_to edit_user_path(@user)
    assert_not @user.reload.otp_enabled?
  end

  test "disabling requires recent re-authentication" do
    sign_in_as(@user, step_up: false)
    @user.update!(otp_secret: ROTP::Base32.random)

    delete two_factor_totp_path
    assert_redirected_to new_reauthentication_path
    assert @user.reload.otp_enabled?, "must not disable without step-up"

    reauthenticate
    delete two_factor_totp_path
    assert_redirected_to edit_user_path(@user)
    assert_not @user.reload.otp_enabled?
  end

  test "enrolling requires recent re-authentication" do
    sign_in_as(@user, step_up: false)

    get new_two_factor_totp_path
    assert_redirected_to new_reauthentication_path, "a resumed cookie must not reach enrollment"

    reauthenticate
    get new_two_factor_totp_path
    assert_response :success
    secret = css_select("code").first.text
    post two_factor_totp_path, params: { code: ROTP::TOTP.new(secret).now }
    assert @user.reload.otp_enabled?
  end

  # A thief's resumed cookie must not outlive the owner tightening (or an
  # attacker loosening) the account's second factor.
  test "enabling and disabling the authenticator each end the user's other sessions, not this one" do
    other = @user.sessions.create!
    bystander = users(:two).sessions.create!
    sign_in_as(@user)

    get new_two_factor_totp_path
    post two_factor_totp_path, params: { code: ROTP::TOTP.new(css_select("code").first.text).now }
    assert @user.reload.otp_enabled?
    assert_not Session.exists?(other.id), "enrolling must end the user's other sessions"
    assert Session.exists?(bystander.id), "other users are untouched"
    get edit_user_path(@user)
    assert_response :success, "the session that made the change stays signed in"

    another = @user.sessions.create!
    delete two_factor_totp_path
    assert_not @user.reload.otp_enabled?
    assert_not Session.exists?(another.id), "removing the factor must end the user's other sessions"
    get edit_user_path(@user)
    assert_response :success
  end

  test "a failed enrollment code ends nothing" do
    other = @user.sessions.create!
    sign_in_as(@user)
    get new_two_factor_totp_path

    post two_factor_totp_path, params: { code: "000000" }

    assert Session.exists?(other.id)
  end

  test "re-enrolling the authenticator clears a wrong-code lock on the old secret" do
    @user.update!(otp_secret: ROTP::Base32.random)
    @user.update_columns(otp_failed_attempts: 10, otp_locked_until: 1.hour.from_now)
    sign_in_as(@user)

    get new_two_factor_totp_path
    post two_factor_totp_path, params: { code: ROTP::TOTP.new(css_select("code").first.text).now }

    assert_not @user.reload.otp_locked?
    assert_equal 0, @user.otp_failed_attempts
  end

  test "wrong confirmation code does not enable" do
    sign_in_as(@user)
    get new_two_factor_totp_path

    post two_factor_totp_path, params: { code: "000000" }

    assert_redirected_to new_two_factor_totp_path
    assert_not @user.reload.otp_enabled?
  end

  test "confirming keeps the same secret across re-renders" do
    sign_in_as(@user)
    get new_two_factor_totp_path
    secret = css_select("code").first.text

    get new_two_factor_totp_path
    assert_equal secret, css_select("code").first.text, "re-render must not rotate the pending secret"
  end
end
