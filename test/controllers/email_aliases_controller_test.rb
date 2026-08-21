require "test_helper"

class EmailAliasesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
  end

  test "mutations require recent re-authentication" do
    # An alias intercepts inbound mail for its address - a resumed cookie
    # (no fresh proof) must be re-challenged before adding or removing one.
    email_alias = @account.email_aliases.create!(email: "sales@example.com")
    delete session_path
    sign_in_as users(:one), step_up: false

    assert_no_difference "MailOnRails::EmailAlias.count" do
      post email_account_email_aliases_url(@account), params: { email_alias: { email: "intercept@example.com" } }
    end
    assert_redirected_to new_reauthentication_path

    assert_no_difference "MailOnRails::EmailAlias.count" do
      delete email_account_email_alias_url(@account, email_alias)
    end
    assert_redirected_to new_reauthentication_path
  end

  test "adds an alias" do
    assert_difference "@account.email_aliases.count", 1 do
      post email_account_email_aliases_url(@account), params: { email_alias: { email: "Sales@Example.com" } }
    end
    assert_redirected_to email_account_url(@account)
    assert_equal "sales@example.com", @account.email_aliases.sole.email
  end

  test "rejects an alias that is already an account address" do
    assert_no_difference "MailOnRails::EmailAlias.count" do
      post email_account_email_aliases_url(@account), params: { email_alias: { email: @account.email } }
    end
    assert_redirected_to email_account_url(@account)
    assert flash[:alert].present?
  end

  test "removes an alias" do
    email_alias = @account.email_aliases.create!(email: "sales@example.com")
    assert_difference "MailOnRails::EmailAlias.count", -1 do
      delete email_account_email_alias_url(@account, email_alias)
    end
    assert_redirected_to email_account_url(@account)
  end

  test "cannot remove another account's alias" do
    other = MailOnRails::EmailAccount.create!(email: "dave@example.com", password: "secret123")
    email_alias = other.email_aliases.create!(email: "sales@example.com")

    assert_no_difference "MailOnRails::EmailAlias.count" do
      delete email_account_email_alias_url(@account, email_alias)
    end
    assert_response :not_found
  end
end
