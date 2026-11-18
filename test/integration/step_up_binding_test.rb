require "test_helper"
require "webauthn/fake_client"

# The step-up window (Reauthentication) lives in the Rack session, while
# identity is a separate signed session_id cookie. These tests swap one
# cookie next to the other - what someone holding a stolen session_id
# cookie plus any login of their own can do - and prove that nothing
# earned under one identity carries over to the other.
class StepUpBindingTest < ActionDispatch::IntegrationTest
  ORIGIN = "http://www.example.com"

  def signed_session_cookie_for(session_row)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session_row.id
    jar[:session_id]
  end

  def ban(cidr)
    post banned_ips_path, params: { banned_ip: { cidr: cidr } }
  end

  setup do
    @admin = users(:one)
    @member = users(:member)
    # A resumed admin session with no step-up: what the gates exist to stop.
    @admin_session = @admin.sessions.create!
  end

  test "a window opened by signing in as one user does not authorize another user's session cookie" do
    post session_path, params: { email_address: @member.email_address, password: "password" }
    assert_redirected_to root_url

    # Keep the member's Rack session (freshly stamped); present the admin's id.
    cookies["session_id"] = signed_session_cookie_for(@admin_session)

    ban "198.51.100.7"
    assert_redirected_to new_reauthentication_path
    assert_nil MailOnRails::BannedIp.find_by(cidr: "198.51.100.7")

    post generate_password_user_path(users(:two)), as: :turbo_stream
    assert_redirected_to new_reauthentication_path
    assert users(:two).reload.authenticate("password"), "the other admin's password must be untouched"
  end

  test "a window opened by the reauthentication prompt is bound the same way" do
    sign_in_as @member, step_up: false
    post reauthentication_path, params: { password: "password" }
    assert_response :redirect

    cookies["session_id"] = signed_session_cookie_for(@admin_session)
    ban "198.51.100.8"

    assert_redirected_to new_reauthentication_path
    assert_nil MailOnRails::BannedIp.find_by(cidr: "198.51.100.8")
  end

  test "a window does not carry to another session of the same user" do
    sign_in_as @admin # stamps the window for this session
    ban "198.51.100.9"
    assert MailOnRails::BannedIp.find_by(cidr: "198.51.100.9"), "control: the stamped session passes"

    cookies["session_id"] = signed_session_cookie_for(@admin_session)
    ban "198.51.100.10"

    assert_redirected_to new_reauthentication_path
    assert_nil MailOnRails::BannedIp.find_by(cidr: "198.51.100.10")
  end

  test "the window still works for the session that earned it, and lapses on time" do
    post session_path, params: { email_address: @admin.email_address, password: "password" }

    ban "198.51.100.11"
    assert MailOnRails::BannedIp.find_by(cidr: "198.51.100.11")

    travel 11.minutes do
      ban "198.51.100.12"
      assert_redirected_to new_reauthentication_path
    end
  end

  # Cookies issued before the binding carry a bare deadline. Honoring it
  # would keep the transplant open for anyone holding such a cookie, so it
  # reads as no window at all (one extra prompt after the upgrade). Asked
  # of the gate directly: the session cookie is encrypted, so a request
  # cannot be handed one with the old key in it.
  test "a window stamped the old way (a bare deadline) is not honored" do
    controller = BannedIpsController.new
    controller.request = ActionDispatch::TestRequest.create
    controller.request.session = ActionController::TestSession.new("reauthenticated_until" => 10.minutes.from_now.to_i)
    Current.session = @admin_session

    assert_not controller.send(:reauthenticated_recently?)
  ensure
    Current.reset
  end

  test "a pending TOTP secret minted under one identity cannot be confirmed under another" do
    sign_in_as @member
    get new_two_factor_totp_path
    attacker_secret = css_select("code").first.text

    # Even with a window of the victim's own (the worst case for this
    # stash), the candidate secret belongs to the member's session.
    cookies["session_id"] = signed_session_cookie_for(@admin_session)
    reauthenticate
    post two_factor_totp_path, params: { code: ROTP::TOTP.new(attacker_secret).now }

    assert_redirected_to new_two_factor_totp_path
    assert_not @admin.reload.otp_enabled?, "the attacker's secret must not become the admin's authenticator"

    # The page mints a fresh secret for the admin instead of showing the
    # transplanted one.
    get new_two_factor_totp_path
    assert_not_equal attacker_secret, css_select("code").first.text
  end

  test "a passkey enrollment challenge issued to one identity cannot be redeemed by another" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    sign_in_as @member
    post options_two_factor_passkeys_path, as: :json
    credential = client.create(challenge: response.parsed_body["challenge"], user_verified: true)

    cookies["session_id"] = signed_session_cookie_for(@admin_session)
    reauthenticate
    assert_no_difference -> { WebauthnCredential.count } do
      post two_factor_passkeys_path, params: { credential: credential, nickname: "Planted" }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "a step-up challenge cannot be redeemed at the enrollment endpoint or vice versa" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    sign_in_as @admin

    # A challenge minted for step-up...
    post webauthn_options_reauthentication_path, as: :json
    credential = client.create(challenge: response.parsed_body["challenge"], user_verified: true)
    # ...is not accepted to enroll a passkey.
    assert_no_difference -> { WebauthnCredential.count } do
      post two_factor_passkeys_path, params: { credential: credential, nickname: "Wrong ceremony" }, as: :json
    end
    assert_response :unprocessable_entity

    # Control: the enrollment challenge enrolls.
    post options_two_factor_passkeys_path, as: :json
    credential = client.create(challenge: response.parsed_body["challenge"], user_verified: true)
    assert_difference -> { @admin.webauthn_credentials.count }, 1 do
      post two_factor_passkeys_path, params: { credential: credential, nickname: "Right ceremony" }, as: :json
    end
  end

  test "a sign-in passkey challenge issued for one pending user is not inherited by the next" do
    client = WebAuthn::FakeClient.new(ORIGIN)
    sign_in_as @admin
    post options_two_factor_passkeys_path, as: :json
    post two_factor_passkeys_path, as: :json,
         params: { credential: client.create(challenge: response.parsed_body["challenge"], user_verified: true) }
    assert_response :success
    @member.update!(otp_secret: ROTP::Base32.random)
    delete session_path

    # Password stage as the member, who asks for a passkey challenge...
    post session_path, params: { email_address: @member.email_address, password: "password" }
    post webauthn_options_two_factor_challenge_path, as: :json
    challenge = response.parsed_body["challenge"]

    # ...then a password stage as the admin in the same browser. The
    # admin's (genuine) assertion over the member's challenge is refused.
    post session_path, params: { email_address: @admin.email_address, password: "password" }
    post webauthn_two_factor_challenge_path,
         params: { credential: client.get(challenge: challenge, user_verified: true) }, as: :json
    assert_response :unprocessable_entity
    assert_nil cookies[:session_id].presence

    # Control: a challenge issued for the admin's own pending sign-in works.
    post webauthn_options_two_factor_challenge_path, as: :json
    post webauthn_two_factor_challenge_path, as: :json,
         params: { credential: client.get(challenge: response.parsed_body["challenge"], user_verified: true) }
    assert_response :success
    assert cookies[:session_id].present?
  end

  test "signing out ends the window" do
    post session_path, params: { email_address: @admin.email_address, password: "password" }
    delete session_path

    sign_in_as @admin, step_up: false
    ban "198.51.100.14"
    assert_redirected_to new_reauthentication_path
  end
end
