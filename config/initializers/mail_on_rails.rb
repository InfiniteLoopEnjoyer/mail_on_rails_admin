# Rails-side seams for the mail_on_rails gem (extracted from this app).
# Protocol behavior (ports, TLS material, limits) stays configured via the
# MAIL_ON_RAILS_* / SMTP_* environment variables, unchanged.

Rails.application.configure do
  # One brute-force budget across IMAP/SMTP and the web login: tell the
  # gem's AuthAttempt analysis which web logins actually exist.
  config.mail_on_rails.web_login_lookup = ->(name) { User.exists?(email_address: name) }

  # Connection lifecycle events -> debounced Turbo refresh broadcasts for
  # the SMTP/IMAP dashboards. Runs on the servers' connection threads;
  # the executor wrap gives them the load interlock (the constant is
  # autoloaded) and an AR connection for the cable write.
  config.mail_on_rails.on_connection_activity = lambda do |protocol|
    Rails.application.executor.wrap { LiveConnectionsBroadcaster.ping(protocol) }
  end
end
