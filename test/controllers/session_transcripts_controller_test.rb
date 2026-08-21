require "test_helper"

class SessionTranscriptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end

  def create_transcript(**extra)
    MailOnRails::SessionTranscript.create!(
      { protocol: "smtp", ip: "203.0.113.9", port: 25, close_reason: "timeout",
        connected_at: 2.minutes.ago, closed_at: Time.current,
        transcript: "<= EHLO client.test\n=> 250 OK" }.merge(extra)
    )
  end

  test "requires a signed-in user" do
    transcript = create_transcript
    reset!
    get session_transcript_path(transcript)
    assert_redirected_to new_session_path
  end

  test "members cannot view transcripts" do
    transcript = create_transcript
    sign_in_as users(:member)
    get session_transcript_path(transcript)
    assert_redirected_to root_path
  end

  test "shows the captured dialogue and its metadata" do
    transcript = create_transcript(username: "carol@example.com", helo: "client.test")
    get session_transcript_path(transcript)
    assert_response :success
    assert_select "h1", /Session transcript/
    assert_match "203.0.113.9", response.body
    assert_match "EHLO client.test", response.body
    assert_match "timeout", response.body
    assert_match "carol@example.com", response.body
  end

  test "a pruned transcript redirects back with an explanation" do
    get session_transcript_path(id: 999_999)
    assert_redirected_to smtp_path
    assert_match(/no longer retained/, flash[:alert])
  end

  test "history rows on the smtp page link to their transcript" do
    transcript = create_transcript
    MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "203.0.113.9", port: 25,
                                          closed_at: Time.current, transcript_id: transcript.id)
    MailOnRails::ClosedConnection.create!(protocol: "smtp", ip: "203.0.113.10", port: 25,
                                          closed_at: Time.current)
    get smtp_path
    assert_response :success
    assert_select "a[href=?]", session_transcript_path(transcript), text: "Transcript", count: 1
  end
end
