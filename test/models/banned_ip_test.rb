require "test_helper"

class BannedIpTest < ActiveSupport::TestCase
  test "normalizes host entries to bare addresses" do
    assert_equal "203.0.113.9", MailOnRails::BannedIp.create!(cidr: " 203.0.113.9/32 ").cidr
    assert_equal "2001:db8::5", MailOnRails::BannedIp.create!(cidr: "2001:db8::5/128").cidr
  end

  test "normalizes ranges to their masked network" do
    assert_equal "203.0.113.0/24", MailOnRails::BannedIp.create!(cidr: "203.0.113.9/24").cidr
    assert_equal "2001:db8::/48", MailOnRails::BannedIp.create!(cidr: "2001:db8::5/48").cidr
  end

  test "rejects input that is not an address or range" do
    ban = MailOnRails::BannedIp.new(cidr: "not-an-ip")
    assert_not ban.valid?
    assert_match(/not an IP address/, ban.errors[:cidr].to_sentence)
  end

  test "rejects manual bans broad enough to be typos" do
    assert_not MailOnRails::BannedIp.new(cidr: "0.0.0.0/0").valid?
    assert_not MailOnRails::BannedIp.new(cidr: "10.0.0.0/4").valid?
    assert_not MailOnRails::BannedIp.new(cidr: "::/16").valid?
    assert MailOnRails::BannedIp.new(cidr: "10.0.0.0/8").valid?
  end

  test "imported DROP rows are exempt from the breadth guard" do
    assert MailOnRails::BannedIp.new(cidr: "10.0.0.0/4", source: "spamhaus_drop").valid?
  end

  test "different spellings of one range cannot coexist" do
    MailOnRails::BannedIp.create!(cidr: "203.0.113.0/24")
    duplicate = MailOnRails::BannedIp.new(cidr: "203.0.113.77/24")
    assert_not duplicate.valid?
  end

  test "covering finds the ban containing an address" do
    range_ban = MailOnRails::BannedIp.create!(cidr: "203.0.113.0/24")
    host_ban = MailOnRails::BannedIp.create!(cidr: "198.51.100.7")

    assert_equal range_ban, MailOnRails::BannedIp.covering("203.0.113.200")
    assert_equal host_ban, MailOnRails::BannedIp.covering("198.51.100.7")
    assert_nil MailOnRails::BannedIp.covering("198.51.100.8")
    assert_nil MailOnRails::BannedIp.covering("garbage")
    assert_nil MailOnRails::BannedIp.covering(nil)
  end

  test "an IPv4 ban never matches an IPv6 address" do
    MailOnRails::BannedIp.create!(cidr: "0.0.0.0/8", source: "spamhaus_drop")
    assert_nil MailOnRails::BannedIp.covering("::1")
  end

  test "canonicalize raises on garbage" do
    assert_raises(IPAddr::Error) { MailOnRails::BannedIp.canonicalize("bogus") }
  end
end
