package codemap

import (
	"encoding/gob"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/keshon/code-scrap/scrap/internal/syntax"
)

// fixture writes a small repository into a temp dir and builds its map
// (no git, so the walk is the file system's).
func fixture(t *testing.T, precise bool) *Map {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{
		"src/a.ts": `import { helper } from './b'

export function main() {
  return helper(1) + local()
}

function local() {
  return 2
}
`,
		"src/b.ts": `export function helper(x: number) {
  if (x > 0) {
    return x + 1
  }
  return 0
}
`,
		"src/b.test.ts":     "import { helper } from './b'\n\ntest('helper', () => {\n  expect(helper(1)).toBe(2)\n})\n",
		"vendor/lib.js":     "function vendored() { return 1 }\n",
		"config/app.json":   "{\n  \"name\": \"fixture\"\n}\n",
		"assets/logo.png":   "\x89PNG\r\n\x1a\n not really an image",
		".env":              "TOKEN=do-not-read\n",
		"docs/readme.md":    "# Fixture\n\nA tiny repository for tests.\n",
		"src/deep/c/d/e.ts": "export const e = 1\n",
	}
	for p, body := range files {
		abs := filepath.Join(root, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(abs, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	m, err := Build(root, Options{NoGit: true, Precise: precise})
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func fileByPath(t *testing.T, m *Map, p string) *File {
	t.Helper()
	for i := range m.Files {
		if m.Files[i].Path == p {
			return &m.Files[i]
		}
	}
	t.Fatalf("file %s not in map", p)
	return nil
}

func scopeNamed(t *testing.T, m *Map, name string) int32 {
	t.Helper()
	for i, n := range m.Nodes {
		if n.Kind == KindScope && n.Name == name {
			return int32(i)
		}
	}
	t.Fatalf("scope %s not in map", name)
	return -1
}

func TestClassify(t *testing.T) {
	cases := []struct {
		path string
		want FileClass
		not  FileClass
	}{
		{"src/app.ts", 0, ClassTest | ClassVendored | ClassData | ClassAsset | ClassSecret},
		{"src/app.test.ts", ClassTest, ClassVendored},
		{"pkg/server_test.go", ClassTest, 0},
		{"e2e/login.spec.ts", ClassTest, 0},
		{"vendor/github.com/x/y.go", ClassVendored, ClassTest},
		{"public/js/jquery.min.js", ClassVendored, 0},
		{"config/app.json", ClassData, ClassTest},
		{"assets/logo.png", ClassAsset, 0},
		{".env", ClassSecret | ClassBinary, 0},
		{".env.production", ClassSecret, 0},
		{"certs/server.pem", ClassSecret, 0},
		{".npmrc", ClassSecret, 0},
		{"config/secrets.yaml", ClassSecret, 0},
		{"src/PasswordInput.tsx", 0, ClassSecret}, // code that mentions passwords is fine
	}
	for _, c := range cases {
		got := Classify(c.path, syntax.For(baseName(c.path)))
		if got&c.want != c.want || got&c.not != 0 {
			t.Errorf("Classify(%q) = %b, want %b set and %b clear", c.path, got, c.want, c.not)
		}
	}
}

func baseName(p string) string { return p[strings.LastIndex(p, "/")+1:] }

func TestSecretsNeverRead(t *testing.T) {
	m := fixture(t, false)
	f := fileByPath(t, m, ".env")
	if !f.Class.Has(ClassSecret) || f.Lines != 0 {
		t.Errorf(".env: class %b, %d lines; want secret and unread", f.Class, f.Lines)
	}
	for _, s := range m.Symbols {
		if strings.Contains(s.Name, "TOKEN") {
			t.Errorf("secret content leaked into symbols: %q", s.Name)
		}
	}
}

// Every child lies inside its parent and siblings never overlap.
func TestLayoutNests(t *testing.T) {
	m := fixture(t, false)
	const eps = 1e-9
	inside := func(a, b Rect) bool {
		return a.X >= b.X-eps && a.Y >= b.Y-eps && a.X+a.W <= b.X+b.W+eps && a.Y+a.H <= b.Y+b.H+eps
	}
	overlap := func(a, b Rect) bool {
		return a.X+eps < b.X+b.W && b.X+eps < a.X+a.W && a.Y+eps < b.Y+b.H && b.Y+eps < a.Y+a.H
	}
	for i, n := range m.Nodes {
		if n.Kind == KindScope {
			continue // scopes are text-flow bounds, not treemap cells
		}
		var boxes []Rect
		for _, c := range n.Children {
			cn := &m.Nodes[c]
			if cn.Kind == KindScope {
				continue
			}
			if cn.Rect.W <= 0 || cn.Rect.H <= 0 {
				t.Errorf("%s: empty rect %v", m.Path(c), cn.Rect)
			}
			if !inside(cn.Rect, n.Rect) {
				t.Errorf("%s %v is outside its parent %s %v", m.Path(c), cn.Rect, m.Path(int32(i)), n.Rect)
			}
			for _, b := range boxes {
				if overlap(cn.Rect, b) {
					t.Errorf("%s overlaps a sibling", m.Path(c))
				}
			}
			boxes = append(boxes, cn.Rect)
		}
	}
}

func TestImportsResolve(t *testing.T) {
	m := fixture(t, false)
	a := fileByPath(t, m, "src/a.ts")
	b := fileByPath(t, m, "src/b.ts")
	out, _, _, _ := m.DepsOf(a.Node, 10)
	found := false
	for _, e := range out {
		if e.To == b.Node {
			found = true
		}
	}
	if !found {
		t.Errorf("src/a.ts should import src/b.ts; edges %v", out)
	}
	_, in, _, inTotal := m.DepsOf(b.Node, 10)
	if inTotal != 2 || len(in) != 2 {
		t.Errorf("src/b.ts should be imported by a.ts and b.test.ts; got %d", inTotal)
	}
}

func TestCallsResolve(t *testing.T) {
	for _, precise := range []bool{false, true} {
		m := fixture(t, precise)
		mainFn := scopeNamed(t, m, "main")
		out, _, _, _ := m.CallsOf(mainFn, 10)
		names := map[string]bool{}
		for _, e := range out {
			names[m.Nodes[e.To].Name] = true
		}
		if !names["helper"] || !names["local"] {
			t.Errorf("precise=%v: main should call helper (imported) and local; got %v", precise, names)
		}
	}
}

func TestImportanceWeights(t *testing.T) {
	m := fixture(t, false)
	test := fileByPath(t, m, "src/b.test.ts").Node
	area := func(v View) float64 {
		r := m.WithView(v).Nodes[test].Rect
		return r.W * r.H
	}
	plain := area(View{})
	def := area(View{Importance: true})
	custom := area(View{Importance: true, Weights: map[string]float64{"test": 1}})
	if !(def < plain) {
		t.Errorf("importance should shrink tests: %g vs %g", def, plain)
	}
	if !(custom > def) {
		t.Errorf("a test weight of 1 should give tests back their area: %g vs %g", custom, def)
	}
}

func TestSearchFindsDeclarations(t *testing.T) {
	m := fixture(t, false)
	res := m.Search("hel", 0, 10)
	if res.Total == 0 {
		t.Fatal("no hits for 'hel'")
	}
	for _, h := range res.Hits {
		if !strings.HasPrefix(strings.ToLower(h.Name), "hel") {
			t.Errorf("hit %q does not match the prefix", h.Name)
		}
	}
}

func TestLegendData(t *testing.T) {
	m := fixture(t, false)
	areas := m.Areas()
	if len(areas) < 4 || areas[0].Name != "src" {
		t.Errorf("areas should list top-level folders, src first; got %+v", areas)
	}
	q := m.Quantiles(MetricLines)
	if len(q) != 5 || q[0] > q[4] || q[0] <= 0 {
		t.Errorf("line quantiles %v", q)
	}
	if m.Quantiles(MetricChurn) != nil {
		t.Error("no git: churn has no quantiles")
	}
	for _, l := range append(HeightLenses(), ColorLenses()...) {
		if l.ID == "" || l.Short == "" || l.Long == "" || l.Desc == "" {
			t.Errorf("incomplete lens %+v", l)
		}
	}
}

func TestFindPathsAndChildren(t *testing.T) {
	m := fixture(t, false)
	hits, total := m.FindPaths("b.t", 10)
	if total < 2 || m.Path(hits[0].Node) != "src/b.ts" {
		t.Errorf("b.t: want src/b.ts first; got %d hits, first %s", total, m.Path(hits[0].Node))
	}
	hits, _ = m.FindPaths("src deep", 10)
	if len(hits) == 0 || !strings.HasPrefix(m.Path(hits[0].Node), "src/deep") {
		t.Errorf("multi-term search failed: %v", hits)
	}
	kids := m.Children(0)
	if len(kids) == 0 || m.Nodes[kids[0]].Kind != KindDir {
		t.Fatal("root children should start with directories")
	}
	for i := 1; i < len(kids); i++ {
		a, b := &m.Nodes[kids[i-1]], &m.Nodes[kids[i]]
		if a.Kind == b.Kind && strings.ToLower(a.Name) > strings.ToLower(b.Name) {
			t.Errorf("children out of order: %s before %s", a.Name, b.Name)
		}
	}
}

func TestLookup(t *testing.T) {
	m := fixture(t, false)
	b := fileByPath(t, m, "src/b.ts")
	if m.Lookup("src/b.ts") != b.Node || m.Lookup("src") < 0 || m.Lookup("nope") != -1 || m.Lookup("") != 0 {
		t.Error("Lookup by path failed")
	}
}

func TestImportanceRules(t *testing.T) {
	rules, err := ParseRules("src/**/*.test.ts = 0.9; vendor/** = 1; **/e.ts=0.2")
	if err != nil || len(rules) != 3 {
		t.Fatalf("ParseRules: %v %v", rules, err)
	}
	for _, c := range []struct {
		i    int
		p    string
		want bool
	}{
		{0, "src/b.test.ts", true}, {0, "src/deep/x.test.ts", true}, {0, "b.test.ts", false},
		{1, "vendor/lib.js", true}, {2, "src/deep/c/d/e.ts", true}, {2, "e.ts", true}, {2, "src/e.tsx", false},
	} {
		if rules[c.i].Match(c.p) != c.want {
			t.Errorf("%s ~ %s: want %v", rules[c.i].Glob, c.p, c.want)
		}
	}
	m := fixture(t, false)
	test := fileByPath(t, m, "src/b.test.ts").Node
	area := func(v View) float64 { r := m.WithView(v).Nodes[test].Rect; return r.W * r.H }
	if !(area(View{Importance: true, Rules: rules}) > area(View{Importance: true})) {
		t.Error("a rule weight of 0.9 should give the test file more room than the class weight")
	}
	if _, err := ParseRules("nonsense"); err == nil {
		t.Error("want an error for a rule without =")
	}
}

func TestFileCache(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "a.go"), []byte("package a\n\nfunc F() int {\n\treturn 1\n}\n"), 0o644)
	c := &FileCache{path: filepath.Join(t.TempDir(), "files.gob"), entries: map[string]cacheEntry{}}
	m1, err := Build(root, Options{NoGit: true, Precise: true, Cache: c})
	if err != nil {
		t.Fatal(err)
	}
	if len(c.entries) != 1 || c.entries["a.go"].Pass != 2 {
		t.Fatalf("cache not filled: %+v", c.entries)
	}
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	// a fast build now gets the precise result from the cache
	c2 := &FileCache{path: c.path}
	f, _ := os.Open(c.path)
	var cf cacheFile
	if err := gob.NewDecoder(f).Decode(&cf); err != nil || cf.Version != cacheVersion {
		t.Fatalf("saved cache unreadable: %v", err)
	}
	f.Close()
	c2.entries = cf.Entries
	m2, err := Build(root, Options{NoGit: true, Cache: c2})
	if err != nil {
		t.Fatal(err)
	}
	if !m2.Files[0].Precise || len(m2.Files[0].Scopes) != len(m1.Files[0].Scopes) {
		t.Error("fast build should reuse the cached precise scopes")
	}
	// a changed file is parsed again
	os.WriteFile(filepath.Join(root, "a.go"), []byte("package a\n\nfunc F() int {\n\treturn 1\n}\n\nfunc G() int {\n\treturn 2\n}\n"), 0o644)
	m3, _ := Build(root, Options{NoGit: true, Precise: true, Cache: c2})
	if len(m3.Files[0].Scopes) != 2 {
		t.Errorf("changed file should be re-parsed: %d scopes", len(m3.Files[0].Scopes))
	}
}

func TestLayoutOrders(t *testing.T) {
	m := fixture(t, false)
	// DirsFirst composes with either order; OrderKind is the old spelling
	// of name + folders first and must still mean that.
	for _, v := range []View{{Order: OrderKind}, {Order: OrderName, DirsFirst: true},
		{Order: OrderSize, DirsFirst: true}, {Order: OrderName, Algorithm: LayoutStrip}, {Algorithm: LayoutStrip}} {
		nm := m.WithView(v)
		root := &nm.Nodes[0]
		if v.Order == OrderKind || v.DirsFirst {
			seenFile := false
			for _, c := range root.Children {
				if nm.Nodes[c].Kind == KindFile {
					seenFile = true
				} else if seenFile {
					t.Errorf("folders first: %s after a file", nm.Nodes[c].Name)
				}
			}
		}
		if v.Order == OrderName && !v.DirsFirst && v.Algorithm == "" {
			for i := 1; i < len(root.Children); i++ {
				a, b := nm.Nodes[root.Children[i-1]].Name, nm.Nodes[root.Children[i]].Name
				if strings.ToLower(a) > strings.ToLower(b) {
					t.Errorf("plain alphabetical: %s before %s", a, b)
				}
			}
		}
		if v.Algorithm == LayoutStrip && v.Order == OrderName {
			// reading order: each child starts right of or below the previous
			for i := 1; i < len(root.Children); i++ {
				a, b := nm.Nodes[root.Children[i-1]].Rect, nm.Nodes[root.Children[i]].Rect
				if b.Y == a.Y && b.X < a.X {
					t.Errorf("strip order broken at %s", nm.Nodes[root.Children[i]].Name)
				}
			}
		}
	}
}

func TestGutter(t *testing.T) {
	m := fixture(t, false)
	plain := fileByPath(t, m, "src/a.ts")
	nm := m.WithView(View{LineNumbers: true})
	var f *File
	for i := range nm.Files {
		if nm.Files[i].Path == "src/a.ts" {
			f = &nm.Files[i]
		}
	}
	if plain.Gutter != 2 || f.Gutter != 7 {
		t.Fatalf("gutter %d / %d, want 2 / 7", plain.Gutter, f.Gutter)
	}
	if lr := f.LineRect(0); lr.X < f.TX+6*f.CW {
		t.Errorf("code starts inside the line-number gutter: %g < %g", lr.X, f.TX+6*f.CW)
	}
}
