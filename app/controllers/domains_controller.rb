class DomainsController < ApplicationController
  before_action :set_domain, only: %i[show update destroy publish_dns recheck_dns rotate_dkim]
  # Adding a domain, cutting off its mail, pushing DNS changes, changing
  # the published brand logo, or rotating signing keys are high-impact
  # writes: gate them behind fresh proof of identity. recheck_dns is
  # read-only (re-runs verification), so it stays ungated.
  before_action :require_recent_reauthentication, only: %i[create update destroy publish_dns rotate_dkim]
  # Tighter than the other admin surfaces: publish_dns calls the
  # Cloudflare API and destroy cuts off a domain's inbound mail.
  rate_limit to: 10, within: 3.minutes, only: %i[create update destroy publish_dns recheck_dns rotate_dkim],
             with: -> { redirect_to domains_path, alert: "Try again later." }

  def index
    @domains = MailOnRails::Domain.order(:name)
  end

  def show
    # refresh! rather than for: the live check doubles as a write-through
    # refresh of the index-pill cache.
    @dns = MailOnRails::DnsCheck.refresh!(@domain)
    @dmarc_stats = MailOnRails::DmarcReport.stats(@domain)
    @dmarc_advice = @domain.dmarc_advice(@dmarc_stats, @dns.dmarc_record)
    @tls_rpt_stats = MailOnRails::TlsRptReport.stats(@domain)
    @tls_rpt_reports = @domain.tls_rpt_reports.recent.order(begin_at: :desc, id: :desc).limit(10)
  end

  def new
    @domain = MailOnRails::Domain.new
  end

  def create
    @domain = MailOnRails::Domain.new(domain_params)
    if @domain.save
      audit "domain.create", @domain
      redirect_to @domain, notice: "Domain #{@domain.name} added. Publish the DNS records below."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # Only the BIMI logo is editable after creation (the name is the
  # domain's identity - remove and re-add for that). The SVG is sanitized
  # by the model's validation; a blank submission clears the logo.
  def update
    if @domain.update(params.expect(domain: [ :bimi_svg ]))
      audit "domain.update", @domain
      notice = @domain.bimi_svg.present? ? "BIMI logo saved. Publish DNS to create the default._bimi record." : "BIMI logo removed."
      redirect_to @domain, notice: notice
    else
      redirect_to @domain, alert: "BIMI logo rejected: #{@domain.errors[:bimi_svg].to_sentence}"
    end
  end

  # Stage a DKIM key rotation: the next key exists from here on, but
  # signing only switches once the daily RotateDkimKeysJob sees the new
  # selector's TXT in public DNS (published via the button above, or by
  # hand for DNS managed elsewhere).
  def rotate_dkim
    if @domain.dkim_staged?
      return redirect_to @domain, alert: "A rotation is already staged (#{@domain.dkim_next_selector}) - " \
                                         "publish its TXT and the daily job will promote it."
    end

    @domain.stage_dkim_rotation!
    audit "domain.rotate_dkim", @domain, next_selector: @domain.dkim_next_selector
    redirect_to @domain, notice: "New DKIM key staged under selector #{@domain.dkim_next_selector}. " \
                                 "Publish the TXT (button above, or manually), and signing switches " \
                                 "automatically once public DNS shows it; the old selector is revoked a week later."
  end

  # Explicit admin action: create this domain's missing DNS records in
  # Cloudflare (see DnsPublisher for what is and isn't touched).
  def publish_dns
    unless MailOnRails::CloudflareDns.enabled?
      return redirect_to @domain, alert: "CLOUDFLARE_API_TOKEN is not configured."
    end

    result = MailOnRails::DnsPublisher.publish!(@domain)
    audit "domain.publish_dns", @domain, actions: result.actions, skipped: result.skipped
    notice = result.actions.any? ? "Cloudflare: #{result.actions.join("; ")}." : "Cloudflare: nothing to publish."
    notice += " Skipped: #{result.skipped.join("; ")}." if result.skipped.any?
    redirect_to @domain, notice: notice
  rescue MailOnRails::CloudflareDns::Error => e
    redirect_to @domain, alert: "Cloudflare publish failed: #{e.message}"
  end

  # Explicit recheck button; show itself re-runs the live check on render.
  def recheck_dns
    redirect_to @domain, notice: "DNS rechecked against public DNS."
  end

  def destroy
    @domain.destroy!
    audit "domain.destroy", @domain
    redirect_to domains_path, notice: "Domain #{@domain.name} removed. Inbound mail for it is now refused.",
                              status: :see_other
  end

  private

  def set_domain
    @domain = MailOnRails::Domain.find(params[:id])
  end

  def domain_params
    params.expect(domain: [ :name ])
  end
end
