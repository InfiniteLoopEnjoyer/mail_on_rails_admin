# The admin surface of the gem's settings schema: every dynamic-scope
# setting (feature toggles, limits, timeouts, service addresses) rendered
# from its metadata, grouped by category, one form per category card.
# Overrides saved here beat the initializer/ENV/default tiers and reach
# the running listeners without a restart. Boot-only settings (ports, TLS
# material, secrets) are never rendered, and MailOnRails::Setting.write
# refuses them server-side.
class SettingsController < ApplicationController
  # Retuning the mail servers (scanner addresses, throttle thresholds,
  # enforcement toggles) is high-impact: gate it behind fresh proof of
  # identity, not just a resumed admin session cookie.
  before_action :require_recent_reauthentication, only: :update
  rate_limit to: 20, within: 10.minutes, only: :update,
             with: -> { redirect_to settings_path, alert: "Try again later." }

  CATEGORY_TITLES = {
    identity: "Identity",
    filtering: "Inbound filtering",
    smtp_limits: "SMTP limits",
    imap_limits: "IMAP limits",
    auth_bruteforce: "Authentication throttling",
    outbound: "Outbound delivery",
    honeypot: "Honeypot",
    retention: "Retention"
  }.freeze

  Row = Struct.new(:definition, :override_raw, :effective_display, :fallback_display, :provenance)

  def show
    @groups = setting_groups
  end

  # One category card posts all its fields; blank means "no override".
  # All-or-nothing: one bad value rolls the whole submit back.
  def update
    changes = settings_params
    return redirect_to settings_path, alert: "Nothing to save." if changes.empty?

    applied = {}
    MailOnRails::Setting.transaction do
      changes.each do |name, raw|
        applied[name.to_sym] = display_value(write_setting(name, raw), MailOnRails::Settings.definition(name.to_sym))
      end
    end
    audit "settings.update", nil, **applied
    redirect_to settings_path, notice: "Settings saved - changes apply to new connections without a restart."
  rescue ArgumentError, TypeError => e
    redirect_to settings_path, alert: "Not saved: #{e.message}."
  end

  private

  # Only names the schema declares dynamic are accepted; anything else in
  # the payload is dropped (Setting.write would refuse it anyway).
  def settings_params
    dynamic = MailOnRails::Settings.definitions.select(&:dynamic?).map { |d| d.name.to_s }
    params.fetch(:settings, ActionController::Parameters.new).permit(*dynamic).to_h
  end

  # Re-raise with the setting's name so the flash says which knob failed.
  def write_setting(name, raw)
    MailOnRails::Setting.write(name, raw)
  rescue ArgumentError, TypeError => e
    raise e.class, e.message.start_with?(name.to_s) ? e.message : "#{name} #{e.message}"
  end

  def setting_groups
    overrides = MailOnRails::Setting.override_rows
    dynamic = MailOnRails::Settings.definitions.select(&:dynamic?)
    CATEGORY_TITLES.keys.filter_map do |category|
      definitions = dynamic.select { |definition| definition.category == category }
      next if definitions.empty?

      rows = definitions.map do |definition|
        Row.new(definition,
                overrides[definition.name.to_s],
                display_value(MailOnRails::Setting.read(definition.name), definition),
                display_value(MailOnRails::Settings.static(definition.name), definition),
                MailOnRails::Settings.provenance(definition.name))
      end
      [ category, rows ]
    end
  end

  def display_value(value, definition)
    case value
    when nil then "(not set)"
    when true then "on"
    when false then "off"
    when Array then value.empty? ? "(none)" : value.join(", ")
    else
      definition.secret? ? "(hidden)" : value.to_s
    end
  end
end
