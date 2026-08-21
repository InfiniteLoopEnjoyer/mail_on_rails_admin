require "test_helper"

# The outbox page: the outbound delivery queue (SmtpOutboundMessage) and
# the delete button that cancels a delivery without retries or a bounce.
class OutboxMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end

  test "index lists queued and failed deliveries with decoded subjects" do
    queue_message(recipient: "pending@example.org", next_attempt_at: 10.minutes.from_now,
                  last_error: "421 try later")
    queue_message(recipient: "dead@example.org", status: :failed, attempts: 8,
                  last_error: "550 no such user")
    queue_message(recipient: "inflight@example.org", status: :delivering)

    get outbox_messages_url
    assert_response :success
    assert_match "pending@example.org", response.body
    assert_match "dead@example.org", response.body
    assert_match "sending now", response.body
    assert_match "Hej världen", response.body # decoded from RFC 2047
    assert_match "421 try later", response.body
    assert_match "550 no such user", response.body
  end

  test "requires an admin session" do
    sign_in_as users(:member)
    get outbox_messages_url
    assert_redirected_to root_url

    message = queue_message
    delete outbox_message_url(message)
    assert_redirected_to root_url
    assert MailOnRails::SmtpOutboundMessage.exists?(message.id)
  end

  test "deleting a pending delivery removes it and audits" do
    message = queue_message(attempts: 3, last_error: "421 greylisted")

    assert_difference -> { MailOnRails::SmtpOutboundMessage.count }, -1 do
      delete outbox_message_url(message)
    end
    assert_redirected_to outbox_messages_url
    follow_redirect!
    assert_match "will not be retried", response.body

    event = AuditEvent.newest_first.first
    assert_equal "outbox_message.destroy", event.action
    assert_equal "friend@example.org", event.details["recipient"]
    assert_equal "one@example.com", event.details["from"]
    assert_equal "421 greylisted", event.details["last_error"]
  end

  test "deleting a failed delivery removes it" do
    message = queue_message(status: :failed, attempts: 8)

    assert_difference -> { MailOnRails::SmtpOutboundMessage.count }, -1 do
      delete outbox_message_url(message)
    end
  end

  test "a delivery in flight is not deleted" do
    message = queue_message(status: :delivering)

    assert_no_difference -> { MailOnRails::SmtpOutboundMessage.count } do
      delete outbox_message_url(message)
    end
    assert_redirected_to outbox_messages_url
    assert_equal "delivering", message.reload.status
    assert_nil AuditEvent.newest_first.first
  end

  test "deletion is a step-up gated action" do
    message = queue_message
    travel Reauthentication::REAUTHENTICATION_GRACE + 1.minute

    delete outbox_message_url(message)
    assert_redirected_to new_reauthentication_url
    assert MailOnRails::SmtpOutboundMessage.exists?(message.id)
  end

  private

  def queue_message(recipient: "friend@example.org", status: :pending, attempts: 0,
                    next_attempt_at: Time.current, last_error: nil)
    MailOnRails::SmtpOutboundMessage.create!(
      mail_from: "one@example.com",
      recipient: recipient,
      data: "Subject: =?UTF-8?Q?Hej_v=C3=A4rlden?=\r\nFrom: One <one@example.com>\r\nTo: #{recipient}\r\n\r\nHello\r\n",
      status: status, attempts: attempts, next_attempt_at: next_attempt_at, last_error: last_error)
  end
end
