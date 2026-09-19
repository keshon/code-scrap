# code-scrap — Draft Specification

> Working name. A zoomable, GPU-rendered map of an entire codebase: one continuous surface (flat or as a 3D city) that you fly over from "whole repo" down to "this line of this function", with no mode switches in between.

Status: **draft v0.2** · 2026-09-19
Toolchain on this machine: Go 1.26.4 · Godot 4.7.1 standard at `E:\Programs\godot\` (**viewer-gd**, GDScript, built first) · Godot 4.7.2 .NET at `E:\Programs\godot.net\` (**viewer-cs**, C#, second). Both viewers talk to the same `scrap` server and protocol.

---

## 1. Reference: what Makepad Scope does

Source: the 48 s demo video (silent, no narration) of Scope browsing the Chromium repo. All 194 frames were reviewed at 4 fps.

### 1.1 Timeline of the demo

| Time | What happens |
|---|---|
| 0–1 s | Whole-repo overview in 2D. Pastel-colored treemap, top-level folder labels (`chrome`, `components`, `third_party`, `web_tests`…). Dark dotted "infinite canvas" around the repo. |
| 1–8 s | Continuous zoom into `third_party/blink/web_tests/external/wpt`. File boxes turn from flat tiles into "minimap" line texture. |
| 8–12 s | Hovers and selects `WPT_BASE_MANIFEST_8.json` (937,615 lines, 20 MB). It gets a **blue selection outline**. Zooms in until the JSON is **fully readable and syntax-colored**, even for a file this size. |
| 12–18 s | Pans across to `blink/renderer/core/scheduler`. Code-level zoom: file boxes contain **columns of source text** with **outlined scope boxes**. Symbol labels such as `TaskAttributionTrackerImpl` and `blink` appear inside files. |
| 18–22 s | Opens the **History** tab briefly (content not visible), then the **Search** tab. Empty state: "Type in the filter to list its hits". |
| 22–25 s | Types `w` → `wi` → `win` → `windo` → `window`. Results update **on every keystroke**. Files with hits light up **yellow-green on the map**. |
| 25–36 s | Steps through hits (**Enter**). Each step **flies the camera**: zoom out to context → pan → zoom back in to the exact line, which is highlighted in yellow. Nearby hits give short hops; distant ones go all the way out to the repo overview. Tooltip on the field: *"Search symbol names · type a prefix; Enter steps through the hits · /"*. |
| 36–38 s | Zooms out to the whole repo. Clicks a file (`shill_profile_client.cc`), which shows in the Inspector. |
| 38–40 s | Switches to the **3D** view. The flat map **tilts smoothly** into a perspective city (animated camera, not a cut). |
| 40–46 s | Flies **down to street level** in `services/network`. Directories are raised colored plinths and files are dark-roofed buildings standing on them. Near the ground, **the code on the roofs is readable in perspective**. A function label (`TEST_F`) floats over its scope. |
| 46–48 s | Pulls back up, **orbits and yaws** around the whole city, and zooms out to the full model. |

### 1.2 Observed features (the complete list)

**Map / layout**
- One nested treemap: dirs ⊃ files ⊃ code scopes. Area ∝ size, apparently lines, or bytes for data files.
- Directory boxes have a **header strip with the name**. Labels are white on a dark pill and truncated with `…`.
- Children are packed in a **slice/strip style**: long rows and columns, not perfectly squarified. That keeps big files as long bands (the 937k-line JSON shows as one wide horizontal band).
- Background outside the repo is a dark dotted grid (infinite canvas).

**Color**
- Each top-level area gets a **hue** (teal, lavender, salmon, lime, sky blue…). Sub-directories vary it slightly.
- **Data / non-code files are grey** (`testdata`, `perf_results.json`, `test`, `.json` manifests).
- Deeper zoom → mostly thin **outline-only boxes** in the area's hue on a near-black background.
- Search hits: **yellow-green fill**, visible from any zoom level.
- Selection: **blue outline**. Hovering a search row gives a secondary blue highlight on the target.

**Semantic zoom (levels of detail)**
1. Tiny: solid colored cell.
2. Small: outlined cell + header label.
3. Medium: file shows **line texture**: horizontal dashes whose length and color follow each line and its syntax colors (a "minimap").
4. Large: **real glyphs**, syntax-highlighted (strings salmon, keywords blue, identifiers light, comments grey).
- The text inside a file is **flowed into multiple columns** so a long file fills a squarish box. The column count adapts to the box's aspect ratio.
- **Scope boxes**: rounded outlines around each top-level construct (include-guard block, `namespace`, `class`, each function / `TEST_F`). Nested scopes are nested outlines.
- **Symbol labels** appear on scopes when zoomed to file level (`blink`, `TaskAttributionTrackerImpl`, `TEST_F`).

**Status line (top bar, after the toolbar)**
- Shows what's under the cursor as `Name (path/)`, e.g. `TEST_F (services/network/p2p/socket_udp_unittest.cc)` or `css-flexbox ()`.
- When something is selected: `selected X (path)`.
- During search: `search: 64 rows (more) in 5.3 ms`.
- **Hover ≠ selection.** Hover goes to the status line, selection goes to the Inspector.

**Inspector (right panel)**
- `name · kind` (e.g. `tags_unittest.cc · file`), full path, `line N`, `2355 source lines · 106758 bytes`, `1 children · 49 descendants`.
- Function metrics section; the video shows "No function metrics for this selection." So functions carry metrics (complexity etc.) and files don't.
- A file seems to have **one child** (a root syntax node) and N descendants (all nested scopes).

**Search**
- Searches **symbol names by prefix**, case-insensitive (`Window` and `window` both match). It is not full-text.
- `/` focuses the field. **Enter steps to the next hit**, with a camera fly-to.
- Results are **grouped by file** (path, left-truncated with `…`, hit count on the right). Each hit row shows `line  symbol`.
- Paged: `64 · more` next to the field, `window · 64 on this page · more` header, and a **More results** button at the bottom.
- Speed is shown: `64 rows in 5.3 ms` on Chromium, so it uses a prebuilt symbol index.

**Camera**
- 2D: pan and zoom around the cursor.
- **Fly-to** uses the zoom-out → pan → zoom-in motion (van Wijk & Nuij "smooth and efficient zooming"), about 0.7–1.5 s.
- The 2D → 3D switch is an animated tilt.
- 3D: orbit (pitch/yaw), dolly down to street level, pull back to the full model.

**3D city**
- Directories are **stacked plinths**: each nesting level raises its children. Walls use the area's hue.
- Files are the topmost blocks, with **dark roofs carrying the code texture/text**.
- Height mostly follows nesting depth, possibly plus size; the exact mapping is unclear.
- Labels float over blocks as dark pills. The hovered directory's label is also shown floating high above the model (`third_party`).

**Toolbar (left → right)**
- `Makepad Scope`, `…` menu.
- `Home` (reset camera), `Open folder`, `Treemap` (active).
- A **"Tokens"** group with 6 toggles: ⊘ none (active the whole demo), ⅄ tree/fork, ▣ scope/box, ≫ flow, ⤳ branch/graph, ⇥ exit/export. Never used in the demo; these are likely overlays for token-level structure (scope, control flow, call graph, exports).
- View mode: `2D grid` / `3D cube` (never used; maybe isometric/orthographic) / `3D perspective` (used).
- `Settings`, `Print`.
- Right side: a `Default` dropdown (workspace/profile/theme?) and a red dot (status/recording/indexing?).

**Right-panel tabs**
- `Inspector`, `Search`, `History`, `Worktrees`. History and Worktrees were never shown open. They are presumably git history and multiple checkouts.

### 1.3 The core idea

> Treat the codebase as a **single map**. Every level from repo to token is the same kind of object (a nested box), and **zooming alone replaces navigation**. Search, structure and source are one surface, so you never lose your place.

What makes it work:
- **Proportion is visible.** You see at once that `web_tests` is half the repo.
- **Spatial memory.** "Networking is bottom-left" sticks.
- **No context switch.** You never open a file; you just get closer to it.
- **It's fast enough to not think about it.** Chromium at interactive frame rates, 5 ms search.

---

## 2. Goals / Non-goals

### Goals (v1, parity with Scope)
1. Open a local folder / git repo and index it. Target: 1M LOC in < 10 s; Chromium-scale in minutes, then incremental.
2. The whole repo as a zoomable treemap at 60 fps.
3. Semantic zoom through all 4 LOD levels down to readable, syntax-highlighted code in multi-column file boxes with scope outlines and symbol labels.
4. A status line for hover, and an Inspector for selection with per-node metrics (file stats + function metrics).
5. Symbol prefix search: per-keystroke, paged, grouped by file, hits highlighted on the map, Enter/`/` keys, fly-to.
6. A 3D city view on the same layout, with an animated 2D↔3D transition, orbit, and street-level flying with readable roof code.
7. Grey for data files, a hue per area.

### Beyond Scope ("or better")
- **Overlays for the "Tokens" idea, implemented for real:**
  - import/dependency edges as bundled arcs when you select a node
  - call-graph edges for a selected function
  - an "exports / public API" highlight
- **Git dimension (History tab):**
  - color by last-modified age, churn heatmap, author ownership
  - a **time slider** that replays repo growth
  - per-node commit list in the Inspector
- **Worktrees tab:** switch between checkouts / branches, and **diff mode**: color what changed between two refs, grey the rest.
- **Full-text search** (trigram) in addition to symbol search, plus filters: `lang:`, `path:`, `kind:func`.
- **Stable layout** so spatial memory survives edits (see §5.4).
- **Tours/annotations:** pinned notes and saved camera paths ("Request lifecycle: 6 stops").
- **Editor bridge:** Ctrl+double-click → open in VS Code / GoLand at that line. Optionally follow the editor cursor on the map.
- **Height/color bindings** chosen by the user (complexity, churn, size, test coverage) instead of fixed ones.
- **Optional LLM summaries:** "what this directory does", cached per content hash.

### Non-goals (v1)
- Editing code in the map.
- Type-resolved semantic analysis (LSP-grade cross-references). Syntax-level (tree-sitter) is enough to start.
- Multi-user / collaboration.

---

## 3. Architecture

```
┌──────────────────────────────┐   tile pyramid + index files   ┌─────────────────────────────────┐
│  scrap (Go)                  │ ─────────────────────────────▶ │  Viewer (Godot 4.7, GDScript)    │
│  - walk FS / git             │    (mmap-friendly, versioned)  │  - camera (2D pan/zoom, 3D orbit)│
│  - parse (tree-sitter)       │                                │  - tile selection by camera      │
│  - metrics, symbols          │ ◀──── localhost WebSocket ──── │  - MultiMesh + code shader       │
│  - layout (§5)               │   (search, text, git, events)  │  - labels, status line, panels   │
│  - bake tiles + text atlases │                                │  - 2D↔3D transition              │
│  - fs watcher → deltas       │ ───── push: changed tiles ───▶ │                                  │
└──────────────────────────────┘                                └─────────────────────────────────┘
```

### 3.1 Stack decision: Go + Godot (why and how)

- **Go does all the heavy computation.** It walks the files, parses them, computes metrics, lays everything out, builds the search index, and **bakes render-ready data**. It's easy to test, parallel, and works as a CLI on its own.
- **Godot is the renderer and UI.** It gives GPU instancing, shaders, 2D/3D cameras, fonts and `Control` panels for free.

**Important constraint:** your Godot is the **standard build, so there is no C#**. GDScript is too slow to walk millions of nodes per frame. So the design must make the viewer do **almost no per-node work in script**:

1. **Go pre-bakes a tile pyramid**, like a web map (slippy tiles).
   - The world rect is split into a quadtree of tiles.
   - Each tile at each zoom level holds a **ready-to-upload instance buffer** (`PackedFloat32Array` bytes: transform + color + custom data per box) for everything visible at that LOD, plus a label list.
   - Godot picks the ~20–60 tiles covering the view, **loads their bytes directly into `MultiMesh.buffer`**, and doesn't loop over nodes at all.
2. **Code text is rendered by a shader, not by glyph nodes** (see §6.3). One quad per file-column block; the GPU does the rest.
3. **GDScript only handles** camera math, tile bookkeeping, picking (ask Go, or do a small tile-local hit test), and UI.

If some hot path still needs native speed later, add a **GDExtension** (C++ via godot-cpp, or Rust via gdext). Keep this as an escape hatch, not the plan.

**Alternative, if you want one language:** pure Go with **Gio** or **raylib-go**. It's feasible, but you'd hand-build the SDF text, instancing, 3D camera and UI widgets. Pick it only if building the engine is part of the fun.

### 3.2 Process model
- Godot launches `scrap serve <repo>` via `OS.create_process` and connects over a localhost WebSocket (`WebSocketPeer`). The indexer's lifetime is tied to the viewer.
- The index lives in `<repo>/.scrap/` or `%LOCALAPPDATA%/scrap/<repo-hash>/`. It's reused across runs and updated incrementally.

---

## 4. Data model

```go
type NodeKind uint8 // Dir, File, Scope (namespace/class/func/block), Symbol

type Node struct {
    ID          uint32
    Parent      uint32
    FirstChild  uint32  // children contiguous (pre-order array)
    ChildCount  uint32
    Descendants uint32
    Kind        NodeKind
    ScopeKind   uint8   // namespace, type, func, test, preproc, block…
    Name        uint32  // offset into string blob
    Lang        uint16
    FileID      uint32
    StartLine, EndLine uint32
    StartByte,  EndByte uint32
    Rect        [4]float32 // world-space x,y,w,h from layout (§5)
    Height      float32    // 3D base elevation (plinth stack)
}
```

- **Pre-order flat array**: a subtree is a contiguous ID range, so "highlight subtree" and "is X inside Y" are O(1).
- **Metric columns**, one `[]float32` per metric, separate from nodes. Color and height modes just bind to a column.
- **Symbol table**: `(name_lower, node_id, file_id, line, col, kind)`, sorted by `name_lower` → prefix search is a binary search plus a range scan. That gives Scope's 5 ms.
- **Trigram index** (Zoekt-style) for full-text search: v2.
- **Per-file text store**: raw bytes + line-offset table + a **token-class array** (one byte per char: keyword/string/comment/ident/number/punct) produced by tree-sitter highlighting. This feeds the code shader.

### 4.1 Metrics (v1)
| Metric | Level | Source |
|---|---|---|
| lines, bytes, blank/comment ratio | file (rolled up) | scan |
| children, descendants, depth | all | tree |
| language, is_data (json/csv/bin/lock/generated) | file | extension + heuristics |
| cyclomatic complexity, params, max nesting, length | func | tree-sitter |
| last-modified, commits (churn), #authors, top author | file (rolled up) | `git log --numstat` |
| fan-in / fan-out (imports) | file | tree-sitter import queries |

Rollups: sizes are summed; complexity uses max/avg; recency uses max.

---

## 5. Layout

### 5.1 Directory / file levels
- The treemap is weighted by lines (bytes for data files; switchable).
- Scope uses long strips and bands, which look like **ordered slice-and-dice / strip treemap** output. Proposal: **ordered squarified** (children sorted by name) as the default, with strip layout as an option. Both are stable when things are added.
- Each directory gets **padding plus a header strip** sized relative to its box. The label lives there.
- Collapse single-child dir chains (`a/b/c` → one box).
- Clamp a minimum weight so tiny files stay visible.

### 5.2 Inside a file (the code level)
1. Take the file's treemap rect (aspect ratio *r*).
2. Choose a column width (e.g. 100 chars) and a line height, then pick a **column count *k*** so that `k × colWidth : ceil(lines/k) × lineHeight ≈ r`. Scale uniformly to fit.
3. **Flow lines into columns**, preferring breaks at top-level scope boundaries (never mid-scope if the scope fits in a column).
4. **Scope boxes** are computed from tree-sitter ranges: a rounded outline around each top-level construct, with nested outlines inside (indented by nesting).
5. Scope label = the symbol name, drawn at the box's top-left when there's room.

Invariant: a file's area stays proportional to its weight, so text size is uniform across the whole map. One line is the same height everywhere, and that's what makes the "minimap" texture look coherent.

### 5.3 3D elevation
- `base_height(node) = depth(node) × plinth_step`. Each directory is a plinth; children stand on it.
- A file's block height is `plinth_step` plus an optional metric-bound extra (size/complexity/churn).
- The roof of a file block is its 2D code surface, drawn with the same shader. That's how code stays readable at street level.

### 5.4 Stability (improvement over Scope)
1. Sort by name (not size), so inserting a file only perturbs its siblings.
2. On a change, re-layout only the affected subtree and keep parent rects if the weight changed by less than N% (hysteresis).
3. v3: seeded Voronoi treemaps.

---

## 6. Rendering

### 6.1 LOD rule
What a node draws depends only on its **on-screen size**.

| Screen size | Dir | File | Code |
|---|---|---|---|
| < 2 px | culled (parent's tile shows it as color) | culled | — |
| 2–30 px | fill (hue) | fill (hue or grey) | — |
| 30–150 px | outline + header label if it fits | outline + **line texture** | — |
| > 150 px | outline + header | outline + line texture + scope outlines + symbol labels | — |
| line ≥ ~6 px tall | — | — | **glyphs** |

### 6.2 Tile pyramid (baked by Go)
- World = `[0,1]²`. Zoom level *z* has 2^z × 2^z tiles. A node goes into the tile(s) at the level where it first becomes ≥ 2 px (assuming a nominal tile resolution of 512 px). This is the same principle as vector map tiles.
- Tile payload:
  - `boxes` (MultiMesh buffer, float32 × 12 per instance: 2D transform + color + custom(kind, flags, node_id_hi, node_id_lo))
  - `labels` (text, pos, size, priority)
  - `code_blocks` (file_id, column, rect)
- Viewer: each frame, compute the needed tiles; load them async (`WorkerThreadPool`); keep an LRU cache; draw each tile as its own `MultiMeshInstance2D`/`3D`. Parent tiles stay visible until children load, so nothing pops.
- Picking: the node_id is packed in instance custom data. Either render an ID buffer (SubViewport) or do a tile-local rect test in GDScript (a few hundred boxes per tile is fine).

### 6.3 Code shader (the key trick)
One quad per file column block. Its material samples:
- a **char texture**: R8 = char code, G8 = token class; rows = lines, cols = chars; baked by Go per file and streamed on demand
- a **monospace MSDF font atlas** (Godot can generate MSDF for a font)
- a small **palette texture**: token class → color

Fragment shader:
- Map the fragment to (column, row, char) → fetch char + class → sample the glyph MSDF → color by class.
- **LOD falls out naturally.**
  - When a glyph is < ~2 px, skip the MSDF and output `class_color × (char != ' ')`.
  - With hardware mipmapping on the char-occupancy texture, that averages into **horizontal dashes**. That's Scope's line texture, for free.
  - Further out, the mip averages to a flat tint.
- This scales to the 937k-line JSON: it's one texture of ~937k × 120 chars, split into column tiles of ≤ 16k rows to respect texture limits.

### 6.4 Overlays
- Search hits, selection and hover are tracked per node by a flag in instance custom data, so updating means touching only the affected tiles' buffers.
- A line highlight inside a file (the current search hit) is a separate small quad.
- Labels: screen-space `Label` pool (or `Label3D` in 3D) with greedy largest-first placement, collision rejection, `…` truncation, and a dark pill background.

### 6.5 3D
- Same tiles, instanced **box mesh** instead of quads. Height comes from §5.3; wall color = hue, roof = dark + code shader.
- Camera: `Camera3D` with orbit (pitch/yaw), dolly and pan; perspective. Light fog to hide distant detail. The "cube" button can be an **orthographic isometric** preset.
- The 2D→3D switch tweens the camera from top-down orthographic-equivalent to a tilted perspective over about 0.8 s, keeping the screen-center node fixed.

### 6.6 Camera fly-to
- van Wijk & Nuij optimal path: given start/end (center, width), compute the zoom-out → pan → zoom-in curve with parameter ρ ≈ 1.4. Duration scales with path length (0.5–1.5 s). Nearby targets give a short hop with little zoom-out.
- Keyboard:
  - `/` → search
  - `Enter` / `Shift+Enter` → next / prev hit
  - `Esc` → clear
  - `Home` → fit repo
  - `Backspace` → up to parent
  - `F` → fit selection
  - `Tab` → 2D/3D

---

## 7. UI

```
┌ Toolbar ────────────────────────────────────────────────────────────────────────────────┐
│ scrap ⋯ │ ⌂ 📂 ▦ │ Overlays: ⊘ imports calls scopes exports churn │ 2D · Iso · 3D │ ⚙ │ status line: hovered "Name (path)" / search stats │ [preset ▾] ● │
├──────────────────────────────────────────────────────────────┬──────────────────────────┤
│                                                              │ Inspector│Search│History │
│                         map viewport                         │ │Worktrees               │
│                                                              │                          │
│ breadcrumb: chromium / services / network / p2p / …          │                          │
└──────────────────────────────────────────────────────────────┴──────────────────────────┘
```

- **Status line** = hover (like Scope). **Inspector** = selection. Keep the two separate.
- **Inspector**: name · kind, path, line, source lines · bytes, children · descendants, then a metrics table (function metrics for scopes; git stats for files/dirs), and actions (Open in editor, Copy path, Reveal in explorer).
- **Search**:
  - symbol prefix (default); `?` prefix switches to full-text in v2
  - results grouped by file, hit count per file, rows `line  symbol  kind`
  - paging (64 per page, "More results")
  - hover row → blue highlight on the map; click / Enter → fly-to + yellow line highlight
  - result count + ms in the status line
- **History** (v2): commit list for the selection, time slider, "color by age/churn".
- **Worktrees** (v2): list `git worktree list` plus branches; switch or diff two refs.
- **Presets dropdown** (Scope's "Default"): named bundles of (color binding, height binding, overlays, filters).
- **Status dot**: indexer state (green idle, amber indexing with %, red error). Click it for the log.
- **Filters**: hide tests / vendored / generated (globs, with defaults from `.gitignore` + `third_party`, `vendor`, `node_modules`).

---

## 8. Indexer (Go) details

### 8.0 Reference corpus: `yougile` (the "heavy app")

`D:\Projects\dev\yougile-llc\yougile` is the primary real-world target. Measured 2026-09-19 via `git ls-files`:

| | |
|---|---|
| Tracked files | 18,303 (5,510 `.ts`, 1,993 `.tsx`, 582 `.js`, 340 `.scss`, 315 `.json`, 828 `.md`) |
| Assets | 5,455 `.svg`, 1,404 `.png`, 369 `.jpg`, 294 `.webp`, 64 `.mp4`, fonts |
| Tracked bytes | 816 MB, mostly media |
| Code (ts/tsx/js/jsx/mjs/scss) | **1.54M lines, 56 MB** |
| Largest code files | vendored bundles: `video.js` builds (2.2 MB), `stoplight.js` (1.9 MB) |
| Untracked but on disk | `node_modules`, `coverage`, `target`, `user-data`, `*.log`, **secret files** (`license.key`, `machine.key`) |

What this changes:
1. **Enumerate files with `git ls-files -z --cached --others --exclude-standard`** when the root is a git repo. It's exact, applies every ignore rule (nested, global, `info/exclude`), and never descends into `node_modules`. The manual walk with `.gitignore` parsing is only the fallback for non-git folders.
2. **Asset weighting.** Area-by-bytes would let media swallow the map. So:
   - binary and asset files (images, video, fonts, `.svg`, `.map`, lockfiles) weigh `clamp(bytes / 2 KB, 1, 200)` line-equivalents and render grey
   - a toolbar toggle **hides assets** entirely
3. **Minified/vendored code.** Weight = `max(lines, bytes / 80)`, so a 1-line 2 MB bundle is visible but not dominant. Files > 1 MB skip the precise parse. Paths that look vendored (`vendor/`, `third_party/`, `*.min.js`, `public/js/**/vendor/`) get a "vendored" flag, with a filter to dim or hide them.
4. **Secrets are never read.** A denylist (`*.key`, `*.pem`, `*.p12`, `.env*`, `id_rsa*`, `*secret*`, `*credential*`) keeps these files on the map as boxes (name + size) but never loads or serves their content.
5. **Performance budget for this repo:**
   - fast pass (walk + lexer + heuristic scopes) < 3 s
   - precise gotreesitter pass ≈ 15–20 s in the background (56 MB at ~3–4 MB/s)
   - warm restart from cache < 1 s

### 8.1 Pipeline

- **Enumerate:** `git ls-files` (see 8.0) or a `filepath.WalkDir` + `.gitignore` fallback; worker pool; binary sniffing (NUL byte); size cap for text rendering (configurable; Scope renders even 20 MB JSON).
- **Parse:** [`github.com/odvcencio/gotreesitter`](https://github.com/odvcencio/gotreesitter) (v0.52): a **pure-Go tree-sitter runtime, no cgo**. It loads the same parse tables as the C runtime and ships **206 grammars** with their highlight and tags queries. Evaluated 2026-09-19:
  - **What we use from it:**
    - `grammars.DetectLanguage(filename)` → language + `HighlightQuery` + `TagsQuery`
    - `Outliner.OutlineTree` → **nested definitions with full spans** (kind, name, range, children). These are our scope boxes and symbols directly; no hand-written `scopes.scm` needed.
    - `Highlighter` / highlight `Query` → token classes for syntax colors
    - `FactProgram` (`FactDefinitions | FactCalls | FactHeritage | FactImports`) → **imports, calls and inheritance edges in one traversal**. This is the data for the "Tokens" overlays (Go, JS/TS/TSX, Python, Java, Starlark today).
    - Incremental reparse, for the fs-watch path.
  - **Measured on this machine** (Go stdlib `net`, 390 files, 3.9 MB):
    - full parse ≈ **1 MB/s per core**, about 3.7 MB/s on 12 cores; the largest files dominate the tail
    - outline ≈ 50 ms/MB
    - highlight query ≈ 4 MB/s on an existing tree
    - That's roughly 3–5× slower than C tree-sitter: fine for a cached background index, too slow to run inside the tile renderer.
  - **Binary size:** 35 MB with all grammars. Build tags `grammar_subset,grammar_subset_<lang>…` trim it to the languages you ship.
  - **Two-phase indexing**, so big repos open instantly:
    1. **Fast pass:** our own lexer (`internal/syntax`) plus the brace/indent scope heuristic. The map, line textures and approximate scopes are ready in seconds.
    2. **Precise pass:** gotreesitter in a background worker pool, largest files first. It replaces scopes/symbols/token classes per file and streams `tiles_changed` to the viewer.
  - Results (scopes, symbols, edges, per-line token classes) are **cached on disk keyed by content hash**, so restarts and incremental updates only reparse changed files.
  - **Fallbacks:**
    - files with no grammar, or > 1 MB (minified bundles, generated code): keep the fast-pass output
    - highlighting for tiles: token classes from the cache, else the fast lexer
- **Symbols:** from Outliner definitions (plus body-less declarations from the fast pass), stored in the sorted symbol table.
- **Bake:** layout → tile pyramid → per-file char/class textures (written lazily on first request, cached).
- **Incremental:** fsnotify → re-parse changed files (content-hash skip) → roll up along ancestors → re-layout the affected subtree → re-bake the touched tiles → push `tiles_changed` to the viewer.
- **Git:** `git log --numstat --format=…` once, cached by HEAD; `git worktree list`.
- **CLI:** `scrap index <path>`, `scrap serve <path>`, `scrap stats <path>` (biggest dirs, hottest files, most complex functions), `scrap search <path> <prefix>`.

### 8.2 Protocol (localhost WebSocket, JSON control + binary payloads)
```
→ {op:"open", path}                         ← {op:"ready", world, maxZoom, tileSize, stats}
→ {op:"tile", z, x, y}                      ← binary: header + boxes + labels + code_blocks
→ {op:"text", file_id, col}                 ← binary: char/class texture (w, h, bytes)
→ {op:"node", id}                           ← {name, kind, path, line, lines, bytes, children, descendants, metrics{}}
→ {op:"pick", x, y, z}                      ← {id}
→ {op:"search", q, mode:"sym"|"text", page} ← {hits:[{file_id, node_id, line, name, kind}], total, more, ms}
→ {op:"git", id}                            ← {commits:[…], churn, age, authors}
← {op:"progress", pct, phase} · {op:"tiles_changed", list}
```

---

## 9. Milestones

| M | Deliverable | Proves |
|---|---|---|
| **M0** | Go: walk + line counts + ordered squarified layout → JSON. Godot: draw rects with one MultiMesh, pan/zoom. | The end-to-end pipeline |
| **M1** | Tile pyramid baking; Godot tile streaming + LRU; labels; status line (hover) + Inspector (selection); Home/fit. | Chromium-scale 2D navigation at 60 fps in pure GDScript |
| **M2** | Code shader: char/class textures, MSDF atlas, mip-based line texture; multi-column file flow. | "Zoom into the code" |
| **M3** | gotreesitter precise pass (Outliner scopes, highlight classes, facts) behind the fast pass, with a content-hash cache; scope outlines; symbol labels; function metrics. | In-file structure |
| **M4** | Symbol index + prefix search panel, paging, map highlights, van Wijk fly-to, keyboard. | Daily usefulness (parity with Scope's demo) |
| **M5** | 3D city: plinth heights, box instancing, roof code shader, orbit/dolly, animated 2D↔3D. | The wow factor, and a second way to read structure |
| **M6** | Git metrics, History tab, color/height bindings, presets, grey data files, filters. | Insight views |
| **M7** | Import/call edges overlays ("Tokens"), incremental watch, stable layout, Worktrees + diff mode. | "Better than Scope" |
| **M8** | Full-text trigram search, tours/annotations, editor bridge, optional LLM summaries. | Onboarding tool |

Test corpora: this repo (tiny) → Go stdlib (~2M LOC) → **yougile** (1.5M LOC TS + 18k files incl. assets; the primary real-world target, §8.0) → Chromium or Linux kernel (stress test).

---

## 10. Open questions

1. **Which languages first?** It should match the codebases you work in.
2. **Layout style:** ordered squarified (squarer, more readable labels) vs strip (closer to Scope, very stable). Default to one and keep the other switchable?
3. **Weight:** lines vs bytes. Default is lines, with bytes for data files.
4. **Scale target:** is "Chromium-smooth" required, or is ~5M LOC enough? The answer decides whether the tile pyramid is needed from M1 or can wait (for small repos a single MultiMesh + GDScript culling is enough).
5. ~~cgo on Windows~~: resolved. gotreesitter is pure Go (§8).
6. **3D height:** pure nesting depth (as Scope appears to do) or depth + a metric?
7. **Tokens group semantics:** Scope never showed them. Which overlays matter most to you: imports, calls, control flow, public API?
