import { Controller } from "@hotwired/stimulus"
import * as pdfjsLib from "pdfjs-dist"
import { consumePendingPdf, storePdf, getPdf } from "services/pdf_storage"
import { ensurePdfOnServer } from "services/pdf_sync"

// Set pdf.js worker URL
pdfjsLib.GlobalWorkerOptions.workerSrc =
  "https://cdn.jsdelivr.net/npm/pdfjs-dist@5.0.375/build/pdf.worker.min.mjs"

export default class extends Controller {
  static targets = [
    "mainCanvas", "overlayCanvas", "thumbSidebar", "scrollContainer",
    "pageInfo", "zoomInfo", "prevBtn", "nextBtn", "drawHint",
    "loadingOverlay", "loadingProgress", "missingOverlay", "reselectInput"
  ]

  static values = {
    documentId: Number,
    documentName: String,
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
    this.submitting = false
    // Tracks whether the PDF has finished syncing to the server. While false,
    // OCR uses a browser-rendered high-DPI crop (no upload latency); once true,
    // OCR sends rect_pts and lets the Go renderer produce the crop.
    this.serverHasPdf = false
    this.thumbsLoaded = 0
    this.thumbsPerBatch = 50
    this.loadingThumbs = false

    this.loadPdf()
    this.boundKeyHandler = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeyHandler)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeyHandler)
  }

  async loadPdf() {
    this.showLoading()

    // 1. Check for a freshly uploaded pending PDF (from upload page)
    const pending = consumePendingPdf()
    if (pending) {
      console.log("Loading PDF from pending upload")
      await storePdf(this.documentIdValue, pending.name, pending.data)
      this.openPdfData(pending.data)
      return
    }

    // 2. Check IndexedDB for a previously stored PDF
    try {
      const stored = await getPdf(this.documentIdValue)
      if (stored) {
        console.log("Loading PDF from IndexedDB")
        this.openPdfData(stored.data)
        return
      }
    } catch (err) {
      console.error("IndexedDB read error:", err)
    }

    // 3. No PDF available — show re-select overlay
    console.log("No PDF found, showing re-select overlay")
    this.hideLoading()
    this.showMissing()
  }

  async openPdfData(arrayBuffer) {
    try {
      // pdfjsLib transfers the buffer; clone before passing so we can also
      // upload it to the server without re-reading from IndexedDB.
      const forServer = arrayBuffer.slice(0)
      const loadingTask = pdfjsLib.getDocument({ data: arrayBuffer })

      this.pdfDoc = await loadingTask.promise
      this.totalPages = this.pdfDoc.numPages
      console.log("PDF loaded, total pages:", this.totalPages)
      this.hideLoading()
      this.updateToolbar()
      this.renderPage()
      this.generateThumbnails()
      // Fire-and-forget — drawing is allowed immediately because endDraw()
      // falls back to a browser-rendered high-DPI crop while serverHasPdf
      // is still false.
      this.syncPdfToServer(forServer)
    } catch (err) {
      console.error("Failed to load PDF:", err)
      this.hideLoading()
      this.showMissing()
    }
  }

  async syncPdfToServer(arrayBuffer) {
    try {
      this.showSyncing()
      const uploaded = await ensurePdfOnServer(this.documentIdValue, arrayBuffer)
      if (uploaded) console.log("PDF uploaded to server")
      this.serverHasPdf = true
    } catch (err) {
      console.error("PDF server sync failed:", err)
      // Browser-rendered crops still work; the user keeps using the app.
    } finally {
      this.hideSyncing()
    }
  }

  showSyncing() {
    if (this.syncIndicator) return
    const el = document.createElement("div")
    el.className = "pdf-sync-indicator"
    el.textContent = "syncing PDF…"
    el.style.cssText = "position:absolute;top:8px;right:8px;padding:4px 10px;border-radius:4px;background:rgba(0,0,0,0.6);color:white;font-size:11px;z-index:10;"
    this.element.appendChild(el)
    this.syncIndicator = el
  }

  hideSyncing() {
    if (this.syncIndicator) {
      this.syncIndicator.remove()
      this.syncIndicator = null
    }
  }

  async reselectPdf() {
    const file = this.reselectInputTarget.files[0]
    if (!file) return

    const arrayBuffer = await file.arrayBuffer()
    await storePdf(this.documentIdValue, file.name, arrayBuffer)
    this.hideMissing()
    this.openPdfData(arrayBuffer)
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

  showMissing() {
    if (this.hasMissingOverlayTarget) {
      this.missingOverlayTarget.style.display = "flex"
    }
  }

  hideMissing() {
    if (this.hasMissingOverlayTarget) {
      this.missingOverlayTarget.style.display = "none"
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

    sidebar.addEventListener('scroll', () => this.handleThumbScroll())

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

  async endDraw() {
    if (!this.drawing) return
    this.drawing = false

    if (!this.rect || this.rect.w < 10 || this.rect.h < 10) {
      this.rect = null
      this.clearOverlay()
      if (this.hasDrawHintTarget) this.drawHintTarget.style.display = ""
      return
    }

    const rectAtCapture = { ...this.rect }
    const pageAtCapture = this.currentPage
    const scaleAtCapture = this.scale

    if (this.serverHasPdf) {
      // Server-side path: send rect in PDF points; Go renderer crops at 300 DPI.
      // PDF.js renders at viewport.scale = this.scale, so 1 viewport pixel
      // corresponds to 1 / this.scale PDF user-space points. Origin matches:
      // both PDF.js viewport and the Go renderer treat top-left as (0, 0).
      const rectPts = {
        x: rectAtCapture.x / scaleAtCapture,
        y: rectAtCapture.y / scaleAtCapture,
        w: rectAtCapture.w / scaleAtCapture,
        h: rectAtCapture.h / scaleAtCapture
      }
      this.submitOcr({ rect_pts: rectPts })
    } else {
      // Browser-side fallback: render the page at high DPI offscreen, crop,
      // ship the JPEG bitmap directly. Keeps the user productive while the
      // PDF is still uploading to the server.
      try {
        const cropDataUrl = await this.highDpiCropDataUrl(rectAtCapture, pageAtCapture, scaleAtCapture)
        this.submitOcr({ crop_data: cropDataUrl })
      } catch (err) {
        console.error("High-DPI browser crop failed:", err)
      }
    }

    setTimeout(() => {
      this.rect = null
      this.clearOverlay()
    }, 500)
  }

  // Render the current page in an offscreen canvas at scale 3 (~288 DPI),
  // crop the user's selection, and return a JPEG data URL capped at
  // ~2000 px on the long side (matches Claude Vision's sweet spot).
  async highDpiCropDataUrl(rect, pageNumber, displayScale) {
    const HIGH_SCALE = 3.0
    const MAX_LONG_SIDE = 2000
    const JPEG_QUALITY = 0.92

    const page = await this.pdfDoc.getPage(pageNumber)
    const viewport = page.getViewport({ scale: HIGH_SCALE })

    const fullCanvas = document.createElement("canvas")
    fullCanvas.width = viewport.width
    fullCanvas.height = viewport.height
    await page.render({ canvasContext: fullCanvas.getContext("2d"), viewport }).promise

    const ratio = HIGH_SCALE / displayScale
    const sx = Math.round(rect.x * ratio)
    const sy = Math.round(rect.y * ratio)
    const sw = Math.round(rect.w * ratio)
    const sh = Math.round(rect.h * ratio)

    let outW = sw
    let outH = sh
    const longSide = Math.max(sw, sh)
    if (longSide > MAX_LONG_SIDE) {
      const ds = MAX_LONG_SIDE / longSide
      outW = Math.round(sw * ds)
      outH = Math.round(sh * ds)
    }

    const cropCanvas = document.createElement("canvas")
    cropCanvas.width = outW
    cropCanvas.height = outH
    cropCanvas.getContext("2d").drawImage(fullCanvas, sx, sy, sw, sh, 0, 0, outW, outH)
    return cropCanvas.toDataURL("image/jpeg", JPEG_QUALITY)
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

  async submitOcr(payload) {
    // payload is either { rect_pts } (server-side render) or { crop_data }
    // (browser-rendered fallback while the PDF is still uploading).
    console.log("submitOcr called")
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
            ...payload
          }
        })
      })

      if (response.ok) {
        const html = await response.text()
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
                targetElement.innerHTML = ''
                targetElement.appendChild(template.content.cloneNode(true))
              } else if (action === 'replace') {
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
      setTimeout(() => { this.submitting = false }, 2000)
    }
  }
}
