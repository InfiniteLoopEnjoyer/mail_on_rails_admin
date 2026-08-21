require "test_helper"

class SettingTest < ActiveSupport::TestCase
  test "trash retention defaults to 30 days with no row" do
    assert_empty MailOnRails::Setting.where(key: "trash_retention_days")
    assert_equal 30, MailOnRails::Setting.trash_retention_days
  end

  test "trash retention round-trips and updates in place" do
    MailOnRails::Setting.trash_retention_days = 7
    assert_equal 7, MailOnRails::Setting.trash_retention_days

    MailOnRails::Setting.trash_retention_days = "14"
    assert_equal 14, MailOnRails::Setting.trash_retention_days
    assert_equal 1, MailOnRails::Setting.where(key: "trash_retention_days").count
  end

  test "trash retention rejects junk and non-positive values" do
    assert_raises(ArgumentError) { MailOnRails::Setting.trash_retention_days = "soon" }
    assert_raises(ArgumentError) { MailOnRails::Setting.trash_retention_days = 0 }
    assert_raises(ArgumentError) { MailOnRails::Setting.trash_retention_days = -3 }
    assert_equal 30, MailOnRails::Setting.trash_retention_days
  end

  test "trash retention blank or nil clears the override" do
    MailOnRails::Setting.trash_retention_days = 7
    MailOnRails::Setting.trash_retention_days = nil
    assert_empty MailOnRails::Setting.where(key: "trash_retention_days")
    assert_equal 30, MailOnRails::Setting.trash_retention_days
  end

  # -- generic schema write/read/clear --------------------------------------

  test "write refuses unknown and boot-only keys" do
    assert_raises(ArgumentError) { MailOnRails::Setting.write(:no_such_setting, "1") }
    error = assert_raises(ArgumentError) { MailOnRails::Setting.write(:smtp_port, "2525") }
    assert_match(/boot-only/, error.message)
  end

  test "write stores canonical forms and read returns typed values" do
    MailOnRails::Setting.write(:smtp_sender_auth, "0")
    assert_equal "0", MailOnRails::Setting.find_by(key: "smtp_sender_auth").value
    assert_equal false, MailOnRails::Setting.read(:smtp_sender_auth)

    MailOnRails::Setting.write(:smtp_rbl_zones, "zen.spamhaus.org bl.example.org")
    assert_equal %w[zen.spamhaus.org bl.example.org], MailOnRails::Setting.read(:smtp_rbl_zones)
  end

  # -- SMTP HELO hostname ----------------------------------------------------

  teardown do
    ENV.delete("SMTP_HELO_HOST")
  end

  test "smtp helo hostname precedence: setting, then env, then system hostname" do
    assert_nil MailOnRails::Setting.smtp_helo_hostname
    assert_equal Socket.gethostname, MailOnRails::Setting.effective_smtp_helo_hostname

    ENV["SMTP_HELO_HOST"] = "Env.Example.Test"
    assert_equal "env.example.test", MailOnRails::Setting.smtp_helo_hostname

    MailOnRails::Setting.smtp_helo_hostname = "mail.example.test"
    assert_equal "mail.example.test", MailOnRails::Setting.smtp_helo_hostname
    assert_equal "mail.example.test", MailOnRails::Setting.effective_smtp_helo_hostname
  end

  test "smtp helo hostname setter normalizes and blank clears the override" do
    MailOnRails::Setting.smtp_helo_hostname = "  MX.Example.Test "
    assert_equal "mx.example.test", MailOnRails::Setting.smtp_helo_hostname_override

    MailOnRails::Setting.smtp_helo_hostname = ""
    assert_nil MailOnRails::Setting.smtp_helo_hostname_override
    assert_empty MailOnRails::Setting.where(key: "smtp_helo_hostname")
  end

  test "smtp helo hostname rejects non-hostnames" do
    [ "mail host", "-bad.example", "bad-.example", "mail..example", "mail.example/25", "a" * 256 ].each do |bad|
      assert_raises(ArgumentError, bad) { MailOnRails::Setting.smtp_helo_hostname = bad }
    end
    assert_nil MailOnRails::Setting.smtp_helo_hostname_override
  end
end
