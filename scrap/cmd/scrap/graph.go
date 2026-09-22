package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"slices"
	"time"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/gitlog"
)

func cmdGraph(args []string) error {
	fs := flag.NewFlagSet("graph", flag.ExitOnError)
	var c common
	c.register(fs)
	out := fs.String("o", "", "output file (default stdout)")
	var o codemap.GraphOptions
	fs.StringVar(&o.Since, "git-since", "24.months", `history window for co-change ("" = all history)`)
	fs.IntVar(&o.MaxFiles, "maxfiles", 40, "skip commits touching more files (mass edits)")
	fs.IntVar(&o.MinShared, "minshared", 2, "shared commits a co-change pair needs")
	fs.IntVar(&o.MaxDecls, "decls", 24, "top-level names kept per file")
	fs.Parse(args)
	if fs.NArg() != 1 {
		usage()
	}
	m, err := build(c, fs.Arg(0))
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr)

	var history [][]string
	if !c.noGit {
		t := time.Now()
		err := gitlog.Walk(context.Background(), m.Root, o.Since, func(cm *gitlog.Commit) {
			history = append(history, slices.Clone(cm.Files))
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "git history unavailable: %v\n", err)
		} else {
			fmt.Fprintf(os.Stderr, "git       %d commits in %d ms\n", len(history), time.Since(t).Milliseconds())
		}
	}

	g := m.Graph(history, o)
	s := g.Stats
	fmt.Fprintf(os.Stderr, "graph     %d files · %d import · %d call · %d co-change edges\n", len(g.Nodes), s.Imports, s.Calls, s.CoChanges)
	if m.Deps != nil {
		fmt.Fprintf(os.Stderr, "barrels   %d import edges traced through re-exports\n", m.Deps.ViaBarrel)
	}
	fmt.Fprintf(os.Stderr, "commits  %d read · %d used · %d skipped as mass edits (> %d files)\n", s.Commits, s.CommitsUsed, s.CommitsTooLarge, o.MaxFiles)

	var w io.Writer = os.Stdout
	if *out != "" {
		f, err := os.Create(*out)
		if err != nil {
			return err
		}
		defer f.Close()
		w = f
	}
	bw := bufio.NewWriter(w)
	if err := json.NewEncoder(bw).Encode(g); err != nil {
		return err
	}
	return bw.Flush()
}

func cmdClusters(args []string) error {
	fs := flag.NewFlagSet("clusters", flag.ExitOnError)
	var c common
	c.register(fs)
	since := fs.String("git-since", "12.months", `co-change history window ("" = all history)`)
	o := codemap.DefaultClusterOptions
	fs.Float64Var(&o.Resolution, "res", o.Resolution, "resolution: higher = more, smaller clusters")
	fs.Float64Var(&o.HubShare, "hub", o.HubShare, "share of the code importing a file that makes it a hub")
	fs.IntVar(&o.HubMin, "hubmin", o.HubMin, "fewest importers a hub needs")
	fs.IntVar(&o.MinSize, "min", o.MinSize, "smaller clusters stay unclustered")
	fs.Parse(args)
	if fs.NArg() != 1 {
		usage()
	}
	m, err := build(c, fs.Arg(0))
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr)
	var history [][]string
	if !c.noGit {
		if h, err := gitlog.ReadHistory(context.Background(), m.Root, *since); err == nil {
			history = h.Commits
		}
	}
	t := time.Now()
	cl := m.Cluster(history, o)
	fmt.Printf("%d clusters · %d hubs · %d commits · %d ms\n\n", len(cl.Clusters), len(cl.Hubs), len(history), time.Since(t).Milliseconds())
	for k, x := range cl.Clusters {
		fmt.Printf("#%-3d %5d files (%4d core) %7d lines  %-44s %s\n", k, x.Files, x.Core, x.Lines, x.Name, m.Path(x.Home))
	}
	fmt.Println("\nhubs:")
	for _, f := range cl.Hubs[:min(len(cl.Hubs), 12)] {
		fmt.Println("  " + m.Files[f].Path)
	}
	return nil
}
