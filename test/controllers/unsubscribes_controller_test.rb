require "test_helper"

# The engine's RFC 8058 one-click unsubscribe endpoint, end to end
# through the mounted routes: anonymous, token-authorized, GET never
# unsubscribes, POST records a sender-scoped suppression.
class UnsubscribesControllerTest < ActionDispatch::IntegrationTest
  SENDER = "news@example.test"
  RECIPIENT = "reader@remote.test"

  setup do
    @token = MailOnRails::UnsubscribeToken.generate(recipient: RECIPIENT, sender: SENDER)
    @path = "/unsubscribe/#{CGI.escape(@token)}"
  end

  test "GET shows a confirmation form and records nothing" do
    get @path
    assert_response :success
    assert_select "form[method=post] button", text: "Unsubscribe"
    assert_not MailOnRails::SuppressedRecipient.suppressed?(RECIPIENT, sender: SENDER),
               "a prefetched GET must never unsubscribe"
  end

  test "POST records a sender-scoped suppression, idempotently" do
    post @path
    assert_response :success
    assert MailOnRails::SuppressedRecipient.suppressed?(RECIPIENT, sender: SENDER)
    assert_not MailOnRails::SuppressedRecipient.suppressed?(RECIPIENT, sender: "other@example.test")

    assert_no_difference "MailOnRails::SuppressedRecipient.count" do
      post @path # providers replay one-click POSTs
    end
    assert_response :success
  end

  test "tampered and garbage tokens answer 410 and record nothing" do
    post "/unsubscribe/#{CGI.escape(@token.sub(/\A../, "xx"))}"
    assert_response :gone

    get "/unsubscribe/garbage"
    assert_response :gone

    assert_equal 0, MailOnRails::SuppressedRecipient.count
  end
end
