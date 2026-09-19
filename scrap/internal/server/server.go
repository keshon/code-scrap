// Package server exposes a code map to viewers over a local WebSocket:
// JSON for control messages, binary frames for tiles.
package server

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/tile"
)

// TextCacheBytes bounds the tokenized source kept in memory for code tiles.
const TextCacheBytes = 512 << 20

// state is one indexed map plus its renderer. It is replaced wholesale when
// the precise pass finishes or another folder is opened.
type state struct {
	gen      uint32 // bumps on every replacement; tiles carry it
	m        *codemap.Map
	renderer *tile.Renderer
	precise  bool
}

// Server indexes one root at a time and serves it.
type Server struct {
	Options codemap.Options
	Atlas   *tile.Atlas // glyph atlas for GPU text; sets the layout's char aspect

	cur      atomic.Pointer[state]
	gen      atomic.Uint32
	mu       sync.Mutex // guards sessions and indexing
	sessions map[*session]bool
	root     string
	indexing context.CancelFunc
	progress atomic.Value // last progress message (map[string]any)
}

// New creates a server; call Open to index a root. fontPath selects the
// code font ("" = the platform's IDE font, e.g. Consolas on Windows).
func New(opt codemap.Options, fontPath string) (*Server, error) {
	atlas, err := tile.LoadAtlas(fontPath)
	if err != nil {
		return nil, err
	}
	opt.CharAspect = atlas.CharAspect()
	log.Printf("code font: %s (%d glyphs, %dx%d cells)", fontName(atlas.Font), len(atlas.Runes), atlas.CellW, atlas.CellH)
	return &Server{Options: opt, Atlas: atlas, sessions: map[*session]bool{}}, nil
}

func fontName(f string) string {
	if f == "" {
		return "Go Mono (embedded)"
	}
	return f
}

// Open indexes root: a fast pass first (served as soon as it's ready), then
// the precise tree-sitter pass in the background.
func (s *Server) Open(root string) error {
	s.mu.Lock()
	if s.indexing != nil {
		s.indexing()
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.indexing = cancel
	s.root = root
	s.mu.Unlock()

	fast := s.Options
	fast.Precise = false
	fast.Progress = s.progressFn("fast")
	m, err := codemap.Build(root, fast)
	if err != nil {
		return err
	}
	s.install(m, false)
	log.Printf("fast index: %d files, %d lines, %d scopes in %d ms", m.Stats.Files, m.Stats.Lines, m.Stats.Scopes, m.Stats.IndexMs)

	go func() {
		precise := s.Options
		precise.Precise = true
		precise.Progress = s.progressFn("precise")
		pm, err := codemap.Build(root, precise)
		if err != nil || ctx.Err() != nil {
			return
		}
		s.install(pm, true)
		log.Printf("precise index: %d/%d files parsed, %d scopes in %d ms", pm.Stats.PreciseFiles, pm.Stats.Files, pm.Stats.Scopes, pm.Stats.IndexMs)
	}()
	return nil
}

func (s *Server) progressFn(pass string) codemap.Progress {
	var last atomic.Int64
	return func(phase string, done, total int) {
		now := time.Now().UnixMilli()
		if prev := last.Load(); now-prev < 200 && done != total {
			return
		}
		last.Store(now)
		msg := map[string]any{"op": "progress", "pass": pass, "phase": phase, "done": done, "total": total}
		s.progress.Store(msg)
		s.broadcast(msg)
	}
}

func (s *Server) install(m *codemap.Map, precise bool) {
	st := &state{gen: s.gen.Add(1), m: m, renderer: tile.NewRenderer(m, s.Atlas, TextCacheBytes), precise: precise}
	s.cur.Store(st)
	s.broadcast(hello(st))
}

func (s *Server) broadcast(msg any) {
	b, err := json.Marshal(msg)
	if err != nil {
		return
	}
	s.mu.Lock()
	list := make([]*session, 0, len(s.sessions))
	for ss := range s.sessions {
		list = append(list, ss)
	}
	s.mu.Unlock()
	for _, ss := range list {
		ss.writeText(b)
	}
}

// Handler returns the HTTP handler serving the WebSocket API at /ws.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("scrap: connect a viewer to /ws\n"))
	})
	return mux
}

// ListenAndServe serves the WebSocket API at ws://addr/ws.
func (s *Server) ListenAndServe(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	log.Printf("serving on ws://%s/ws", ln.Addr())
	return http.Serve(ln, s.Handler())
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: []string{"localhost", "127.0.0.1"}})
	if err != nil {
		return
	}
	c.SetReadLimit(1 << 20)
	ss := newSession(r.Context(), s, c)
	s.mu.Lock()
	s.sessions[ss] = true
	s.mu.Unlock()
	if st := s.cur.Load(); st != nil {
		ss.writeJSON(hello(st))
	}
	if p := s.progress.Load(); p != nil {
		ss.writeJSON(p)
	}
	ss.run(r.Context())
	s.mu.Lock()
	delete(s.sessions, ss)
	s.mu.Unlock()
	c.CloseNow()
}
