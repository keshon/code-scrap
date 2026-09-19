package main

import (
	"flag"
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"math"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/keshon/code-scrap/scrap/internal/tile"
)

// cmdRender writes a preview PNG of an n×n block of tiles starting at (x, y)
// on level z — a quick way to eyeball layout and code rendering without a
// viewer.
func cmdRender(args []string) error {
	fs := flag.NewFlagSet("render", flag.ExitOnError)
	var c common
	c.register(fs)
	n := fs.Int("n", 1, "render an n×n block of tiles")
	file := fs.String("file", "", "focus the first file whose path contains this (ignores z x y)")
	lh := fs.Float64("lh", 10, "with -file: target line height in pixels")
	fs.Parse(args)
	if fs.NArg() != 5 && !(*file != "" && fs.NArg() == 2) {
		usage()
	}
	m, err := build(c, fs.Arg(0))
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr)
	var z, x, y int
	outPath := fs.Arg(fs.NArg() - 1)
	if *file != "" {
		fi := -1
		for i, f := range m.Files {
			if strings.Contains(f.Path, *file) && f.Rows > 0 {
				fi = i
				break
			}
		}
		if fi < 0 {
			return fmt.Errorf("no text file matches %q", *file)
		}
		f := m.Files[fi]
		z = max(0, min(tile.MaxZ, int(math.Round(math.Log2(*lh/(f.LH*tile.Px))))))
		k := 1 / math.Exp2(float64(z))
		x, y = int(f.TX/k), int(f.TY/k)
		fmt.Fprintf(os.Stderr, "%s: %d lines, %d cols, z=%d x=%d y=%d\n", f.Path, f.Lines, f.Cols, z, x, y)
	} else {
		z, _ = strconv.Atoi(fs.Arg(1))
		x, _ = strconv.Atoi(fs.Arg(2))
		y, _ = strconv.Atoi(fs.Arg(3))
	}
	r := tile.NewRenderer(m, nil, 256<<20)
	out := image.NewRGBA(image.Rect(0, 0, *n*tile.Px, *n*tile.Px))
	t := time.Now()
	var wg sync.WaitGroup
	for j := 0; j < *n; j++ {
		for i := 0; i < *n; i++ {
			wg.Add(1)
			go func(i, j int) {
				defer wg.Done()
				img := r.Preview(tile.Key{Z: z, X: x + i, Y: y + j})
				draw.Draw(out, image.Rect(i*tile.Px, j*tile.Px, (i+1)*tile.Px, (j+1)*tile.Px), img, image.Point{}, draw.Src)
			}(i, j)
		}
	}
	wg.Wait()
	fmt.Fprintf(os.Stderr, "rendered %d tiles in %v\n", *n**n, time.Since(t))
	f, err := os.Create(outPath)
	if err != nil {
		return err
	}
	defer f.Close()
	return png.Encode(f, out)
}
