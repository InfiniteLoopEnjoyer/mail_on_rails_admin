# Role gate for the web UI. Default-deny: every controller is admin-only
# unless it opts member access in with allow_member_access (the mirror of
# Authentication.allow_unauthenticated_access). Member-facing controllers
# then resolve all mail data through accessible_email_accounts, so an
# account outside a member's grants 404s exactly like one that doesn't
# exist.
#
# Runs after require_authentication; on unauthenticated surfaces
# (metrics, MTA-STS, login itself) Current.user is absent and the gate
# no-ops - those endpoints keep their own protections.
module Authorization
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :accessible_email_accounts
  end

  class_methods do
    def allow_member_access(**options)
      skip_before_action :require_admin, **options
    end
  end

  private
    def require_admin
      return unless Current.user
      return if Current.user.admin?

      redirect_to root_path, alert: "You don't have access to that page."
    end

    def accessible_email_accounts
      Current.user.accessible_email_accounts
    end

    # Validates a posted draft_message_id: returns it only if it names a
    # \Draft message inside an accessible account, else nil - so a foreign
    # id behaves like a stale one (EmailDraft's documented silent-miss
    # path) instead of deleting another account's draft via
    # EmailDraft#discard_previous.
    def accessible_draft_id(id)
      return nil if id.blank?

      message = MailOnRails::EmailMessage.where(mailbox: MailOnRails::Mailbox.where(email_account_id: accessible_email_accounts.select(:id)))
                            .find_by(id: id)
      message&.draft? ? id : nil
    end
end
