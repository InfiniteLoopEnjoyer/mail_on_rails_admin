# App side of the gem's MailOnRails.on_connection_activity seam (wired in
# config/initializers/mail_on_rails.rb): turns connection lifecycle events
# from the in-process SMTP/IMAP servers into Turbo page-refresh broadcasts
# for the live-connection dashboards. A refresh broadcast carries no data -
# each subscribed browser re-fetches its own URL and morphs - so this only
# signals; the dashboards render with their own session and window param.
#
# The events arrive at connection-flood rate on the servers' connection
# threads, and turbo-rails' own refresh debouncer is per-thread so it
# collapses nothing across them. This debounces per protocol with a
# leading and a trailing edge: the first event broadcasts immediately, a
# burst schedules exactly one catch-up broadcast INTERVAL later, so
# subscribed pages refetch at most once per INTERVAL per protocol no
# matter how hard a scanner hammers the listeners.
class LiveConnectionsBroadcaster
  INTERVAL = 2.0 # seconds; minimum spacing between broadcasts per protocol

  def self.ping(protocol)
    (@instance ||= new).ping(protocol)
  end

  def initialize(interval: INTERVAL)
    @interval = interval
    @mutex = Mutex.new
    @state = Hash.new { |states, protocol| states[protocol] = { last_at: nil, pending: false } }
  end

  # Thread-safe; called from server connection threads. Only the debounce
  # decision happens under the lock - the broadcast itself is a database
  # write (Solid Cable) and must not serialize the callers.
  def ping(protocol)
    now = monotonic
    verdict = @mutex.synchronize do
      state = @state[protocol]
      if state[:pending]
        nil # a trailing broadcast is already scheduled; it covers this event
      elsif state[:last_at].nil? || now - state[:last_at] >= @interval
        state[:last_at] = now
        :now
      else
        state[:pending] = true
        state[:last_at] + @interval - now
      end
    end

    case verdict
    when :now then broadcast(protocol)
    when Numeric then schedule(protocol, verdict)
    end
  end

  private

  def schedule(protocol, delay)
    Thread.new do
      sleep(delay)
      @mutex.synchronize do
        state = @state[protocol]
        state[:pending] = false
        state[:last_at] = monotonic
      end
      broadcast(protocol)
    end
  end

  # The stream pairs with `turbo_stream_from controller_name, :connections`
  # on the dashboard pages. Failures are swallowed: a cable hiccup must
  # never reach the connection thread that pinged, and the pages' fallback
  # poll covers any missed signal.
  def broadcast(protocol)
    Rails.application.executor.wrap do
      Turbo::StreamsChannel.broadcast_refresh_to(protocol, :connections)
    end
  rescue StandardError => e
    Rails.logger.warn("live-connections broadcast failed: #{e.class}: #{e.message}")
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
