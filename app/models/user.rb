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

  # Accept the previous/next TOTP code too - phone clocks drift. That makes
  # three codes valid at any instant instead of one, which the wrong-code
  # lock below is what pays for: at its long-run rate of
  # OTP_FAILURES_PER_LOCK guesses a day the odds stay around 1.5e-5 a day.
  OTP_DRIFT = 30
  OTP_ISSUER = "Mail on Rails"

  # Wrong authenticator codes are counted per user, apart from the shared
  # password budget (MailOnRails::AuthThrottle), because the guesser here
  # already holds the password or a session cookie and the space is only
  # 10^6: a flat "N failures, short block, start over" lets them grind it.
  # Every OTP_FAILURES_PER_LOCK-th consecutive failure blocks code
  # verification, and each block is twice the last - 5 min, 10 min, 20 min
  # ... up to OTP_LOCK_MAX - so sustained guessing settles at
  # OTP_FAILURES_PER_LOCK codes a day. Only an accepted code (or
  # re-enrolling, or a password rotation, which cuts the guesser off) puts
  # the count back to zero; waiting does not. Passkeys are unaffected, so
  # an owner with one enrolled is never locked out by someone else's
  # guessing.
  OTP_FAILURES_PER_LOCK = 5
  OTP_LOCK_BASE = 5.minutes
  OTP_LOCK_MAX = 24.hours

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
  #
  # The same lock covers the failure count (see OTP_FAILURES_PER_LOCK): the
  # block is re-read and enforced inside it, so a burst of parallel guesses
  # is adjudicated one at a time against the budget rather than all against
  # the count as it stood before the burst. While blocked nothing is
  # checked - a correct code is refused too.
  def verify_otp(code)
    return false unless otp_enabled?

    with_lock do
      next false if otp_locked?

      timestep = ROTP::TOTP.new(otp_secret, issuer: OTP_ISSUER).verify(
        code.to_s.delete(" "),
        drift_behind: OTP_DRIFT, drift_ahead: OTP_DRIFT, after: otp_last_used_at
      )
      if timestep
        update!(otp_last_used_at: timestep, otp_failed_attempts: 0, otp_locked_until: nil)
        true
      else
        record_otp_failure
        false
      end
    end
  end

  def otp_locked?(now: Time.current)
    otp_locked_until.present? && otp_locked_until > now
  end

  # Forgets the failure count and any block. For the moments the secret
  # being guessed stops existing or the guesser loses their way in:
  # (re-)enrolling or removing the authenticator, and a password rotation.
  def clear_otp_lock!
    update_columns(otp_failed_attempts: 0, otp_locked_until: nil)
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

  private
    # update_columns: a counter bump is not a profile change - no validations
    # to run and no users-index broadcast to send per wrong guess.
    def record_otp_failure(now: Time.current)
      failures = otp_failed_attempts + 1
      locked_until = nil
      if (failures % OTP_FAILURES_PER_LOCK).zero?
        doublings = [ failures / OTP_FAILURES_PER_LOCK - 1, 30 ].min
        locked_until = now + [ OTP_LOCK_BASE * (2**doublings), OTP_LOCK_MAX ].min
      end
      update_columns(otp_failed_attempts: failures, otp_locked_until: locked_until)
    end
end
