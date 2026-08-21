import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Refreshes the page in place every intervalValue ms - a Turbo page
// refresh, so the layout's `turbo_refreshes_with method: :morph,
// scroll: :preserve` keeps scroll position and only patches what
// changed. The live connection pages get their real-time updates over
// turbo_stream_from refresh broadcasts; this poll is the slow backstop
// that keeps relative times ("3 minutes ago", lockout countdowns) fresh
// and covers a dropped cable connection. Hidden tabs skip refreshes.
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  refresh() {
    if (document.hidden) return
    Turbo.session.refresh(window.location.href)
  }
}
