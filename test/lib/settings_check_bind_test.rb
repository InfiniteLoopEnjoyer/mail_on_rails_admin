require "test_helper"
require "mail_on_rails/settings/check"

# The production-posture warning for a listener bound to every interface
# must recognise both spellings: "0.0.0.0" and the dual-stack "::".
class SettingsCheckBindTest < ActiveSupport::TestCase
  def with_production_env
    original = Rails.env
    Rails.env = ActiveSupport::EnvironmentInquirer.new("production")
    yield
  ensure
    Rails.env = original
  end

  def warnings_with(env)
    saved = env.keys.to_h { |key| [ key, ENV[key] ] }
    env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    MailOnRails::Settings.reset!
    with_production_env { MailOnRails::Settings::Check.new.warnings }
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    MailOnRails::Settings.reset!
  end

  test "a :: bind warns like 0.0.0.0 does" do
    warnings = warnings_with("SMTP_HOST" => "::", "MAIL_ON_RAILS_HOST" => "127.0.0.1")
    warning = warnings.find { |w| w.include?("bind all interfaces") }

    assert warning, warnings.inspect
    assert_includes warning, "smtp_host"
    assert_not_includes warning, "imap_host"
  end

  test "explicit addresses do not warn" do
    warnings = warnings_with("SMTP_HOST" => "127.0.0.1", "MAIL_ON_RAILS_HOST" => "::1")

    assert_nil warnings.find { |w| w.include?("bind all interfaces") }, warnings.inspect
  end
end
