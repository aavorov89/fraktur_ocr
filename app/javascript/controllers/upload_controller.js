import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "name", "submit", "dropzone", "prompt", "progressArea", "progressBar", "progressText"]

  connect() {
    this.element.addEventListener("direct-upload:start", () => this.uploadStarted())
    this.element.addEventListener("direct-upload:progress", (e) => this.uploadProgress(e))
    this.element.addEventListener("direct-upload:error", (e) => this.uploadError(e))
  }

  fileSelected() {
    const file = this.inputTarget.files[0]
    if (!file) return

    this.nameTarget.value = file.name.replace(/\.pdf$/i, "")
    this.showProgress(0)
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

    const dt = new DataTransfer()
    dt.items.add(file)
    this.inputTarget.files = dt.files

    this.nameTarget.value = file.name.replace(/\.pdf$/i, "")
    this.showProgress(0)
    this.submitTarget.click()
  }

  uploadStarted() {
    this.showProgress(0)
  }

  uploadProgress(event) {
    const { progress } = event.detail
    this.showProgress(progress)
  }

  uploadError(event) {
    event.preventDefault()
    const error = event.detail.error
    console.error("Direct upload error:", error)

    this.promptTarget.innerHTML = `
      <div class="upload-icon" style="color: var(--accent);">
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
          <circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>
        </svg>
      </div>
      <span class="upload-text" style="color: var(--accent);">Upload failed</span>
      <span class="upload-hint" style="color: var(--accent);">${error || "Connection error"}</span>
      <span class="upload-hint">Click to try again</span>
    `
    this.promptTarget.style.display = ""
    this.progressAreaTarget.style.display = "none"
  }

  showProgress(percent) {
    const pct = Math.round(percent)
    this.promptTarget.style.display = "none"
    this.progressAreaTarget.style.display = ""
    this.progressBarTarget.style.width = `${pct}%`
    this.progressTextTarget.textContent = `${pct}%`
  }
}
