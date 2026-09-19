package tile

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
)

// Text block keys must survive a rebuild (fast pass → precise pass) when the
// text did not change, and differ when the column layout does: viewers keep
// already-loaded text across generations by this key.
func TestTextKeyStable(t *testing.T) {
	root := t.TempDir()
	src := strings.Repeat("export function f() {\n  return 1\n}\n", 40)
	for _, p := range []string{"a/one.ts", "b/two.ts", "b/three.go"} {
		abs := filepath.Join(root, filepath.FromSlash(p))
		os.MkdirAll(filepath.Dir(abs), 0o755)
		if err := os.WriteFile(abs, []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	fast, err := codemap.Build(root, codemap.Options{NoGit: true})
	if err != nil {
		t.Fatal(err)
	}
	precise, err := codemap.Build(root, codemap.Options{NoGit: true, Precise: true})
	if err != nil {
		t.Fatal(err)
	}
	keys := map[string]uint32{}
	for i := range fast.Files {
		f := &fast.Files[i]
		keys[f.Path] = TextKey(f, 0, 0)
	}
	for i := range precise.Files {
		f := &precise.Files[i]
		if k := TextKey(f, 0, 0); k != keys[f.Path] {
			t.Errorf("%s: key changed across passes (%d → %d)", f.Path, keys[f.Path], k)
		}
		if TextKey(f, 0, 0) == TextKey(f, 1, 0) {
			t.Errorf("%s: columns share a key", f.Path)
		}
	}
}
