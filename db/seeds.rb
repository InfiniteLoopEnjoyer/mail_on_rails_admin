# These seeds create accounts with a well-known weak password, so they are
# strictly development-only - the guard below no-ops everywhere else. (Do
# NOT abort in production: db:prepare runs db:seed after creating a fresh
# database, so a raise here would break the production boot.)
if Rails.env.development?

  # App login (Rails 8 authentication). This is the web UI login, separate
  # from the mail identities below - an admin can browse every mail
  # account; members see only the accounts granted to them.
  User.find_or_create_by!(email_address: "admin@mailonrails.test") do |user|
    user.password = "password123"
    user.role = "admin"
  end
  puts "App login: admin@mailonrails.test / password123 (admin)"

  # Development accounts for the mail_on_rails SMTP/IMAP servers.
  # IMAP/SMTP login: full email address + the password below.

  accounts = [
    { email: "alice@mailonrails.test", name: "Alice" },
    { email: "bob@mailonrails.test", name: "Bob" }
  ]

  accounts.each do |attrs|
    EmailAccount.find_or_create_by!(email: attrs[:email]) do |account|
      account.name = attrs[:name]
      account.password = "password123"
    end
  end

  alice = EmailAccount.find_by!(email: "alice@mailonrails.test")

  # A member login granted only Alice's account, for trying out RBAC.
  member = User.find_or_create_by!(email_address: "member@mailonrails.test") do |user|
    user.password = "password123"
  end
  member.email_accounts << alice unless member.email_accounts.include?(alice)
  puts "App login: member@mailonrails.test / password123 (member, granted #{alice.email})"

  if alice.inbox.email_messages.none?
    welcome = Mail.new do
      from "bob@mailonrails.test"
      to "alice@mailonrails.test"
      subject "Welcome to mail_on_rails"
      date Time.current
      body <<~BODY
        Hi Alice,

        This message was seeded into your INBOX. Try reading it over IMAP
        (localhost:1143) or sending a new one over SMTP (localhost:1025).

        - Bob
      BODY
    end
    EmailMessage.deliver_raw(alice.inbox, welcome.to_s)

    puts "Seeded welcome message into #{alice.email}'s INBOX"
  end

  puts "Accounts: #{EmailAccount.pluck(:email).join(", ")} (password: password123)"

end
