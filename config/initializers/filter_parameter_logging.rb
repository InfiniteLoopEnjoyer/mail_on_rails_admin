# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # TOTP codes (:code), WebAuthn assertions/attestations (:credential), and
  # the Authorization request header - none matched by the entries above.
  :code, :credential, :authorization,
  # Mail content. The composer's autosave posts draft[to|cc|subject|
  # body_html] every few seconds and search carries its terms in ?q= (both
  # the Parameters line and the "Started GET" path are filtered); the send
  # form's composed_email[...] is already covered by :email above. The
  # field names themselves are listed too, exact-match for the short ones,
  # so a future form that posts them under another root stays out of the
  # log as well.
  :draft, /\Aq\z/, :subject, :body, :in_reply_to, :references, /\A(to|cc|bcc)\z/
]
