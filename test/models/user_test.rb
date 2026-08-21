require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "verify_otp accepts a current code once and rejects replays" do
    user = users(:one)
    user.update!(otp_secret: ROTP::Base32.random)
    code = ROTP::TOTP.new(user.otp_secret).now

    assert user.verify_otp(code)
    assert_not user.verify_otp(code), "the same timestep must not verify twice"
  end

  # Two requests presenting the same code must not both burn it: the row
  # lock serializes verify+burn, so a separate instance re-reading the
  # already-burned timestep is rejected.
  test "verify_otp burns a code atomically against a concurrent instance" do
    user = users(:one)
    user.update!(otp_secret: ROTP::Base32.random)
    code = ROTP::TOTP.new(user.otp_secret).now
    concurrent = User.find(user.id)

    assert user.verify_otp(code)
    assert_not concurrent.verify_otp(code),
               "a second instance must re-read the burned timestep inside the lock and reject"
  end

  test "verify_otp rejects wrong codes and users without a secret" do
    user = users(:one)
    assert_not user.verify_otp("000000")

    user.update!(otp_secret: ROTP::Base32.random)
    assert_not user.verify_otp("000000")
  end

  test "role must be admin or member" do
    user = users(:one)
    user.role = "superuser"
    assert_not user.valid?

    User::ROLES.each do |role|
      user.role = role
      assert user.valid?, "#{role} must be a valid role"
    end
  end

  test "admin? reflects the role" do
    assert users(:one).admin?
    assert_not users(:member).admin?
  end

  test "accessible_email_accounts is everything for an admin, grants for a member" do
    granted = MailOnRails::EmailAccount.create!(email: "granted@example.com", password: "secret123")
    other = MailOnRails::EmailAccount.create!(email: "other@example.com", password: "secret123")

    member = users(:member)
    member.email_accounts << granted

    assert_includes users(:one).accessible_email_accounts, granted
    assert_includes users(:one).accessible_email_accounts, other

    assert_includes member.accessible_email_accounts, granted
    assert_not_includes member.accessible_email_accounts, other
  end

  test "second_factor_enabled? with otp or a passkey" do
    user = users(:one)
    assert_not user.second_factor_enabled?

    user.update!(otp_secret: ROTP::Base32.random)
    assert user.second_factor_enabled?

    user.update!(otp_secret: nil)
    user.webauthn_credentials.create!(external_id: "abc", public_key: "pk", nickname: "Key")
    assert user.second_factor_enabled?
  end
end
