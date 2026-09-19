package server

import (
	"context"
	"encoding/json"
	"log"
	"runtime"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/tile"
)

// session is one connected viewer. Tile requests go into a queue that each
// "tiles" message replaces, so a fast-moving camera never waits behind tiles
// it no longer needs.
type session struct {
	srv *Server
	c   *websocket.Conn
	ctx context.Context

	mu    sync.Mutex
	queue []tile.Key
	qgen  uint32 // state generation the queue was requested for
	q3D   bool   // queue holds 3D (extruded) tiles
	texts []textKey
	tgen  uint32
	wake  chan struct{}
}

func newSession(ctx context.Context, s *Server, c *websocket.Conn) *session {
	return &session{srv: s, c: c, ctx: ctx, wake: make(chan struct{}, 1)}
}

type textKey struct {
	file     int32
	col, seg int
}

type request struct {
	ID    int64         `json:"id"`
	Op    string        `json:"op"`
	Keys  [][3]int      `json:"keys"`
	Gen   uint32        `json:"gen"`
	Dim   int           `json:"dim"`
	Ray   [6]float64    `json:"ray"`   // origin xyz, direction xyz (world units, Y up)
	Pts   [][2]float64  `json:"pts"`   // ground points for "heights"
	Texts [][3]int      `json:"texts"` // text blocks: file node, column, segment
	View  *codemap.View `json:"view"`  // for "options"
	// also for "options": viewer settings that shape the served map
	Weights  map[string]float64 `json:"weights"`
	GitSince *string            `json:"gitSince"`
	Node     int32              `json:"node"`
	X        float64            `json:"x"`
	Y        float64            `json:"y"`
	Scale    float64            `json:"scale"`
	Q        string             `json:"q"`
	Page     int                `json:"page"`
	Size     int                `json:"size"`
	Path     string             `json:"path"`
}

func (ss *session) run(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	workers := max(2, runtime.NumCPU()-1)
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ss.tileWorker(ctx)
		}()
	}
	for {
		typ, data, err := ss.c.Read(ctx)
		if err != nil {
			break
		}
		if typ != websocket.MessageText {
			continue
		}
		var req request
		if err := json.Unmarshal(data, &req); err != nil {
			continue
		}
		if req.Op == "tiles" {
			ss.setQueue(req)
			continue
		}
		if req.Op == "texts" {
			ss.setTexts(req)
			continue
		}
		if req.Op == "font" {
			go ss.writeBinary(encodeFont(ss.srv.Atlas))
			continue
		}
		go ss.handle(req)
	}
	cancel()
	wg.Wait()
}

func (ss *session) setQueue(req request) {
	keys := make([]tile.Key, 0, len(req.Keys))
	for _, k := range req.Keys {
		if k[0] >= 0 && k[0] <= tile.MaxZ {
			keys = append(keys, tile.Key{Z: k[0], X: k[1], Y: k[2]})
		}
	}
	ss.mu.Lock()
	ss.queue = keys // viewer orders them center-first
	ss.qgen = req.Gen
	ss.q3D = req.Dim == 3
	ss.mu.Unlock()
	for range min(len(keys), cap(ss.wake)+1) {
		select {
		case ss.wake <- struct{}{}:
		default:
		}
	}
}

func (ss *session) setTexts(req request) {
	keys := make([]textKey, 0, len(req.Texts))
	for _, k := range req.Texts {
		keys = append(keys, textKey{int32(k[0]), k[1], k[2]})
	}
	ss.mu.Lock()
	ss.texts = keys
	ss.tgen = req.Gen
	ss.mu.Unlock()
	select {
	case ss.wake <- struct{}{}:
	default:
	}
}

// work is one queued job: a tile, or (when no tiles wait) a text block.
type work struct {
	tile tile.Key
	is3D bool
	text *textKey
	gen  uint32
}

func (ss *session) next() (work, bool) {
	ss.mu.Lock()
	defer ss.mu.Unlock()
	if len(ss.queue) > 0 {
		k := ss.queue[0]
		ss.queue = ss.queue[1:]
		return work{tile: k, is3D: ss.q3D, gen: ss.qgen}, true
	}
	if len(ss.texts) > 0 {
		k := ss.texts[0]
		ss.texts = ss.texts[1:]
		return work{text: &k, gen: ss.tgen}, true
	}
	return work{}, false
}

func (ss *session) tileWorker(ctx context.Context) {
	for {
		w, ok := ss.next()
		if !ok {
			select {
			case <-ctx.Done():
				return
			case <-ss.wake:
				continue
			case <-time.After(50 * time.Millisecond):
				continue
			}
		}
		st := ss.srv.cur.Load()
		if st == nil || st.gen != w.gen {
			continue // requested against a map that has been replaced
		}
		if w.text != nil {
			if b := encodeText(st, *w.text); b != nil {
				ss.writeBinary(b)
			}
			continue
		}
		ss.writeBinary(encodeTile(st, w.tile, w.is3D))
	}
}

func (ss *session) handle(req request) {
	st := ss.srv.cur.Load()
	var resp any
	switch req.Op {
	case "hello":
		if st != nil {
			resp = hello(st)
		}
	case "node":
		if st != nil {
			resp = nodeInfo(st, req.Node)
		}
	case "pick":
		if st != nil {
			resp = pick(st, req.X, req.Y, req.Scale)
		}
	case "options":
		if req.View != nil {
			go ss.srv.SetView(*req.View)
		}
		if req.Weights != nil {
			go ss.srv.SetWeights(req.Weights)
		}
		if req.GitSince != nil {
			ss.srv.SetGitSince(*req.GitSince)
		}
		return
	case "edges", "calls":
		if st != nil {
			resp = relations(st, req.Op, req.Node)
		}
	case "pickRay":
		if st != nil {
			resp = pickRay(st, req.Ray)
		}
	case "heights":
		if st != nil {
			hs := make([]float64, len(req.Pts))
			for i, p := range req.Pts {
				hs[i] = st.m.HeightAt(p[0], p[1])
			}
			resp = map[string]any{"op": "heights", "h": hs}
		}
	case "search":
		if st != nil {
			resp = search(st, req.Q, req.Page, req.Size)
		}
	case "open":
		go func() {
			if err := ss.srv.Open(req.Path); err != nil {
				ss.writeJSON(map[string]any{"op": "error", "id": req.ID, "error": err.Error()})
			}
		}()
		return
	default:
		resp = map[string]any{"op": "error", "error": "unknown op " + req.Op}
	}
	if resp == nil {
		resp = map[string]any{"op": "error", "error": "no map loaded"}
	}
	// echo the request id so the viewer can match replies
	if m, ok := resp.(map[string]any); ok {
		m["id"] = req.ID
	}
	ss.writeJSON(resp)
}

func (ss *session) writeJSON(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("encode: %v", err)
		return
	}
	ss.writeText(b)
}

func (ss *session) writeText(b []byte) {
	ss.c.Write(ss.ctx, websocket.MessageText, b)
}

func (ss *session) writeBinary(b []byte) {
	ss.c.Write(ss.ctx, websocket.MessageBinary, b)
}
