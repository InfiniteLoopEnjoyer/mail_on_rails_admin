# The web composer's server side (EmailDraft).
#
# A draft is a message in the Drafts mailbox, so #edit reads one back out
# of its message and every save writes a new message and expunges the one
# it supersedes. #create therefore answers with the new id the client must
# send next time. A client holding a stale id is normal - a phone editing
# the same draft replaces it out from under us - and is handled by the
# model rather than treated as an error.
class DraftsController < ApplicationController
  allow_member_access
  before_action :set_message, only: %i[edit destroy]
  # Generous - autosave fires on a timer while composing - but bounded, so
  # a scripted client can't use the drafts endpoint as a free write amp.
  rate_limit to: 300, within: 10.minutes, only: :create,
             with: -> { render json: { errors: [ "Saving too quickly - try again later." ] }, status: :too_many_requests }

  # Continue writing a saved draft.
  def edit
    @draft = EmailDraft.from_message(@message)
    @email_account = @message.mailbox.email_account
    @mailbox = @message.mailbox
  end

  def create
    draft = EmailDraft.new(draft_params)
    saved = draft.save

    if saved
      render json: { draft_message_id: saved.id, message_id: draft.message_id,
                     saved_at: saved.internal_date.iso8601 }
    elsif draft.errors.any?
      render json: { errors: draft.errors.full_messages }, status: :unprocessable_entity
    else
      # Nothing worth persisting yet (an empty composer on a timer). Not an
      # error - the client just has no draft id to carry forward.
      render json: { draft_message_id: nil }
    end
  end

  def destroy
    mailbox = @message.mailbox
    @message.destroy
    redirect_to email_account_mailbox_path(mailbox.email_account, mailbox),
                notice: "Draft discarded."
  end

  private

  # Only ever a draft, and only in an accessible account. The id names an
  # EmailMessage, so without these checks this route would delete any
  # message in any mailbox.
  def set_message
    @message = MailOnRails::EmailMessage.where(mailbox: MailOnRails::Mailbox.where(email_account_id: accessible_email_accounts.select(:id)))
                           .find(params[:id])
    raise ActiveRecord::RecordNotFound unless @message.draft?
  end

  # Same normalization as EmailsController#composed_email_params: the
  # posted ids are the authority, so an inaccessible account or foreign
  # draft id behaves exactly like a nonexistent one.
  def draft_params
    @draft_params ||=
      params.expect(draft: [ :email_account_id, :to, :cc, :subject, :body, :body_html,
                             :in_reply_to, :references, :message_id, :draft_message_id ]).tap do |p|
        p[:email_account_id] = accessible_email_accounts.find_by(id: p[:email_account_id])&.id
        p[:draft_message_id] = accessible_draft_id(p[:draft_message_id])
      end
  end
end
