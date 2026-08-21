require "application_system_test_case"

# The sign-in form through a real browser. Request-level tests cover the
# controller; this level proves the rendered form's fields, the flash, and
# the layout's sign-out button are actually wired together.
class SignInTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
  end

  test "signing in lands on the accounts page" do
    visit new_session_url
    fill_in "Enter your email address", with: @user.email_address
    fill_in "Enter your password", with: "password"
    click_on "Sign in"

    assert_selector "h1", text: "Email Accounts"
    assert_no_current_path new_session_path
  end

  test "a wrong password shows the error and stays on the sign-in form" do
    visit new_session_url
    fill_in "Enter your email address", with: @user.email_address
    fill_in "Enter your password", with: "wrong-password"
    click_on "Sign in"

    assert_text "Try another email address or password."
    assert_current_path new_session_path
    assert_selector "h1", text: "Sign in"
  end

  test "signing out returns to the sign-in form and ends the session" do
    sign_in_as(@user)

    click_on "Sign out"
    assert_selector "h1", text: "Sign in"
    assert_current_path new_session_path

    # The session really ended: a signed-in page now bounces back here.
    visit root_url
    assert_current_path new_session_path
  end
end
