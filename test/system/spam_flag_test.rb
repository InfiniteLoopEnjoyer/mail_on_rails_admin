require "application_system_test_case"

# The Junk round-trip from the message page. Both buttons are plain
# button_to forms (no confirm dialog), and each move mints a new message
# row, so the assertions re-query the mailboxes rather than hold on to ids.
class SpamFlagTest < ApplicationSystemTestCase
  RAW = "From: sender@remote.test\r\nTo: carol@example.com\r\n" \
        "Subject: You may already have won\r\nMessage-ID: <m1@remote.test>\r\n\r\n" \
        "Click here to claim.\r\n"

  setup do
    @user = users(:one)
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
    @message = MailOnRails::EmailMessage.deliver_raw(@account.inbox, RAW)
    @junk = @account.find_mailbox("Junk")
    sign_in_as(@user)
  end

  test "marking a message as spam moves it to Junk" do
    visit email_account_mailbox_email_message_url(@account, @account.inbox, @message)

    click_on "Mark as spam"

    # The redirect lands back on the folder the message left, now empty.
    assert_text "Moved to Junk."
    assert_selector "h1", text: "INBOX"
    assert_text "This folder is empty."
    assert_equal 1, @junk.email_messages.count
    assert_equal 0, @account.inbox.email_messages.count
  end

  test "Not spam moves a junked message back to INBOX" do
    junked = @message.move_to!(@junk)
    visit email_account_mailbox_email_message_url(@account, @junk, junked)

    click_on "Not spam"

    assert_text "Moved to INBOX."
    assert_selector "h1", text: "Junk"
    assert_text "This folder is empty."
    assert_equal 1, @account.inbox.email_messages.count
    assert_equal 0, @junk.email_messages.count
  end
end
