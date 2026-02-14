import { Controller } from "@hotwired/stimulus"
import * as pdfjsLib from "pdfjs-dist"
import * as Turbo from "@hotwired/turbo-rails"

// Set pdf.js worker URL
pdfjsLib.GlobalWorkerOptions.workerSrc =
  "https://cdn.jsdelivr.net/npm/pdfjs-dist@5.0.375/build/pdf.worker.min.mjs"

export default class extends Controller {
  static targets = [
    "mainCanvas", "overlayCanvas", "thumbSidebar", "scrollContainer",
    "pageInfo", "zoomInfo", "prevBtn", "nextBtn", "drawHint", "loadingOverlay", "loadingProgress"
  ]

  static values = {
    url: String,
    documentId: Number,
    ocrUrl: String
  }

  connect() {
    console.log("PDF Viewer controller connected")
    this.currentPage = 1
    this.totalPages = 0
    this.scale = 0.5
    this.pdfDoc = null
    this.renderTask = null
    this.drawing = false
    this.startPos = null
    this.rect = null
    this.submitting = false  // Prevent duplicate submissions
    this.thumbsLoaded = 0     // Track how many thumbnails loaded
    this.thumbsPerBatch = 50  // Load 50 at a time
    this.loadingThumbs = false // Prevent concurrent loading

    this.loadPdf()
    this.boundKeyHandler = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeyHandler)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeyHandler)
  }

  async loadPdf() {
    console.log("Loading PDF from:", this.urlValue)
    this.showLoading()

    try {
      const loadingTask = pdfjsLib.getDocument({
        url: this.urlValue,
        // Enable range requests — pdf.js will only download
        // what it needs per page instead of the entire file
        disableRange: false,
        disableStream: false,
        disableAutoFetch: true,  // Don't prefetch the whole file
        rangeChunkSize: 65536    // 64 KB chunks
      })

      loadingTask.onProgress = ({ loaded, total }) => {
        if (total > 0) {
          const pct = Math.round((loaded / total) * 100)
          this.updateLoadingProgress(pct, loaded, total)
        }
      }

      this.pdfDoc = await loadingTask.promise
      this.totalPages = this.pdfDoc.numPages
      console.log("PDF loaded, total pages:", this.totalPages)
      this.hideLoading()
      this.updateToolbar()
      this.renderPage()
      this.generateThumbnails()
    } catch (err) {
      console.error("Failed to load PDF:", err)
      this.hideLoading()
    }
  }

  showLoading() {
    if (this.hasLoadingOverlayTarget) {
      this.loadingOverlayTarget.style.display = "flex"
    }
  }

  hideLoading() {
    if (this.hasLoadingOverlayTarget) {
      this.loadingOverlayTarget.style.display = "none"
    }
  }

  updateLoadingProgress(pct, loaded, total) {
    if (this.hasLoadingProgressTarget) {
      const mb = (loaded / 1024 / 1024).toFixed(1)
      const totalMb = (total / 1024 / 1024).toFixed(1)
      this.loadingProgressTarget.textContent = `${mb} / ${totalMb} MB`
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
    // Explicitly match overlay CSS size to main canvas display size
    // so mouse-to-canvas coordinate conversion stays 1:1
    overlay.style.width = canvas.width + "px"
    overlay.style.height = canvas.height + "px"

    try {
      this.renderTask = page.render({ canvasContext: ctx, viewport })
      await this.renderTask.promise
    } catch (err) {
      if (err.name !== "RenderingCancelled") console.error(err)
    }

    this.updateToolbar()
  }

  async generateThumbnails() {
    console.log("Generating thumbnails for", this.totalPages, "pages")
    const sidebar = this.thumbSidebarTarget
    sidebar.innerHTML = ""

    // Set up scroll listener for lazy loading
    sidebar.addEventListener('scroll', () => this.handleThumbScroll())

    // Load first batch
    await this.loadNextThumbBatch()
  }

  async loadNextThumbBatch() {
    if (this.loadingThumbs || this.thumbsLoaded >= this.totalPages) return

    this.loadingThumbs = true
    const startPage = this.thumbsLoaded + 1
    const endPage = Math.min(this.thumbsLoaded + this.thumbsPerBatch, this.totalPages)

    console.log(`Loading thumbnails ${startPage}-${endPage}`)

    const sidebar = this.thumbSidebarTarget

    for (let i = startPage; i <= endPage; i++) {
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

    this.thumbsLoaded = endPage
    this.loadingThumbs = false

    // Update or add progress message
    this.updateThumbMessage()
  }

  updateThumbMessage() {
    const sidebar = this.thumbSidebarTarget
    let message = sidebar.querySelector('.thumb-message')

    if (this.thumbsLoaded < this.totalPages) {
      if (!message) {
        message = document.createElement("div")
        message.className = "thumb-message"
        message.style.cssText = "padding: 10px; font-size: 11px; color: var(--text-muted); text-align: center;"
        sidebar.appendChild(message)
      }
      message.textContent = `Loaded ${this.thumbsLoaded} of ${this.totalPages} pages`
    } else if (message) {
      message.remove()
    }
  }

  handleThumbScroll() {
    const sidebar = this.thumbSidebarTarget
    const scrollBottom = sidebar.scrollHeight - sidebar.scrollTop - sidebar.clientHeight

    // Load more when within 200px of bottom
    if (scrollBottom < 200 && !this.loadingThumbs) {
      this.loadNextThumbBatch()
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
    // Convert overlay coordinates to main canvas coordinates in case of any size mismatch
    const mainCanvas = this.mainCanvasTarget
    const overlay = this.overlayCanvasTarget
    const scaleX = mainCanvas.width / overlay.width
    const scaleY = mainCanvas.height / overlay.height
    const sx = Math.round(this.rect.x * scaleX)
    const sy = Math.round(this.rect.y * scaleY)
    const sw = Math.round(this.rect.w * scaleX)
    const sh = Math.round(this.rect.h * scaleY)

    const cropCanvas = document.createElement("canvas")
    cropCanvas.width = sw
    cropCanvas.height = sh
    const cropCtx = cropCanvas.getContext("2d")
    cropCtx.drawImage(
      mainCanvas,
      sx, sy, sw, sh,
      0, 0, sw, sh
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
    console.log("submitOcr called")
    // Prevent duplicate submissions
    if (this.submitting) {
      console.log("OCR submission already in progress, skipping")
      return
    }
    this.submitting = true

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

          if (target && template) {
            const targetElement = document.getElementById(target)
            if (targetElement) {
              if (action === 'update') {
                // Update innerHTML, preserving the wrapper
                targetElement.innerHTML = ''
                targetElement.appendChild(template.content.cloneNode(true))
              } else if (action === 'replace') {
                // Replace entire element
                targetElement.replaceWith(template.content.cloneNode(true))
              }
            }
          }
        })
      } else {
        console.error("OCR request failed:", response.status)
      }
    } catch (err) {
      console.error("OCR submission error:", err)
    } finally {
      // Reset submission flag after a delay to allow for next request
      setTimeout(() => { this.submitting = false }, 2000)
    }
  }
}
