import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { text: String }

  copy() {
    navigator.clipboard.writeText(this.textValue).then(() => {
      const svg = this.element.querySelector("svg")
      if (svg) {
        const original = svg.innerHTML
        svg.innerHTML = '<polyline points="20,6 9,17 4,12" />'
        setTimeout(() => { svg.innerHTML = original }, 1200)
      }
    })
  }
}
