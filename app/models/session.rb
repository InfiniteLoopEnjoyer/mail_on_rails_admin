class Session < ApplicationRecord
  belongs_to :user

  # Activity is only written when it's stale by this much - one indexed
  # UPDATE per interval per session, not one per request.
  TOUCH_INTERVAL = 5.minutes

  before_create { self.last_active_at ||= Time.current }

  scope :active, ->(now: Time.current) {
    scope = where(last_active_at: (now - idle_timeout)..)
    max = max_lifetime
    max.positive? ? scope.where(created_at: (now - max)..) : scope
  }

  # Server-side idle timeout, the authoritative one (the cookie horizon
  # below only bounds how long the browser keeps presenting the id).
  def self.idle_timeout = Integer(ENV.fetch("MAIL_ON_RAILS_SESSION_IDLE_TIMEOUT", 86_400)).seconds

  # Absolute cap on a session's age regardless of activity: a session that
  # slid on activity for weeks is still re-challenged eventually, bounding
  # how long a stolen cookie stays useful. 0 disables the cap.
  def self.max_lifetime = Integer(ENV.fetch("MAIL_ON_RAILS_SESSION_MAX_LIFETIME", 30 * 86_400)).seconds

  # Cookie expiry; re-set on activity, so it slides.
  def self.cookie_lifetime = Integer(ENV.fetch("MAIL_ON_RAILS_SESSION_COOKIE_LIFETIME", 14 * 86_400)).seconds

  # Expired sessions are refused at resume; this removes the rows: idle past
  # the timeout, or older than the absolute lifetime cap.
  def self.prune!(now: Time.current)
    idle = where(last_active_at: ...(now - idle_timeout))
    max = max_lifetime
    max.positive? ? idle.or(where(created_at: ...(now - max))).delete_all : idle.delete_all
  end

  def expired?(now: Time.current)
    return true if last_active_at < now - self.class.idle_timeout

    max = self.class.max_lifetime
    max.positive? && created_at < now - max
  end

  def touch_activity! = update_column(:last_active_at, Time.current)
end
