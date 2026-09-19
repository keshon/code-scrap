package main

import (
	"flag"
	"fmt"
	"image"
	"image/png"
	"os"

	"github.com/keshon/code-scrap/scrap/internal/tile"
)

// cmdAtlas writes the GPU text glyph atlas as a PNG (debugging).
func cmdAtlas(args []string) error {
	fs := flag.NewFlagSet("atlas", flag.ExitOnError)
	fontPath := fs.String("font", "", "code font file")
	fs.Parse(args)
	if fs.NArg() != 1 {
		usage()
	}
	a, err := tile.LoadAtlas(*fontPath)
	if err != nil {
		return err
	}
	img := &image.Gray{Pix: a.Pix, Stride: a.Cols * a.CellW, Rect: image.Rect(0, 0, a.Cols*a.CellW, a.Rows*a.CellH)}
	f, err := os.Create(fs.Arg(0))
	if err != nil {
		return err
	}
	defer f.Close()
	fmt.Printf("font %q: %d glyphs, cells %dx%d, aspect %.3f\n", a.Font, len(a.Runes), a.CellW, a.CellH, a.CharAspect())
	return png.Encode(f, img)
}
