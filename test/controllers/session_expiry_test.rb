require "test_helper"

class SessionExpiryTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "an idle-expired session is refused and destroyed" do
    sign_in_as(@user)
    get root_path
    assert_response :success

    travel Session.idle_timeout + 1.hour do
      get root_path

      assert_redirected_to new_session_path
      assert_equal 0, @user.sessions.count, "expired session row is removed"
    end
  end

  test "activity slides the idle window past the timeout" do
    sign_in_as(@user)

    travel Session.idle_timeout - 1.hour do
      get root_path
      assert_response :success
    end

    # Total elapsed time now exceeds the idle timeout, but the mid-way
    # request refreshed last_active_at.
    travel Session.idle_timeout + Session.idle_timeout - 2.hours do
      get root_path
      assert_response :success
    end
  end

  test "activity writes are throttled to TOUCH_INTERVAL" do
    sign_in_as(@user)
    session = @user.sessions.sole
    stamp = session.last_active_at

    get root_path
    assert_equal stamp, session.reload.last_active_at, "no write within the interval"

    travel Session::TOUCH_INTERVAL + 1.minute do
      get root_path
      assert_operator session.reload.last_active_at, :>, stamp
    end
  end

  test "prune! removes only idle-expired sessions" do
    fresh = @user.sessions.create!
    stale = @user.sessions.create!
    stale.update_column(:last_active_at, (Session.idle_timeout + 1.hour).ago)

    Session.prune!

    assert Session.exists?(fresh.id)
    assert_not Session.exists?(stale.id)
  end

  test "active scope excludes idle-expired sessions" do
    fresh = @user.sessions.create!
    stale = @user.sessions.create!
    stale.update_column(:last_active_at, (Session.idle_timeout + 1.hour).ago)

    assert_includes Session.active, fresh
    assert_not_includes Session.active, stale
  end

  # An always-active session must still be re-challenged eventually, so a
  # stolen cookie that keeps sliding cannot live forever.
  test "a session past the absolute lifetime cap is expired, pruned, and refused" do
    old = (Session.max_lifetime + 1.day).ago
    capped = @user.sessions.create!(last_active_at: Time.current)
    capped.update_column(:created_at, old)

    assert capped.expired?, "a session older than the cap is expired even when recently active"
    assert_not_includes Session.active, capped

    Session.prune!
    assert_not Session.exists?(capped.id), "an over-cap session row is pruned"
  end

  test "a session within the cap is not expired by it" do
    within = @user.sessions.create!(last_active_at: Time.current)
    within.update_column(:created_at, (Session.max_lifetime - 1.day).ago)

    assert_not within.expired?
    assert_includes Session.active, within
  end
end
