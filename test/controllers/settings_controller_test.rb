require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end

  test "requires authentication" do
    sign_out
    get settings_url
    assert_redirected_to new_session_url
  end

  # -- rendering -------------------------------------------------------------

  test "shows dynamic settings grouped by category with schema metadata" do
    get settings_url

    # An integer knob: empty when no override, fallback as placeholder.
    assert_select "input[name='settings[smtp_max_conn]'][placeholder='100']"
    assert_select "input[name='settings[trash_retention_days]'][placeholder='30']"
    # A boolean knob renders the three-way select.
    assert_select "select[name='settings[smtp_sender_auth]'] option[value='']", text: "Default (on)"
    # Boot-only settings are never rendered.
    assert_select "input[name='settings[smtp_port]']", count: 0
    assert_select "input[name='settings[smtp_rspamd_password]']", count: 0
  end

  test "shows the stored override value and its provenance" do
    MailOnRails::Setting.trash_retention_days = 7
    get settings_url
    assert_select "input[name='settings[trash_retention_days]'][value='7']"
    assert_select "p", text: /Currently\s+7\s+\(overridden here\)/
  end

  # -- updates ---------------------------------------------------------------

  test "update saves typed values and reports success" do
    patch settings_url, params: { settings: { smtp_max_conn: "55", trash_retention_days: "45" } }
    assert_redirected_to settings_url
    assert_match(/Settings saved/, flash[:notice])
    assert_equal 55, MailOnRails::Setting.read(:smtp_max_conn)
    assert_equal 45, MailOnRails::Setting.trash_retention_days
  end

  test "update saves a boolean override and blank restores the default" do
    patch settings_url, params: { settings: { smtp_sender_auth: "0" } }
    assert_equal false, MailOnRails::Setting.read(:smtp_sender_auth)

    patch settings_url, params: { settings: { smtp_sender_auth: "" } }
    assert_equal true, MailOnRails::Setting.read(:smtp_sender_auth)
    assert_empty MailOnRails::Setting.where(key: "smtp_sender_auth")
  end

  test "update rejects junk and rolls the whole submit back" do
    patch settings_url, params: { settings: { smtp_max_conn: "55", trash_retention_days: "soon" } }
    assert_redirected_to settings_url
    assert_match(/trash_retention_days/, flash[:alert])
    assert_equal 100, MailOnRails::Setting.read(:smtp_max_conn), "one bad field must roll back the good ones"
    assert_equal 30, MailOnRails::Setting.trash_retention_days
  end

  test "update rejects out-of-bounds and non-hostname values" do
    patch settings_url, params: { settings: { trash_retention_days: "0" } }
    assert_match(/trash_retention_days/, flash[:alert])
    assert_equal 30, MailOnRails::Setting.trash_retention_days

    patch settings_url, params: { settings: { smtp_helo_hostname: "not a hostname" } }
    assert_match(/must be a hostname/, flash[:alert])
    assert_nil MailOnRails::Setting.smtp_helo_hostname_override
  end

  test "update saves the smtp hostname normalized and blank clears it" do
    patch settings_url, params: { settings: { smtp_helo_hostname: "MX.Example.Test" } }
    assert_equal "mx.example.test", MailOnRails::Setting.smtp_helo_hostname

    patch settings_url, params: { settings: { smtp_helo_hostname: "" } }
    assert_nil MailOnRails::Setting.smtp_helo_hostname_override
  end

  test "boot-only and unknown keys in the payload are ignored" do
    patch settings_url, params: { settings: { smtp_port: "2525", nonsense: "1", smtp_max_conn: "55" } }
    assert_redirected_to settings_url
    assert_match(/Settings saved/, flash[:notice])
    assert_empty MailOnRails::Setting.where(key: "smtp_port")
    assert_empty MailOnRails::Setting.where(key: "nonsense")
    assert_equal 55, MailOnRails::Setting.read(:smtp_max_conn)
  end

  test "update with no recognized settings is a no-op" do
    patch settings_url, params: { settings: { smtp_port: "2525" } }
    assert_redirected_to settings_url
    assert_match(/Nothing to save/, flash[:alert])
  end

  test "update writes an audit event" do
    assert_difference -> { AuditEvent.count } do
      patch settings_url, params: { settings: { smtp_max_conn: "55" } }
    end
    assert_equal "settings.update", AuditEvent.last.action
  end

  test "update requires recent re-authentication" do
    delete session_path
    sign_in_as users(:one), step_up: false

    patch settings_url, params: { settings: { smtp_max_conn: "55" } }
    assert_redirected_to new_reauthentication_path
    assert_nil MailOnRails::Setting.where(key: "smtp_max_conn").first,
               "a resumed cookie must not retune the mail servers"
  end

  # M9: the scanner addresses are admin-tunable at runtime, so their SSRF
  # potential is bounded by the gem-side validator (link-local/metadata
  # rejected). The controller surfaces the rejection as a flash alert.
  test "update rejects a scanner address pointed at the metadata endpoint" do
    patch settings_url, params: { settings: { smtp_rspamd_addr: "http://169.254.169.254/latest" } }

    assert_match(/rspamd/i, flash[:alert])
    assert_nil MailOnRails::Setting.where(key: "smtp_rspamd_addr").first
  end
end
