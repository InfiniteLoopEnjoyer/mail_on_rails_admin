require "test_helper"

# The outbound queue drain: rows are claimed (pending -> delivering)
# before the network attempt, transient failures back off and retry,
# permanent failures (or exhausted retries) DSN-bounce into the local
# sender's INBOX.
class DeliverSmtpOutboundJobTest < ActiveSupport::TestCase
  RAW = "From: carol@example.com\r\nTo: out@remote.test\r\n" \
        "Subject: hello\r\nMessage-ID: <m1@example.com>\r\n\r\nbody\r\n"

  setup do
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
  end

  def queue(**attrs)
    MailOnRails::SmtpOutboundMessage.create!(mail_from: @account.email, recipient: "out@remote.test",
                                data: RAW, next_attempt_at: 1.minute.ago, **attrs)
  end

  # minitest/mock is unavailable; swap OutboundDeliverer.deliver on its
  # singleton class (the without_sender_verification pattern) and restore.
  def with_deliverer(handler)
    singleton = MailOnRails::OutboundDeliverer.singleton_class
    original = MailOnRails::OutboundDeliverer.method(:deliver)
    singleton.define_method(:deliver) { |message| handler.call(message) }
    yield
  ensure
    singleton.define_method(:deliver, original)
  end

  test "a successful delivery marks the row sent" do
    message = queue
    delivered = []
    with_deliverer(->(m) { delivered << m.id }) { MailOnRails::DeliverSmtpOutboundJob.perform_now }

    assert_equal [ message.id ], delivered
    message.reload
    assert_equal "sent", message.status
    assert_not_nil message.sent_at
    assert_nil message.last_error
  end

  test "a permanent failure bounces a DSN into the local sender's INBOX" do
    message = queue
    with_deliverer(->(_m) { raise MailOnRails::OutboundDeliverer::PermanentError, "550 no such user" }) do
      MailOnRails::DeliverSmtpOutboundJob.perform_now
    end

    assert_equal "failed", message.reload.status
    bounce = @account.inbox.email_messages.sole
    assert_equal "Undelivered Mail Returned to Sender", bounce.subject
    # Bounces must not bounce: the DSN comes from the mailer-daemon at the
    # sender's own domain, where Domain aliases it into postmaster - so a
    # reply to the bounce reaches the operator.
    assert_match(/mailer-daemon@example\.com/, bounce.raw.to_s)
    assert_includes bounce.body_text, "out@remote.test"
    assert_includes bounce.body_text, "550 no such user"
  end

  test "a transient failure below the retry limit defers, no bounce" do
    message = queue
    with_deliverer(->(_m) { raise MailOnRails::OutboundDeliverer::TransientError, "421 try later" }) do
      MailOnRails::DeliverSmtpOutboundJob.perform_now
    end

    message.reload
    assert_equal "pending", message.status
    assert_equal 1, message.attempts
    assert_equal "421 try later", message.last_error
    assert_predicate message.next_attempt_at, :future?
    assert_equal 0, @account.inbox.email_messages.count

    # Once the backoff lapses the row is due again on its own schedule -
    # no stuck-window rescue involved.
    message.update_columns(next_attempt_at: 1.second.ago)
    with_deliverer(->(_m) { }) { MailOnRails::DeliverSmtpOutboundJob.perform_now }
    assert_equal "sent", message.reload.status
  end

  test "a transient failure on the last allowed attempt fails and bounces" do
    message = queue(attempts: MailOnRails::SmtpOutboundMessage::MAX_ATTEMPTS - 1)
    with_deliverer(->(_m) { raise MailOnRails::OutboundDeliverer::TransientError, "421 still greylisted" }) do
      MailOnRails::DeliverSmtpOutboundJob.perform_now
    end

    assert_equal "failed", message.reload.status
    assert_includes @account.inbox.email_messages.sole.body_text, "421 still greylisted"
  end

  # --- DSN requests (RFC 3461/3464) ---

  test "NOTIFY=NEVER suppresses the failure DSN" do
    message = queue(dsn_notify: "NEVER")
    with_deliverer(->(_m) { raise MailOnRails::OutboundDeliverer::PermanentError, "550 nope" }) do
      MailOnRails::DeliverSmtpOutboundJob.perform_now
    end

    assert_equal "failed", message.reload.status
    assert_equal 0, @account.inbox.email_messages.count
  end

  test "NOTIFY=SUCCESS delivers a relayed DSN unless the next hop took the request over" do
    queue(dsn_notify: "SUCCESS")
    with_deliverer(->(_m) { :delivered }) { MailOnRails::DeliverSmtpOutboundJob.perform_now }
    report = @account.inbox.email_messages.sole
    assert_equal "Successful Mail Delivery Report", report.subject
    assert_includes report.raw.to_s, "Action: relayed"

    queue(dsn_notify: "SUCCESS")
    with_deliverer(->(_m) { :propagated_dsn }) { MailOnRails::DeliverSmtpOutboundJob.perform_now }
    assert_equal 1, @account.inbox.email_messages.count,
                 "a propagated DSN request must not also be reported locally"
  end

  test "the failure DSN is a parseable multipart/report honoring RET=FULL" do
    queue(dsn_ret: "FULL", dsn_envid: "QQ314159")
    with_deliverer(->(_m) { raise MailOnRails::OutboundDeliverer::PermanentError, "mx: 550 5.1.1 no such user" }) do
      MailOnRails::DeliverSmtpOutboundJob.perform_now
    end

    mail = Mail.read_from_string(@account.inbox.email_messages.sole.raw.to_s)
    assert_match(/multipart\/report/, mail.content_type)
    status = mail.parts.find { |p| p.content_type.start_with?("message/delivery-status") }.body.to_s
    assert_includes status, "Action: failed"
    assert_includes status, "Status: 5.1.1"
    assert_includes status, "Original-Envelope-Id: QQ314159"
    assert_match(/message\/rfc822/, mail.parts.last.content_type)
    assert_includes mail.parts.last.body.to_s, "body", "RET=FULL must return the whole original"
  end

  test "a long-queued message gets exactly one delayed DSN" do
    MailOnRails::Settings.overrides = { smtp_delay_warning_seconds: 60 }
    message = queue
    message.update_columns(created_at: 10.minutes.ago)
    transient = ->(_m) { raise MailOnRails::OutboundDeliverer::TransientError, "421 greylisted" }

    with_deliverer(transient) { MailOnRails::DeliverSmtpOutboundJob.perform_now }
    message.reload
    assert_predicate message.delay_notified_at, :present?
    delayed = @account.inbox.email_messages.sole
    assert_equal "Delayed Mail (still being retried)", delayed.subject
    assert_includes delayed.raw.to_s, "Will-Retry-Until:"

    message.update_columns(next_attempt_at: 1.second.ago)
    with_deliverer(transient) { MailOnRails::DeliverSmtpOutboundJob.perform_now }
    assert_equal 1, @account.inbox.email_messages.count, "the delay warning is sent once per message"
  ensure
    MailOnRails::Settings.overrides = {}
  end

  test "no delayed DSN before the threshold or when disabled" do
    MailOnRails::Settings.overrides = { smtp_delay_warning_seconds: 3600 }
    message = queue
    with_deliverer(->(_m) { raise MailOnRails::OutboundDeliverer::TransientError, "421 later" }) do
      MailOnRails::DeliverSmtpOutboundJob.perform_now
    end
    assert_nil message.reload.delay_notified_at
    assert_equal 0, @account.inbox.email_messages.count

    MailOnRails::Settings.overrides = { smtp_delay_warning_seconds: 0 }
    message.update_columns(next_attempt_at: 1.second.ago, created_at: 2.days.ago)
    with_deliverer(->(_m) { raise MailOnRails::OutboundDeliverer::TransientError, "421 later" }) do
      MailOnRails::DeliverSmtpOutboundJob.perform_now
    end
    assert_nil message.reload.delay_notified_at, "0 disables the delay warning"
  ensure
    MailOnRails::Settings.overrides = {}
  end

  test "a row already claimed as delivering is not sent again" do
    message = queue(status: :delivering)
    delivered = []
    with_deliverer(->(m) { delivered << m.id }) { MailOnRails::DeliverSmtpOutboundJob.perform_now }

    assert_empty delivered
    assert_equal "delivering", message.reload.status
  end

  test "stuck delivering rows are reset to pending and retried in the same run" do
    message = queue(status: :delivering)
    message.update_columns(updated_at: 16.minutes.ago)
    delivered = []
    with_deliverer(->(m) { delivered << m.id }) { MailOnRails::DeliverSmtpOutboundJob.perform_now }

    assert_equal [ message.id ], delivered
    assert_equal "sent", message.reload.status
  end
end
