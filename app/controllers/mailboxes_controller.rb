require "mail_on_rails/clamav_scanner"

class MailboxesController < ApplicationController
  # Folder CRUD and mbox import/export are mail usage, not administration -
  # a member's own IMAP client can do all of this with the account password.
  # Scoping lives in set_email_account.
  allow_member_access
  before_action :set_email_account
  before_action :set_mailbox, only: %i[show edit update destroy export import]
  # Export lifts an entire folder out of the account in one request - the
  # exact move a stolen session cookie would make - so it takes a fresh
  # step-up on top of the audit trail below.
  before_action :require_recent_reauthentication, only: :export
  rate_limit to: 30, within: 10.minutes, only: %i[create update destroy import],
             with: -> { redirect_to email_account_path(params[:email_account_id]), alert: "Try again later." }

  # The same bound the IMAP server advertises as APPENDLIMIT: import is the
  # web-UI mirror of APPEND, so a file APPEND would refuse is refused here too.
  MAX_IMPORT_BYTES = 30 * 1024 * 1024

  # Newest-first, one page at a time - a mailbox can hold years of mail and
  # rendering it all in one response hurts long before the query does
  # (there's an index on mailbox_id + internal_date).
  MESSAGES_PER_PAGE = 50

  # One list row per conversation: the messages sharing a thread_id,
  # oldest first (the row shows the newest and a count).
  MailboxThread = Struct.new(:messages) do
    def latest = messages.last
    def count = messages.size
    def unseen? = messages.any? { |m| !m.seen? }
  end

  def show
    scope = @mailbox.email_messages
    @message_count = scope.count
    # Threads paginate by latest activity: the thread with the newest
    # message comes first, however old its roots are.
    @thread_count = scope.distinct.count(:thread_id)
    @pages = [ @thread_count.fdiv(MESSAGES_PER_PAGE).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    page_threads = scope.group(:thread_id)
                        .select("thread_id, MAX(internal_date) AS latest_date, MAX(uid) AS latest_uid")
                        .order("latest_date DESC, latest_uid DESC")
                        .offset((@page - 1) * MESSAGES_PER_PAGE).limit(MESSAGES_PER_PAGE)
    grouped = scope.where(thread_id: page_threads.map(&:thread_id))
                   .order(:internal_date, :uid).group_by(&:thread_id)
    @threads = page_threads.filter_map { |t| (messages = grouped[t.thread_id]) && MailboxThread.new(messages) }
  end

  # The whole folder as one standard mbox download. The export enumerates
  # lazily (one message in memory at a time) and Rack streams the
  # enumerator, so a folder holding years of mail never builds a
  # folder-sized string.
  def export
    export = MboxExport.new(@mailbox)
    # Bulk export lifts an entire folder out of the account in one download -
    # the forensic signal is who did it and how much, so audit before the
    # stream starts (byte totals are unknowable until the enumerator runs).
    audit "mailbox.export", @mailbox,
          account: @email_account.email, mailbox: @mailbox.name,
          messages: @mailbox.email_messages.count
    headers["Content-Disposition"] = "attachment; filename=\"#{export.filename}\""
    headers["Last-Modified"] = Time.current.httpdate # disable Rack::ETag buffering
    self.response_body = export.each
    response.content_type = "application/mbox"
  end

  # Files uploaded .eml messages into this folder - the web-UI mirror of
  # IMAP APPEND, with APPEND's gates: the size cap above, a ClamAV scan
  # when the scanner is on (infected uploads are refused outright, and a
  # scanner outage refuses the import under the same imap_append_fail_closed
  # knob APPEND honors - default on; opting out stores the message flagged
  # "unscanned", never quarantined), and the storage quota inside
  # deliver_raw. No authenticated_as: imported bytes are foreign mail being
  # filed, not mail this user is vouched to have written.
  def import
    files = Array(params[:eml]).reject(&:blank?)
    if files.none?
      return redirect_to email_account_mailbox_path(@email_account, @mailbox),
                         alert: "Choose one or more .eml files to import."
    end

    imported = 0
    failures = []
    files.each do |file|
      if (failure = import_one(file))
        failures << "#{file.original_filename}: #{failure}"
      else
        imported += 1
      end
    end

    flash[:notice] = "Imported #{imported} #{"message".pluralize(imported)}." if imported.positive?
    flash[:alert] = "Not imported - #{failures.to_sentence}" if failures.any?
    redirect_to email_account_mailbox_path(@email_account, @mailbox)
  end

  def new
    @mailbox = @email_account.mailboxes.new
  end

  def create
    @mailbox = @email_account.mailboxes.new(mailbox_params)
    if @mailbox.save
      redirect_to email_account_path(@email_account), notice: "Folder #{@mailbox.name} created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @mailbox.update(mailbox_params)
      redirect_to email_account_mailbox_path(@email_account, @mailbox), notice: "Folder updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @mailbox.destroy
      redirect_to email_account_path(@email_account), notice: "Folder #{@mailbox.name} deleted.", status: :see_other
    else
      redirect_to email_account_mailbox_path(@email_account, @mailbox),
                  alert: @mailbox.errors.full_messages.to_sentence, status: :see_other
    end
  end

  private

  # Stores one uploaded file, returning nil on success or the reason it was
  # refused. Mirrors the APPEND path in Store::ImapBackend#append.
  def import_one(file)
    raw = file.read
    return "larger than #{MAX_IMPORT_BYTES / 1_048_576} MB" if raw.bytesize > MAX_IMPORT_BYTES

    mail = Mail.read_from_string(raw) rescue nil
    return "not an RFC822 message" if raw.blank? || mail.nil? || mail.header.fields.none?

    scan_status = nil
    if MailOnRails::ClamavScanner.enabled?
      verdict = MailOnRails::ClamavScanner.scan(raw)
      if verdict.infected?
        # Generic refusal only: echoing the signature name would hand an
        # authenticated user a packing oracle against the scanner.
        Rails.logger.warn("[clamav] import refused for #{@email_account.email}: #{verdict.virus}")
        return "virus detected"
      end
      if verdict.unavailable? && MailOnRails::Settings[:imap_append_fail_closed]
        return "the virus scanner is unavailable - try again later"
      end

      scan_status = verdict.clean? ? "clean" : "unscanned"
    end

    MailOnRails::EmailMessage.deliver_raw(@mailbox, raw, internal_date: original_date(mail), scan_status: scan_status)
    nil
  rescue MailOnRails::EmailMessage::OverQuota => e
    e.message
  end

  # The message's own Date header, so an imported archive sorts where the
  # mail actually happened rather than piling up at the import moment.
  # Mail raises on malformed dates; those fall back to delivery time.
  def original_date(mail)
    mail.date&.to_time
  rescue StandardError
    nil
  end

  def set_email_account
    @email_account = accessible_email_accounts.find(params[:email_account_id])
  end

  def set_mailbox
    @mailbox = @email_account.mailboxes.find(params[:id])
  end

  def mailbox_params
    params.expect(mailbox: [ :name ])
  end
end
