# The honeypot intelligence dashboard (/honeypot): canary logins and exploit
# probes recorded by the mail listeners (HoneypotEvent), each showing the
# automatic response taken (a temporary throttle, or observe-only). Unlike the
# auth-attempts page every row here is unambiguously hostile - a real user
# never touches a canary or throws a ${run{...}} payload - so there is nothing
# to separate from noise. Permanent bans and live kicks are manual escalations
# from here. The index also lists the canary accounts the whole thing depends
# on (managed from account settings, EmailAccount#honeypot).
class HoneypotController < ApplicationController
  include BanCoverage

  WINDOWS = { "24h" => 1.day, "7d" => 7.days, "30d" => 30.days }.freeze
  DEFAULT_WINDOW = "7d"

  before_action :set_window, only: :index
  # Kicking live connections is containment tooling; a hijacked session
  # must re-prove identity before wielding it (matching BannedIps).
  before_action :require_recent_reauthentication, only: :kick

  def index
    scope = MailOnRails::HoneypotEvent.recent(@since)
    @totals = {
      events: scope.count,
      sources: scope.where.not(ip: nil).distinct.count(:ip),
      canary_auths: scope.where(trigger: "canary_auth").count,
      probes: scope.where(trigger: "exploit_probe").count
    }
    @events = scope.order(occurred_at: :desc).limit(100)
    @canaries = MailOnRails::EmailAccount.honeypots.order(:email)
    @bans = MailOnRails::BannedIp.order(created_at: :desc).to_a
  end

  def show
    @event = MailOnRails::HoneypotEvent.find(params[:id])
    @bans = MailOnRails::BannedIp.order(created_at: :desc).to_a
  end

  # Immediate, connection-scoped containment: drop the source's live
  # connections without persisting a ban. Zero collateral beyond the
  # moment - the safest escalation, complementing the permanent-ban button
  # (which is the deliberate, higher-collateral step). The mail listeners
  # may live in other containers, so this is a command row per protocol
  # (MailOnRails::ConnectionKick) that each listener picks up on its next
  # ops-sync tick and acknowledges with the count; the flash is
  # fire-and-forget on purpose - waiting on the acknowledgement inside a
  # web request would be RPC over the database.
  def kick
    ip = params[:ip].to_s
    target = IPAddr.new(ip).to_s
    kicks = MailOnRails::ConnectionKick.request!(target, requested_by: Current.user&.email_address)
    audit "honeypot.kick", nil, ip: target, kick_ids: kicks.map(&:id)
    redirect_to honeypot_events_path,
                notice: "Asked the mail servers to drop live connections from #{target}; they act within a few seconds."
  rescue IPAddr::Error
    redirect_to honeypot_events_path, alert: "#{ip.inspect} is not an IP address."
  end

  private

  def set_window
    @window = WINDOWS.key?(params[:window]) ? params[:window] : DEFAULT_WINDOW
    @since = WINDOWS.fetch(@window).ago
  end
end
