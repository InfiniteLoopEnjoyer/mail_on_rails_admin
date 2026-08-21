# The suppression list (/suppressions): remote addresses the outbound
# drainer refuses to mail because they reported our mail as spam through
# a provider feedback loop (delivered to fbl@/jmrp@ - see
# MailOnRails::IngestFblReportJob). Admin-only like the other ops pages.
class SuppressedRecipientsController < ApplicationController
  # Lifting a suppression resumes mailing someone who reported us as
  # spam - a write to the server's sending reputation that a stolen admin
  # cookie must not reach, so step-up like the other destructive actions.
  before_action :require_recent_reauthentication, only: :destroy
  rate_limit to: 20, within: 10.minutes, only: :destroy,
             with: -> { redirect_to suppressed_recipients_path, alert: "Try again later." }

  PER_PAGE = 50

  def index
    suppressed = MailOnRails::SuppressedRecipient.order(last_complaint_at: :desc, id: :desc)
    @count = suppressed.count
    @pages = [ @count.fdiv(PER_PAGE).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    @suppressed_recipients = suppressed.offset((@page - 1) * PER_PAGE).limit(PER_PAGE).to_a
  end

  def destroy
    suppressed = MailOnRails::SuppressedRecipient.find(params[:id])
    suppressed.destroy!
    audit "suppressed_recipient.destroy", nil,
          email: suppressed.email, complaints_count: suppressed.complaints_count
    redirect_to suppressed_recipients_path, status: :see_other,
                notice: "Lifted the suppression of #{suppressed.email}. Outbound mail to them will be attempted again."
  end
end
