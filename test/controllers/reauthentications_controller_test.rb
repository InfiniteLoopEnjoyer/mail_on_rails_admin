require "test_helper"
require "webauthn/fake_client"

class ReauthenticationsControllerTest < ActionDispatch::IntegrationTest
  ORIGIN = "http://www.example.com"

  setup { @user = users(:one) }

  test "requires authentication" do
    get new_reauthentication_path
    assert_redirected_to new_session_path
  end

  test "gated action redirects to the prompt and opens the window on password" do
    sign_in_as(@user, step_up: false)
    @user.update!(otp_secret: ROTP::Base32.random)

    delete two_factor_totp_path
    assert_redirected_to new_reauthentication_path

    post reauthentication_path, params: { password: "password" }
    # The stored return path (the settings page) is honored on success.
    assert_response :redirect

    delete two_factor_totp_path
    assert_redirected_to edit_user_path(@user)
    assert_not @user.reload.otp_enabled?
  end

  test "a wrong password does not open the window" do
    sign_in_as(@user, step_up: false)
    @user.update!(otp_secret: ROTP::Base32.random)

    post reauthentication_path, params: { password: "nope" }
    assert_redirected_to new_reauthentication_path

    delete two_factor_totp_path
    assert_redirected_to new_reauthentication_path
    assert @user.reload.otp_enabled?
  end

  test "a valid TOTP code opens the window" do
    secret = ROTP::Base32.random
    @user.update!(otp_secret: secret)
    sign_in_as(@user, step_up: false)

    post totp_reauthentication_path, params: { code: ROTP::TOTP.new(secret).now }
    assert_response :redirect

    delete two_factor_totp_path
    assert_redirected_to edit_user_path(@user)
  end

  test "a passkey assertion opens the window" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    sign_in_as(@user)
    post options_two_factor_passkeys_path, as: :json
    credential = client.create(challenge: response.parsed_body["challenge"], user_verified: true)
    post two_factor_passkeys_path, params: { credential: credential, nickname: "Key" }, as: :json
    assert_response :success

    post webauthn_options_reauthentication_path, as: :json
    challenge = response.parsed_body["challenge"]
    post webauthn_reauthentication_path,
      params: { credential: client.get(challenge: challenge, user_verified: true) }, as: :json
    assert_response :success

    passkey = @user.webauthn_credentials.last
    delete two_factor_passkey_path(passkey)
    assert_redirected_to edit_user_path(@user)
    assert_not WebauthnCredential.exists?(passkey.id)
  end

  test "repeated failures are throttled" do
    sign_in_as(@user)

    11.times { post reauthentication_path, params: { password: "nope" } }
    assert_redirected_to new_reauthentication_path
    assert_match(/Try again later/, flash[:alert])
  end
end
