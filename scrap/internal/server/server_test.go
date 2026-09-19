package server

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
)

func TestProtocol(t *testing.T) {
	s, err := New(codemap.Options{}, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Open("../.."); err != nil { // the scrap module itself
		t.Fatal(err)
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()
	c.SetReadLimit(64 << 20)

	send := func(v any) {
		b, _ := json.Marshal(v)
		if err := c.Write(ctx, websocket.MessageText, b); err != nil {
			t.Fatal(err)
		}
	}
	var gen uint32
	readUntil := func(pred func(typ websocket.MessageType, b []byte) bool) {
		for {
			typ, b, err := c.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			if typ == websocket.MessageText {
				var m map[string]any
				json.Unmarshal(b, &m)
				if m["op"] == "hello" {
					gen = uint32(m["gen"].(float64))
				}
			}
			if pred(typ, b) {
				return
			}
		}
	}
	readUntil(func(typ websocket.MessageType, b []byte) bool { return strings.Contains(string(b), `"op":"hello"`) })

	send(map[string]any{"op": "tiles", "gen": gen, "keys": [][3]int{{0, 0, 0}, {1, 0, 0}}})
	got := 0
	readUntil(func(typ websocket.MessageType, b []byte) bool {
		if typ != websocket.MessageBinary {
			return false
		}
		if b[0] != 1 || binary.LittleEndian.Uint32(b[16:]) == 0 {
			t.Fatalf("bad tile frame header % x", b[:24])
		}
		got++
		return got == 2
	})

	send(map[string]any{"op": "search", "id": 7, "q": "build"})
	readUntil(func(typ websocket.MessageType, b []byte) bool {
		if !strings.Contains(string(b), `"op":"search"`) {
			return false
		}
		var m struct {
			ID    int              `json:"id"`
			Total int              `json:"total"`
			Hits  []map[string]any `json:"hits"`
		}
		json.Unmarshal(b, &m)
		if m.ID != 7 || m.Total == 0 {
			t.Fatalf("search reply: %s", b)
		}
		return true
	})

	send(map[string]any{"op": "font"})
	readUntil(func(typ websocket.MessageType, b []byte) bool {
		return typ == websocket.MessageBinary && b[0] == 4 && len(b) > 10
	})

	// a text block of this very file
	var fileNode int32 = -1
	st := s.cur.Load()
	for _, f := range st.m.Files {
		if strings.HasSuffix(f.Path, "server_test.go") {
			fileNode = f.Node
		}
	}
	send(map[string]any{"op": "texts", "gen": gen, "texts": [][3]int{{int(fileNode), 0, 0}}})
	readUntil(func(typ websocket.MessageType, b []byte) bool {
		if typ != websocket.MessageBinary || b[0] != 3 {
			return false
		}
		rows := int(binary.LittleEndian.Uint16(b[10:]))
		if rows == 0 || len(b) != 20+rows*128*6 {
			t.Fatalf("text frame: rows %d, len %d", rows, len(b))
		}
		if key := binary.LittleEndian.Uint32(b[16:]); key != st.renderer.TextKey(fileNode, 0, 0) || key == 0 {
			t.Fatalf("text frame: key %d", key)
		}
		return true
	})

	send(map[string]any{"op": "pick", "x": 0.5, "y": 0.3, "scale": 2000})
	readUntil(func(typ websocket.MessageType, b []byte) bool { return strings.Contains(string(b), `"op":"pick"`) })
}
