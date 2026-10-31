package render

import (
	"os"
	"testing"
)

// Rasterization re-executes the current binary as a MuPDF child process. In
// tests that binary is the test binary, so it has to answer the child call
// too.
func TestMain(m *testing.M) {
	MaybeRunChild()
	os.Exit(m.Run())
}
