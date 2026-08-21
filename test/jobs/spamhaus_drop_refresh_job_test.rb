require "test_helper"

# Thin recurring wrapper: the import logic itself is covered by the
# SpamhausDrop tests; here only the invocation and the retry policy.
class SpamhausDropRefreshJobTest < ActiveJob::TestCase
  # minitest/mock is unavailable; swap SpamhausDrop.refresh! on its
  # singleton class and restore (the without_sender_verification pattern).
  def with_refresh(handler)
    singleton = MailOnRails::SpamhausDrop.singleton_class
    original = MailOnRails::SpamhausDrop.method(:refresh!)
    singleton.define_method(:refresh!) { |**| handler.call }
    yield
  ensure
    singleton.define_method(:refresh!, original)
  end

  test "perform runs the DROP import" do
    calls = 0
    with_refresh(-> { calls += 1 }) { MailOnRails::SpamhausDropRefreshJob.perform_now }

    assert_equal 1, calls
  end

  test "a failing refresh is retried, then surfaces once attempts are exhausted" do
    calls = 0
    with_refresh(-> { calls += 1; raise "spamhaus unreachable" }) do
      MailOnRails::SpamhausDropRefreshJob.perform_later
      # Flush form only: the block form wraps the block in
      # _assert_nothing_raised_or_warn, swallowing the final re-raise.
      # Each flush performs one attempt; retry_on re-enqueues the next.
      2.times { perform_enqueued_jobs }
      error = assert_raises(RuntimeError) { perform_enqueued_jobs }
      assert_equal "spamhaus unreachable", error.message
    end

    assert_equal 3, calls
    assert_empty enqueued_jobs
  end
end
