// Package gitlog reads commit history and per-file statistics from git.
package gitlog

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"time"
)

// Stat is the history of one path.
type Stat struct {
	Commits    int32
	Authors    int32
	LastChange int64 // unix seconds
}

// Commit is one non-merge commit: when, by whom, and the paths it touched.
type Commit struct {
	Time   int64 // unix seconds
	Author string
	Files  []string // repo-relative slash paths
}

// Walk streams the non-merge history of the repository at root since the
// given git date ("12.months", "2024-01-01"; "" = all history, which can
// take minutes on large repositories), newest first. fn must not keep
// c.Files past the call.
func Walk(ctx context.Context, root, since string, fn func(c *Commit)) error {
	//  starts a commit header "timeauthor"; file names follow.
	args := []string{"-C", root, "log", "--no-merges", "--no-renames",
		"--format=%x1e%ct%x1f%aN", "--name-only", "--relative"}
	if since != "" {
		args = append(args, "--since="+since)
	}
	cmd := exec.CommandContext(ctx, "git", args...)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	var c Commit
	started := false
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		if line[0] == 0x1e {
			if started {
				fn(&c)
			}
			started = true
			c.Time, c.Author, c.Files = 0, "", c.Files[:0]
			h := line[1:]
			if i := bytes.IndexByte(h, 0x1f); i >= 0 {
				c.Time, _ = strconv.ParseInt(string(h[:i]), 10, 64)
				c.Author = string(h[i+1:])
			}
			continue
		}
		c.Files = append(c.Files, string(line))
	}
	if started {
		fn(&c)
	}
	if err := cmd.Wait(); err != nil {
		return err
	}
	return sc.Err()
}

// History is what the viewer needs from git: per-path statistics and the
// paths each commit touched (for co-change).
type History struct {
	Stats   map[string]Stat `json:"stats"`
	Commits [][]string      `json:"commits"` // newest first
}

// Read returns per-path statistics over the history Walk visits. Files
// untouched in the window are absent.
func Read(ctx context.Context, root, since string) (map[string]Stat, error) {
	h, err := ReadHistory(ctx, root, since)
	if err != nil {
		return nil, err
	}
	return h.Stats, nil
}

// ReadHistory walks the history once for statistics and commit file lists.
func ReadHistory(ctx context.Context, root, since string) (*History, error) {
	stats := map[string]*Stat{}
	authors := map[string]map[string]bool{}
	var commits [][]string
	err := Walk(ctx, root, since, func(c *Commit) {
		commits = append(commits, slices.Clone(c.Files))
		for _, p := range c.Files {
			s := stats[p]
			if s == nil {
				s = &Stat{}
				stats[p] = s
				authors[p] = map[string]bool{}
			}
			s.Commits++
			s.LastChange = max(s.LastChange, c.Time)
			if !authors[p][c.Author] {
				authors[p][c.Author] = true
				s.Authors++
			}
		}
	})
	if err != nil {
		return nil, err
	}
	h := &History{Stats: make(map[string]Stat, len(stats)), Commits: commits}
	for p, s := range stats {
		h.Stats[p] = *s
	}
	return h, nil
}

// Head returns the commit the repository's HEAD points at ("" if none).
func Head(ctx context.Context, root string) string {
	out, err := exec.CommandContext(ctx, "git", "-C", root, "rev-parse", "HEAD").Output()
	if err != nil {
		return ""
	}
	return string(bytes.TrimSpace(out))
}

// ReadCached is ReadHistory with a cache in dir keyed by HEAD, the day and
// the window: history only changes with new commits (and relative windows
// with the date), so restarts skip the slow git log.
func ReadCached(ctx context.Context, root, since, dir string) (*History, bool, error) {
	head := Head(ctx, root)
	if head == "" || dir == "" {
		h, err := ReadHistory(ctx, root, since)
		return h, false, err
	}
	name := fmt.Sprintf("history-%s-%s-%x.json", head[:min(12, len(head))], time.Now().Format("20060102"), sha1.Sum([]byte(since)))
	p := filepath.Join(dir, name)
	if b, err := os.ReadFile(p); err == nil {
		var h History
		if json.Unmarshal(b, &h) == nil && h.Stats != nil {
			return &h, true, nil
		}
	}
	h, err := ReadHistory(ctx, root, since)
	if err != nil {
		return nil, false, err
	}
	if b, err := json.Marshal(h); err == nil && os.MkdirAll(dir, 0o755) == nil {
		// drop older git caches of this repository, then write ours
		for _, pat := range []string{"git-*.json", "history-*.json"} {
			old, _ := filepath.Glob(filepath.Join(dir, pat))
			for _, o := range old {
				os.Remove(o)
			}
		}
		os.WriteFile(p, b, 0o644)
	}
	return h, false, nil
}
