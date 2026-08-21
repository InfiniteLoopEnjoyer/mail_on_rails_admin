# One stored session capture (MailOnRails::SessionTranscript), opened from a
# history row on the live connections pages (/smtp, /imap). Captures exist
# only when smtp_trace_capture is on, and only for sessions that ended
# abnormally - the redacted command/reply dialogue, never message bodies or
# credentials. Transcripts are pruned on a much shorter clock than the
# history rows that link to them, so a dangling link is expected: it lands
# here as an explanatory redirect rather than a 404.
class SessionTranscriptsController < ApplicationController
  include BanCoverage

  def show
    @transcript = MailOnRails::SessionTranscript.find_by(id: params[:id])
    unless @transcript
      return redirect_to smtp_path, alert: "That capture is no longer retained (transcripts are pruned after #{MailOnRails::SessionTranscript.retention_days} days)."
    end

    @bans = MailOnRails::BannedIp.order(created_at: :desc).to_a
  end
end
