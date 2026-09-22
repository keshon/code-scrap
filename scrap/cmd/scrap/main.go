// Command scrap indexes a source tree into a zoomable map and serves it to
// the viewers over a local WebSocket.
package main

import (
	"flag"
	"fmt"
	"os"
)

func usage() {
	fmt.Fprint(os.Stderr, `scrap — codebase map indexer and server

usage:
  scrap stats  [flags] <path>                  index and print a summary
  scrap search [flags] <path> <prefix>         symbol prefix search
  scrap graph  [flags] <path>                  export the file relation graph as JSON
  scrap clusters [flags] <path>                print file clusters (the cluster lens)
  scrap render [flags] <path> <z> <x> <y> <out.png>  render one tile (debugging)
  scrap serve  [flags] [path]                  index and serve the viewer API
  scrap atlas  [-font file] <out.png>          write the code-font glyph atlas

flags (all commands):
  -precise   run the tree-sitter pass (exact scopes, slower)
  -byname    stable alphabetical layout instead of largest-first
  -nogit     walk the file system instead of using git ls-files
serve:
  -addr      listen address (default 127.0.0.1:7878)
graph:
  -o         output file (default stdout)
  -git-since co-change history window (default 24.months)
  -maxfiles  skip commits touching more files (default 40)
  -minshared shared commits a co-change pair needs (default 2)
`)
	os.Exit(2)
}

type common struct {
	precise, byName, noGit bool
}

func (c *common) register(fs *flag.FlagSet) {
	fs.BoolVar(&c.precise, "precise", false, "run the tree-sitter pass")
	fs.BoolVar(&c.byName, "byname", false, "alphabetical layout")
	fs.BoolVar(&c.noGit, "nogit", false, "walk instead of git ls-files")
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "stats":
		err = cmdStats(os.Args[2:])
	case "search":
		err = cmdSearch(os.Args[2:])
	case "clusters":
		err = cmdClusters(os.Args[2:])
	case "graph":
		err = cmdGraph(os.Args[2:])
	case "render":
		err = cmdRender(os.Args[2:])
	case "atlas":
		err = cmdAtlas(os.Args[2:])
	case "serve":
		err = cmdServe(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "scrap:", err)
		os.Exit(1)
	}
}
