ENV["RAILS_ENV"] ||= "test"
# ClamavScanner defaults to the clamav accessory's docker address when the
# env is unset; pin it off so un-stubbed code paths never open a socket.
# Tests exercising the scanner stub it (ClamavStubHelper) or set their own
# address (clamav_scanner_test.rb).
ENV["SMTP_CLAMAV_ADDR"] ||= ""
# The 2FA mandate is on by default; fixture users have no second factor,
# so pin it off here. require_two_factor_test flips it per-case
# (including deleting it to prove unset means required).
ENV["MAIL_ON_RAILS_REQUIRE_2FA"] ||= "0"
require_relative "../config/environment"
require "rails/test_help"

# Transactional tests never fire after_commit, so the settings cache's
# push-refresh never runs here; a zero TTL makes every read pull the
# current rows through the test transaction's own connection. The pull
# must also skip the engine's executor wrap: an executor cycle on a bare
# test thread deadlocks against the fixture-locked connection (its
# completion hooks touch the pool the main thread holds).
MailOnRails::Settings.cache_ttl = 0
MailOnRails::Settings.store = -> { MailOnRails::Setting.override_rows }
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/generated_password_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
