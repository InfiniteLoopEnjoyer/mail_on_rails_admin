require "test_helper"
require "tmpdir"

class EmailAliasTest < ActiveSupport::TestCase
  setup do
    @account = MailOnRails::EmailAccount.create!(email: "owner@example.test", password: "secret-pass-123")
  end

  test "normalizes the address like EmailAccount" do
    email_alias = @account.email_aliases.create!(email: " Sales@Example.test ")
    assert_equal "sales@example.test", email_alias.email
  end

  test "requires an address, unique across aliases case-insensitively" do
    assert_not @account.email_aliases.new(email: "").valid?

    @account.email_aliases.create!(email: "info@example.test")
    other = MailOnRails::EmailAccount.create!(email: "other@example.test", password: "secret-pass-123")
    assert_not other.email_aliases.new(email: "INFO@example.test").valid?
  end

  test "an alias cannot take an existing account address" do
    email_alias = @account.email_aliases.new(email: "owner@example.test")
    assert_not email_alias.valid?
    assert_includes email_alias.errors[:email], "is already an account address"
  end

  test "an account cannot take an existing alias address" do
    @account.email_aliases.create!(email: "info@example.test")
    account = MailOnRails::EmailAccount.new(email: "info@example.test", password: "secret-pass-123")
    assert_not account.valid?
    assert_includes account.errors[:email], "is already in use as an alias"
  end

  test "destroying the account destroys its aliases" do
    @account.email_aliases.create!(email: "info@example.test")
    assert_difference "MailOnRails::EmailAlias.count", -1 do
      @account.destroy!
    end
  end

  test "alias create, rename, and destroy are visible to the SMTP recipient check" do
    require "mail_on_rails/store/smtp_backend"
    store = MailOnRails::Store::SmtpBackend.new

    email_alias = @account.email_aliases.create!(email: "info@example.test")
    assert_equal %w[info@example.test], store.local_rcpts([ "info@example.test" ])[:local]

    email_alias.update!(email: "contact@example.test")
    assert_equal %w[contact@example.test], store.local_rcpts([ "contact@example.test" ])[:local]
    assert_empty store.local_rcpts([ "info@example.test" ])[:local]

    email_alias.destroy!
    assert_empty store.local_rcpts([ "contact@example.test" ])[:local]
  end
  # -- pattern aliases ---------------------------------------------------------

  def hosted!(name = "example.test")
    MailOnRails::Domain.create!(name: name)
  end

  def pattern!(email, account: @account)
    account.email_aliases.create!(email: email, pattern: true)
  end

  test "a pattern keeps its local part's case but downcases the domain" do
    hosted!
    row = pattern!(" Shop-\\D+@Example.TEST ")
    assert_equal "Shop-\\D+@example.test", row.email
    assert row.pattern?
  end

  test "a pattern must compile, fit the size cap, and sit on a hosted domain" do
    hosted!
    bad = @account.email_aliases.new(email: "shop-(@example.test", pattern: true)
    assert_not bad.valid?
    assert_match(/not a valid pattern/, bad.errors[:email].join)

    long = @account.email_aliases.new(email: "#{"a" * (MailOnRails::EmailAlias::MAX_PATTERN_LENGTH + 1)}@example.test", pattern: true)
    assert_not long.valid?
    assert_match(/too long/, long.errors[:email].join)

    foreign = @account.email_aliases.new(email: "shop-.*@elsewhere.test", pattern: true)
    assert_not foreign.valid?
    assert_includes foreign.errors[:email], "must be on a hosted domain"

    assert_not @account.email_aliases.new(email: "shop-.*", pattern: true).valid?
    assert_not @account.email_aliases.new(email: "@example.test", pattern: true).valid?
  end

  test "a pattern matches the whole local part, case-insensitively, on its own domain only" do
    hosted!
    pattern!("shop-.*@example.test")

    assert_equal @account, MailOnRails::EmailAlias.account_for_pattern("shop-amazon@example.test")
    assert_equal @account, MailOnRails::EmailAlias.account_for_pattern("SHOP-Ebay@example.test")
    assert_nil MailOnRails::EmailAlias.account_for_pattern("myshop-x@example.test"), "anchored at the start"
    assert_nil MailOnRails::EmailAlias.account_for_pattern("shop-x@other.test"), "other domain"
    assert_nil MailOnRails::EmailAlias.account_for_pattern("shop-x")
    assert_nil MailOnRails::EmailAlias.account_for_pattern("")
  end

  test "the oldest matching pattern wins" do
    hosted!
    other = MailOnRails::EmailAccount.create!(email: "other@example.test", password: "secret-pass-123")
    pattern!("shop-.*@example.test", account: other)
    pattern!(".*@example.test")

    assert_equal other, MailOnRails::EmailAlias.account_for_pattern("shop-x@example.test")
    assert_equal @account, MailOnRails::EmailAlias.account_for_pattern("anything@example.test")
  end

  test "exact accounts and aliases beat a catch-all pattern" do
    hosted!
    other = MailOnRails::EmailAccount.create!(email: "other@example.test", password: "secret-pass-123")
    other.email_aliases.create!(email: "exact@example.test")
    pattern!(".*@example.test")

    assert_equal other, MailOnRails::EmailAccount.for_address("other@example.test")
    assert_equal other, MailOnRails::EmailAccount.for_address("exact@example.test")
    assert_equal @account, MailOnRails::EmailAccount.for_address("random@example.test")
    assert_nil MailOnRails::EmailAccount.for_address("random@elsewhere.test")
  end

  test "the exact scope never reads a pattern row as a literal address" do
    hosted!
    row = pattern!("shop-.*@example.test")

    assert_empty MailOnRails::EmailAlias.exact.where(email: row.email)
    # A pattern is receive-only: it is not a sender identity.
    require "mail_on_rails/store/smtp_backend"
    assert_equal [ @account.email ], MailOnRails::Store::SmtpBackend.new.sender_addresses(@account.email)
  end

  test "a catch-all pattern does not stop the domain's system aliases from being created" do
    pattern_account = @account
    domain = MailOnRails::Domain.create!(name: "fresh.test")
    pattern_account.email_aliases.create!(email: ".*@fresh.test", pattern: true)

    # Re-running the bootstrap must still see abuse@/jmrp@ as free.
    MailOnRails::EmailAlias.exact.where("email LIKE ?", "%@fresh.test").delete_all
    domain.send(:ensure_postmaster_account!)
    domain.send(:ensure_fbl_account!)
    assert MailOnRails::EmailAlias.exact.exists?(email: "abuse@fresh.test")
    assert MailOnRails::EmailAlias.exact.exists?(email: "jmrp@fresh.test")
  end

  test "a match that blows its time budget counts as no match" do
    hosted!
    row = pattern!("shop-.*@example.test")
    slow = Object.new
    def slow.match?(_) = raise(Regexp::TimeoutError, "regexp match timeout")
    row.instance_variable_set(:@regexp, slow)

    assert_not row.match?("shop-x")
  end

  test "a hostile local part is matched within the per-pattern budget" do
    hosted!
    row = pattern!("shop-.*@example.test")
    assert_in_delta MailOnRails::EmailAlias::MATCH_TIMEOUT, row.send(:regexp).timeout, 0.001
    assert row.match?("shop-#{"a" * 10_000}")
  end
end
