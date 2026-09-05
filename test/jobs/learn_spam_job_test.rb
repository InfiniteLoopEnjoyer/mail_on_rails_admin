require "test_helper"
require "mail_on_rails/rspamd_analyzer"
require_relative "../test_helpers/fake_rspamd"

# The Bayes-training job: feeds the moved message's bytes to the rspamd
# controller, retries only when the controller is unreachable, and finds
# the message again by its content id when the user has moved it on.
class LearnSpamJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  RAW = "From: spammer@remote.test\r\nTo: carol@example.com\r\n" \
        "Subject: hello\r\nMessage-ID: <m1@remote.test>\r\n\r\nbody\r\n"

  setup do
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
    @message = MailOnRails::EmailMessage.deliver_raw(@account.junk_mailbox, RAW)
  end

  def with_controller_at(addr)
    ENV["SMTP_RSPAMD_CONTROLLER_ADDR"] = addr
    yield
  ensure
    ENV.delete("SMTP_RSPAMD_CONTROLLER_ADDR")
  end

  def perform(message = @message, klass: "spam")
    MailOnRails::LearnSpamJob.perform_now(message.id, message.email_object_id, @account.id, klass)
  end

  test "does nothing without a controller address" do
    FakeRspamd.serving({ "success" => true }) do |_addr, captured|
      perform
      assert_empty captured
    end
  end

  test "posts the message to the learn endpoint" do
    FakeRspamd.serving({ "success" => true }) do |addr, captured|
      with_controller_at(addr) { perform(klass: "ham") }
      assert_equal "/learnham", captured["__path"]
      assert_equal RAW.bytesize.to_s, captured["content-length"]
    end
    assert_no_enqueued_jobs only: MailOnRails::LearnSpamJob
  end

  test "retries when the controller is unreachable" do
    closed = TCPServer.new("127.0.0.1", 0)
    addr = "127.0.0.1:#{closed.addr[1]}"
    closed.close

    with_controller_at(addr) { perform }
    assert_enqueued_jobs 1, only: MailOnRails::LearnSpamJob
  end

  test "a refusal is not retried" do
    FakeRspamd.serving({ "error" => "Unauthorized" }, status: 403) do |addr, _captured|
      with_controller_at(addr) { perform }
    end
    assert_no_enqueued_jobs only: MailOnRails::LearnSpamJob
  end

  test "follows the message to its new row after another move" do
    moved = @message.move_to!(@account.inbox)
    FakeRspamd.serving({ "success" => true }) do |addr, captured|
      with_controller_at(addr) do
        MailOnRails::LearnSpamJob.perform_now(@message.id, moved.email_object_id, @account.id, "spam")
      end
      assert_equal "/learnspam", captured["__path"]
    end
  end
end
