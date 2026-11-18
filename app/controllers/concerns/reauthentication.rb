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

  # The window is kept in the Rack session, but identity is a different
  # cookie (the signed session_id). A bare deadline would therefore
  # authorize whichever identity it is presented next to: someone holding a
  # stolen session_id cookie could sign in as themselves, keep their own
  # freshly stamped Rack session and swap in the stolen id. So the stamp
  # names the Session row and user that earned it, and only counts for
  # exactly that pair.
  def reauthenticated_recently?
    stamp = session_bound(:reauthenticated)
    stamp.present? && Time.current.to_i < stamp["until"].to_i
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
    bind_to_session(:reauthenticated, "until" => REAUTHENTICATION_GRACE.from_now.to_i)
  end

  # Rack-session state that belongs to one signed-in identity (the step-up
  # stamp, a pending TOTP secret, a WebAuthn challenge) is stored together
  # with the Session row id and user id it was created under, and read back
  # only while both still match Current.session - see
  # reauthenticated_recently? for the cookie transplant this stops. A value
  # written under another identity reads as absent.
  def bind_to_session(key, value)
    session[key] = value.merge("session_id" => Current.session.id, "user_id" => Current.session.user_id)
  end

  def session_bound(key)
    value = session[key]
    return nil unless value.is_a?(Hash) && Current.session
    return nil unless value["session_id"] == Current.session.id && value["user_id"] == Current.session.user_id

    value
  end

  # Read-once variant: the key is gone afterwards whether or not it matched.
  def take_session_bound(key)
    session_bound(key).tap { session.delete(key) }
  end

  # The WebAuthn challenge issued to this session for +purpose+, consumed.
  # "" when there is none (or it was issued to another identity, or for
  # another ceremony), which no assertion can verify against.
  def take_webauthn_challenge(purpose)
    stash = take_session_bound(:webauthn_challenge)
    stash && stash["purpose"] == purpose ? stash["challenge"].to_s : ""
  end

  # Same-origin only (url_from rejects other hosts and protocol-relative
  # URLs); consumed once on success.
  def reauthentication_return_to
    url_from(session.delete(:reauthentication_return_to)) || edit_user_url(Current.user)
  end
end
