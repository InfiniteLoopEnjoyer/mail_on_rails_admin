require "active_support/core_ext/integer/time"

Rails.application.configure do
  # No Action Mailbox ingress: the in-process SMTP server creates
  # InboundEmails directly (Store::SmtpBackend), and the ingress routes are
  # pinned closed in config/routes.rb.

  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # The web host underpins WebAuthn origins, mailer URLs, and Host-header
  # authorization; a silent "localhost" fallback would break passkeys and
  # leave hosts open. Fail the boot instead - the deploy overlay sets it.
  # (Environment files load before initializers, so this is the earliest
  # clean place to fail, before webauthn.rb reads the same value.)
  #
  # Skipped during image build: `assets:precompile` loads the production env
  # with no runtime ENV (SECRET_KEY_BASE_DUMMY marks that phase). The check
  # still fires on every real boot, where the deploy injects the value.
  web_host = ENV["MAIL_ON_RAILS_WEB_HOST"].to_s.strip
  if web_host.empty? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
    raise "MAIL_ON_RAILS_WEB_HOST must be set in production"
  end

  # The Prometheus endpoint is token-gated (secure_compare) and needs both
  # METRICS_TOKEN and METRICS_ALLOW_IPS - a token-only endpoint is one
  # leaked scrape config away from open, so MetricsController keeps
  # answering 404 until the allowlist exists too. Warn here so an operator
  # who set only the token learns why their scrape 404s.
  if ENV["METRICS_TOKEN"].present? && ENV["METRICS_ALLOW_IPS"].to_s.strip.empty? &&
     ENV["SECRET_KEY_BASE_DUMMY"].blank?
    warn "[mail_on_rails] METRICS_TOKEN is set without METRICS_ALLOW_IPS - " \
         "the metrics endpoint stays 404 until an IP allowlist is set"
  end

  # Set host to be used by links generated in mailer templates (a harmless
  # placeholder during the build; the runtime value is guaranteed above).
  config.action_mailer.default_url_options = { host: web_host.presence || "localhost" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # DNS rebinding / Host-header protection. web_host is guaranteed present
  # at runtime (the boot check above); pin authorization to it when set
  # (unset only during the asset-precompile build).
  config.hosts = [ web_host ] if web_host.present?

  # /up is probed by kamal-proxy against the container IP, and the MTA-STS
  # policy is fetched by sending MTAs from mta-sts.<each hosted domain> -
  # those hosts are DB-driven (DnsPublisher CNAMEs them here), so exclude
  # the path rather than enumerate hosts. MtaStsController serves one
  # static policy for any Host and derives no URLs from it.
  config.host_authorization = {
    exclude: ->(request) { request.path == "/up" || request.path == "/.well-known/mta-sts.txt" }
  }
end
