import { Controller } from "@hotwired/stimulus"
import * as pdfjsLib from "pdfjs-dist"
import * as Turbo from "@hotwired/turbo-rails"

// Set pdf.js worker URL
pdfjsLib.GlobalWorkerOptions.workerSrc =
  "https://cdn.jsdelivr.net/npm/pdfjs-dist@5.0.375/build/pdf.worker.min.mjs"

export default class extends Controller {
  static targets = [
    "mainCanvas", "overlayCanvas", "thumbSidebar", "scrollContainer",
    "pageInfo", "zoomInfo", "prevBtn", "nextBtn", "drawHint"
  ]

  static values = {
    url: String,
    documentId: Number,
    ocrUrl: String
  }

  connect() {
    this.currentPage = 1
    this.totalPages = 0
    this.scale = 1.5
    this.pdfDoc = null
    this.renderTask = null
    this.drawing = false
    this.startPos = null
    this.rect = null

    this.loadPdf()
    this.boundKeyHandler = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeyHandler)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeyHandler)
  }

  async loadPdf() {
    try {
      this.pdfDoc = await pdfjsLib.getDocument(this.urlValue).promise
      this.totalPages = this.pdfDoc.numPages
      this.updateToolbar()
      this.renderPage()
      this.generateThumbnails()
    } catch (err) {
      console.error("Failed to load PDF:", err)
    }
  }

  async renderPage() {
    if (!this.pdfDoc) return

    if (this.renderTask) {
      this.renderTask.cancel()
    }

    const page = await this.pdfDoc.getPage(this.currentPage)
    const viewport = page.getViewport({ scale: this.scale })

    const canvas = this.mainCanvasTarget
    const ctx = canvas.getContext("2d")
    canvas.width = viewport.width
    canvas.height = viewport.height

    const overlay = this.overlayCanvasTarget
    overlay.width = viewport.width
    overlay.height = viewport.height

    try {
      this.renderTask = page.render({ canvasContext: ctx, viewport })
      await this.renderTask.promise
    } catch (err) {
      if (err.name !== "RenderingCancelled") console.error(err)
    }

    this.updateToolbar()
  }

  async generateThumbnails() {
    const sidebar = this.thumbSidebarTarget
    sidebar.innerHTML = ""

    for (let i = 1; i <= this.totalPages; i++) {
      const page = await this.pdfDoc.getPage(i)
      const viewport = page.getViewport({ scale: 0.2 })

      const thumbCanvas = document.createElement("canvas")
      thumbCanvas.width = viewport.width
      thumbCanvas.height = viewport.height

      const ctx = thumbCanvas.getContext("2d")
      await page.render({ canvasContext: ctx, viewport }).promise

      const btn = document.createElement("button")
      btn.className = `thumb-item ${i === this.currentPage ? "active" : ""}`
      btn.dataset.page = i
      btn.addEventListener("click", () => this.goToPage(i))

      const img = document.createElement("img")
      img.src = thumbCanvas.toDataURL()
      img.alt = `Page ${i}`

      const num = document.createElement("span")
      num.className = "thumb-num"
      num.textContent = i

      btn.appendChild(img)
      btn.appendChild(num)
      sidebar.appendChild(btn)
    }
  }

  goToPage(num) {
    if (num < 1 || num > this.totalPages || num === this.currentPage) return
    this.currentPage = num
    this.renderPage()
    this.updateActiveThumbnail()
    this.clearOverlay()
  }

  prevPage() { this.goToPage(this.currentPage - 1) }
  nextPage() { this.goToPage(this.currentPage + 1) }

  zoomIn() {
    if (this.scale >= 4) return
    this.scale = Math.round((this.scale + 0.25) * 100) / 100
    this.renderPage()
  }

  zoomOut() {
    if (this.scale <= 0.5) return
    this.scale = Math.round((this.scale - 0.25) * 100) / 100
    this.renderPage()
  }

  updateToolbar() {
    this.pageInfoTarget.textContent = `${this.currentPage} / ${this.totalPages}`
    this.zoomInfoTarget.textContent = `${Math.round(this.scale * 100)}%`
    this.prevBtnTarget.disabled = this.currentPage <= 1
    this.nextBtnTarget.disabled = this.currentPage >= this.totalPages
  }

  updateActiveThumbnail() {
    this.thumbSidebarTarget.querySelectorAll(".thumb-item").forEach((btn, i) => {
      btn.classList.toggle("active", i + 1 === this.currentPage)
    })
  }

  handleKeydown(e) {
    if (e.key === "ArrowRight" || e.key === "ArrowDown") {
      e.preventDefault()
      this.nextPage()
    } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
      e.preventDefault()
      this.prevPage()
    }
  }

  // === Rectangle drawing ===

  getCanvasPos(e) {
    const overlay = this.overlayCanvasTarget
    const rect = overlay.getBoundingClientRect()
    return {
      x: (e.clientX - rect.left) * (overlay.width / rect.width),
      y: (e.clientY - rect.top) * (overlay.height / rect.height)
    }
  }

  startDraw(e) {
    if (e.button !== 0) return
    this.startPos = this.getCanvasPos(e)
    this.drawing = true
    this.rect = null
    this.clearOverlay()
    if (this.hasDrawHintTarget) this.drawHintTarget.style.display = "none"
  }

  draw(e) {
    if (!this.drawing || !this.startPos) return
    const pos = this.getCanvasPos(e)
    this.rect = {
      x: Math.min(this.startPos.x, pos.x),
      y: Math.min(this.startPos.y, pos.y),
      w: Math.abs(pos.x - this.startPos.x),
      h: Math.abs(pos.y - this.startPos.y)
    }
    this.drawRect(this.rect)
  }

  endDraw() {
    if (!this.drawing) return
    this.drawing = false

    if (!this.rect || this.rect.w < 10 || this.rect.h < 10) {
      this.rect = null
      this.clearOverlay()
      if (this.hasDrawHintTarget) this.drawHintTarget.style.display = ""
      return
    }

    // Crop selection from main canvas
    const mainCanvas = this.mainCanvasTarget
    const cropCanvas = document.createElement("canvas")
    cropCanvas.width = this.rect.w
    cropCanvas.height = this.rect.h
    const cropCtx = cropCanvas.getContext("2d")
    cropCtx.drawImage(
      mainCanvas,
      this.rect.x, this.rect.y, this.rect.w, this.rect.h,
      0, 0, this.rect.w, this.rect.h
    )

    const dataUrl = cropCanvas.toDataURL("image/png")
    this.submitOcr(dataUrl)

    // Fade out selection
    setTimeout(() => {
      this.rect = null
      this.clearOverlay()
    }, 500)
  }

  drawRect(r) {
    const overlay = this.overlayCanvasTarget
    const ctx = overlay.getContext("2d")
    ctx.clearRect(0, 0, overlay.width, overlay.height)

    ctx.fillStyle = "rgba(196, 69, 60, 0.08)"
    ctx.fillRect(r.x, r.y, r.w, r.h)

    ctx.strokeStyle = "#c4453c"
    ctx.lineWidth = 2
    ctx.setLineDash([6, 3])
    ctx.strokeRect(r.x, r.y, r.w, r.h)
    ctx.setLineDash([])
  }

  clearOverlay() {
    const overlay = this.overlayCanvasTarget
    const ctx = overlay.getContext("2d")
    ctx.clearRect(0, 0, overlay.width, overlay.height)
  }

  // === OCR submission via Turbo Stream ===

  async submitOcr(cropDataUrl) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    try {
      const response = await fetch(this.ocrUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "text/vnd.turbo-stream.html"
        },
        body: JSON.stringify({
          ocr_request: {
            page_number: this.currentPage,
            crop_data: cropDataUrl
          }
        })
      })

      if (response.ok) {
        const html = await response.text()
        // Parse and execute each turbo-stream action
        const parser = new DOMParser()
        const doc = parser.parseFromString(html, 'text/html')
        const streams = doc.querySelectorAll('turbo-stream')

        streams.forEach(stream => {
          const action = stream.getAttribute('action')
          const target = stream.getAttribute('target')
          const template = stream.querySelector('template')

          if (action === 'replace' && target && template) {
            const targetElement = document.getElementById(target)
            if (targetElement) {
              targetElement.replaceWith(template.content.cloneNode(true))
            }
          }
        })
      } else {
        console.error("OCR request failed:", response.status)
      }
    } catch (err) {
      console.error("OCR submission error:", err)
    }
  }
}
