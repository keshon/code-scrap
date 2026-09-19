package codemap

import (
	"crypto/sha1"
	"encoding/gob"
	"encoding/hex"
	"os"
	"path/filepath"
	"sync"

	"github.com/keshon/code-scrap/scrap/internal/syntax"
)

// cacheVersion changes whenever analysis results change shape or meaning;
// an old cache is then ignored.
const cacheVersion = 3

// FileCache keeps per-file analysis results between runs, keyed by path,
// size and modification time, so restarts and re-indexes only parse files
// that changed. Safe for concurrent use.
type FileCache struct {
	path    string
	mu      sync.Mutex
	entries map[string]cacheEntry
	dirty   bool
}

type cacheEntry struct {
	Size, Mod int64
	Pass      uint8 // 1 fast, 2 precise attempted
	Class     FileClass
	Lines     int32
	Precise   bool
	Scopes    []syntax.Scope
	Decls     []syntax.Decl
	Imports   []string
	Calls     [][]string
}

type cacheFile struct {
	Version int
	Entries map[string]cacheEntry
}

// CacheDir is where caches for a repository root live: the user's cache
// folder, then code-scrap, then a hash of the root path.
func CacheDir(root string) string {
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	abs, _ := filepath.Abs(root)
	sum := sha1.Sum([]byte(filepath.ToSlash(abs)))
	return filepath.Join(base, "code-scrap", hex.EncodeToString(sum[:8]))
}

// LoadFileCache reads the cache of a repository (an empty one if there is
// none or it is from another version).
func LoadFileCache(root string) *FileCache {
	c := &FileCache{path: filepath.Join(CacheDir(root), "files.gob"), entries: map[string]cacheEntry{}}
	f, err := os.Open(c.path)
	if err != nil {
		return c
	}
	defer f.Close()
	var cf cacheFile
	if gob.NewDecoder(f).Decode(&cf) == nil && cf.Version == cacheVersion && cf.Entries != nil {
		c.entries = cf.Entries
	}
	return c
}

// Save writes the cache if it changed.
func (c *FileCache) Save() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.dirty {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(c.path), 0o755); err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := gob.NewEncoder(f).Encode(cacheFile{Version: cacheVersion, Entries: c.entries}); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	c.dirty = false
	return os.Rename(tmp, c.path)
}

// get fills f from the cache when its size and time match and the cached
// pass is at least as thorough as the one asked for.
func (c *FileCache) get(f *rawFile, mod int64, precise bool) bool {
	if c == nil {
		return false
	}
	c.mu.Lock()
	e, ok := c.entries[f.path]
	c.mu.Unlock()
	if !ok || e.Size != f.size || e.Mod != mod || (precise && e.Pass < 2) {
		return false
	}
	f.class, f.lines, f.precise = e.Class, e.Lines, e.Precise
	f.scopes, f.decls, f.imports, f.calls = e.Scopes, e.Decls, e.Imports, e.Calls
	return true
}

func (c *FileCache) put(f *rawFile, mod int64, precise bool) {
	if c == nil {
		return
	}
	pass := uint8(1)
	if precise {
		pass = 2
	}
	c.mu.Lock()
	if old, ok := c.entries[f.path]; ok && old.Pass > pass && old.Size == f.size && old.Mod == mod {
		c.mu.Unlock()
		return // keep the more thorough result
	}
	c.entries[f.path] = cacheEntry{Size: f.size, Mod: mod, Pass: pass, Class: f.class, Lines: f.lines,
		Precise: f.precise, Scopes: f.scopes, Decls: f.decls, Imports: f.imports, Calls: f.calls}
	c.dirty = true
	c.mu.Unlock()
}
