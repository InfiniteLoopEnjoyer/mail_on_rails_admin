class User < ApplicationRecord
  has_secure_password
  include MailOnRails::GeneratedPassword
  has_many :sessions, dependent: :destroy
  has_many :webauthn_credentials, dependent: :destroy
  has_many :email_account_users, dependent: :destroy
  has_many :email_accounts, through: :email_account_users

  encrypts :otp_secret

  # Web-UI roles. Admins see and manage everything; members are confined to
  # the email accounts granted to them via email_account_users. Protocol
  # (IMAP/SMTP) access is a separate credential system on EmailAccount and
  # is not governed by this.
  ROLES = %w[admin member].freeze

  # Accept the previous/next TOTP code too - phone clocks drift.
  OTP_DRIFT = 30
  OTP_ISSUER = "Mail on Rails"

  # Theme preferences, edited from the profile's Appearance card and painted
  # onto <html> by the layout. Accent names map to their light-mode swatch
  # colour; the CSS holding both modes lives with the [data-accent] rules in
  # app/assets/tailwind/application.css - keep the two lists in sync.
  # "system" resolves to the OS preference client-side.
  APPEARANCES = %w[light dark system].freeze
  ACCENT_THEMES = {
    "crimson" => "#c8102e",
    "blue"    => "#2563eb",
    "emerald" => "#059669",
    "violet"  => "#7c3aed",
    "orange"  => "#ea580c",
    "sky"     => "#0284c7"
  }.freeze

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: ROLES }
  validates :appearance, inclusion: { in: APPEARANCES }
  validates :accent, inclusion: { in: ACCENT_THEMES.keys }

  # Live-refresh the users index (subscribed via turbo_stream_from :users).
  after_commit -> { broadcast_refresh_later_to :users }

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  def admin?
    role == "admin"
  end

  # The single scoping primitive for the web UI: every controller that
  # touches mail data resolves accounts through this. Always a relation,
  # so .find/.order/.exists? compose either way.
  def accessible_email_accounts
    admin? ? MailOnRails::EmailAccount.all : email_accounts
  end

  def second_factor_enabled?
    otp_enabled? || webauthn_credentials.exists?
  end

  def otp_enabled?
    otp_secret.present?
  end

  # Checks a TOTP code and burns its timestep, so a stolen code can't be
  # replayed inside the drift window. Returns true iff the code was accepted.
  # The verify-then-burn runs under a row lock so two requests presenting the
  # same code can't both read the old otp_last_used_at and both succeed - the
  # loser re-reads the burned timestep inside the lock and is rejected.
  def verify_otp(code)
    return false unless otp_enabled?

    with_lock do
      timestep = ROTP::TOTP.new(otp_secret, issuer: OTP_ISSUER).verify(
        code.to_s.delete(" "),
        drift_behind: OTP_DRIFT, drift_ahead: OTP_DRIFT, after: otp_last_used_at
      )
      return false unless timestep

      update!(otp_last_used_at: timestep)
      true
    end
  end

  def otp_provisioning_uri(secret)
    ROTP::TOTP.new(secret, issuer: OTP_ISSUER).provisioning_uri(email_address)
  end

  # The stable opaque handle authenticators know this user by; minted when
  # the first passkey is registered.
  def webauthn_handle
    update!(webauthn_id: WebAuthn.generate_user_id) if webauthn_id.blank?
    webauthn_id
  end
end
