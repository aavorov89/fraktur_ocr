import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "name"]

  submit() {
    const file = this.inputTarget.files[0]
    if (!file) return

    this.nameTarget.value = file.name.replace(/\.pdf$/i, "")
    this.element.requestSubmit()
  }
}
