# Serves the cached, sanitized BIMI logo of an inbound sender domain
# (MailOnRails::BimiIndicator), referenced by <img> tags next to
# DMARC-passing messages in the webmail. Authenticated like the rest of
# the webmail - which domains we hold logos for is correspondence
# metadata. The strict sanitizer already ran at fetch time; the headers
# here keep even a hypothetical bad SVG inert (no scripts, no external
# loads, never a document in our origin).
class BimiLogosController < ApplicationController
  def show
    indicator = MailOnRails::BimiIndicator.find_by(domain: params[:sender].to_s.strip.downcase)
    return head :not_found unless indicator&.displayable?

    response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "private, max-age=86400"
    render plain: indicator.svg, content_type: "image/svg+xml"
  end
end
