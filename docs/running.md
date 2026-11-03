# Running code-scrap

Use Go 1.26.4+ as declared by `scrap/go.mod`, Git for repository enumeration,
and Godot 4.7 as declared by `viewer-gd/project.godot`. On Windows, `build.cmd` is the one entry point (set `GODOT` to override the Godot path):

| | |
|---|---|
| `build.cmd` | build the scrap server |
| `build.cmd run [repo]` | build, then open the viewer on a repository (no path = this one) |
| `build.cmd serve [repo] [addr]` | build, then run the server in this console |

Development helper commands (tests, screenshots, packaging and cleanup) are
described in [Conventions](conventions.md).

Or step by step:

```bash
# From the repository root, build the server in its Go module.
cd scrap
go build -o bin/scrap.exe ./cmd/scrap
cd ..
```

```bash
godot --path viewer-gd -- --repo=D:/path/to/some/repo
```

A packaged copy (`dist\`) takes the folder to map as a plain argument - `code-scrap.exe D:\path\to\some\repo`, or a folder dropped on it - and runs the `scrap.exe` that sits beside it.

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
| `F12` | diagnostics overlay (frame time, tile and text streaming, redraws) |
| Mouse **back** / **forward**, `Alt+Left` / `Alt+Right` | step back and forward through the places you have been, like a browser |
| `Ctrl+1` … `9` / `1` … `9` | save a bookmark (view, camera, selection) / go back to it |
| `]` / `[` | step through the selection's relations (Inspector list) |

The *Classic* keymap keeps the old scheme: left drag pans, right drag orbits, `Home` frames all.

### Server: cache and watching

`scrap serve` keeps each file's analysis (keyed by path, size and time) and the git history (keyed by HEAD) in the user cache folder, to avoid repeating unchanged work. It watches the open folder and re-indexes
changed files; latency depends on repository size and analysis work. `-no-cache` and `-no-watch` turn these off.

### Settings and presets

Every tunable (UI scale and theme, camera, labels, code text, highlight and arc colors, budgets, importance weights, git window) is described in `config/settings.schema.json`; the settings panel is generated from it. Changes apply live and are saved to the Godot user folder. **Presets** (`config/presets/*.json`, plus your own via *Save as…*) load whole sets of values. Themes are token files in `config/themes/`. The viewer–server protocol is documented in [protocol](protocol.md).

### Layout

The implemented interface uses the following zones. The historical UI plan
is preserved separately; use this guide for current navigation.

| Zone | What's there |
|---|---|
| Top bar | Explorer toggle, repository (open, recent), 2D / 3D, settings preset, **search** (files and folders by path, symbols by prefix; `>` for commands), settings |
| Explorer (left) | the file tree, down to functions; follows the selection |
| Viewport header | breadcrumb (click a segment to select it, › to list what is inside) · Camera menu (framing, back / forward) · ☰ display toggles |
| Legend (bottom right) | what colors and arcs mean; click an area to frame it |
| Right pane | **Inspector** (what reaches the selection, the selection, what it reaches for, then its outline - every row a button) · **View** (lenses, importance, relations) |
| ☰ display menu | what the viewport draws: labels, code text, line numbers, hover, search hits, legend, grid, minimap, folder headers, the **hover card** under the cursor, **focus the selection** (dim everything outside it) and **fill functions** (function bodies as filled blocks — with the code text off, a map of functions rather than files) |
| Status bar | server, index progress, hover, keymap hints, fps |

### Importance rules

Besides the per-class weights (View tab), rules give paths their own weight: `src/legacy/** = 0.3; **/*.stories.tsx = 0.2`. A repository can carry its own in `.scrap.json`:

```json
{"importance": {"rules": {"src/legacy/**": 0.3}}}
```

### Lenses (View tab)

Every lens is optional; the defaults show the plain map.

| Lens | What it does |
|---|---|
| **height** | 3D building height: *Nesting* (terraces), *Flat*, or a metric: lines, complexity, functions, churn, recent change, authors. **Terrace step** says whether a level's height scales with the box (a big folder gets a tall terrace) or is the same everywhere, so height reads as depth alone |
| **nest folder chains** | a folder holding only one folder is one box (`cmd/scrap`) unless this is on, which draws every level — in the map, in the Explorer, and as its own header band; it re-indexes the repository |
| **merge folder bands** | a folder that fills its parent shares its band (`docs / reference`) instead of stacking one; off gives every folder its own |
| **band height** | how tall a folder's band is, as a share of the folder it sits in |
| **card levels** | with the cards layout: how many levels from the root are cards before the packed treemap takes over (0 = all the way down) |
| **order** | where siblings land inside a folder: *size* (biggest first) or *name* (alphabetical, so boxes barely move when a lens or a file changes). **Folders first** groups the folders ahead of the loose files on top of either one, the way Windows lists a folder; off is plain alphabetical, the way macOS does |
| **layout** | how a folder's contents are packed: *squarified* (squarest boxes), *strip* (reading order), *rows* / *columns* (one band per item, alternating direction with depth), *cards* (a grid of equal cards with air — size stops carrying weight, so a folder becomes countable) |
| **color** | *Area* hue, *Cluster* (files grouped by imports, calls and git co-change rather than folders; hubs most of the code imports shown apart), or the same metrics as a blue → red percentile ramp |
| **importance** | shrink vendored, test, generated, asset and data files so the core code gets the space |
| **imports** | arcs from the selection to what it imports (orange) and from what imports it (blue); an arc leaves the import statement and lands on the declaration it names (JS/TS, through barrels), and both lines light up while they are readable on screen |
| **calls** | arcs to what the selected function/file calls (violet) and from its callers (green); an arc leaves the call and lands on the callee's first line; syntax-level, ambiguous names skipped |

The Inspector reads as a route map, top to bottom: what imports or calls the selection, then the selection itself, then what it imports or calls. Every row carries the address it lands on (`analyze  build.go:327`), clicking a row goes there, and its icon opens the file in an editor - whatever the system opens it with, or the command in **Settings, Open in editor** (`code -g {file}:{line}`, `goland64 --line {line} {file}`). Under the routes is the outline: a file's functions in reading order with the line each starts on, a folder's contents with their size.

Every arrowhead points at what is used, so the color only says which side of the relation the selection is on. By default two colors carry that (what the selection uses, what uses it) and imports are dashed while calls are solid; **View → Arc colors** switches to a color per kind and direction instead. Arcs are on when Show imports / Show calls are on — there is no separate master switch. Hovering an arc reads it out as a sentence ("build.go:312 imports Hub · hub.ts:14"); clicking one travels to its far end, and clicking it again comes back.

Git lenses read `git log` for the last 12 months in the background (**Settings → History**, or `scrap serve -git-since`, changes the window). Importance weights per file class are in **Settings → Importance weights**.

### CLI

```
scrap stats  [-precise] <path>                 summary: sizes, classes, most complex functions
scrap search [-precise] <path> <prefix>        symbol prefix search
scrap render [-precise] -n 4 <path> <z> <x> <y> out.png
scrap render -file <substr> -lh 11 -n 4 <path> out.png   preview tiles around a file
scrap serve  [-addr host:port] [path]          WebSocket API for the viewers
scrap graph  [-git-since 24.months] -o g.json <path>  file graph (imports, calls, co-change) as JSON
scrap clusters [-res 1] [-git-since 12.months] <path> the clusters the cluster lens shows
```


## Verify a first run

Open a small repository you control. Confirm that the map appears, search finds
a known symbol, selecting a result updates the Inspector, and toggling 2D/3D
keeps the same selection. Edit a source file and confirm the watched map updates.
A working Go indexer alone does not verify the viewer's GPU/text path.

If the viewer reports a protocol mismatch, rebuild/use matching server and
viewer sources. The active protocol is documented in [Protocol](protocol.md).
If a map remains empty, inspect server output, the selected repository and the
viewer diagnostics (`F12`) before deleting caches or changing budgets.

## Local state and boundaries

Repository analysis/git caches live in the user cache directory; viewer
settings, presets, recents and bookmarks live under Godot's `user://` directory.
`config/` holds the shipped schema, themes, keymaps and presets. User overrides
are separate from repository source. `-no-cache` disables cache reads/writes;
`-no-watch` disables automatic re-indexing.

The WebSocket server defaults to loopback. It exposes repository metadata and
source-derived content, and is not an authenticated remote hosting service.
Keep it on a trusted local interface. The helper's `build stop` terminates
processes named `scrap.exe`; review other running instances before using it.

See [Conventions](conventions.md) for tests, screenshot runs and packaging.
