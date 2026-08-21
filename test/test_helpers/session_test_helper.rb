module SessionTestHelper
  # Mirrors a real sign-in, which opens the step-up window (see
  # Reauthentication): the gated enrollment/admin actions expect a
  # freshly-authenticated session, so stamp it by default. Pass
  # step_up: false to reproduce a resumed cookie that must be re-challenged.
  # Fixture users share the password "password".
  def sign_in_as(user, step_up: true, password: "password")
    Current.session = user.sessions.create!

    ActionDispatch::TestRequest.create.cookie_jar.tap do |cookie_jar|
      cookie_jar.signed[:session_id] = Current.session.id
      cookies["session_id"] = cookie_jar[:session_id]
    end

    reauthenticate(password: password) if step_up
  end

  def sign_out
    Current.session&.destroy!
    cookies.delete("session_id")
  end

  # Opens the step-up grace window (Reauthentication) so a following gated
  # action (removing TOTP/passkeys) is allowed. Fixture users share the
  # password "password".
  def reauthenticate(password: "password")
    post reauthentication_path, params: { password: password }
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include SessionTestHelper
end
