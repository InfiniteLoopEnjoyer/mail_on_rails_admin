require "test_helper"
require_relative "../test_helpers/clamav_stub_helper"

class MailboxesControllerTest < ActionDispatch::IntegrationTest
  include ClamavStubHelper

  setup do
    sign_in_as users(:one)
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
    @inbox = @account.inbox
    @sent = @account.find_mailbox("Sent")
  end

  test "a member reaches folders of a granted account but 404s elsewhere" do
    member = users(:member)
    member.email_accounts << @account
    sign_in_as member

    get email_account_mailbox_url(@account, @inbox)
    assert_response :success

    other = MailOnRails::EmailAccount.create!(email: "dave@example.com", password: "secret123")
    get email_account_mailbox_url(other, other.inbox)
    assert_response :not_found
  end

  test "folder page subscribes to live updates" do
    get email_account_mailbox_url(@account, @inbox)
    assert_response :success
    assert_select "turbo-cable-stream-source", 1
  end

  # -- mbox export -------------------------------------------------------------

  test "export streams the folder as an mbox download" do
    MailOnRails::EmailMessage.deliver_raw(@inbox, "From: a@remote.test\r\nSubject: one\r\n\r\nfirst\r\n")
    MailOnRails::EmailMessage.deliver_raw(@inbox, "From: b@remote.test\r\nSubject: two\r\n\r\nsecond\r\n")

    get export_email_account_mailbox_url(@account, @inbox)

    assert_response :success
    assert_equal "application/mbox", response.media_type
    assert_match(/attachment; filename="INBOX\.mbox"/, response.headers["Content-Disposition"])
    assert_equal 2, response.body.scan(/^From (?:a|b)@remote\.test /).size
    assert_includes response.body, "Subject: one\n"
    assert_includes response.body, "second\n"
  end

  test "export writes an audit row naming the account, mailbox and message count" do
    MailOnRails::EmailMessage.deliver_raw(@inbox, "From: a@remote.test\r\nSubject: one\r\n\r\nfirst\r\n")

    assert_difference -> { AuditEvent.count }, 1 do
      get export_email_account_mailbox_url(@account, @inbox)
    end
    event = AuditEvent.last
    assert_equal "mailbox.export", event.action
    assert_equal @account.email, event.details["account"]
    assert_equal "INBOX", event.details["mailbox"]
    assert_equal 1, event.details["messages"]
  end

  test "export requires a fresh step-up - a resumed cookie is challenged" do
    # A real logout clears the step-up window; sign back in as a resumed
    # cookie (no fresh proof) and the bulk egress must be gated.
    delete session_path
    sign_in_as users(:one), step_up: false

    get export_email_account_mailbox_url(@account, @inbox)
    assert_redirected_to new_reauthentication_path
  end

  # -- .eml import -------------------------------------------------------------

  def import_eml(*files, mailbox: @inbox)
    post import_email_account_mailbox_url(@account, mailbox), params: { eml: files }
  end

  def eml_upload(raw, filename: "message.eml")
    Rack::Test::UploadedFile.new(StringIO.new(raw), "message/rfc822", original_filename: filename)
  end

  test "import files an .eml into the folder at its original date" do
    import_eml fixture_file_upload("sample.eml", "message/rfc822")

    assert_redirected_to email_account_mailbox_url(@account, @inbox)
    assert_equal "Imported 1 message.", flash[:notice]

    message = @inbox.email_messages.sole
    assert_equal "imported hello", message.subject
    assert_nil message.scan_status
    assert_nil message.authenticated_as, "imported mail must not carry the importer's vouching"
    assert_equal Time.utc(2025, 3, 10, 12), message.internal_date
  end

  test "import stamps the scanner's verdict like IMAP APPEND" do
    clean = MailOnRails::ClamavScanner::Result.new(:clean, nil)
    with_scanner(enabled: true, scan: clean) { import_eml eml_upload("Subject: ok\r\n\r\nhi\r\n") }
    assert_equal "clean", @inbox.email_messages.sole.scan_status
  end

  test "import refuses uploads while the scanner is down, mirroring fail-closed APPEND" do
    MailOnRails::Settings.overrides = { imap_append_fail_closed: true }
    down = MailOnRails::ClamavScanner::Result.new(:unavailable, nil)
    with_scanner(enabled: true, scan: down) do
      import_eml eml_upload("Subject: two\r\n\r\nhi\r\n", filename: "two.eml")
    end

    assert_match(/two\.eml: the virus scanner is unavailable/, flash[:alert])
    assert_empty @inbox.email_messages
  ensure
    MailOnRails::Settings.overrides = {}
  end

  test "opting out of fail-closed stores a scanner-outage import flagged unscanned" do
    MailOnRails::Settings.overrides = { imap_append_fail_closed: false }
    down = MailOnRails::ClamavScanner::Result.new(:unavailable, nil)
    with_scanner(enabled: true, scan: down) { import_eml eml_upload("Subject: two\r\n\r\nhi\r\n") }
    assert_equal "unscanned", @inbox.email_messages.sole.scan_status
  ensure
    MailOnRails::Settings.overrides = {}
  end

  test "import refuses an infected upload without echoing the signature name" do
    infected = MailOnRails::ClamavScanner::Result.new(:infected, "Eicar-Test-Signature")
    with_scanner(enabled: true, scan: infected) do
      import_eml eml_upload("Subject: bad\r\n\r\npayload\r\n", filename: "bad.eml")
    end

    assert_redirected_to email_account_mailbox_url(@account, @inbox)
    assert_equal "Not imported - bad.eml: virus detected", flash[:alert]
    assert_empty @inbox.email_messages
  end

  test "import refuses a file that is not a message" do
    import_eml eml_upload("", filename: "empty.eml"), eml_upload("Subject: ok\r\n\r\nhi\r\n")

    assert_equal "Imported 1 message.", flash[:notice]
    assert_match(/empty\.eml: not an RFC822 message/, flash[:alert])
    assert_equal 1, @inbox.email_messages.count
  end

  test "import refuses a file over the APPENDLIMIT-sized cap" do
    huge = eml_upload("Subject: big\r\n\r\n#{"x" * 64}\r\n", filename: "big.eml")
    original = MailboxesController::MAX_IMPORT_BYTES
    MailboxesController.send(:remove_const, :MAX_IMPORT_BYTES)
    MailboxesController.const_set(:MAX_IMPORT_BYTES, 32)
    begin
      import_eml huge
    ensure
      MailboxesController.send(:remove_const, :MAX_IMPORT_BYTES)
      MailboxesController.const_set(:MAX_IMPORT_BYTES, original)
    end

    assert_match(/big\.eml: larger than/, flash[:alert])
    assert_empty @inbox.email_messages
  end

  test "import respects the storage quota" do
    @account.update!(quota_bytes: 1)

    import_eml eml_upload("Subject: over\r\n\r\nbody\r\n", filename: "over.eml")

    assert_match(/over\.eml: .*over its storage quota/, flash[:alert])
    assert_empty @inbox.email_messages
  end

  test "import with no file chosen explains itself" do
    post import_email_account_mailbox_url(@account, @inbox)

    assert_redirected_to email_account_mailbox_url(@account, @inbox)
    assert_equal "Choose one or more .eml files to import.", flash[:alert]
  end

  # -- pagination --------------------------------------------------------------

  def deliver_messages(count)
    count.times do |i|
      MailOnRails::EmailMessage.deliver_raw(@inbox, "Subject: msg #{i}\r\n\r\nbody #{i}\r\n")
    end
  end

  test "a folder within one page shows no pagination nav" do
    deliver_messages(3)

    get email_account_mailbox_url(@account, @inbox)

    assert_select "li a span.primary", 3
    assert_select "nav[aria-label='Pagination']", 0
  end

  test "a large folder renders one page at a time, newest first" do
    deliver_messages(MailboxesController::MESSAGES_PER_PAGE + 2)

    get email_account_mailbox_url(@account, @inbox)

    assert_select "li a span.primary", MailboxesController::MESSAGES_PER_PAGE
    assert_select "nav[aria-label='Pagination']" do
      assert_select "a", text: "Older \u2192"
      assert_select "a", text: "\u2190 Newer", count: 0
    end
    assert_match "msg #{MailboxesController::MESSAGES_PER_PAGE + 1}", response.body
    assert_no_match "msg 0", response.body
  end

  test "the last page holds the remainder and links back to newer" do
    deliver_messages(MailboxesController::MESSAGES_PER_PAGE + 2)

    get email_account_mailbox_url(@account, @inbox, page: 2)

    assert_select "li a span.primary", 2
    assert_select "nav[aria-label='Pagination']" do
      assert_select "a", text: "\u2190 Newer"
      assert_select "a", text: "Older \u2192", count: 0
    end
    assert_match "msg 0", response.body
  end

  test "an out-of-range page clamps instead of erroring" do
    deliver_messages(1)

    get email_account_mailbox_url(@account, @inbox, page: 99)
    assert_response :success
    assert_match "msg 0", response.body

    get email_account_mailbox_url(@account, @inbox, page: -1)
    assert_response :success
  end

  # -- threading ---------------------------------------------------------------

  test "a conversation collapses into one row with a count" do
    MailOnRails::EmailMessage.deliver_raw(@inbox, "Message-Id: <root@x>\r\nSubject: hi\r\n\r\na\r\n")
    MailOnRails::EmailMessage.deliver_raw(@inbox, "Message-Id: <r1@x>\r\nReferences: <root@x>\r\nSubject: Re: hi\r\n\r\nb\r\n")
    MailOnRails::EmailMessage.deliver_raw(@inbox, "Message-Id: <o@x>\r\nSubject: lunch\r\n\r\nc\r\n")

    get email_account_mailbox_url(@account, @inbox)

    assert_select "li a span.primary", 2
    assert_select "li a span[title='2 messages in this conversation']", text: "2"
  end

  test "a thread with any unread message shows the unread dot on its row" do
    root = MailOnRails::EmailMessage.deliver_raw(@inbox, "Message-Id: <root@x>\r\nSubject: hi\r\n\r\na\r\n")
    reply = MailOnRails::EmailMessage.deliver_raw(@inbox, "Message-Id: <r1@x>\r\nReferences: <root@x>\r\nSubject: Re: hi\r\n\r\nb\r\n")
    root.mark_seen!
    reply.mark_seen!
    MailOnRails::EmailMessage.deliver_raw(@inbox, "Message-Id: <r2@x>\r\nReferences: <root@x>\r\nSubject: Re: hi\r\n\r\nc\r\n")

    get email_account_mailbox_url(@account, @inbox)

    assert_select "li a span.primary span.bg-accent", 1
  end

  test "creates a folder" do
    assert_difference "@account.mailboxes.count", 1 do
      post email_account_mailboxes_url(@account), params: { mailbox: { name: "Archive" } }
    end
    assert_redirected_to email_account_url(@account)
  end

  test "rejects a duplicate folder name" do
    assert_no_difference "MailOnRails::Mailbox.count" do
      post email_account_mailboxes_url(@account), params: { mailbox: { name: "Sent" } }
    end
    assert_response :unprocessable_entity
  end

  test "renames a folder" do
    patch email_account_mailbox_url(@account, @sent), params: { mailbox: { name: "Outbox" } }
    assert_redirected_to email_account_mailbox_url(@account, @sent)
    assert_equal "Outbox", @sent.reload.name
  end

  test "refuses to rename INBOX" do
    patch email_account_mailbox_url(@account, @inbox), params: { mailbox: { name: "Inbox2" } }
    assert_response :unprocessable_entity
    assert_equal "INBOX", @inbox.reload.name
  end

  test "destroys a folder" do
    assert_difference "MailOnRails::Mailbox.count", -1 do
      delete email_account_mailbox_url(@account, @sent)
    end
    assert_redirected_to email_account_url(@account)
  end

  test "refuses to destroy INBOX" do
    assert_no_difference "MailOnRails::Mailbox.count" do
      delete email_account_mailbox_url(@account, @inbox)
    end
    assert_redirected_to email_account_mailbox_url(@account, @inbox)
    assert flash[:alert].present?
  end
end
