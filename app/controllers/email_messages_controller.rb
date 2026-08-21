require "mail_on_rails/clamav_scanner"

class EmailMessagesController < ApplicationController
  allow_member_access
  before_action :set_email_message
  # Raw .eml egress is the per-message form of mailbox export: a stolen
  # session cookie must not walk the store out one download at a time, so
  # it takes a fresh step-up on top of the audit trail. Viewing the source
  # is the same bytes on a page instead of in a file, so it gets the same
  # gate - otherwise it would be the ungated copy of a gated download.
  before_action :require_recent_reauthentication, only: %i[download source]
  # rescan feeds the stored bytes through clamav on demand - bounded so it
  # can't be scripted into a scanner-load amplifier.
  rate_limit to: 10, within: 3.minutes, only: :rescan,
             with: -> { redirect_back fallback_location: root_path, alert: "Try again later." }

  def show
    # Turbo prefetches links on hover; only an actual visit marks the message
    # read. A click served from the prefetch cache never re-requests, so the
    # page POSTs to mark_read instead (see the mark-read Stimulus controller).
    @email_message.mark_seen! unless prefetch_request?
    # Replying to your own unsent draft is nonsense; that page offers to
    # carry on writing it instead (see the view).
    @draft = EmailDraft.reply_to(@email_message, account: @email_account) unless @email_message.draft?

    # HTML rendering is opt-out (?view=text) and remote images are opt-in
    # (?images=1) - both are per-visit URL state, so nothing sticky can keep
    # a tracking pixel loading behind the reader's back.
    @plain_view = params[:view] == "text"
    @remote_images_allowed = params[:images] == "1"
    @html = @email_message.html_body(allow_remote_images: @remote_images_allowed) unless @plain_view
  end

  def mark_read
    @email_message.mark_seen!
    head :no_content
  end

  # Manual (re)scan from the message page: runs the stored bytes through
  # clamav and records the verdict, which is what unlocks (or keeps locked)
  # the attachment downloads. An unavailable scanner leaves the stored
  # verdict untouched - a clamd hiccup must not downgrade a real "clean".
  def rescan
    head :forbidden and return unless @email_message.rescannable?

    result = MailOnRails::ClamavScanner.scan(@email_message.raw)
    if result.unavailable?
      redirect_to message_path, alert: "The virus scanner is unavailable - try again shortly."
    else
      @email_message.update!(scan_status: result.infected? ? "infected" : "clean",
                             virus_name: result.virus)
      # The flash stays generic; the signature name is retained server-side
      # on the record (virus_name) rather than echoed to the browser.
      redirect_to message_path,
                  notice: result.infected? ? "Virus detected." : "No virus found."
    end
  end

  # "Mark as spam" / "Not spam" from the message page: an IMAP-style move
  # into Junk or back to INBOX. The moved message is a new row with a new
  # UID, so both land back on the folder the message left. Drafts are the
  # owner's own writing - nothing there to mark.
  def mark_spam
    head :forbidden and return if @email_message.draft? || @mailbox.junk?

    @email_message.move_to!(@email_account.junk_mailbox)
    redirect_to email_account_mailbox_path(@email_account, @mailbox), notice: "Moved to Junk."
  end

  def unmark_spam
    head :forbidden and return unless @mailbox.junk?

    @email_message.move_to!(@email_account.inbox)
    redirect_to email_account_mailbox_path(@email_account, @mailbox), notice: "Moved to INBOX."
  end

  # "Delete" from the message page: an IMAP-style move into Trash. Inside
  # Trash there is nowhere softer left to go, so the same action deletes
  # permanently (the view asks for confirmation there).
  def destroy
    if @mailbox.trash?
      @email_message.destroy!
      notice = "Message permanently deleted."
    else
      @email_message.move_to!(@email_account.trash_mailbox)
      notice = "Moved to Trash."
    end
    redirect_to email_account_mailbox_path(@email_account, @mailbox), notice: notice
  end

  # The message as it arrived, byte for byte: raw IS the RFC822 form, and
  # .eml is nothing else. No scan gate - unlike a decoded attachment, an
  # .eml is not a payload a browser will run, and getting mail *out* of
  # the system must not depend on a scanner verdict.
  def download
    audit "message.download", @email_message,
          account: @email_account.email, mailbox: @mailbox.name, bytes: @email_message.raw.bytesize
    send_data @email_message.raw,
              filename: "#{download_basename}.eml", type: "message/rfc822", disposition: "attachment"
  end

  # "Show source": the same stored bytes as download, rendered on a page
  # the way every mail client offers. The template escapes them, so the
  # message's own HTML is inert here; scrubbing makes the bytes valid
  # UTF-8 so escaping can happen at all (raw mail is whatever 8-bit the
  # sender transmitted).
  def source
    audit "message.source", @email_message,
          account: @email_account.email, mailbox: @mailbox.name, bytes: @email_message.raw.bytesize
    @source = @email_message.raw.dup.force_encoding(Encoding::UTF_8).scrub
  end

  # Attachment content types safe to hand back verbatim; anything else is
  # served as an opaque octet-stream. The MIME type is attacker-controlled
  # (it comes straight from the received message), so echoing it lets a
  # sender pick a type the browser might render inline despite the
  # attachment disposition - force a benign type instead.
  SAFE_ATTACHMENT_TYPES = %w[
    image/png image/jpeg image/gif image/webp application/pdf text/plain
  ].freeze

  # Serves one MIME attachment as a download. The view only links attachments
  # on messages that pass attachments_downloadable?; enforce the same rule
  # here so a pasted URL can't fetch an unscanned or infected payload.
  def attachment
    head :forbidden and return unless @email_message.attachments_downloadable?

    info = @email_message.attachments[params[:index].to_i]
    head :not_found and return unless info

    part = @email_message.parsed.attachments[info.index]
    audit "message.attachment", @email_message,
          account: @email_account.email, filename: info.filename, index: params[:index].to_i
    send_data part.body.decoded,
              filename: safe_attachment_filename(info.filename),
              type: safe_content_type(info.content_type), disposition: "attachment"
  end

  private

  def message_path
    email_account_mailbox_email_message_path(@email_account, @mailbox, @email_message)
  end

  # Only an allowlisted MIME type survives to the browser; everything else
  # downloads as an opaque octet-stream (nosniff keeps it from being
  # re-interpreted).
  def safe_content_type(content_type)
    base = content_type.to_s.split(";").first.to_s.strip.downcase
    SAFE_ATTACHMENT_TYPES.include?(base) ? base : "application/octet-stream"
  end

  # The MIME filename comes straight from the received message - attacker
  # header text - so reduce it like download_basename does (keeping the
  # extension) before it reaches Content-Disposition. Rails escapes the
  # header itself; this is the app-layer strip of CR/LF, quotes and path
  # segments so nothing depends on that alone.
  def safe_attachment_filename(name)
    base = File.basename(name.to_s).gsub(/[^\w. \-]/, "").sub(/\A\.+/, "").strip.truncate(80, omission: "")
    base.presence || "attachment"
  end

  # The subject, reduced to filesystem-safe characters; the id keeps two
  # "(no subject)" downloads from clobbering each other.
  def download_basename
    subject = @email_message.subject.to_s.gsub(/[^\w \-]/, "").strip.truncate(60, omission: "")
    [ "message", @email_message.id, subject.presence ].compact.join("-").tr(" ", "-")
  end

  # The scoped root proves the account is accessible; the nested finds
  # below prove the mailbox/message actually belong to it.
  def set_email_message
    @email_account = accessible_email_accounts.find(params[:email_account_id])
    @mailbox = @email_account.mailboxes.find(params[:mailbox_id])
    @email_message = @mailbox.email_messages.find(params[:id])
  end

  def prefetch_request?
    [ request.headers["X-Sec-Purpose"], request.headers["Sec-Purpose"] ].any? { |h| h.to_s.include?("prefetch") }
  end
end
