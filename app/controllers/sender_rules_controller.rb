# Per-account sender allow/deny rules (MailOnRails::SenderRule). The list
# and the add form live on the account page, so both actions land back
# there; a failed create carries the reason over in flash. Members manage
# the rules of accounts they were granted - the same people who can
# already click "Mark as spam", which writes these rules automatically.
class SenderRulesController < ApplicationController
  allow_member_access
  before_action :set_email_account
  # An allow rule lifts the spam verdict for a sender; a deny hides their
  # mail. Both change what reaches the inbox, so a resumed cookie proves
  # itself first, like every other account-shaping write.
  before_action :require_recent_reauthentication
  rate_limit to: 30, within: 10.minutes,
             with: -> { redirect_to email_account_path(params[:email_account_id]), alert: "Try again later." }

  def create
    verdict = sender_rule_params[:verdict].to_s
    unless MailOnRails::SenderRule::VERDICTS.include?(verdict)
      redirect_to @email_account, alert: "Rule not added: verdict must be allow or deny." and return
    end

    rule = MailOnRails::SenderRule.record!(@email_account, sender_rule_params[:address], verdict, source: "manual")
    audit "sender_rule.create", rule, account: @email_account.email, address: rule.address, verdict: rule.verdict
    redirect_to @email_account, notice: "#{rule.address} #{outcome(rule)}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @email_account, alert: "Rule not added: #{e.record.errors.full_messages.to_sentence}."
  end

  def destroy
    rule = @email_account.sender_rules.find(params[:id])
    rule.destroy!
    audit "sender_rule.destroy", rule, account: @email_account.email, address: rule.address, verdict: rule.verdict
    redirect_to @email_account, notice: "Rule for #{rule.address} removed.", status: :see_other
  end

  private

  def set_email_account
    # Scoped through the signed-in user like every other account lookup, so
    # a member can never reach an account outside their grants.
    @email_account = Current.user.accessible_email_accounts.find(params[:email_account_id])
  end

  def sender_rule_params
    params.expect(sender_rule: [ :address, :verdict ])
  end

  def outcome(rule)
    rule.deny? ? "will be filed into Junk" : "will be delivered to INBOX"
  end
end
