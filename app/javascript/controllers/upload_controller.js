import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "name", "submit", "dropzone"]

  fileSelected() {
    const file = this.inputTarget.files[0]
    if (!file) return

    this.nameTarget.value = file.name.replace(/\.pdf$/i, "")
    this.submitTarget.click()
  }

  dragover(e) {
    e.preventDefault()
    this.dropzoneTarget.classList.add("drag-over")
  }

  dragleave() {
    this.dropzoneTarget.classList.remove("drag-over")
  }

  drop(e) {
    e.preventDefault()
    this.dropzoneTarget.classList.remove("drag-over")

    const file = e.dataTransfer.files[0]
    if (!file || file.type !== "application/pdf") return

    // Create a new DataTransfer to set the file on the input
    const dt = new DataTransfer()
    dt.items.add(file)
    this.inputTarget.files = dt.files

    this.nameTarget.value = file.name.replace(/\.pdf$/i, "")
    this.submitTarget.click()
  }
}
