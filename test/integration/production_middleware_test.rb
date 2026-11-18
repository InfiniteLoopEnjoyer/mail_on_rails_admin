require "test_helper"
require "open3"

# Rack::Runtime stamps every response with X-Runtime (server time spent on
# the request): a timing side channel on the login and reset forms, and a
# framework fingerprint. Production removes the middleware
# (config/environments/production.rb). The test environment keeps the
# stock stack, so this asks a production-configured boot for its own
# middleware list - the same way the image build boots it, with no runtime
# secrets and no database.
class ProductionMiddlewareTest < ActiveSupport::TestCase
  test "the production stack has no Rack::Runtime" do
    env = { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "MAIL_ON_RAILS_WEB_HOST" => nil }
    output, status = Open3.capture2e(env, Rails.root.join("bin/rails").to_s, "middleware", chdir: Rails.root.to_s)

    assert status.success?, output
    assert_match(/^use ActionDispatch::Cookies$/, output, "sanity: this is a middleware listing")
    assert_no_match(/Rack::Runtime/, output)
  end
end
