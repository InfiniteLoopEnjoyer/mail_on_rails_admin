module OutboxMessagesHelper
  # The Subject header out of the queued message's raw bytes, decoded for
  # display. Cheap header-block scan rather than a full Mail.new parse -
  # the index renders a page of these per request.
  def outbox_subject(message)
    header = message.data.to_s.b.partition(/\r?\n\r?\n/).first
    raw = header[/^Subject:[ \t]*(.*(?:\r?\n[ \t].*)*)/i, 1]
    return nil if raw.blank?

    Mail::Encodings.value_decode(raw.gsub(/\r?\n[ \t]+/, " ")).scrub.strip.presence
  rescue StandardError
    nil
  end

  # "3 of 8" - how far through the retry schedule a queued row is.
  def outbox_attempts_label(message)
    "#{message.attempts} of #{MailOnRails::SmtpOutboundMessage::MAX_ATTEMPTS}"
  end
end
