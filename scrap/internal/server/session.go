package server

import (
	"context"
	"encoding/json"
	"log"
	"runtime"
	"sync"
	"time"

	"github.com/coder/websocket"

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
	wake  chan struct{}
}

func newSession(ctx context.Context, s *Server, c *websocket.Conn) *session {
	return &session{srv: s, c: c, ctx: ctx, wake: make(chan struct{}, 1)}
}

type request struct {
	ID    int64    `json:"id"`
	Op    string   `json:"op"`
	Keys  [][3]int `json:"keys"`
	Gen   uint32   `json:"gen"`
	Node  int32    `json:"node"`
	X     float64  `json:"x"`
	Y     float64  `json:"y"`
	Scale float64  `json:"scale"`
	Q     string   `json:"q"`
	Page  int      `json:"page"`
	Size  int      `json:"size"`
	Path  string   `json:"path"`
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
	ss.mu.Unlock()
	for range min(len(keys), cap(ss.wake)+1) {
		select {
		case ss.wake <- struct{}{}:
		default:
		}
	}
}

func (ss *session) next() (tile.Key, uint32, bool) {
	ss.mu.Lock()
	defer ss.mu.Unlock()
	if len(ss.queue) == 0 {
		return tile.Key{}, 0, false
	}
	k := ss.queue[0]
	ss.queue = ss.queue[1:]
	return k, ss.qgen, true
}

func (ss *session) tileWorker(ctx context.Context) {
	for {
		k, gen, ok := ss.next()
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
		if st == nil || st.gen != gen {
			continue // requested against a map that has been replaced
		}
		ss.writeBinary(encodeTile(st, k))
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
