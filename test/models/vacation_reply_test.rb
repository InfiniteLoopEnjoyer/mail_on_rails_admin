require "test_helper"

# The claim table behind the vacation responder's once-per-window rule:
# normalized keys, atomic claims, and enforced retention.
class VacationReplyTest < ActiveSupport::TestCase
  setup do
    @account = MailOnRails::EmailAccount.create!(email: "away@example.com", password: "secret123")
  end

  test "normalize downcases and strips the +tag subaddress" do
    assert_equal "friend@remote.test", MailOnRails::VacationReply.normalize("Friend@Remote.Test")
    assert_equal "friend@remote.test", MailOnRails::VacationReply.normalize("friend+tag@remote.test")
    assert_equal "friend@remote.test", MailOnRails::VacationReply.normalize(" FRIEND+a+b@remote.test ")
    assert_equal "no-at-sign", MailOnRails::VacationReply.normalize("No-At-Sign")
  end

  test "claim is granted once per window and again after it lapses" do
    assert MailOnRails::VacationReply.claim(@account, "friend@remote.test", window: 7.days)
    assert_not MailOnRails::VacationReply.claim(@account, "friend@remote.test", window: 7.days)

    travel(7.days + 1.minute) do
      assert MailOnRails::VacationReply.claim(@account, "friend@remote.test", window: 7.days)
    end
    assert_equal 1, MailOnRails::VacationReply.count, "re-claims update the row instead of adding one"
  end

  test "replied_recently? reflects the window without writing" do
    assert_not MailOnRails::VacationReply.replied_recently?(@account, "friend@remote.test", window: 7.days)
    MailOnRails::VacationReply.claim(@account, "friend@remote.test", window: 7.days)

    assert MailOnRails::VacationReply.replied_recently?(@account, "friend@remote.test", window: 7.days)
    travel(7.days + 1.minute) do
      assert_not MailOnRails::VacationReply.replied_recently?(@account, "friend@remote.test", window: 7.days)
    end
    assert_equal 1, MailOnRails::VacationReply.count
  end

  test "prune! removes only rows past the reply window" do
    MailOnRails::VacationReply.create!(email_account: @account, sender: "old@remote.test",
                          last_sent_at: MailOnRails::VacationResponder::REPLY_WINDOW.ago - 1.hour)
    MailOnRails::VacationReply.create!(email_account: @account, sender: "fresh@remote.test",
                          last_sent_at: 1.hour.ago)

    assert_equal 1, MailOnRails::VacationReply.prune!
    assert_equal "fresh@remote.test", MailOnRails::VacationReply.sole.sender
  end
end
