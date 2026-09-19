package server

import (
	"context"
	"log"
	"os"
	"time"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/gitlog"
)

type stamp struct{ size, mod int64 }

// watch polls the open repository and re-indexes when files change: sizes
// and times of mapped files every couple of seconds, the file list and the
// git HEAD less often. Unchanged files come from the cache, so a re-index
// costs about as much as the files that changed.
func (s *Server) watch(ctx context.Context, root string, m *codemap.Map) {
	const every = 2 * time.Second
	known := stamps(m)
	count := len(codemap.ListFiles(root, s.Options.NoGit))
	head := gitlog.Head(ctx, root)
	tick := time.NewTicker(every)
	defer tick.Stop()
	for n := 1; ; n++ {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		changed := false
		for i := range m.Files {
			f := &m.Files[i]
			var cur stamp
			if st, err := os.Stat(f.Abs); err == nil {
				cur = stamp{st.Size(), st.ModTime().UnixNano()}
			}
			if cur != known[f.Path] {
				changed = true
				break
			}
		}
		if n%5 == 0 {
			if !changed {
				changed = len(codemap.ListFiles(root, s.Options.NoGit)) != count
			}
			if h := gitlog.Head(ctx, root); h != head {
				head = h
				log.Printf("watch: new HEAD, re-reading git history")
				s.startGit()
			}
		}
		if !changed {
			continue
		}
		// let a burst of saves settle, then re-index from the cache
		time.Sleep(400 * time.Millisecond)
		if ctx.Err() != nil {
			return
		}
		nm, err := s.reindex(root)
		if err != nil || ctx.Err() != nil {
			continue
		}
		m = nm
		known = stamps(m)
		count = len(codemap.ListFiles(root, s.Options.NoGit))
	}
}

func stamps(m *codemap.Map) map[string]stamp {
	out := make(map[string]stamp, len(m.Files))
	for i := range m.Files {
		if st, err := os.Stat(m.Files[i].Abs); err == nil {
			out[m.Files[i].Path] = stamp{st.Size(), st.ModTime().UnixNano()}
		}
	}
	return out
}

// reindex rebuilds the precise map, reusing the cache, and installs it.
func (s *Server) reindex(root string) (*codemap.Map, error) {
	s.mu.Lock()
	cache := s.cache
	s.mu.Unlock()
	opt := s.Options
	opt.Precise = true
	opt.Cache = cache
	opt.Progress = s.progressFn("precise")
	t := time.Now()
	m, err := codemap.Build(root, opt)
	if err != nil {
		return nil, err
	}
	s.setBase(m, true)
	log.Printf("watch: re-indexed %d files in %d ms", m.Stats.Files, time.Since(t).Milliseconds())
	if err := cache.Save(); err != nil {
		log.Printf("cache: %v", err)
	}
	return m, nil
}
