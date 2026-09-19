package main

import (
	"cmp"
	"flag"
	"fmt"
	"os"
	"runtime/pprof"
	"slices"
	"strings"
	"time"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
)

func build(c common, path string) (*codemap.Map, error) {
	last := time.Now()
	return codemap.Build(path, codemap.Options{
		Precise:    c.precise,
		SortByName: c.byName,
		NoGit:      c.noGit,
		Progress: func(phase string, done, total int) {
			if time.Since(last) > 500*time.Millisecond || done == total {
				last = time.Now()
				fmt.Fprintf(os.Stderr, "\r%-6s %d/%d   ", phase, done, total)
			}
		},
	})
}

func cmdStats(args []string) error {
	fs := flag.NewFlagSet("stats", flag.ExitOnError)
	var c common
	c.register(fs)
	prof := fs.String("cpuprofile", "", "write a CPU profile")
	fs.Parse(args)
	if fs.NArg() != 1 {
		usage()
	}
	if *prof != "" {
		f, err := os.Create(*prof)
		if err != nil {
			return err
		}
		pprof.StartCPUProfile(f)
		defer pprof.StopCPUProfile()
	}
	m, err := build(c, fs.Arg(0))
	if err != nil {
		return err
	}
	s := m.Stats
	fmt.Fprintln(os.Stderr)
	fmt.Printf("root      %s\n", m.Root)
	fmt.Printf("dirs      %d\nfiles     %d (%d precise)\nlines     %d\nbytes     %.1f MB\n", s.Dirs, s.Files, s.PreciseFiles, s.Lines, float64(s.Bytes)/1e6)
	fmt.Printf("scopes    %d\nsymbols   %d\nnodes     %d\n", s.Scopes, s.Symbols, len(m.Nodes))
	fmt.Printf("index     %d ms\nlayout    %d ms\n", s.IndexMs, s.LayoutMs)

	var classes [6]int
	for _, f := range m.Files {
		for b := 0; b < 5; b++ {
			if f.Class&(1<<b) != 0 {
				classes[b]++
			}
		}
	}
	fmt.Printf("classes   binary %d · asset %d · secret %d · vendored %d · data %d\n",
		classes[0], classes[1], classes[2], classes[3], classes[4])

	fmt.Println("\nlargest top-level entries:")
	root := m.Nodes[0]
	kids := slices.Clone(root.Children)
	slices.SortFunc(kids, func(a, b int32) int { return cmp.Compare(m.Nodes[b].Weight, m.Nodes[a].Weight) })
	for _, id := range kids[:min(len(kids), 12)] {
		n := m.Nodes[id]
		fmt.Printf("  %6.1f%%  %-40s %8d lines\n", 100*n.Weight/root.Weight, n.Name, n.Lines)
	}

	var funcs []int32
	for i, n := range m.Nodes {
		if n.Kind == codemap.KindScope && n.Complexity > 0 {
			funcs = append(funcs, int32(i))
		}
	}
	slices.SortFunc(funcs, func(a, b int32) int { return cmp.Compare(m.Nodes[b].Complexity, m.Nodes[a].Complexity) })
	fmt.Println("\nmost complex functions:")
	for _, id := range funcs[:min(len(funcs), 10)] {
		n := m.Nodes[id]
		f := m.Files[n.File]
		fmt.Printf("  %4d  %-32s %s:%d (%d lines)\n", n.Complexity, trunc(n.Name, 32), f.Path, n.StartLine+1, n.Lines)
	}
	return nil
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func cmdSearch(args []string) error {
	fs := flag.NewFlagSet("search", flag.ExitOnError)
	var c common
	c.register(fs)
	fs.Parse(args)
	if fs.NArg() != 2 {
		usage()
	}
	m, err := build(c, fs.Arg(0))
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr)
	t := time.Now()
	res := m.Search(fs.Arg(1), 0, 64)
	fmt.Printf("%q: %d hits (%d files) in %v\n", fs.Arg(1), res.Total, len(res.Files), time.Since(t))
	for _, h := range res.Hits {
		fmt.Printf("  %-60s %5d  %s %s\n", trunc(m.Files[h.File].Path, 60), h.Line+1, strings.ToLower(h.Kind.String()), h.Name)
	}
	return nil
}
