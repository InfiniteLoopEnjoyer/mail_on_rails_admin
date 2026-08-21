# Aliases live entirely on the account page (inline add form + remove
# buttons), so both actions land back there; a failed create carries the
# errors over in flash rather than needing a page of its own.
class EmailAliasesController < ApplicationController
  before_action :set_email_account
  # An alias on a hosted domain intercepts inbound mail for that address -
  # the same class of write domains#create gates, so it takes the same
  # step-up (both actions here are mutations).
  before_action :require_recent_reauthentication
  rate_limit to: 20, within: 10.minutes,
             with: -> { redirect_to email_account_path(params[:email_account_id]), alert: "Try again later." }

  def create
    email_alias = @email_account.email_aliases.new(email_alias_params)
    if email_alias.save
      audit "email_alias.create", email_alias, account: @email_account.email
      redirect_to @email_account, notice: "Alias #{email_alias.email} added."
    else
      redirect_to @email_account, alert: "Alias not added: #{email_alias.errors.full_messages.to_sentence}."
    end
  end

  def destroy
    email_alias = @email_account.email_aliases.find(params[:id])
    email_alias.destroy!
    audit "email_alias.destroy", email_alias, account: @email_account.email
    redirect_to @email_account, notice: "Alias #{email_alias.email} removed.", status: :see_other
  end

  private

  def set_email_account
    # Scope through the signed-in user like every other account lookup, so a
    # member can never reach an account outside their grants (admin-only
    # today, but the scoping is the invariant, not the current role gate).
    @email_account = Current.user.accessible_email_accounts.find(params[:email_account_id])
  end

  def email_alias_params
    params.expect(email_alias: [ :email ])
  end
end
