import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  fire(event) {
    event.preventDefault()
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.urlValue, {
      method: "POST",
      headers: {
        "X-CSRF-Token": token || "",
        "Accept": "text/html",
      },
      credentials: "same-origin",
    }).catch(() => {})
  }
}
