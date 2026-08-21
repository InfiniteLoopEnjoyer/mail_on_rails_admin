# Live view of the mail servers' connections - the SMTP and IMAP sidebar
# sections, one subclass per protocol. The listeners may run inside this
# very Puma process (the :mail_on_rails plugin) or in their own containers
# (the production smtp/imap roles); either way each server projects its
# live picture into the database every couple of seconds
# (MailOnRails::Netserv::OpsSync -> Listener / OpenConnection /
# AcceptLockout), and this page reads those tables. Ban buttons reuse
# BannedIp - the listeners drop a banned address's live connections on
# their next sync tick (BannedIpsController).
class LiveConnectionsController < ApplicationController
  include BanCoverage

  # Window tabs for the history section (ClosedConnection); the live
  # table above it always shows the present moment regardless.
  WINDOWS = { "24h" => 1.day, "7d" => 7.days, "30d" => 30.days }.freeze
  DEFAULT_WINDOW = "24h"

  def show
    @window = WINDOWS.key?(params[:window]) ? params[:window] : DEFAULT_WINDOW
    @since = WINDOWS.fetch(@window).ago
    # The running servers for this protocol (normally one; a stale row -
    # a killed container that never ran its shutdown - drops out after
    # ops_stale_after seconds).
    @listeners = MailOnRails::Listener.alive(protocol)
    @max_connections = @listeners.sum { |listener| listener.max_connections.to_i }
    @connections = MailOnRails::OpenConnection.live(protocol).to_a
    # The accept-side per-IP lockouts ({ ip => seconds remaining }) -
    # these addresses are refused before a session exists, so the live
    # table alone would never show them.
    @lockouts = MailOnRails::AcceptLockout.active(protocol)
    # History and the repeat-offender totals are DB-backed too.
    @history = MailOnRails::ClosedConnection.recent_list(protocol, since: @since)
    @top_sources = MailOnRails::ClosedConnection.top_sources(protocol, since: @since)
    @bans = MailOnRails::BannedIp.order(created_at: :desc).to_a
    # Attribution (rDNS/ASN/country, the honeypot pages' CymruLookup blob)
    # for every address the page shows, from the IpEnrichment cache.
    # Unknown addresses get a background lookup and fill in on a later
    # refresh; order sets who wins the per-call lookup budget.
    ips = @connections.map(&:peer_ip) + @lockouts.keys +
          @top_sources.map { |source| source[:ip] } + @history.map(&:ip)
    @enrichments = MailOnRails::IpEnrichment.ensure_all(ips)
  end

  private

  # :smtp / :imap, from the subclass naming (SmtpController -> "smtp").
  def protocol
    controller_name.to_sym
  end
end
