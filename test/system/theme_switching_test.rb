require "application_system_test_case"

# The appearance picker on the profile page drives the theme Stimulus
# controller: a click restamps <html> immediately (class + data-appearance)
# and PATCHes the preference, which is what makes the choice survive a
# full reload on any device.
class ThemeSwitchingTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  # Polls the persisted preference: the PATCH the picker fires is async, so
  # the DB row trails the instant <html> restamp by one request.
  def wait_for_saved_appearance(value, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until @user.reload.appearance == value
      flunk "appearance #{value.inspect} was not saved within #{timeout}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.2
    end
  end

  test "picking Dark stamps <html> immediately and survives a reload" do
    visit edit_user_url(@user)
    assert_selector "h2", text: "Appearance"

    click_on "Dark"

    assert_selector "html.dark[data-appearance='dark']"
    assert_selector "button[aria-pressed='true']", text: "Dark"

    # Reload only after the PATCH has landed; the server must now paint
    # dark from the first byte, before any JavaScript runs.
    wait_for_saved_appearance "dark"
    visit edit_user_url(@user)
    assert_selector "html.dark[data-appearance='dark']"
  end

  test "switching back to Light removes the dark class" do
    @user.update!(appearance: "dark")
    visit edit_user_url(@user)
    assert_selector "html.dark"

    click_on "Light"

    assert_selector "html[data-appearance='light']"
    assert_no_selector "html.dark"

    wait_for_saved_appearance "light"
    visit edit_user_url(@user)
    assert_selector "html[data-appearance='light']"
    assert_no_selector "html.dark"
  end
end
