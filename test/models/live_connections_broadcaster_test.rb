require "test_helper"

# The debounce contract: connection events arrive at flood rate from the
# servers' threads, subscribed dashboards must refetch at most once per
# interval per protocol, and the last event of a burst must still produce
# a (trailing) broadcast - a dropped final event would leave the page
# showing a connection that already ended until the backstop poll.
class LiveConnectionsBroadcasterTest < ActiveSupport::TestCase
  INTERVAL = 0.1

  class RecordingBroadcaster < LiveConnectionsBroadcaster
    def initialize(...)
      super
      @sent = Queue.new
    end

    attr_reader :sent

    private

    def broadcast(protocol)
      @sent << protocol
    end
  end

  setup do
    @broadcaster = RecordingBroadcaster.new(interval: INTERVAL)
  end

  def pop = @broadcaster.sent.pop(timeout: 2)

  test "the first event broadcasts immediately" do
    @broadcaster.ping(:smtp)
    assert_equal :smtp, pop
  end

  test "a burst collapses into one immediate and one trailing broadcast" do
    5.times { @broadcaster.ping(:smtp) }
    assert_equal :smtp, pop, "leading edge"
    assert_equal :smtp, pop, "trailing edge"

    sleep INTERVAL * 2
    assert @broadcaster.sent.empty?, "the burst produced exactly two broadcasts"
  end

  test "events spaced wider than the interval each broadcast immediately" do
    @broadcaster.ping(:smtp)
    assert_equal :smtp, pop
    sleep INTERVAL * 1.5
    @broadcaster.ping(:smtp)
    assert_equal :smtp, pop

    sleep INTERVAL * 2
    assert @broadcaster.sent.empty?, "no trailing broadcast was scheduled"
  end

  test "protocols debounce independently" do
    @broadcaster.ping(:smtp)
    @broadcaster.ping(:imap)
    assert_equal %i[imap smtp], [ pop, pop ].sort
  end
end
