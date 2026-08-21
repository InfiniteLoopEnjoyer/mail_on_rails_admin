require "test_helper"
require "webauthn/fake_client"

class TwoFactor::PasskeysControllerTest < ActionDispatch::IntegrationTest
  ORIGIN = "http://www.example.com"

  setup { @user = users(:one) }

  test "options requires authentication" do
    post options_two_factor_passkeys_path
    assert_redirected_to new_session_path
  end

  test "register and remove a passkey" do
    sign_in_as(@user)

    post options_two_factor_passkeys_path, as: :json
    assert_response :success
    credential = WebAuthn::FakeClient.new(ORIGIN).create(challenge: response.parsed_body["challenge"], user_verified: true)

    assert_difference -> { @user.webauthn_credentials.count }, 1 do
      post two_factor_passkeys_path, params: { credential: credential, nickname: "Test key" }, as: :json
    end
    assert_response :success
    assert_equal edit_user_url(@user), response.parsed_body["location"]

    passkey = @user.webauthn_credentials.last
    assert_equal "Test key", passkey.nickname
    assert @user.reload.webauthn_id.present?, "user handle minted on first registration"

    reauthenticate
    delete two_factor_passkey_path(passkey)
    assert_redirected_to edit_user_path(@user)
    assert_not WebauthnCredential.exists?(passkey.id)
  end

  test "removal requires recent re-authentication" do
    passkey = @user.webauthn_credentials.create!(external_id: "own", public_key: "pk", nickname: "Mine")
    sign_in_as(@user, step_up: false)

    delete two_factor_passkey_path(passkey)
    assert_redirected_to new_reauthentication_path
    assert WebauthnCredential.exists?(passkey.id), "must not remove without step-up"

    reauthenticate
    delete two_factor_passkey_path(passkey)
    assert_redirected_to edit_user_path(@user)
    assert_not WebauthnCredential.exists?(passkey.id)
  end

  test "enrollment requires recent re-authentication and answers JSON with a reauth url" do
    sign_in_as(@user, step_up: false)

    post options_two_factor_passkeys_path, as: :json
    assert_response :forbidden
    assert_equal new_reauthentication_path, response.parsed_body["reauth_url"]

    reauthenticate
    post options_two_factor_passkeys_path, as: :json
    assert_response :success
  end

  test "registration without a live challenge is rejected" do
    sign_in_as(@user)
    credential = WebAuthn::FakeClient.new(ORIGIN).create(user_verified: true)

    assert_no_difference -> { WebauthnCredential.count } do
      post two_factor_passkeys_path, params: { credential: credential, nickname: "Test key" }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "registration without user verification is rejected" do
    sign_in_as(@user)
    post options_two_factor_passkeys_path, as: :json
    credential = WebAuthn::FakeClient.new(ORIGIN).create(challenge: response.parsed_body["challenge"], user_verified: false)

    assert_no_difference -> { WebauthnCredential.count } do
      post two_factor_passkeys_path, params: { credential: credential, nickname: "No UV" }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "cannot remove another user's passkey" do
    other = users(:two).webauthn_credentials.create!(external_id: "abc", public_key: "pk", nickname: "Other")
    sign_in_as(@user)
    reauthenticate

    delete two_factor_passkey_path(other)
    assert_response :not_found
  end
end
