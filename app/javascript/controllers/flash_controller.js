import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    // Auto-dismiss after 10 seconds
    setTimeout(() => {
      this.dismiss()
    }, 10000)
  }

  dismiss() {
    this.element.style.opacity = "0"
    setTimeout(() => {
      this.element.remove()
    }, 300)
  }
}
