// Server-side PDF sync. The Go render service reads PDFs from disk under
// PDF_ROOT_DIR; the browser keeps copies in IndexedDB. This module bridges
// the two: HEAD checks whether the server already has the file, PUT uploads it.

function csrfToken() {
  return document.querySelector("meta[name='csrf-token']")?.content
}

export async function pdfExistsOnServer(documentId) {
  const res = await fetch(`/documents/${documentId}/pdf`, { method: "HEAD" })
  return res.status === 200
}

export async function uploadPdfToServer(documentId, arrayBuffer) {
  const res = await fetch(`/documents/${documentId}/pdf`, {
    method: "PUT",
    headers: {
      "Content-Type": "application/pdf",
      "X-CSRF-Token": csrfToken()
    },
    body: arrayBuffer
  })
  if (!res.ok) {
    throw new Error(`PDF upload failed: HTTP ${res.status}`)
  }
}

// One-time sync: upload only if the server doesn't have the file yet.
export async function ensurePdfOnServer(documentId, arrayBuffer) {
  if (await pdfExistsOnServer(documentId)) return false
  await uploadPdfToServer(documentId, arrayBuffer)
  return true
}
