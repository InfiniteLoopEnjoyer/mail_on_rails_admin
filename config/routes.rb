Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  # Two-factor auth. The challenge is the login-time second step (password
  # accepted, session not yet started - see SessionsController#create);
  # passkeys/totp manage enrollment from the user's own edit page.
  namespace :two_factor do
    resource :challenge, only: :new do
      post :webauthn_options
      post :webauthn
      post :totp
    end
    resources :passkeys, only: %i[create destroy] do
      collection { post :options }
    end
    resource :totp, only: %i[new create destroy], controller: "totp"
  end

  # Step-up ("sudo mode") re-verification before removing a second factor -
  # see the Reauthentication concern and ReauthenticationsController.
  resource :reauthentication, only: %i[new create] do
    post :webauthn_options
    post :webauthn
    post :totp
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Health status on /up: 200 once the app booted with no exceptions AND
  # (in deploys running the in-process mail servers) the SMTP/IMAP
  # listeners are bound - kamal must not consider a container healthy
  # while its mail ports are down. See HealthController.
  get "up" => "health#show", as: :rails_health_check

  # The mail servers run inside this process (the :mail_on_rails Puma
  # plugin) and hand inbound mail to Action Mailbox directly
  # (Store::SmtpBackend), so no HTTP ingress exists anymore. Action
  # Mailbox's routes are drawn after this file; pin them closed for
  # everyone with an explicit earlier route answering the same 404 an
  # unknown path would.
  match "rails/action_mailbox/*path", via: :all,
    to: proc { [ 404, { "Content-Type" => "text/plain" }, [ "Not Found\n" ] ] }

  # MTA-STS policy (RFC 8461), fetched by sending MTAs from the
  # mta-sts.<domain> hosts DnsPublisher points at this app.
  # Serves /.well-known/mta-sts.txt (MailOnRails::MtaStsController).
  mount MailOnRails::Engine => "/"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "email_accounts#index"

  # Operational internals (app-wide knobs) - see SettingsController.
  resource :settings, only: %i[show update]

  # Live connections on the in-process mail listeners, one page per
  # protocol - see LiveConnectionsController.
  get "smtp", to: "smtp#show"
  get "imap", to: "imap#show"

  # Stored captures of abnormally ended sessions (smtp_trace_capture),
  # opened from the history rows on the live connections pages - see
  # MailOnRails::SessionTranscript / SessionTranscriptsController.
  resources :session_transcripts, only: :show, path: "transcripts"

  # Prometheus scrape endpoint, enabled by METRICS_TOKEN - see
  # MetricsController.
  get "metrics", to: "metrics#show"

  # The outbound delivery queue (SmtpOutboundMessage) with a delete
  # button to cancel a stuck delivery - see OutboxMessagesController.
  resources :outbox_messages, only: %i[index destroy], path: "outbox"

  # Remote addresses outbound delivery skips because they reported us as
  # spam through a feedback loop, with a button to lift one - see
  # MailOnRails::SuppressedRecipient / SuppressedRecipientsController.
  resources :suppressed_recipients, only: %i[index destroy], path: "suppressions"

  # Failed credential checks across all three auth surfaces - see
  # AuthAttempt / AuthAttemptsController. range drills into one /24's
  # individual addresses; its CIDR travels as a query param because of
  # the slash.
  resources :auth_attempts, only: :index do
    collection { get :range }
  end

  # Permanent IP/CIDR bans, managed from the auth attempts page - see
  # BannedIp for how they reach the mail listeners and the web login.
  resources :banned_ips, only: %i[create destroy]

  # The audit trail of admin actions - see AuditEvent / the Auditing
  # controller concern.
  resources :audit_events, only: :index, path: "audit"

  # Honeypot intelligence: canary logins and exploit probes recorded by the
  # mail listeners, with per-event transcripts - see HoneypotEvent /
  # HoneypotController.
  resources :honeypot_events, only: %i[index show], path: "honeypot", controller: "honeypot" do
    collection { post :kick }
  end

  # The signed-in user's appearance/accent preference, saved from the
  # profile's Appearance card - see ThemesController.
  resource :theme, only: :update



  resources :users, except: %i[show] do
    member do
      post :generate_password
    end
  end

  # Domains we host. Create/destroy takes effect at the next RCPT check
  # (Store::SmtpBackend reads the Domain table live). publish_dns creates
  # the domain's missing DNS records in Cloudflare (DnsPublisher).
  resources :domains, only: %i[index new create show update destroy] do
    member do
      post :publish_dns
      post :recheck_dns
      # Stage a DKIM key rotation: mints the next key/selector; the daily
      # RotateDkimKeysJob promotes it once its TXT is visible in DNS.
      post :rotate_dkim
    end
  end

  # Cached BIMI logos of inbound senders, shown next to DMARC-passing
  # messages in the webmail - see BimiLogosController. (Our own hosted
  # domains' logos are served anonymously by the engine at
  # /bimi/<domain>/logo.svg instead.) The param is :sender, not :domain -
  # :domain is a reserved url_for host option and never binds as a
  # path segment.
  get "bimi/:sender", to: "bimi_logos#show", as: :bimi_logo, format: false,
                      constraints: { sender: /[a-z0-9.\-]+/ }

  # Web-UI compose (ComposedEmail); ?from= preselects the sending account.
  resources :emails, only: %i[new create]

  # Composer autosave. A draft is a message in the Drafts mailbox, so each
  # save replaces the previous revision - see EmailDraft.
  resources :drafts, only: %i[edit create destroy]

  resources :email_accounts, path: "accounts" do
    member do
      post :generate_password
    end
    # Account-wide full-text search over the tsvector index - see
    # SearchesController.
    resource :search, only: :show
    resources :email_aliases, only: %i[create destroy], path: "aliases"
    resources :mailboxes, except: %i[index] do
      # The whole folder as a standard mbox file (streamed - see
      # MboxExport), importable by any other mail client; and the reverse:
      # .eml uploads filed into the folder, the web-UI mirror of IMAP APPEND.
      member do
        get :export
        post :import
      end
      resources :email_messages, only: %i[show destroy], path: "messages" do
        member do
          post :mark_read
          post :rescan
          post :mark_spam
          post :unmark_spam
          # The stored bytes as message/rfc822 - a standard .eml file.
          get :download
          # The same bytes rendered on a page - the "show source" view.
          get :source
          get "attachments/:index", action: :attachment, as: :attachment, constraints: { index: /\d+/ }
        end
      end
    end
  end
end
