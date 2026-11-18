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

  # -- wrong-code lock (User::OTP_FAILURES_PER_LOCK) ---------------------------

  def user_with_otp
    users(:one).tap { |user| user.update!(otp_secret: ROTP::Base32.random) }
  end

  def fail_otp(user, times)
    times.times { assert_not user.verify_otp("000000") }
  end

  test "wrong codes below the limit do not lock, and an accepted code resets the count" do
    user = user_with_otp
    fail_otp(user, User::OTP_FAILURES_PER_LOCK - 1)

    assert_not user.otp_locked?
    assert user.verify_otp(ROTP::TOTP.new(user.otp_secret).now)
    assert_equal 0, user.reload.otp_failed_attempts
  end

  test "the fifth consecutive wrong code locks verification, and a correct code is refused while locked" do
    user = user_with_otp
    freeze_time do
      fail_otp(user, User::OTP_FAILURES_PER_LOCK)

      assert user.otp_locked?
      assert_equal User::OTP_LOCK_BASE.from_now, user.otp_locked_until
      assert_not user.verify_otp(ROTP::TOTP.new(user.otp_secret).now), "nothing is checked while locked"
      assert_equal User::OTP_FAILURES_PER_LOCK, user.reload.otp_failed_attempts, "refused attempts are not counted"
    end
  end

  # The audit's grind: fail to the limit, wait out the block, repeat. Each
  # block must be twice the last instead of the count starting over.
  test "each further batch of wrong codes doubles the block, up to the cap" do
    user = user_with_otp
    now = Time.current
    blocks = []

    12.times do
      travel_to now do
        fail_otp(user, User::OTP_FAILURES_PER_LOCK)
        blocks << (user.otp_locked_until - Time.current).round
      end
      now = user.otp_locked_until + 1.second
    end

    assert_equal [ 300, 600, 1200, 2400, 4800, 9600, 19_200, 38_400, 76_800, 86_400, 86_400, 86_400 ], blocks
    assert_equal 12 * User::OTP_FAILURES_PER_LOCK, user.reload.otp_failed_attempts
  end

  test "waiting out a block does not reset the count; only an accepted code does" do
    user = user_with_otp
    fail_otp(user, User::OTP_FAILURES_PER_LOCK)
    a_day_later = user.otp_locked_until + 1.day

    travel_to a_day_later do
      assert_not user.otp_locked?
      fail_otp(user, User::OTP_FAILURES_PER_LOCK)
      assert_in_delta 2 * User::OTP_LOCK_BASE, user.otp_locked_until - Time.current, 1
    end

    travel_to user.otp_locked_until + 1.second do
      assert user.verify_otp(ROTP::TOTP.new(user.otp_secret).now)
      assert_equal 0, user.reload.otp_failed_attempts
      assert_nil user.otp_locked_until
    end
  end

  # A second instance holding a stale copy of the row (a parallel request)
  # must re-read the lock inside the row lock rather than check its code
  # against the count as it stood before the burst.
  test "a concurrent instance cannot guess past a lock it has not seen yet" do
    user = user_with_otp
    stale = User.find(user.id)
    fail_otp(user, User::OTP_FAILURES_PER_LOCK)

    assert_not stale.verify_otp(ROTP::TOTP.new(user.otp_secret).now)
    assert_equal User::OTP_FAILURES_PER_LOCK, user.reload.otp_failed_attempts
  end

  test "clear_otp_lock! forgets the count and the block" do
    user = user_with_otp
    fail_otp(user, User::OTP_FAILURES_PER_LOCK)

    user.clear_otp_lock!

    assert_not user.reload.otp_locked?
    assert_equal 0, user.otp_failed_attempts
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
