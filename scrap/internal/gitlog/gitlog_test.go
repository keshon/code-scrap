package gitlog

import (
	"context"
	"testing"
)

func TestReadThisRepo(t *testing.T) {
	stats, err := Read(context.Background(), "../../..", "")
	if err != nil {
		t.Skip("not a git work tree:", err)
	}
	s, ok := stats["SPEC.md"]
	if !ok || s.Commits == 0 || s.LastChange == 0 || s.Authors == 0 {
		t.Fatalf("SPEC.md history missing: %+v (%d paths)", s, len(stats))
	}
}
