# Compose and send mail from the web UI. The From select - and, more
# importantly, the posted email_account_id it feeds - is scoped to the
# accounts the user can access; the params normalization below is the
# enforcement, the select is just UI. Routing/queueing lives in
# ComposedEmail#deliver.
class EmailsController < ApplicationController
  allow_member_access
  # Sending is speaking as the account - a stolen session cookie must not
  # get to do that on an idle session, so the first send after the grace
  # window re-proves the operator (fresh sign-ins are already step-up-fresh,
  # and the composer autosaves to Drafts, so a prompted user resumes the
  # draft rather than retyping).
  before_action :require_recent_reauthentication, only: :create
  # Per-IP brake on scripted form posts; the per-ACCOUNT outbound cap is
  # ComposedEmail's send quota (shared with SMTP submission).
  rate_limit to: 30, within: 10.minutes, only: :create,
             with: -> { redirect_to new_email_path, alert: "Sending too quickly - try again later." }

  def new
    from = accessible_email_accounts.find_by(id: params[:from])&.id ||
           accessible_email_accounts.order(:email).first&.id
    @draft = EmailDraft.new(email_account_id: from)
    load_accounts
  end

  def create
    @composed_email = ComposedEmail.new(composed_email_params.except(:draft_message_id))
    if @composed_email.deliver
      discard_draft
      account = @composed_email.account
      sent = account.find_mailbox("Sent")
      destination = sent ? email_account_mailbox_path(account, sent) : email_account_path(account)
      redirect_to destination, notice: "Email sent."
    else
      # Re-render the composer with what was typed rather than an empty
      # form; the autosaved revision (if any) is still in Drafts and its id
      # goes back into the form so the next save keeps replacing it.
      # Attachments can't be re-rendered into a file input - the user
      # re-picks them - and EmailDraft has no such attribute anyway.
      @draft = EmailDraft.new(composed_email_params.except(:attachments))
      load_accounts
      render :new, status: :unprocessable_entity
    end
  end

  private

  # A sent reply must not leave its autosaved revision sitting in Drafts on
  # every device. Only after delivery commits, so a failed send keeps it.
  def discard_draft
    id = composed_email_params[:draft_message_id]
    return if id.blank?

    EmailDraft.new(email_account_id: @composed_email.email_account_id,
                   draft_message_id: id).discard
  end

  def load_accounts
    @email_accounts = accessible_email_accounts.order(:email)
  end

  # The posted ids are the authority (the select is only UI), so both are
  # normalized through the accessible scope: an inaccessible account id
  # becomes nil and fails ComposedEmail's own validation exactly like a
  # nonexistent one, and a foreign draft_message_id is dropped rather than
  # letting discard_draft delete another account's draft.
  def composed_email_params
    @composed_email_params ||=
      params.expect(composed_email: [ :email_account_id, :to, :cc, :subject, :body, :body_html,
                                      :in_reply_to, :references, :message_id, :draft_message_id,
                                      attachments: [] ]).tap do |p|
        p[:email_account_id] = accessible_email_accounts.find_by(id: p[:email_account_id])&.id
        p[:draft_message_id] = accessible_draft_id(p[:draft_message_id])
      end
  end
end
