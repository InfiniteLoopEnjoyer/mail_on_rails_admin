require "test_helper"

# The account page's Senders section: anyone with access to the account
# manages its allow/deny rules, behind the same step-up as the other
# account-shaping writes, and never for an account outside their grants.
class SenderRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    @account = MailOnRails::EmailAccount.create!(email: "carol@example.com", password: "secret123")
  end

  def add(address, verdict = "deny", account: @account)
    post email_account_sender_rules_url(account), params: { sender_rule: { address: address, verdict: verdict } }
  end

  test "mutations require recent re-authentication" do
    rule = @account.sender_rules.create!(address: "spam@remote.test", verdict: "deny", source: "manual")
    delete session_path
    sign_in_as users(:one), step_up: false

    assert_no_difference "MailOnRails::SenderRule.count" do
      add "other@remote.test"
    end
    assert_redirected_to new_reauthentication_path

    assert_no_difference "MailOnRails::SenderRule.count" do
      delete email_account_sender_rule_url(@account, rule)
    end
    assert_redirected_to new_reauthentication_path
  end

  test "adds a deny rule, normalized" do
    assert_difference "@account.sender_rules.count", 1 do
      add " Spam@Remote.TEST "
    end
    assert_redirected_to email_account_url(@account)
    assert_equal "spam@remote.test will be filed into Junk.", flash[:notice]

    rule = @account.sender_rules.sole
    assert_equal [ "spam@remote.test", "deny", "manual" ], [ rule.address, rule.verdict, rule.source ]
    assert AuditEvent.exists?(action: "sender_rule.create"), "the write is audited"
  end

  test "re-adding an address flips its verdict instead of duplicating it" do
    add "spam@remote.test", "deny"
    assert_no_difference "MailOnRails::SenderRule.count" do
      add "spam@remote.test", "allow"
    end
    assert_equal "spam@remote.test will be delivered to INBOX.", flash[:notice]
    assert_equal "allow", @account.sender_rules.sole.verdict
  end

  test "accepts a domain wildcard" do
    add "@spam.example"
    assert_equal "@spam.example", @account.sender_rules.sole.address
  end

  test "rejects a malformed address and an unknown verdict" do
    assert_no_difference "MailOnRails::SenderRule.count" do
      add "not-an-address"
    end
    assert_redirected_to email_account_url(@account)
    assert_match(/Rule not added/, flash[:alert])

    assert_no_difference "MailOnRails::SenderRule.count" do
      add "spam@remote.test", "maybe"
    end
    assert_match(/allow or deny/, flash[:alert])
  end

  test "removes a rule" do
    rule = @account.sender_rules.create!(address: "spam@remote.test", verdict: "deny", source: "imap")
    assert_difference "MailOnRails::SenderRule.count", -1 do
      delete email_account_sender_rule_url(@account, rule)
    end
    assert_redirected_to email_account_url(@account)
    assert AuditEvent.exists?(action: "sender_rule.destroy")
  end

  test "cannot remove another account's rule" do
    other = MailOnRails::EmailAccount.create!(email: "dave@example.com", password: "secret123")
    rule = other.sender_rules.create!(address: "spam@remote.test", verdict: "deny", source: "manual")

    assert_no_difference "MailOnRails::SenderRule.count" do
      delete email_account_sender_rule_url(@account, rule)
    end
    assert_response :not_found
  end

  test "a member manages the rules of a granted account only" do
    member = users(:member)
    member.email_accounts << @account
    other = MailOnRails::EmailAccount.create!(email: "dave@example.com", password: "secret123")
    sign_in_as member

    assert_difference "@account.sender_rules.count", 1 do
      add "spam@remote.test"
    end
    assert_redirected_to email_account_url(@account)

    assert_no_difference "MailOnRails::SenderRule.count" do
      add "spam@remote.test", account: other
    end
    assert_response :not_found

    rule = @account.sender_rules.sole
    assert_difference "MailOnRails::SenderRule.count", -1 do
      delete email_account_sender_rule_url(@account, rule)
    end
  end

  test "the account page lists the rules with their verdicts" do
    @account.sender_rules.create!(address: "spam@remote.test", verdict: "deny", source: "imap")
    @account.sender_rules.create!(address: "friend@remote.test", verdict: "allow", source: "web")

    get email_account_url(@account)
    assert_response :success
    assert_select "section", /Senders/
    assert_select "li", /deny.*spam@remote\.test.*imap/m
    assert_select "li", /allow.*friend@remote\.test.*web/m
    assert_select "form[action=?]", email_account_sender_rules_path(@account)
  end
end
