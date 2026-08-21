# App-side behavior on the gem's models, attached via load hooks so the
# gem stays free of turbo-rails and this app's RBAC. These restore exactly
# the callbacks the models carried before extraction.

# RBAC: which users may operate which accounts (admin UI concern).
ActiveSupport.on_load(:mail_on_rails_email_account) do
  has_many :email_account_users, dependent: :destroy, inverse_of: :email_account
  has_many :users, through: :email_account_users

  # Live-refresh the accounts index and this account's own page (Turbo
  # refresh broadcasts - pages subscribe via turbo_stream_from).
  after_commit -> { broadcast_refresh_later_to :email_accounts }
  after_update_commit -> { broadcast_refresh_later }
end

# Live-refresh the account page (folder list) and this folder's own page.
ActiveSupport.on_load(:mail_on_rails_mailbox) do
  after_commit -> { broadcast_refresh_later_to email_account }
  after_update_commit -> { broadcast_refresh_later }
end

# Any message change (delivery, flag change, expunge) live-refreshes the
# folder's message list, the account page's per-folder unread counts, and
# the accounts index's unread badges.
ActiveSupport.on_load(:mail_on_rails_email_message) do
  after_commit do
    broadcast_refresh_later_to mailbox
    broadcast_refresh_later_to mailbox.email_account
    broadcast_refresh_later_to :email_accounts
  end
end

# The account page renders its aliases, so alias changes refresh it the
# same way the account's own changes do. Skipped when the account itself
# is being destroyed (dependent: :destroy) - nothing left to render.
ActiveSupport.on_load(:mail_on_rails_email_alias) do
  after_commit -> { email_account.broadcast_refresh_later unless email_account.destroyed? }
end

# Live-refresh the domain page and index pills when check RESULTS change
# (subscribed via turbo_stream_from). Only on result changes: every show
# render runs a write-through DnsCheck.refresh! (touching dns_checked_at),
# so an unconditional broadcast would ping-pong refreshes between viewers.
ActiveSupport.on_load(:mail_on_rails_domain) do
  after_update_commit -> { broadcast_refresh_later }, if: -> { saved_change_to_dns_checks? }
  after_update_commit -> { broadcast_refresh_later_to :domains }, if: -> { saved_change_to_dns_checks? }
  # Index also lists the domains themselves.
  after_create_commit -> { broadcast_refresh_later_to :domains }
  after_destroy_commit -> { broadcast_refresh_later_to :domains }
end
