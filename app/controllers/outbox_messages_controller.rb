# The server-wide outbox (/outbox): every delivery DeliverSmtpOutboundJob
# still owes a remote server, plus the ones it has given up on, with a
# delete button to drop one that must not be retried (a typoed recipient,
# a destination tarpitting us). Admin-only like the other ops pages.
class OutboxMessagesController < ApplicationController
  # Deleting queued mail silently discards it - no retry, no bounce back
  # to the sender - so the button sits behind step-up like the other
  # destructive admin writes.
  before_action :require_recent_reauthentication, only: :destroy

  FAILED_PER_PAGE = 50

  def index
    @queued = MailOnRails::SmtpOutboundMessage.where(status: %i[pending delivering])
                          .order(:next_attempt_at, :id).to_a

    failed = MailOnRails::SmtpOutboundMessage.failed.order(updated_at: :desc, id: :desc)
    @failed_count = failed.count
    @failed_pages = [ @failed_count.fdiv(FAILED_PER_PAGE).ceil, 1 ].max
    @failed_page = params[:page].to_i.clamp(1, @failed_pages)
    @failed = failed.offset((@failed_page - 1) * FAILED_PER_PAGE).limit(FAILED_PER_PAGE).to_a
  end

  def destroy
    message = MailOnRails::SmtpOutboundMessage.find(params[:id])

    # Single-statement delete guarded on status, mirroring the drain job's
    # claim (pending -> delivering): exactly one of the two statements
    # wins, so a row can't be yanked out mid-SMTP-conversation and then
    # look cancelled when the mail actually left.
    if MailOnRails::SmtpOutboundMessage.where(id: message.id).where.not(status: :delivering).delete_all == 1
      audit "outbox_message.destroy", nil,
            recipient: message.recipient, from: message.mail_from, status: message.status,
            attempts: message.attempts, last_error: message.last_error.to_s.truncate(200)
      redirect_to outbox_messages_path, status: :see_other,
                  notice: "Deleted the message to #{message.recipient}. It will not be retried, and no bounce will be sent."
    else
      redirect_to outbox_messages_path, status: :see_other,
                  alert: "The message to #{message.recipient} is being delivered right now - refresh in a moment and delete it if it comes back pending or failed."
    end
  end
end
