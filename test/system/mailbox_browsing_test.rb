require "application_system_test_case"

# Reading mail through the real UI: accounts list -> folder list -> message
# list -> message page. All of it is plain server-rendered markup, so a
# renamed label or broken route breaks here first.
class MailboxBrowsingTest < ApplicationSystemTestCase
  RAW = "From: sender@remote.test\r\nTo: carol@example.com\r\n" \
        "Subject: Quarterly numbers\r\nMessage-ID: <m1@remote.test>\r\n\r\n" \
        "The figures are attached below.\r\n"

  setup do
    @user = users(:one)
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
    @message = MailOnRails::EmailMessage.deliver_raw(@account.inbox, RAW)
    sign_in_as(@user)
  end

  test "a delivered message is listed in INBOX and can be opened and read" do
    visit root_url
    assert_selector "h1", text: "Email Accounts"
    click_on @account.email

    click_on "INBOX"
    assert_selector "h1", text: "INBOX"

    click_on "Quarterly numbers"
    assert_selector "h1", text: "Quarterly numbers"
    assert_text "sender@remote.test"
    # A text-only message renders in the plain <pre> body, not the iframe.
    assert_text "The figures are attached below."
  end

  test "the folder list navigates between INBOX, Sent and Trash" do
    visit email_account_url(@account)
    assert_selector "h1", text: @account.email

    click_on "INBOX"
    assert_selector "h1", text: "INBOX"
    assert_text "Quarterly numbers"

    # Breadcrumb back to the account, then into the empty folders.
    click_on @account.email
    click_on "Sent"
    assert_selector "h1", text: "Sent"
    assert_text "This folder is empty."

    click_on @account.email
    click_on "Trash"
    assert_selector "h1", text: "Trash"
    assert_text "This folder is empty."
  end
end
