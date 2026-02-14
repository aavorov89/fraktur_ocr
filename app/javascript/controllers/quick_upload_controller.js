import { Controller } from "@hotwired/stimulus"
import { storePdf } from "services/pdf_storage"

export default class extends Controller {
  static targets = ["input"]
  static values = { documentId: Number }

  async submit() {
    const file = this.inputTarget.files[0]
    if (!file) return

    const arrayBuffer = await file.arrayBuffer()
    await storePdf(this.documentIdValue, file.name, arrayBuffer)
    window.location.reload()
  }
}
