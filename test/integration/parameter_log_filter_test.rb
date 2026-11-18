require "test_helper"

# Mail content must not reach the request log. The composer autosaves
# draft[to|cc|subject|body_html] every few seconds, and search carries its
# terms in the query string - neither matched an entry in
# filter_parameters, so production's info-level log held both
# (config/initializers/filter_parameter_logging.rb).
class ParameterLogFilterTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
  end

  # Everything a request writes at production's level (info): the
  # "Started ..." line (Rails::Rack::Logger) and the Processing/Parameters/
  # Completed lines (ActionController's log subscriber).
  def capture_request_log
    io = StringIO.new
    logger = ActiveSupport::TaggedLogging.logger(io, level: :info)
    previous = [ Rails.logger, ActionController::Base.logger ]
    Rails.logger = ActionController::Base.logger = logger
    yield
    io.string
  ensure
    Rails.logger, ActionController::Base.logger = previous
  end

  test "a draft autosave logs none of the message" do
    log = capture_request_log do
      post drafts_path, as: :json, params: {
        draft: { email_account_id: @account.id, to: "recipient-zebra@remote.test", cc: "copy-yak@remote.test",
                 subject: "Quarterly numbers SUBJECT-MARKER", body_html: "<p>BODY-MARKER</p>",
                 in_reply_to: "<parent-MARKER@remote.test>", references: "<root-MARKER@remote.test>" }
      }
    end

    assert_response :success
    assert_equal 1, @account.find_mailbox("Drafts").email_messages.count, "the autosave itself must still work"
    assert_match(/Parameters:.*"draft"\s*=>\s*"\[FILTERED\]"/, log, "sanity: the Parameters line was captured")
    %w[SUBJECT-MARKER BODY-MARKER recipient-zebra copy-yak parent-MARKER root-MARKER].each do |marker|
      assert_no_match(/#{marker}/, log)
    end
  end

  test "a search logs neither its terms in the path nor in the parameters" do
    log = capture_request_log do
      get email_account_search_path(@account, q: "kumquat-SEARCH-MARKER")
    end

    assert_response :success
    assert_match(/Started GET "\/accounts\/#{@account.id}\/search\?q=\[FILTERED\]"/, log)
    assert_no_match(/SEARCH-MARKER/, log)
  end

  test "sending from the composer logs none of the message" do
    log = capture_request_log do
      post emails_path, params: {
        composed_email: { email_account_id: @account.id, to: "recipient-zebra@remote.test",
                          subject: "SUBJECT-MARKER", body: "BODY-MARKER" }
      }
    end

    assert_match(/Parameters:/, log)
    %w[SUBJECT-MARKER BODY-MARKER recipient-zebra].each { |marker| assert_no_match(/#{marker}/, log) }
  end

  # The same field names posted under any other root, or bare - a form
  # added later must not have to remember this initializer.
  test "content field names are filtered wherever they appear, without swallowing unrelated keys" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "to" => "a@x.test", "cc" => "b@x.test", "bcc" => "c@x.test", "subject" => "s", "body" => "b",
      "body_html" => "<p>b</p>", "in_reply_to" => "<i>", "references" => "<r>", "q" => "terms",
      "reply" => { "subject" => "nested", "note" => "kept" },
      "window" => "24h", "page" => "2", "quota_megabytes" => "10", "auto_ban" => "1", "accent" => "blue"
    )

    %w[to cc bcc subject body body_html in_reply_to references q].each do |key|
      assert_equal "[FILTERED]", filtered[key], key
    end
    assert_equal({ "subject" => "[FILTERED]", "note" => "kept" }, filtered["reply"])
    %w[window page quota_megabytes auto_ban accent].each do |key|
      assert_not_equal "[FILTERED]", filtered[key], "#{key} is not mail content"
    end
  end
end
