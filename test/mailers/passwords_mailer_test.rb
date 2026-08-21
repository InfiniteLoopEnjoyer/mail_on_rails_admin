require "test_helper"

class PasswordsMailerTest < ActionMailer::TestCase
  test "reset addresses the user with a working reset link in both parts" do
    user = users(:one)

    mail = PasswordsMailer.reset(user)

    assert_equal [ "one@example.com" ], mail.to
    assert_equal "Reset your password", mail.subject

    # Each view mints its own token, so verify rather than compare: the
    # link's token must resolve back to this user.
    link = %r{http://example\.com/passwords/([^/"\s]+)/edit}
    [ mail.text_part, mail.html_part ].each do |part|
      token = part.decoded[link, 1]
      assert token, "reset link missing from #{part.mime_type} part"
      assert_equal user, User.find_by_password_reset_token(CGI.unescape(token))
    end
  end
end
