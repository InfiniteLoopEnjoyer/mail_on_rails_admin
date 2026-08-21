require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user
  end

  test "requires authentication" do
    sign_out
    get users_url
    assert_redirected_to new_session_url
  end

  test "index lists users" do
    get users_url
    assert_response :success
    assert_select ".primary", text: @user.email_address
    assert_select "turbo-cable-stream-source", 1
  end

  test "creates a user with a generated password shown once" do
    assert_difference "User.count", 1 do
      post users_url, params: { user: { email_address: "new@example.com" } }
    end
    user = User.find_by(email_address: "new@example.com")
    assert_redirected_to edit_user_url(user)

    follow_redirect!
    plaintext = extract_generated_password
    assert user.authenticate(plaintext)

    get edit_user_url(user)
    assert_not_includes response.body, plaintext
  end

  test "editing your own account shows passkeys and totp state" do
    @user.webauthn_credentials.create!(external_id: "abc", public_key: "pk", nickname: "My YubiKey")

    get edit_user_url(@user)

    assert_response :success
    assert_match "My YubiKey", response.body
    assert_match "Set up authenticator app", response.body
  end

  test "editing another user hides the two-factor sections" do
    get edit_user_url(users(:two))

    assert_response :success
    assert_no_match "Set up authenticator app", response.body
    assert_no_match "Register passkey", response.body
  end

  test "rejects a duplicate email address" do
    assert_no_difference "User.count" do
      post users_url, params: { user: { email_address: @user.email_address } }
    end
    assert_response :unprocessable_entity
  end

  test "update ignores password params" do
    other = users(:two)
    patch user_url(other), params: { user: { email_address: "renamed@example.com", password: "sneaky" } }
    assert_redirected_to users_url
    other.reload
    assert_equal "renamed@example.com", other.email_address
    assert other.authenticate("password")
    assert_not other.authenticate("sneaky")
  end

  test "generate_password for another user rotates their password and destroys their sessions" do
    other = users(:two)
    other.sessions.create!

    post generate_password_user_url(other), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_select "turbo-stream[action=replace][target=password-generator]"

    plaintext = extract_generated_password
    other.reload
    assert other.authenticate(plaintext)
    assert_not other.authenticate("password")
    assert_empty other.sessions

    get edit_user_url(other)
    assert_not_includes response.body, plaintext
  end

  test "generate_password for yourself ends every session and forces re-login" do
    @user.sessions.create!

    post generate_password_user_url(@user)
    assert_redirected_to new_session_url
    assert_empty @user.sessions.reload, "rotating your own password must drop every session, this one included"

    # The one-time plaintext rides the flash to the sign-in page.
    follow_redirect!
    assert_includes response.body, extract_generated_password

    # The session cookie is gone: a protected page bounces to sign-in.
    get users_url
    assert_redirected_to new_session_url
  end

  test "generate_password requires recent re-authentication" do
    # A real logout clears the step-up window; sign back in as a resumed
    # cookie (no fresh proof) and the rotation must be gated.
    delete session_path
    sign_in_as @user, step_up: false
    other = users(:two)

    post generate_password_user_url(other)
    assert_redirected_to new_reauthentication_path
    assert other.reload.authenticate("password"), "a resumed cookie must not rotate a password"
  end

  test "destroys a user" do
    assert_difference "User.count", -1 do
      delete user_url(users(:two))
    end
    assert_redirected_to users_url
  end

  test "destroying yourself signs you out" do
    assert_difference "User.count", -1 do
      delete user_url(@user)
    end
    assert_redirected_to new_session_url
    assert_nil User.find_by(id: @user.id)

    get users_url
    assert_redirected_to new_session_url
  end

  test "the only remaining user cannot be deleted" do
    User.excluding(@user).delete_all

    assert_no_difference "User.count" do
      delete user_url(@user)
    end
    assert_redirected_to users_url

    get users_url
    assert_response :success, "the session must survive the refused delete"
  end

  # -- roles ------------------------------------------------------------------

  test "a member manages only themselves" do
    member = users(:member)
    sign_in_as member

    get edit_user_url(member)
    assert_response :success

    get edit_user_url(users(:two))
    assert_response :not_found

    get users_url
    assert_redirected_to root_url
  end

  test "a member cannot promote themselves or self-grant accounts" do
    account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
    member = users(:member)
    sign_in_as member

    patch user_url(member), params: { user: { email_address: member.email_address,
                                              role: "admin", email_account_ids: [ account.id ] } }
    assert_response :redirect

    member.reload
    assert_not member.admin?
    assert_empty member.email_accounts
  end

  test "an admin assigns role and account grants" do
    account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
    member = users(:member)

    patch user_url(member), params: { user: { email_address: member.email_address,
                                              role: "member", email_account_ids: [ account.id ] } }
    assert_redirected_to users_url
    assert_equal [ account ], member.reload.email_accounts.to_a

    # Unchecking every box (the hidden blank field) clears the grants.
    patch user_url(member), params: { user: { email_address: member.email_address,
                                              role: "member", email_account_ids: [ "" ] } }
    assert_empty member.reload.email_accounts
  end

  test "the last admin cannot be deleted" do
    User.where(role: "admin").excluding(@user).delete_all

    assert_no_difference "User.count" do
      delete user_url(@user)
    end
    assert_redirected_to users_url
    assert @user.reload.admin?
  end

  test "the last admin cannot be demoted" do
    User.where(role: "admin").excluding(@user).delete_all

    patch user_url(@user), params: { user: { email_address: @user.email_address, role: "member" } }
    assert_redirected_to edit_user_url(@user)
    assert @user.reload.admin?
  end

  test "the delete button is hidden for the only remaining user" do
    User.excluding(@user).delete_all

    get edit_user_url(@user)

    assert_response :success
    assert_empty css_select("form[action='#{user_path(@user)}'] input[name=_method][value=delete]"),
      "no delete-user button when only one user is left"
  end
end
