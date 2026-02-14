import { Controller } from "@hotwired/stimulus"
import { setPendingPdf } from "services/pdf_storage"

export default class extends Controller {
  static targets = ["input", "name", "submit", "dropzone", "prompt", "progressArea", "progressBar", "progressText"]

  fileSelected() {
    const file = this.inputTarget.files[0]
    if (!file) return

    this.nameTarget.value = file.name.replace(/\.pdf$/i, "")
    this.readFile(file)
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

    this.nameTarget.value = file.name.replace(/\.pdf$/i, "")
    this.readFile(file)
  }

  readFile(file) {
    this.showProgress(0)

    const reader = new FileReader()

    reader.onprogress = (e) => {
      if (e.lengthComputable) {
        this.showProgress((e.loaded / e.total) * 100)
      }
    }

    reader.onload = () => {
      this.showProgress(100)
      setPendingPdf(file.name, reader.result)
      this.submitTarget.click()
    }

    reader.onerror = () => {
      console.error("FileReader error:", reader.error)
      this.showError("Failed to read file")
    }

    reader.readAsArrayBuffer(file)
  }

  showProgress(percent) {
    const pct = Math.round(percent)
    this.promptTarget.style.display = "none"
    this.progressAreaTarget.style.display = ""
    this.progressBarTarget.style.width = `${pct}%`
    this.progressTextTarget.textContent = `${pct}%`
  }

  showError(message) {
    this.promptTarget.innerHTML = `
      <div class="upload-icon" style="color: var(--accent);">
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
          <circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>
        </svg>
      </div>
      <span class="upload-text" style="color: var(--accent);">${message}</span>
      <span class="upload-hint">Click to try again</span>
    `
    this.promptTarget.style.display = ""
    this.progressAreaTarget.style.display = "none"
  }
}
