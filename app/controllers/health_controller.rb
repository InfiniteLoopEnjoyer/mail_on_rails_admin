# The /up endpoint kamal health-checks during deploys. On top of Rails'
# stock "booted without exceptions" check, this reports down (500) while
# mail listeners that are supposed to live IN THIS PROCESS have not bound
# yet - a container that publishes mail ports must not be cut over before
# it can serve them. Which protocols those are is
# MailOnRails::Runtime.in_process_protocols (the Puma plugin's answer:
# config.mail_on_rails.protocols, else MAIL_ON_RAILS_SERVERS, else every
# installed protocol in development and none elsewhere). A web process
# whose listeners run in other containers (the production roles) gates on
# nothing but itself: those containers answer for their own ports.
class HealthController < Rails::HealthController
  before_action :require_mail_listeners

  private

  def require_mail_listeners
    require "mail_on_rails"
    return if MailOnRails::Runtime.in_process_protocols.empty?

    render_down unless MailOnRails.ready?
  rescue ArgumentError
    # An unknown protocol name in MAIL_ON_RAILS_SERVERS fails the plugin's
    # boot loudly; here it just means nothing could have bound.
    render_down
  end
end
