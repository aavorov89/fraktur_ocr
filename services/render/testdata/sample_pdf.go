package testdata

import (
	"bytes"
	"fmt"
)

// BuildMinimalPDF returns a single-page PDF whose MediaBox is widthPts x heightPts
// (PDF user-space points, 72/in). The byte offsets in the xref table are tracked
// as objects are appended so the resulting file is always valid regardless of
// MediaBox dimensions.
func BuildMinimalPDF(widthPts, heightPts int) []byte {
	var buf bytes.Buffer
	offsets := make([]int, 0, 6)

	write := func(s string) {
		offsets = append(offsets, buf.Len())
		buf.WriteString(s)
	}

	buf.WriteString("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")

	write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
	write("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
	write(fmt.Sprintf(
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Contents 4 0 R "+
			"/Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
		widthPts, heightPts,
	))
	stream := fmt.Sprintf("BT /F1 24 Tf 50 %d Td (Hello Fraktur) Tj ET\n", heightPts-50)
	write(fmt.Sprintf("4 0 obj\n<< /Length %d >>\nstream\n%sendstream\nendobj\n", len(stream), stream))
	write("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n")

	xrefOffset := buf.Len()
	buf.WriteString("xref\n0 6\n")
	buf.WriteString("0000000000 65535 f \n")
	for _, off := range offsets {
		fmt.Fprintf(&buf, "%010d 00000 n \n", off)
	}
	fmt.Fprintf(&buf, "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", xrefOffset)
	return buf.Bytes()
}
