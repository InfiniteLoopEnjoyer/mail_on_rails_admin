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
  # connections without persisting anything. Zero collateral beyond the
  # moment - the safest escalation, complementing the permanent-ban button
  # (which is the deliberate, higher-collateral step).
  def kick
    ip = params[:ip].to_s
    count = kick_connections_from(ip)
    audit "honeypot.kick", nil, ip: ip, kicked: count
    notice = count.positive? ? "Dropped #{count} live #{"connection".pluralize(count)} from #{ip}." : "No live connections from #{ip}."
    redirect_to honeypot_events_path, notice: notice
  end

  private

  def kick_connections_from(ip)
    require "mail_on_rails"
    target = IPAddr.new(ip)
    MailOnRails.kick_connections do |conn_ip|
      IPAddr.new(conn_ip) == target
    rescue IPAddr::Error
      false
    end
  rescue IPAddr::Error
    0
  end

  def set_window
    @window = WINDOWS.key?(params[:window]) ? params[:window] : DEFAULT_WINDOW
    @since = WINDOWS.fetch(@window).ago
  end
end
