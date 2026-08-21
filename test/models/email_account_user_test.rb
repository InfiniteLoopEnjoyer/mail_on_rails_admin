require "test_helper"

class EmailAccountUserTest < ActiveSupport::TestCase
  setup do
    @account = MailOnRails::EmailAccount.create!(email: "granted@example.com", password: "secret123")
    @member = users(:member)
  end

  test "a grant is unique per user and account" do
    EmailAccountUser.create!(user: @member, email_account: @account)
    duplicate = EmailAccountUser.new(user: @member, email_account: @account)
    assert_not duplicate.valid?
  end

  test "deleting the account removes its grants" do
    @member.email_accounts << @account
    assert_difference "EmailAccountUser.count", -1 do
      @account.destroy!
    end
  end

  test "deleting the user removes their grants" do
    @member.email_accounts << @account
    assert_difference "EmailAccountUser.count", -1 do
      @member.destroy!
    end
    assert MailOnRails::EmailAccount.exists?(@account.id), "the account itself must survive"
  end
end
