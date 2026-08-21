import { Controller } from "@hotwired/stimulus"

// Holds a one-time secret (a generated password) in JS memory instead of
// the page: the data attribute carrying it is stripped on connect, the
// visible text stays masked until deliberately revealed, and the wrapper's
// data-turbo-temporary keeps the element - revealed or not - out of
// Turbo's page snapshots. Extensions reading the DOM later, cached
// back/forward navigations, and saved HTML archives see only the mask.
export default class extends Controller {
  static targets = ["display", "feedback"]

  connect() {
    this.secret = this.element.dataset.secretValue
    this.element.removeAttribute("data-secret-value")
  }

  async activate() {
    if (!this.revealed) {
      this.revealed = true
      this.displayTarget.textContent = this.secret
      return
    }
    await navigator.clipboard.writeText(this.secret)
    this.feedbackTarget.hidden = false
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => { this.feedbackTarget.hidden = true }, 2000)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }
}
