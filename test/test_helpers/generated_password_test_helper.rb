# Pulls the one-time generated password out of the last response's reveal
# markup (the data-secret-value attribute secret_controller strips and
# holds in JS memory on real pages).
module GeneratedPasswordTestHelper
  def extract_generated_password
    raw = response.body[/data-secret-value="([^"]+)"/, 1]
    assert raw.present?, "expected a generated password in the response body"
    CGI.unescapeHTML(raw)
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include GeneratedPasswordTestHelper
end
