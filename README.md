# code-scrap

A zoomable map of a codebase. The whole repository is one surface: directories, files and code scopes are nested boxes, and you zoom from the overview down to readable, syntax-highlighted code without opening anything. It's inspired by Rik Arends' Makepad Scope; see [SPEC.md](SPEC.md) for the design and [docs/reference](docs/reference) for frames from the Scope demo.

![overview](docs/screenshots/overview.png)

![search and fly-to](docs/screenshots/search-flyto.png)

![3D city](docs/screenshots/city.png)

## Layout

| Path | What |
|---|---|
| `scrap/` | Go indexer and tile server (`scrap` command) |
| `viewer-gd/` | Godot 4.7 viewer in GDScript |
| `viewer-cs/` | Godot 4.7 .NET viewer in C# (planned; same server and protocol) |
| `docs/reference/` | Frames of the Makepad Scope demo used for the spec |

All heavy work happens in `scrap`:
- file enumeration (`git ls-files`)
- tokenizing and scope finding (a fast heuristic pass, then a precise tree-sitter pass via [gotreesitter](https://github.com/odvcencio/gotreesitter), pure Go)
- layout
- symbol search
- tiles:
  - vector box tiles, as ready-to-upload MultiMesh buffers
  - raster code tiles: line dashes when zoomed out, Go Mono glyphs when zoomed in

The viewers only stream tiles, draw them, and handle the UI.

## Run

Requires Go 1.26+ and Godot 4.7. On Windows, `build-n-run.bat [repo-path]` builds the server and opens the viewer (set `GODOT` to override the Godot path). Or step by step:

```bash
cd scrap && go build -o bin/scrap.exe ./cmd/scrap
```

```bash
godot --path viewer-gd -- --repo=D:/path/to/some/repo
```

The viewer starts `scrap serve` itself if nothing is listening on `ws://127.0.0.1:7878/ws`. You can also run the server yourself:

```bash
scrap/bin/scrap.exe serve -addr 127.0.0.1:7878 D:/path/to/some/repo
```

### Viewer controls

Mouse and keys come from a keymap (`config/keymaps/*.json`, picked in **Settings → Mouse & keys**). The default is Maya-like:

| Input (Maya keymap) | Action |
|---|---|
| Wheel / pinch | zoom toward the cursor (3D: toward the roof or wall under it) |
| `Alt`+LMB drag | orbit (3D) · pan (2D) |
| MMB drag · `Alt`+MMB drag | pan |
| `Alt`+RMB drag | dolly / drag-zoom |
| Click | select → Inspector · click on empty space deselects |
| Double-click | fly to the box under the cursor |
| `F` / `A` | frame the selection / frame all |
| `Q` | deselect |
| `Tab` / **2D**·**3D** | switch between the flat map and the 3D city |
| `/` or `Ctrl+K` | search symbols (prefix); **Enter** / **Shift+Enter** step through hits |
| `Backspace` | select and fly to the parent |
| `Esc` | close settings / clear search |
| `Ctrl+,` | settings |
| `F12` | diagnostics overlay (frame time, tile and text streaming) |

The *Classic* keymap keeps the old scheme: left drag pans, right drag orbits, `Home` frames all.

### Settings and presets

Every tunable (UI scale and theme, camera, labels, code text, highlight and arc colors, budgets, importance weights, git window) is described in `config/settings.schema.json`; the settings panel is generated from it. Changes apply live and are saved to the Godot user folder. **Presets** (`config/presets/*.json`, plus your own via *Save as…*) load whole sets of values. Themes are token files in `config/themes/`. The viewer–server protocol is documented in [docs/protocol.md](docs/protocol.md).

### Layout

| Zone | What's there |
|---|---|
| Top bar | repository (open, recent), 2D / 3D, settings preset, **search field** (symbol prefix; start with `>` for commands), settings |
| Left: Display panel | lenses (height, color, importance weights, git window) with what each one means, overlays (imports, calls, labels, code text) |
| Viewport header | breadcrumb of the selection (click to go up), Camera menu, ☰ display toggles |
| Legend (bottom right) | what colors and arcs mean; click an area to frame it |
| Right panel | Inspector (with clickable imports / callers lists) and search results |
| Status bar | server, index progress, hover, keymap hints, fps |

### Lenses (Display panel)

Every lens is optional; the defaults show the plain map.

| Lens | What it does |
|---|---|
| **height** | 3D building height: *Nesting* (terraces), *Flat*, or a metric: lines, complexity, functions, churn, recent change, authors |
| **color** | *Area* hue, or the same metrics as a blue → red percentile ramp |
| **importance** | shrink vendored, test, generated, asset and data files so the core code gets the space |
| **imports** | arcs from the selection to what it imports (orange) and from what imports it (blue) |
| **calls** | arcs to what the selected function/file calls (violet) and from its callers (green); syntax-level, ambiguous names skipped |

Git lenses read `git log` for the last 12 months in the background (**Settings → History**, or `scrap serve -git-since`, changes the window). Importance weights per file class are in **Settings → Importance weights**.

### CLI

```
scrap stats  [-precise] <path>                 summary: sizes, classes, most complex functions
scrap search [-precise] <path> <prefix>        symbol prefix search
scrap render [-precise] -n 4 <path> <z> <x> <y> out.png
scrap render -file <substr> -lh 11 -n 4 <path> out.png   preview tiles around a file
scrap serve  [-addr host:port] [path]          WebSocket API for the viewers
```

## Status

Done:
- **Map:** indexing (fast pass + tree-sitter), layout, tile streaming
- **GPU text:** the system coding font, from line dashes to readable code without popping
- **Search:** symbol search with fly-to
- **3D city:** orbit camera and x-ray selection
- **Lenses:** height/color metrics, importance weighting and git history
- **Relations:** import graph and call graph

Next:
- a content-hash cache for the precise pass
- file watching
- aggregated arcs when zoomed out
- UI polish and DPI scaling
- the C# viewer
