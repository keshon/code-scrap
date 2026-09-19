package tile

import (
	"container/list"
	"os"
	"sync"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/syntax"
)

// Source is a file's tokenized text.
type Source struct {
	Lines []string
	Segs  [][]syntax.Seg
	bytes int
}

// Texts is an LRU cache of tokenized files, bounded by total source bytes.
type Texts struct {
	m        *codemap.Map
	maxBytes int

	mu    sync.Mutex
	bytes int
	lru   *list.List // front = most recent; values are *textEntry
	byID  map[int32]*list.Element
}

type textEntry struct {
	file int32
	once sync.Once
	src  *Source
}

// NewTexts creates a cache holding up to maxBytes of source text.
func NewTexts(m *codemap.Map, maxBytes int) *Texts {
	return &Texts{m: m, maxBytes: maxBytes, lru: list.New(), byID: map[int32]*list.Element{}}
}

// Get returns the tokenized file, loading it on first use. It returns nil for
// files without text (binary, assets, secrets) or unreadable ones.
func (t *Texts) Get(fi int32) *Source {
	f := &t.m.Files[fi]
	if f.Class.Has(codemap.ClassBinary|codemap.ClassSecret) || f.Lines == 0 {
		return nil
	}
	t.mu.Lock()
	el, ok := t.byID[fi]
	if ok {
		t.lru.MoveToFront(el)
	} else {
		el = t.lru.PushFront(&textEntry{file: fi})
		t.byID[fi] = el
	}
	e := el.Value.(*textEntry)
	t.mu.Unlock()

	e.once.Do(func() {
		src, err := os.ReadFile(f.Abs)
		if err != nil {
			return
		}
		lines := syntax.SplitLines(src)
		e.src = &Source{Lines: lines, Segs: syntax.Tokenize(lines, f.Lang, true, nil), bytes: len(src)}
		t.mu.Lock()
		t.bytes += len(src)
		for t.bytes > t.maxBytes && t.lru.Len() > 1 {
			back := t.lru.Back()
			old := back.Value.(*textEntry)
			if old == e {
				break
			}
			t.lru.Remove(back)
			delete(t.byID, old.file)
			if old.src != nil {
				t.bytes -= old.src.bytes
			}
		}
		t.mu.Unlock()
	})
	return e.src
}
