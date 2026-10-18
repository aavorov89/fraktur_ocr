import { Controller } from "@hotwired/stimulus"
import * as pdfjsLib from "pdfjs-dist"
import { consumePendingPdf, storePdf, getPdf } from "services/pdf_storage"
import { ensurePdfOnServer } from "services/pdf_sync"

// Set pdf.js worker URL
pdfjsLib.GlobalWorkerOptions.workerSrc =
  "https://cdn.jsdelivr.net/npm/pdfjs-dist@5.0.375/build/pdf.worker.min.mjs"

// Extra margin (PDF points) around a clicked Mistral region before cropping.
const REGION_PADDING_PTS = 4
// Pages after the visible one whose text regions are detected in advance.
const REGION_PREFETCH_PAGES = 2
// Fallback polling while a server-side render is in flight (~2.5 min, a bit
// longer than PageLayout::STALE_AFTER).
const REGION_POLL_INTERVAL_MS = 5000
const REGION_POLL_MAX_ATTEMPTS = 30
// Region editing by gesture: a plain click recognizes a region, dragging its
// inside moves it, dragging an edge or corner resizes it (overlay pixels).
const EDGE_GRAB_PX = 6
const DRAG_THRESHOLD_PX = 4
const MIN_REGION_PX = 12
const HANDLE_PX = 6
// Round delete button (✕) just outside the hovered region's top-right
// corner; the hover sticks while the mouse is this close to the region so
// the button can be reached.
const DELETE_BTN_RADIUS_PX = 8
const DELETE_BTN_OFFSET_PX = 12
const HOVER_KEEP_PX = 24
const RESIZE_CURSORS = {
  n: "ns-resize", s: "ns-resize", e: "ew-resize", w: "ew-resize",
  ne: "nesw-resize", sw: "nesw-resize", nw: "nwse-resize", se: "nwse-resize"
}

export default class extends Controller {
  static targets = [
    "mainCanvas", "overlayCanvas", "thumbSidebar", "scrollContainer",
    "pageInfo", "zoomInfo", "prevBtn", "nextBtn", "drawHint",
    "loadingOverlay", "loadingProgress", "missingOverlay", "reselectInput",
    "regionStatus", "layoutUpdate"
  ]

  static values = {
    documentId: Number,
    documentName: String,
    ocrUrl: String,
    textRegionsUrl: String
  }

  connect() {
    console.log("PDF Viewer controller connected")
    this.currentPage = 1
    this.totalPages = 0
    this.scale = 0.5
    this.pdfDoc = null
    this.renderTask = null
    // Tracks whether the PDF has finished syncing to the server. While false,
    // OCR uses a browser-rendered high-DPI crop (no upload latency); once true,
    // OCR sends rect_pts and lets the Go renderer produce the crop.
    this.serverHasPdf = false
    this.thumbsLoaded = 0
    this.thumbsPerBatch = 50
    this.loadingThumbs = false
    // Text regions detected by Mistral OCR, per page number. Coordinates are
    // normalized to 0..1 of the page; clicking one starts the regular OCR.
    this.regionsByPage = new Map()
    this.regionsInFlight = new Set()
    this.regionsFailed = new Set()
    // Index (into the current page's regions) of the free region under the
    // mouse, and the move/resize in progress ({ page, index, edges, ... }).
    this.hoverRegion = null
    this.drag = null
    this.suppressClick = false
    // Regions already in the text buffer: "<page>:<region index>" -> OCR
    // status. Rendered by the recognized-text panel; clicking one again does
    // nothing unless its recognition failed.
    this.bufferedRegions = new Map()
    this.watchBuffer()

    this.loadPdf()
    this.boundKeyHandler = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeyHandler)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeyHandler)
    this.bufferObserver?.disconnect()
    this.stopDragListeners()
  }

  // The recognized-text panel is re-rendered by Turbo Streams (our own
  // responses and broadcasts); re-read the buffered regions every time.
  watchBuffer() {
    this.readBufferedRegions()
    const panel = document.getElementById("recognized_panel")
    if (!panel) return
    this.bufferObserver = new MutationObserver(() => this.readBufferedRegions())
    this.bufferObserver.observe(panel, { childList: true })
  }

  readBufferedRegions() {
    const el = document.getElementById("buffered_regions")
    try {
      this.bufferedRegions = new Map(Object.entries(JSON.parse(el?.dataset.regions || "{}")))
    } catch (err) {
      console.error("Bad buffered regions:", err)
      this.bufferedRegions = new Map()
    }
    if (this.pdfDoc) this.redrawOverlay()
  }

  regionKey(pageNumber, index) {
    return `${pageNumber}:${index}`
  }

  // A region can be clicked, moved and resized unless its text is already in
  // the buffer; a failed recognition can be fixed and retried.
  isRegionFree(index) {
    if (this.currentRegions()[index]?.deleted) return false
    const status = this.bufferedRegions.get(this.regionKey(this.currentPage, index))
    return status === undefined || status === "failed"
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
      // Fire-and-forget — region clicks work immediately because
      // clickRegion() falls back to a browser-rendered high-DPI crop while
      // serverHasPdf is still false.
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
      if (this.pdfDoc) this.loadRegionsAround(this.currentPage)
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
    this.hoverRegion = null
    this.redrawOverlay()
    this.loadRegionsAround(this.currentPage)
  }

  // === Text regions (Mistral OCR layout) ===

  regionsUrl(pageNumber) {
    return this.textRegionsUrlValue.replace("__PAGE__", pageNumber)
  }

  // Lazy detection: the page in view plus a few ahead (prefetch). Prefetch
  // only uses the server path — the browser renders just the visible page.
  loadRegionsAround(pageNumber) {
    this.loadRegions(pageNumber)
    for (let i = 1; i <= REGION_PREFETCH_PAGES; i++) {
      this.loadRegions(pageNumber + i, { prefetch: true })
    }
  }

  async loadRegions(pageNumber, { prefetch = false } = {}) {
    if (pageNumber < 1 || pageNumber > this.totalPages) return
    if (this.regionsByPage.has(pageNumber) || this.regionsInFlight.has(pageNumber)) {
      this.updateRegionStatus()
      return
    }
    if (prefetch && !this.serverHasPdf) return

    this.regionsInFlight.add(pageNumber)
    this.regionsFailed.delete(pageNumber)
    this.updateRegionStatus()

    try {
      const url = this.regionsUrl(pageNumber)
      const response = await fetch(url, { headers: { "Accept": "application/json" } })
      if (!response.ok && response.status !== 404) throw new Error(`HTTP ${response.status}`)
      let layout = response.ok ? await response.json() : null

      if (layout?.status !== "completed") {
        // POST is idempotent: the server re-renders only when nothing is in
        // flight. Before the PDF reaches the server we render the page here.
        const needsImage = !this.serverHasPdf && layout?.status !== "pending"
        const body = needsImage ? { image: await this.pageImageDataUrl(pageNumber) } : {}
        const posted = await fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
          },
          body: JSON.stringify(body)
        })
        if (!posted.ok) throw new Error(`HTTP ${posted.status}`)
        layout = await posted.json()
      }

      this.applyLayout(layout)
    } catch (err) {
      // Next visit to this page retries.
      console.error(`Text region detection failed for page ${pageNumber}:`, err)
      this.finishRegions(pageNumber, { failed: true })
    }
  }

  // Layout JSON from a response, a poll or a Turbo Stream broadcast.
  applyLayout(layout) {
    const page = layout.page_number
    if (layout.status === "completed") {
      this.regionsByPage.set(page, layout.regions || [])
      this.finishRegions(page)
    } else if (layout.status === "failed") {
      if (layout.error) console.warn(`Text region detection failed for page ${page}: ${layout.error}`)
      this.finishRegions(page, { failed: true })
    } else if (this.regionsInFlight.has(page)) {
      // Server render in flight: the result arrives as a broadcast; poll in
      // case the cable connection drops it.
      this.pollRegions(page)
    }
  }

  finishRegions(pageNumber, { failed = false } = {}) {
    this.regionsInFlight.delete(pageNumber)
    if (failed) this.regionsFailed.add(pageNumber)
    else this.regionsFailed.delete(pageNumber)
    if (pageNumber === this.currentPage) {
      this.updateRegionStatus()
      this.redrawOverlay()
    }
  }

  pollRegions(pageNumber, attempt = 0) {
    setTimeout(async () => {
      if (!this.element.isConnected || !this.regionsInFlight.has(pageNumber)) return
      if (attempt >= REGION_POLL_MAX_ATTEMPTS) {
        this.finishRegions(pageNumber, { failed: true })
        return
      }
      try {
        const response = await fetch(this.regionsUrl(pageNumber), { headers: { "Accept": "application/json" } })
        if (response.ok) {
          const layout = await response.json()
          if (layout.status !== "pending") {
            this.applyLayout(layout)
            return
          }
        }
      } catch (err) {
        console.error(`Polling text regions for page ${pageNumber} failed:`, err)
      }
      this.pollRegions(pageNumber, attempt + 1)
    }, REGION_POLL_INTERVAL_MS)
  }

  layoutUpdateTargetConnected(element) {
    try {
      this.applyLayout(JSON.parse(element.dataset.layout))
    } catch (err) {
      console.error("Bad page layout broadcast:", err)
    }
    element.remove()
  }

  updateRegionStatus() {
    if (!this.hasRegionStatusTarget) return
    const page = this.currentPage
    let state = ""
    if (this.regionsInFlight.has(page)) state = "detecting"
    else if (this.regionsFailed.has(page)) state = "failed"
    this.regionStatusTarget.dataset.state = state
  }

  // Render a whole page as JPEG for layout detection. ~2000 px on the long
  // side is plenty to find paragraph boxes and keeps the upload small.
  async pageImageDataUrl(pageNumber) {
    const MAX_LONG_SIDE = 2000
    const MAX_SCALE = 3.0
    const JPEG_QUALITY = 0.85

    const page = await this.pdfDoc.getPage(pageNumber)
    const base = page.getViewport({ scale: 1 })
    const scale = Math.min(MAX_SCALE, MAX_LONG_SIDE / Math.max(base.width, base.height))
    const viewport = page.getViewport({ scale })

    const canvas = document.createElement("canvas")
    canvas.width = Math.round(viewport.width)
    canvas.height = Math.round(viewport.height)
    await page.render({ canvasContext: canvas.getContext("2d"), viewport }).promise
    return canvas.toDataURL("image/jpeg", JPEG_QUALITY)
  }

  currentRegions() {
    return this.regionsByPage.get(this.currentPage) || []
  }

  // Region (normalized) -> overlay canvas pixels, optionally padded a little
  // so tight Mistral boxes don't clip ascenders/descenders.
  regionToCanvasRect(region, padPts = 0) {
    const overlay = this.overlayCanvasTarget
    const pad = padPts * this.scale
    const x = Math.max(0, region.x * overlay.width - pad)
    const y = Math.max(0, region.y * overlay.height - pad)
    const right = Math.min(overlay.width, (region.x + region.w) * overlay.width + pad)
    const bottom = Math.min(overlay.height, (region.y + region.h) * overlay.height + pad)
    return { x, y, w: right - x, h: bottom - y }
  }

  // What a point grabs among the free regions: { index, edges } where edges
  // is "", "n", "se", ... ("" = inside: click or move). Edge zones win over
  // insides so a nested box's border stays grabbable; ties go to the
  // smallest box.
  // The hovered region's delete button wins over everything ({ remove: true }).
  regionGrabAt(pos) {
    if (this.hoverRegion !== null && this.isRegionFree(this.hoverRegion)) {
      const c = this.deleteButtonCenter(this.regionToCanvasRect(this.currentRegions()[this.hoverRegion]))
      if (Math.hypot(pos.x - c.x, pos.y - c.y) <= DELETE_BTN_RADIUS_PX + 2) {
        return { index: this.hoverRegion, edges: "", remove: true }
      }
    }

    const t = EDGE_GRAB_PX
    let best = null
    this.currentRegions().forEach((region, index) => {
      if (!this.isRegionFree(index)) return
      const r = this.regionToCanvasRect(region)
      if (pos.x < r.x - t || pos.x > r.x + r.w + t || pos.y < r.y - t || pos.y > r.y + r.h + t) return

      const dTop = Math.abs(pos.y - r.y)
      const dBottom = Math.abs(pos.y - (r.y + r.h))
      const dLeft = Math.abs(pos.x - r.x)
      const dRight = Math.abs(pos.x - (r.x + r.w))
      let edges = ""
      if (Math.min(dTop, dBottom) <= t) edges += dTop <= dBottom ? "n" : "s"
      if (Math.min(dLeft, dRight) <= t) edges += dLeft <= dRight ? "w" : "e"
      const inside = pos.x >= r.x && pos.x <= r.x + r.w && pos.y >= r.y && pos.y <= r.y + r.h
      if (!edges && !inside) return

      const rank = edges ? 0 : 1
      const area = r.w * r.h
      if (!best || rank < best.rank || (rank === best.rank && area < best.area)) {
        best = { index, edges, rank, area }
      }
    })
    return best && { index: best.index, edges: best.edges }
  }

  deleteButtonCenter(r) {
    const overlay = this.overlayCanvasTarget
    const margin = DELETE_BTN_RADIUS_PX + 1
    return {
      x: Math.min(r.x + r.w + DELETE_BTN_OFFSET_PX, overlay.width - margin),
      y: Math.max(r.y - DELETE_BTN_OFFSET_PX, margin)
    }
  }

  updateHover(e) {
    if (this.drag) return
    const pos = this.getCanvasPos(e)
    const grab = this.regionGrabAt(pos)
    this.overlayCanvasTarget.style.cursor = grab ? (RESIZE_CURSORS[grab.edges] || "pointer") : ""
    if (!grab && this.hoverRegion !== null && this.isRegionFree(this.hoverRegion)) {
      // Heading for the delete button outside the box: keep the hover.
      const r = this.regionToCanvasRect(this.currentRegions()[this.hoverRegion])
      const k = HOVER_KEEP_PX
      if (pos.x >= r.x - k && pos.x <= r.x + r.w + k && pos.y >= r.y - k && pos.y <= r.y + r.h + k) return
    }
    const index = grab ? grab.index : null
    if (index === this.hoverRegion) return
    this.hoverRegion = index
    this.redrawOverlay()
  }

  leaveOverlay() {
    if (this.drag) return
    this.overlayCanvasTarget.style.cursor = ""
    if (this.hoverRegion !== null) {
      this.hoverRegion = null
      this.redrawOverlay()
    }
  }

  // === Region move / resize ===

  startRegionDrag(e) {
    if (e.button !== 0 || this.drag) return
    const pos = this.getCanvasPos(e)
    const grab = this.regionGrabAt(pos)
    if (!grab || grab.remove) return
    e.preventDefault() // no text selection while dragging

    this.drag = {
      page: this.currentPage,
      index: grab.index,
      edges: grab.edges,
      start: pos,
      original: { ...this.currentRegions()[grab.index] },
      moved: false
    }
    // Listen on window so the drag keeps going outside the canvas.
    this.boundDragMove = (ev) => this.moveRegionDrag(ev)
    this.boundDragEnd = () => this.endRegionDrag()
    window.addEventListener("mousemove", this.boundDragMove)
    window.addEventListener("mouseup", this.boundDragEnd)
  }

  moveRegionDrag(e) {
    const drag = this.drag
    if (!drag || drag.page !== this.currentPage) return
    const pos = this.getCanvasPos(e)
    const dx = pos.x - drag.start.x
    const dy = pos.y - drag.start.y
    if (!drag.moved && Math.hypot(dx, dy) < DRAG_THRESHOLD_PX) return
    drag.moved = true

    const region = this.currentRegions()[drag.index]
    if (!region) return
    const overlay = this.overlayCanvasTarget
    Object.assign(region, this.draggedRegion(drag, dx / overlay.width, dy / overlay.height))
    overlay.style.cursor = RESIZE_CURSORS[drag.edges] || "grabbing"
    this.hoverRegion = drag.index
    this.redrawOverlay()
  }

  // New normalized box for a drag offset (dx, dy as page fractions), kept on
  // the page and no smaller than MIN_REGION_PX.
  draggedRegion({ original: o, edges }, dx, dy) {
    const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)
    if (!edges) {
      return { x: clamp(o.x + dx, 0, 1 - o.w), y: clamp(o.y + dy, 0, 1 - o.h) }
    }
    const overlay = this.overlayCanvasTarget
    const minW = MIN_REGION_PX / overlay.width
    const minH = MIN_REGION_PX / overlay.height
    let left = o.x, top = o.y, right = o.x + o.w, bottom = o.y + o.h
    if (edges.includes("w")) left = clamp(left + dx, 0, right - minW)
    if (edges.includes("e")) right = clamp(right + dx, left + minW, 1)
    if (edges.includes("n")) top = clamp(top + dy, 0, bottom - minH)
    if (edges.includes("s")) bottom = clamp(bottom + dy, top + minH, 1)
    return { x: left, y: top, w: right - left, h: bottom - top }
  }

  async endRegionDrag() {
    this.stopDragListeners()
    const drag = this.drag
    this.drag = null
    // A plain click: the click event that follows recognizes the region.
    if (!drag?.moved) return

    // The click event fired right after this mouseup must not recognize.
    this.suppressClick = true
    setTimeout(() => { this.suppressClick = false }, 0)
    this.overlayCanvasTarget.style.cursor = ""

    const region = this.regionsByPage.get(drag.page)?.[drag.index]
    if (!region) return
    const ok = await this.saveRegion(drag.page, drag.index, region)
    if (!ok) {
      Object.assign(region, drag.original)
      if (drag.page === this.currentPage) this.redrawOverlay()
    }
  }

  // Optimistic soft delete (the entry stays, marked deleted, so the other
  // regions keep their indices); restored if the server refuses.
  async deleteRegion(pageNumber, index) {
    const region = this.regionsByPage.get(pageNumber)?.[index]
    if (!region || region.deleted) return
    region.deleted = true
    this.hoverRegion = null
    this.overlayCanvasTarget.style.cursor = ""
    this.redrawOverlay()

    try {
      const response = await fetch(`${this.regionsUrl(pageNumber)}/${index}`, {
        method: "DELETE",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
    } catch (err) {
      console.error(`Deleting text region ${pageNumber}:${index} failed:`, err)
      delete region.deleted
      if (pageNumber === this.currentPage) this.redrawOverlay()
    }
  }

  stopDragListeners() {
    if (this.boundDragMove) window.removeEventListener("mousemove", this.boundDragMove)
    if (this.boundDragEnd) window.removeEventListener("mouseup", this.boundDragEnd)
    this.boundDragMove = this.boundDragEnd = null
  }

  async saveRegion(pageNumber, index, region) {
    const round = (v) => Math.round(v * 1e5) / 1e5
    try {
      const response = await fetch(`${this.regionsUrl(pageNumber)}/${index}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: JSON.stringify({ region: { x: round(region.x), y: round(region.y), w: round(region.w), h: round(region.h) } })
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      return true
    } catch (err) {
      console.error(`Saving text region ${pageNumber}:${index} failed:`, err)
      return false
    }
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
    if (e.target.closest?.("input, textarea, select, [contenteditable]")) return
    if ((e.key === "Delete" || e.key === "Backspace") && this.hoverRegion !== null && !this.drag) {
      // Delete the free region under the mouse.
      if (this.isRegionFree(this.hoverRegion)) {
        e.preventDefault()
        this.deleteRegion(this.currentPage, this.hoverRegion)
      }
    } else if (e.key === "ArrowRight" || e.key === "ArrowDown") {
      e.preventDefault()
      this.nextPage()
    } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
      e.preventDefault()
      this.prevPage()
    }
  }

  // === Region click -> OCR into the buffer ===

  getCanvasPos(e) {
    const overlay = this.overlayCanvasTarget
    const rect = overlay.getBoundingClientRect()
    return {
      x: (e.clientX - rect.left) * (overlay.width / rect.width),
      y: (e.clientY - rect.top) * (overlay.height / rect.height)
    }
  }

  async clickRegion(e) {
    if (e.button !== 0 || this.suppressClick) return
    const grab = this.regionGrabAt(this.getCanvasPos(e))
    if (!grab) return
    if (grab.remove) {
      this.deleteRegion(this.currentPage, grab.index)
      return
    }
    const index = grab.index

    const page = this.currentPage
    const scale = this.scale
    const key = this.regionKey(page, index)
    const rect = this.regionToCanvasRect(this.currentRegions()[index], REGION_PADDING_PTS)

    // Optimistic: block a second click right away; the server dedupes too.
    this.bufferedRegions.set(key, "pending")
    this.overlayCanvasTarget.style.cursor = ""
    this.hoverRegion = null
    this.redrawOverlay()

    let payload
    if (this.serverHasPdf) {
      // Server-side path: send rect in PDF points; Go renderer crops at 300 DPI.
      // PDF.js renders at viewport.scale = this.scale, so 1 viewport pixel
      // corresponds to 1 / this.scale PDF user-space points. Origin matches:
      // both PDF.js viewport and the Go renderer treat top-left as (0, 0).
      payload = {
        rect_pts: { x: rect.x / scale, y: rect.y / scale, w: rect.w / scale, h: rect.h / scale }
      }
    } else {
      // Browser-side fallback: render the page at high DPI offscreen, crop,
      // ship the JPEG bitmap directly. Keeps the user productive while the
      // PDF is still uploading to the server.
      try {
        payload = { crop_data: await this.highDpiCropDataUrl(rect, page, scale) }
      } catch (err) {
        console.error("High-DPI browser crop failed:", err)
      }
    }

    const ok = payload && await this.submitOcr({ page_number: page, region_index: index, ...payload })
    if (!ok) {
      this.bufferedRegions.delete(key)
      this.redrawOverlay()
    }
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

  // Clears the overlay and draws the detected text regions of the current
  // page: regions already in the buffer are tinted green (dashed while being
  // recognized), the hovered free one is emphasized with resize handles.
  redrawOverlay() {
    const overlay = this.overlayCanvasTarget
    const ctx = overlay.getContext("2d")
    ctx.clearRect(0, 0, overlay.width, overlay.height)

    this.currentRegions().forEach((region, index) => {
      if (region.deleted) return
      const r = this.regionToCanvasRect(region)
      const status = this.bufferedRegions.get(this.regionKey(this.currentPage, index))

      if (status === "completed" || status === "pending" || status === "processing") {
        ctx.fillStyle = "rgba(76, 155, 96, 0.12)"
        ctx.fillRect(r.x, r.y, r.w, r.h)
        ctx.strokeStyle = "rgba(76, 155, 96, 0.8)"
        ctx.lineWidth = 1.5
        if (status !== "completed") ctx.setLineDash([6, 3])
        ctx.strokeRect(r.x, r.y, r.w, r.h)
        ctx.setLineDash([])
        return
      }

      const hovered = index === this.hoverRegion
      if (hovered) {
        ctx.fillStyle = "rgba(196, 69, 60, 0.12)"
        ctx.fillRect(r.x, r.y, r.w, r.h)
      }
      ctx.strokeStyle = hovered ? "rgba(196, 69, 60, 0.9)" : "rgba(196, 69, 60, 0.35)"
      ctx.lineWidth = hovered ? 2 : 1
      ctx.strokeRect(r.x, r.y, r.w, r.h)

      if (hovered) {
        // Corner handles: the box can be resized.
        ctx.fillStyle = "rgba(196, 69, 60, 0.9)"
        for (const [hx, hy] of [[r.x, r.y], [r.x + r.w, r.y], [r.x, r.y + r.h], [r.x + r.w, r.y + r.h]]) {
          ctx.fillRect(hx - HANDLE_PX / 2, hy - HANDLE_PX / 2, HANDLE_PX, HANDLE_PX)
        }
        if (!this.drag) this.drawDeleteButton(ctx, this.deleteButtonCenter(r))
      }
    })
  }

  drawDeleteButton(ctx, c) {
    const arm = DELETE_BTN_RADIUS_PX * 0.45
    ctx.beginPath()
    ctx.arc(c.x, c.y, DELETE_BTN_RADIUS_PX, 0, Math.PI * 2)
    ctx.fillStyle = "rgba(196, 69, 60, 0.95)"
    ctx.fill()
    ctx.beginPath()
    ctx.moveTo(c.x - arm, c.y - arm)
    ctx.lineTo(c.x + arm, c.y + arm)
    ctx.moveTo(c.x + arm, c.y - arm)
    ctx.lineTo(c.x - arm, c.y + arm)
    ctx.strokeStyle = "#fff"
    ctx.lineWidth = 1.5
    ctx.stroke()
  }

  // === OCR submission via Turbo Stream ===

  // Returns true when the server accepted the click (new fragment, retry, or
  // a region that was already in the buffer).
  async submitOcr(ocrRequest) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    try {
      const response = await fetch(this.ocrUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "text/vnd.turbo-stream.html"
        },
        body: JSON.stringify({ ocr_request: ocrRequest })
      })

      if (!response.ok) {
        console.error("OCR request failed:", response.status)
        return false
      }
      window.Turbo.renderStreamMessage(await response.text())
      return true
    } catch (err) {
      console.error("OCR submission error:", err)
      return false
    }
  }
}
