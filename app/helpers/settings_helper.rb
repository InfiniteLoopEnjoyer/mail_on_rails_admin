module SettingsHelper
  # Casing humanize can't know: protocol acronyms stay uppercase wherever they
  # land in the label ("rspamd" is styled lowercase by that project, so it is
  # deliberately absent).
  ACRONYMS = {
    "smtp" => "SMTP", "smtps" => "SMTPS", "imap" => "IMAP", "imaps" => "IMAPS",
    "helo" => "HELO", "vrfy" => "VRFY", "dns" => "DNS", "rbl" => "RBL",
    "ttl" => "TTL", "tls" => "TLS", "ip" => "IP", "dkim" => "DKIM",
    "dmarc" => "DMARC", "dane" => "DANE", "mta" => "MTA", "sts" => "STS",
    "clamav" => "ClamAV"
  }.freeze

  def settings_category_title(category)
    SettingsController::CATEGORY_TITLES.fetch(category, category.to_s.humanize)
  end

  def settings_field_label(name)
    label = name.to_s.humanize.split.map { |word| ACRONYMS.fetch(word.downcase, word) }.join(" ")
    label.sub("MTA STS", "MTA-STS")
  end

  # Lowercase for mid-sentence use ("Save SMTP limits"), keeping acronyms.
  def settings_category_phrase(category)
    settings_category_title(category).split.map { |word| ACRONYMS.value?(word) ? word : word.downcase }.join(" ")
  end

  # Where the effective value comes from, for the per-field hint line.
  def settings_provenance_label(row)
    case row.provenance
    when :db then "overridden here"
    when :initializer then "from the initializer"
    when :env then "from ENV #{row.definition.env}"
    else "gem default"
    end
  end
end
