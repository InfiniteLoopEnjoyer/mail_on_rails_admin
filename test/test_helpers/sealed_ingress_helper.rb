require "mail_on_rails/ingress_seal"

# The SMTP edge seals every message it hands to Action Mailbox, and the
# mailroom drops unsealed mail by default - so mailbox tests feed sealed
# sources by default too. Pass seal: false to exercise the non-edge path
# (an unsealed or hand-tampered source).
module SealedIngressHelper
  def receive_inbound_email_from_source(source, seal: true, **kwargs)
    source = MailOnRails::IngressSeal.seal(source) + source if seal
    super(source, **kwargs)
  end
end
