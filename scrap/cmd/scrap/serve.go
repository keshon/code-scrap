package main

import (
	"flag"
	"os"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/server"
)

func cmdServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	var c common
	c.register(fs)
	addr := fs.String("addr", "127.0.0.1:7878", "listen address")
	fontPath := fs.String("font", "", "code font file (default: Consolas / Cascadia / Menlo / DejaVu Sans Mono, else Go Mono)")
	gitSince := fs.String("git-since", "12.months", `history window for git metrics ("" = all history)`)
	noCache := fs.Bool("no-cache", false, "do not read or write the analysis and git caches")
	noWatch := fs.Bool("no-watch", false, "do not re-index when files change")
	parent := fs.Int("parent", 0, "exit when this process id exits (set by the viewer)")
	fs.Parse(args)
	if *parent > 0 {
		exitWithParent(*parent)
	}
	root := "."
	if fs.NArg() > 0 {
		root = fs.Arg(0)
	}
	if _, err := os.Stat(root); err != nil {
		return err
	}
	s, err := server.New(codemap.Options{SortByName: c.byName, NoGit: c.noGit}, *fontPath)
	if err != nil {
		return err
	}
	s.GitSince = *gitSince
	s.NoCache = *noCache
	s.NoWatch = *noWatch
	errc := make(chan error, 1)
	go func() { errc <- s.ListenAndServe(*addr) }()
	if err := s.Open(root); err != nil {
		return err
	}
	return <-errc
}
