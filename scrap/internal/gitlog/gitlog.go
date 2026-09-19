// Package gitlog reads per-file history statistics from git.
package gitlog

import (
	"bufio"
	"bytes"
	"context"
	"os/exec"
	"strconv"
)

// Stat is the history of one path.
type Stat struct {
	Commits    int32
	Authors    int32
	LastChange int64 // unix seconds
}

// Read walks the non-merge history of the repository at root since the
// given git date ("12.months", "2024-01-01"; "" = all history, which can
// take minutes on large repositories) and returns statistics keyed by
// repo-relative slash paths. Files untouched in the window are absent.
func Read(ctx context.Context, root, since string) (map[string]Stat, error) {
	// \x1e starts a commit header "time\x1fauthor"; file names follow.
	args := []string{"-C", root, "log", "--no-merges", "--no-renames",
		"--format=%x1e%ct%x1f%aN", "--name-only", "--relative"}
	if since != "" {
		args = append(args, "--since="+since)
	}
	cmd := exec.CommandContext(ctx, "git", args...)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	stats := map[string]*Stat{}
	authors := map[string]map[string]bool{}
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	var when int64
	var who string
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		if line[0] == 0x1e {
			h := line[1:]
			if i := bytes.IndexByte(h, 0x1f); i >= 0 {
				when, _ = strconv.ParseInt(string(h[:i]), 10, 64)
				who = string(h[i+1:])
			}
			continue
		}
		p := string(line)
		s := stats[p]
		if s == nil {
			s = &Stat{}
			stats[p] = s
			authors[p] = map[string]bool{}
		}
		s.Commits++
		if when > s.LastChange {
			s.LastChange = when
		}
		if !authors[p][who] {
			authors[p][who] = true
			s.Authors++
		}
	}
	if err := cmd.Wait(); err != nil {
		return nil, err
	}
	res := make(map[string]Stat, len(stats))
	for p, s := range stats {
		res[p] = *s
	}
	return res, sc.Err()
}
