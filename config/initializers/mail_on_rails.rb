# Rails-side seams for the mail_on_rails gem (extracted from this app).
# Protocol behavior (ports, TLS material, limits) stays configured via the
# MAIL_ON_RAILS_* / SMTP_* environment variables, unchanged.

Rails.application.configure do
  # One brute-force budget across IMAP/SMTP and the web login: tell the
  # gem's AuthAttempt analysis which web logins actually exist.
  config.mail_on_rails.web_login_lookup = ->(name) { User.exists?(email_address: name) }

  # Which protocols run inside the web process: left to MAIL_ON_RAILS_SERVERS
  # (see config/puma.rb). Uncomment to pin it in code instead, e.g. [] for
  # a web-only process regardless of the environment:
  # config.mail_on_rails.protocols = []

  # Connection-picture changes -> debounced Turbo refresh broadcasts for
  # the SMTP/IMAP dashboards. Fired from each listener's ops-sync thread
  # right after it wrote its live picture to the tables the dashboards
  # read - in this process or in the smtp/imap containers, which run this
  # same app (bin/mail_server) and broadcast through Solid Cable. The
  # executor wrap gives the thread the load interlock (the constant is
  # autoloaded) and an AR connection for the cable write.
  config.mail_on_rails.on_connection_activity = lambda do |protocol|
    Rails.application.executor.wrap { LiveConnectionsBroadcaster.ping(protocol) }
  end
end
