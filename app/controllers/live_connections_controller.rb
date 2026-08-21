# Live view of the in-process mail servers' connections - the SMTP and
# IMAP sidebar sections, one subclass per protocol. The servers run as
# threads inside this very Puma process (the :mail_on_rails plugin), so
# the page snapshots Server#connections with a method call, no transport;
# a poll Stimulus controller reloads the page's turbo frame every few
# seconds to keep it live. Ban buttons reuse BannedIp - banning also
# drops the address's live connections (BannedIpsController).
class LiveConnectionsController < ApplicationController
  include BanCoverage

  # Window tabs for the history section (ClosedConnection); the live
  # table above it always shows the present moment regardless.
  WINDOWS = { "24h" => 1.day, "7d" => 7.days, "30d" => 30.days }.freeze
  DEFAULT_WINDOW = "24h"

  def show
    require "mail_on_rails"
    @window = WINDOWS.key?(params[:window]) ? params[:window] : DEFAULT_WINDOW
    @since = WINDOWS.fetch(@window).ago
    @server = MailOnRails.server(protocol)
    @connections = (@server&.connections || []).sort_by { |conn| conn[:connected_at] }
    # AuthThrottle's live per-IP lockouts ({ ip => seconds remaining }) -
    # these addresses are refused before a session exists, so the live
    # table alone would never show them.
    @lockouts = @server&.lockouts || {}
    # History and the repeat-offender totals are DB-backed, so they render
    # even when no server runs in this process.
    @history = MailOnRails::ClosedConnection.recent_list(protocol, since: @since)
    @top_sources = MailOnRails::ClosedConnection.top_sources(protocol, since: @since)
    @bans = MailOnRails::BannedIp.order(created_at: :desc).to_a
    # Attribution (rDNS/ASN/country, the honeypot pages' CymruLookup blob)
    # for every address the page shows, from the IpEnrichment cache.
    # Unknown addresses get a background lookup and fill in on a later
    # refresh; order sets who wins the per-call lookup budget.
    ips = @connections.map { |conn| conn[:peer_ip] } + @lockouts.keys +
          @top_sources.map { |source| source[:ip] } + @history.map(&:ip)
    @enrichments = MailOnRails::IpEnrichment.ensure_all(ips)
  end

  private

  # :smtp / :imap, from the subclass naming (SmtpController -> "smtp").
  def protocol
    controller_name.to_sym
  end
end
