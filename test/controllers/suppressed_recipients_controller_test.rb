require "test_helper"

# The suppression list page: recipients the outbound drainer skips
# because of feedback-loop complaints, and the button that lifts one.
class SuppressedRecipientsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end

  test "index lists suppressed recipients" do
    MailOnRails::SuppressedRecipient.create!(email: "complainer@remote.test", feedback_type: "abuse",
                                             reporter: "JMRP/2.0", complaints_count: 3,
                                             last_complaint_at: 2.hours.ago)

    get suppressed_recipients_url
    assert_response :success
    assert_match "complainer@remote.test", response.body
    assert_match "abuse", response.body
    assert_match "JMRP/2.0", response.body
  end

  test "index shows an empty state" do
    get suppressed_recipients_url
    assert_response :success
    assert_match "No suppressed recipients", response.body
  end

  test "requires an admin session" do
    suppressed = MailOnRails::SuppressedRecipient.create!(email: "complainer@remote.test")
    sign_in_as users(:member)

    get suppressed_recipients_url
    assert_redirected_to root_url

    delete suppressed_recipient_url(suppressed)
    assert_redirected_to root_url
    assert MailOnRails::SuppressedRecipient.exists?(suppressed.id)
  end

  test "lifting a suppression removes it and audits" do
    suppressed = MailOnRails::SuppressedRecipient.create!(email: "complainer@remote.test",
                                                          complaints_count: 2)

    assert_difference -> { MailOnRails::SuppressedRecipient.count }, -1 do
      delete suppressed_recipient_url(suppressed)
    end
    assert_redirected_to suppressed_recipients_url
    follow_redirect!
    assert_match "Lifted the suppression", response.body

    event = AuditEvent.newest_first.first
    assert_equal "suppressed_recipient.destroy", event.action
    assert_equal "complainer@remote.test", event.details["email"]
    assert_equal 2, event.details["complaints_count"]
  end
end
