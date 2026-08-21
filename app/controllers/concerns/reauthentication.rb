# Step-up ("sudo mode") for sensitive account actions - removing or adding a
# second factor, rotating a password, privileged admin writes, and mail
# egress (folder export, .eml download, web send). An active session is not
# enough for these: a stolen session cookie could otherwise strip a user's
# TOTP, enroll an attacker's passkey, rotate the password, retune the mail
# servers, or walk the mail store out. A gated action redirects (or, for
# JSON/passkey
# endpoints, 403s) to ReauthenticationsController, which re-verifies the
# password or a current second factor and stamps a short grace window here.
#
# Signing in stamps the window too (see the auth flow): a user who just
# proved their password - and second factor, if enrolled - is step-up-fresh
# for the grace period, so first-login 2FA enrollment and a run of admin
# edits need no extra prompt. The threat these gates stop is a *resumed*
# session cookie, which never passes a fresh sign-in.
module Reauthentication
  extend ActiveSupport::Concern

  # How long a successful re-auth authorizes the gated actions. Long enough to
  # remove several passkeys in one sitting without re-confirming each.
  REAUTHENTICATION_GRACE = 10.minutes

  STEP_UP_MESSAGE = "Confirm your identity to continue."

  private

  def reauthenticated_recently?
    deadline = session[:reauthenticated_until].to_i
    deadline.positive? && Time.current.to_i < deadline
  end

  # before_action for the gated actions. Non-GET actions (button_to DELETE,
  # form POSTs) return to the settings page that issued them (the referrer),
  # never the action target itself. JSON callers (the passkey enrollment
  # endpoints) get a 403 with the URL to send the user to instead of a
  # redirect their fetch can't follow.
  def require_recent_reauthentication
    return if reauthenticated_recently?

    if request.format.json?
      render json: { error: STEP_UP_MESSAGE, reauth_url: new_reauthentication_path },
             status: :forbidden
    else
      session[:reauthentication_return_to] = url_from(request.referer) || edit_user_url(Current.user)
      redirect_to new_reauthentication_path, alert: STEP_UP_MESSAGE
    end
  end

  def mark_reauthenticated!
    session[:reauthenticated_until] = REAUTHENTICATION_GRACE.from_now.to_i
  end

  # Same-origin only (url_from rejects other hosts and protocol-relative
  # URLs); consumed once on success.
  def reauthentication_return_to
    url_from(session.delete(:reauthentication_return_to)) || edit_user_url(Current.user)
  end
end
