class ApplicationMailbox < ActionMailbox::Base
  routing all: :"mail_on_rails/mailroom"
end
