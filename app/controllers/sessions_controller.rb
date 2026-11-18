class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  allow_member_access
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    # Admin-managed permanent bans (BannedIp) and the durable AuthThrottle
    # cover this surface just like the mail edges (Store::Base#authenticate):
    # both refuse before the bcrypt comparison. Rails' cache-backed
    # rate_limit above stays as the cheap first gate. Deliberately the same
    # message for ban and throttle: a blocked scanner learns nothing new.
    email_address, password = credential_param(:email_address), credential_param(:password)

    if MailOnRails::BannedIp.covering(request.remote_ip) ||
       MailOnRails::AuthThrottle.check(ip: request.remote_ip, email: email_address)
      MailOnRails::AuthAttempt.record(ip: request.remote_ip, username: email_address,
                         source: "web", outcome: "throttled")
      return redirect_to new_session_path, alert: "Try again later."
    end

    if user = User.authenticate_by(email_address: email_address, password: password)
      if user.second_factor_enabled?
        # No clear_account yet: a password-only success must not refill the
        # budget for an attacker still guessing the second factor. The
        # counter clears in ChallengesController#complete_sign_in.
        stash_pending_second_factor user
        redirect_to new_two_factor_challenge_path
      else
        MailOnRails::AuthThrottle.clear_account(user.email_address)
        start_new_session_for user
        # A fresh password sign-in opens the step-up window (a resumed cookie
        # never reaches here), so enrollment/admin gates don't re-prompt.
        mark_reauthenticated!
        redirect_to after_authentication_url
      end
    else
      MailOnRails::AuthThrottle.record_failure(ip: request.remote_ip, email: email_address)
      # Recorded so the web login shows up alongside IMAP and SMTP AUTH in
      # the attempt log. The rejected password rides along; AuthAttempt
      # keeps it only while the auth_log_passwords setting is on.
      MailOnRails::AuthAttempt.record(ip: request.remote_ip, username: email_address,
                         source: "web", outcome: "bad_credentials", password: password)
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  private
    # The login form posts two strings. Anything else a client can make of
    # those names - email_address[]=, email_address[x]=, a NUL byte - is
    # read as an empty credential, so it takes the ordinary failed-login
    # path (counted and logged like any wrong guess) instead of raising in
    # the finder or the database driver.
    def credential_param(name)
      value = params[name]
      value.is_a?(String) && !value.include?("\0") ? value : ""
    end
end
