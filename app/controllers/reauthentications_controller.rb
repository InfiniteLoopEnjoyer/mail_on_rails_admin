# Step-up verification (see the Reauthentication concern). Re-checks the
# signed-in user's password or a current second factor, then stamps the grace
# window that lets the gated actions (removing TOTP/passkeys) proceed. Mirrors
# TwoFactor::ChallengesController, but the user is already signed in, so
# success stamps the window instead of starting a session.
class ReauthenticationsController < ApplicationController
  allow_member_access
  rate_limit to: 10, within: 3.minutes, only: %i[create totp],
             with: -> { redirect_to new_reauthentication_path, alert: "Try again later." }
  # The passkey endpoints answer JSON (webauthn_controller.js); a separate
  # name so the counters don't merge with the password/totp forms.
  rate_limit to: 10, within: 3.minutes, only: %i[webauthn_options webauthn], name: "webauthn",
             with: -> { render json: { error: "Try again later." }, status: :too_many_requests }
  # Same durable, account-scoped brute-force budget the login stages use, so
  # an attacker holding a session cookie can't grind the password/TOTP space
  # by hopping IPs. webauthn_options only mints a challenge, so it is left out.
  before_action :enforce_throttle, only: %i[create totp webauthn]

  def new
  end

  # Password path.
  def create
    if Current.user.authenticate(params[:password].to_s)
      confirmed
      redirect_to reauthentication_return_to, notice: "Identity confirmed."
    else
      record_failure
      redirect_to new_reauthentication_path, alert: "That password didn't match."
    end
  end

  # Authenticator-app path.
  def totp
    if Current.user.verify_otp(params[:code])
      confirmed
      redirect_to reauthentication_return_to, notice: "Identity confirmed."
    else
      record_failure
      redirect_to new_reauthentication_path, alert: "That code didn't work. Try again."
    end
  end

  def webauthn_options
    options = WebAuthn::Credential.options_for_get(
      allow: Current.user.webauthn_credentials.pluck(:external_id),
      user_verification: "required"
    )
    session[:webauthn_challenge] = options.challenge
    render json: options
  end

  def webauthn
    credential = WebAuthn::Credential.from_get(params.require(:credential).to_unsafe_h)
    stored = Current.user.webauthn_credentials.find_by!(external_id: credential.id)
    credential.verify(session.delete(:webauthn_challenge).to_s,
      public_key: stored.public_key, sign_count: stored.sign_count, user_verification: true)
    stored.update!(sign_count: credential.sign_count)
    confirmed
    render json: { location: reauthentication_return_to }
  rescue WebAuthn::Error, ActiveRecord::RecordNotFound, ActionController::ParameterMissing
    record_failure
    render json: { error: "Passkey verification failed." }, status: :unprocessable_entity
  end

  private
    def confirmed
      mark_reauthenticated!
      MailOnRails::AuthThrottle.clear_account(Current.user.email_address)
    end

    def enforce_throttle
      return unless MailOnRails::AuthThrottle.check(ip: request.remote_ip, email: Current.user.email_address)

      MailOnRails::AuthAttempt.record(ip: request.remote_ip, username: Current.user.email_address,
                                      source: "web", outcome: "throttled")
      message = "Too many attempts. Try again later."
      if request.format.json?
        render json: { error: message }, status: :too_many_requests
      else
        redirect_to new_reauthentication_path, alert: message
      end
    end

    def record_failure
      MailOnRails::AuthThrottle.record_failure(ip: request.remote_ip, email: Current.user.email_address)
      MailOnRails::AuthAttempt.record(ip: request.remote_ip, username: Current.user.email_address,
                                      source: "web", outcome: "bad_credentials")
    end
end
