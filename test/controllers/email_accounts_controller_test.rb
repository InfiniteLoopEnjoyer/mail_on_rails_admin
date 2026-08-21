require "test_helper"

class EmailAccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", name: "Carol", password: "secret123")
  end

  test "requires authentication" do
    sign_out
    get root_url
    assert_redirected_to new_session_url
  end

  test "mutations require recent re-authentication" do
    # A real logout clears the step-up window; sign back in as a resumed
    # cookie (no fresh proof) - rotating a mailbox password, rewriting the
    # account (honeypot flag, autoresponder), and deletion must all gate.
    delete session_path
    sign_in_as users(:one), step_up: false

    post generate_password_email_account_url(@account)
    assert_redirected_to new_reauthentication_path

    patch email_account_url(@account), params: { email_account: { honeypot: true } }
    assert_redirected_to new_reauthentication_path
    assert_not @account.reload.honeypot?

    assert_no_difference "MailOnRails::EmailAccount.count" do
      delete email_account_url(@account)
    end
    assert_redirected_to new_reauthentication_path
  end

  test "a member's index lists only granted accounts" do
    other = MailOnRails::EmailAccount.create!(email: "dave@example.com", password: "secret123")
    member = users(:member)
    member.email_accounts << @account
    sign_in_as member

    get root_url
    assert_response :success
    assert_select ".primary", text: @account.email
    assert_select ".primary", text: other.email, count: 0
  end

  test "a member cannot show an account they were not granted" do
    sign_in_as users(:member)

    get email_account_url(@account)
    assert_response :not_found
  end

  test "a member is denied the account-administration actions" do
    member = users(:member)
    member.email_accounts << @account
    sign_in_as member

    get new_email_account_url
    assert_redirected_to root_url

    get edit_email_account_url(@account)
    assert_redirected_to root_url

    delete email_account_url(@account)
    assert_redirected_to root_url
    assert MailOnRails::EmailAccount.exists?(@account.id)

    post generate_password_email_account_url(@account)
    assert_redirected_to root_url
  end

  test "index lists accounts" do
    get root_url
    assert_response :success
    assert_select ".primary", text: @account.email
    assert_select "turbo-cable-stream-source", 1
  end

  test "index sorts regular accounts by domain then email and splits postmaster, fbl, dmarc and tls-rpt accounts into their own lists" do
    MailOnRails::EmailAccount.create!(email: "zed@aardvark.test", name: "Zed", password: "secret123")
    MailOnRails::EmailAccount.create!(email: "amy@zebra.test", name: "Amy", password: "secret123")
    domain = MailOnRails::Domain.create!(name: "example.com")

    get root_url
    assert_response :success
    assert_select "ul", 5
    emails = css_select("ul:first-of-type .primary").map(&:text)
    assert_equal [ "zed@aardvark.test", "carol@example.com", "amy@zebra.test" ], emails
    assert_equal [ domain.postmaster_address ], css_select("ul:nth-of-type(2) .primary").map(&:text)
    # bounce@ and unsubscribe@ sit with the complaint accounts (the
    # suppression-ingestion family).
    assert_equal [ domain.bounce_address, domain.fbl_address, domain.unsubscribe_address ],
                 css_select("ul:nth-of-type(3) .primary").map(&:text)
    assert_equal [ domain.dmarc_address ], css_select("ul:nth-of-type(4) .primary").map(&:text)
    assert_equal [ domain.tls_rpt_address ], css_select("ul:last-of-type .primary").map(&:text)
  end

  test "account page subscribes to live updates" do
    get email_account_url(@account)
    assert_response :success
    assert_select "turbo-cable-stream-source", 1
  end

  test "index shows an unread count when an account has unseen messages" do
    raw = "From: a@example.com\r\nTo: #{@account.email}\r\nSubject: hi\r\n\r\nbody\r\n"
    MailOnRails::EmailMessage.deliver_raw(@account.inbox, raw)
    MailOnRails::EmailMessage.deliver_raw(@account.inbox, raw, flags: [ "\\Seen" ])

    get root_url
    assert_response :success
    assert_select "span", text: "1 unread"
  end

  test "account page shows unseen/total per mailbox, or just the total when all seen" do
    raw = "From: a@example.com\r\nTo: #{@account.email}\r\nSubject: hi\r\n\r\nbody\r\n"
    MailOnRails::EmailMessage.deliver_raw(@account.inbox, raw)
    MailOnRails::EmailMessage.deliver_raw(@account.inbox, raw, flags: [ "\\Seen" ])
    sent = @account.mailboxes.find_by!(name: "Sent")
    MailOnRails::EmailMessage.deliver_raw(sent, raw, flags: [ "\\Seen" ])

    get email_account_url(@account)

    assert_response :success
    assert_select "span", text: "1 new / 2"
    assert_select "li" do |items|
      sent_row = items.find { |li| li.text.include?("Sent") }
      assert_includes sent_row.text, "1"
      assert_not_includes sent_row.text, "new /"
    end
  end

  test "creates an account with the default folders and a generated password shown once" do
    assert_difference "MailOnRails::EmailAccount.count", 1 do
      post email_accounts_url, params: { email_account: { email: "dave@example.com", name: "Dave" } }
    end
    account = MailOnRails::EmailAccount.find_by(email: "dave@example.com")
    assert_redirected_to email_account_url(account)
    assert_equal MailOnRails::EmailAccount::DEFAULT_MAILBOXES.sort, account.mailboxes.pluck(:name).sort

    follow_redirect!
    plaintext = extract_generated_password
    assert account.authenticate(plaintext)

    get email_account_url(account)
    assert_not_includes response.body, plaintext
  end

  test "rejects a duplicate email" do
    assert_no_difference "MailOnRails::EmailAccount.count" do
      post email_accounts_url, params: { email_account: { email: @account.email } }
    end
    assert_response :unprocessable_entity
  end

  test "an account can be toggled into a canary" do
    assert_not @account.honeypot?
    patch email_account_url(@account), params: { email_account: { honeypot: "1" } }
    assert @account.reload.honeypot?
  end

  test "an account can be flagged as a mailing-list sender" do
    assert_not @account.mailing_list?
    patch email_account_url(@account), params: { email_account: { mailing_list: "1" } }
    assert @account.reload.mailing_list?

    get root_url
    assert_select "span", text: "mailing list"
  end

  test "update ignores password params" do
    patch email_account_url(@account), params: { email_account: { email: "carol@example.org", name: "Carol", password: "sneaky" } }
    assert_redirected_to email_account_url(@account)
    @account.reload
    assert_equal "carol@example.org", @account.email
    assert @account.authenticate("secret123")
    assert_not @account.authenticate("sneaky")
  end

  test "generate_password rotates the digest and shows the password once" do
    post generate_password_email_account_url(@account), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_select "turbo-stream[action=replace][target=password-generator]"

    plaintext = extract_generated_password
    @account.reload
    assert @account.authenticate(plaintext)
    assert_not @account.authenticate("secret123")

    get edit_email_account_url(@account)
    assert_not_includes response.body, plaintext
  end

  test "destroys an account together with its folders" do
    assert_difference "MailOnRails::EmailAccount.count", -1 do
      assert_difference "MailOnRails::Mailbox.count", -MailOnRails::EmailAccount::DEFAULT_MAILBOXES.size do
        delete email_account_url(@account)
      end
    end
    assert_redirected_to root_url
  end
end
