# scrap wire protocol

Version **5** (`hello.protocol`). The `scrap serve` process and the viewers talk over one WebSocket (`ws://127.0.0.1:7878/ws` by default).

- **Text frames** carry JSON control messages.
- **Binary frames** carry geometry, text textures and the font atlas.

All binary values are little endian. Any incompatible change to a message or frame bumps the version, both in `scrap/internal/server/api.go` (`Protocol`) and in each viewer (`ScrapClient.PROTOCOL`). A viewer that sees a different version says so in its status bar.

History:

| Version | Change |
|---|---|
| 5 | Labels carry the box color (`u8 r, g, b`) and, for scopes, the scope kind in the kind byte's high nibble. Scope instances: kind = 2 + scope kind / 10, depth = nesting inside the file. `options` accepts `rules`. |
| 4 | `children` op. `search` also returns `paths`/`pathTotal` (files and folders). `node` accepts `path` instead of `node`. |
| 3 | `hello.lenses` (lens descriptors) and `hello.legend`. `node.ancestors`. Relation replies carry `names`. |
| 2 | Text blocks carry a content key (`u32 key`) in tile frames and text frames. `hello.protocol` added. `options` accepts `weights` and `gitSince`. |
| 1 | Initial (unversioned). |

## Concepts

- **World:** the map lives in world units. The root rectangle is `hello.world` = `[x, y, w, h]`, about `[0, 0, 1, 0.625]`. Heights (3D) use the same units.
- **Tiles:** a quadtree over the unit square. Tile `(z, x, y)` covers `[x/2^z, y/2^z, 1/2^z, 1/2^z]` and is drawn at about `hello.tilePx` pixels. `z ≤ hello.maxZ`.
- **Generation (`gen`):** each rebuilt map (fast pass → precise pass, git history loaded, lens change, folder opened) gets a new `gen`, announced by a fresh `hello`.
  - Node ids are only valid within one generation.
  - Requests carry the `gen` they were made for; the server drops work for older generations.
- **Text blocks:** one column of a file's text layout, at most `hello.text.blockRows` lines, drawn on the GPU. A block's `key` is a hash of path + layout + place. It stays the same across generations whenever the texture would be identical, so viewers keep text they already have.

## Requests (viewer → server)

Every request is `{"op": …, "id": n, …}`. JSON replies echo `id`.

| op | fields | reply |
|---|---|---|
| `hello` | — | `hello` |
| `tiles` | `gen`, `dim` (2 flat · 3 city), `keys: [[z, x, y], …]` in priority order | binary tile frames. The list **replaces** the pending queue. |
| `texts` | `gen`, `texts: [[fileNode, col, seg], …]` | binary text frames. The list replaces the pending text queue. Tiles go first. |
| `font` | — | one binary font-atlas frame |
| `node` | `node`, or `path` (a file or folder, stable across generations) | `node` |
| `children` | `node` | `{"op": "children", "node", "items": [{node, name, kind, lines, kids, color}]}`: dirs, then files, then scopes |
| `pick` | `x`, `y` (world), `scale` (px per world unit) | `pick` |
| `pickRay` | `ray: [ox, oy, oz, dx, dy, dz]` (world units, Y up) | `pick` with `t` (ray distance) |
| `heights` | `pts: [[x, y], …]` | `{"op": "heights", "h": [roof height, …]}` |
| `search` | `q` (symbol-name prefix), `page`, `size` (≤ 500) | `search` |
| `edges` | `node` | relations: imports (file level) |
| `calls` | `node` | relations: syntax-level call graph |
| `options` | any of `view: {height, color, importance}`, `weights: {vendored, test, minified, asset, data}`, `rules` ("glob = weight; …", plus the repo's `.scrap.json`), `gitSince` | no reply. The map rebuilds and a new `hello` follows when anything changed. |
| `open` | `path` | new `hello` once indexed, or `{"op": "error", "error": …}` |

## Messages (server → viewer)

### `hello`

```json
{
  "op": "hello", "protocol": 5, "gen": 3,
  "root": "D:/repo", "name": "repo",
  "world": [0, 0, 1, 0.625], "tilePx": 256, "maxZ": 24, "maxTop": 0.05,
  "precise": true, "git": true,
  "stats": {"Files": 18303, "Lines": 1849427, "...": "..."},
  "view": {"height": "depth", "color": "area", "importance": false, "weights": {}},
  "metrics": ["lines", "complexity", "functions", "churn", "age", "authors"],
  "lenses": {"height": [Lens, …], "color": [Lens, …]},
  "legend": {"kind": "area", "areas": [{"node", "name", "color": [r, g, b], "lines"}, …], "more": 3},
  "text": {"font": "consola.ttf", "colChars": 100, "blockRows": 4096, "texW": 128}
}
```

The server sends it on connect and after every rebuild.

- **Lens:** `{id, short, long, desc, unit, high, needsGit}`. Viewers build their lens menus, descriptions and legend units from these, so a new metric needs no viewer change.
- **Legend:** under a metric color lens it is `{"kind": "metric", "ramp": [[r, g, b] × 9], "quantiles": [p0, p25, p50, p75, p100]}`, with quantiles in the lens unit (null when no file has a value). Otherwise it lists up to 16 top-level areas, biggest first; `more` counts the rest.

### `progress`

`{"op": "progress", "pass": "fast"|"precise"|"git", "phase": …, "done": n, "total": n}`

This is broadcast while indexing. `done == total` ends a phase.

### `node`

The node's id, `parent`, `name`, `kind` (`dir` | `file` | `scope`), `path`, `lines`, `bytes`, `children`, `descendants`, `rect`, `top` and `line`. Depending on the node it also carries:

- files and scopes: `lang`, `precise`, `classes`;
- files: `fileMetrics` (`functions`, `maxComplexity`, and when git is loaded `commits`, `authors`, `lastChange`);
- scopes: `scope` (the kind);
- function scopes: `metrics` (`complexity`, `params`, `nesting`, `lines`).

`ancestors: [[id, name], …]` runs from the root down to the parent (for breadcrumbs).

### `pick`

`node` (−1 = nothing) and `line` (file line under the point, or −1). When a node was hit, it also carries `name`, `kind`, `path`, `rect`, `top`, and `lineRect` or `t`.

### `search`

`q`, `page`, `total`, `more`, `ms`, `files` and `hits`:

- `files: [[x, y, w, h, top], …]` lists every file with a hit.
- `hits: [{node, fileNode, path, line, name, kind, rect, top}, …]`: `rect` is the line's rectangle.
- `paths: [{node, path, name, kind, rect, top}, …]` (page 0, best 50): files and folders whose path contains every word of `q`, name matches first; `pathTotal` counts all.

### Relations (`edges`, `calls`)

`node`, `out: [[from, to], …]`, `in: [[from, to], …]`, `outTotal`, `inTotal` `nodes: {"id": [x, y, w, h, top]}` and `names: {"id": "path" or "name · path"}`. `nodes` gives the geometry of every endpoint, so arcs draw without further requests. Each list is capped at 2000 edges.

## Binary frames

The first byte is the frame type.

### 1 / 2: box tile (2D / 3D)

```
u8  type (1 = 2D, 2 = 3D)
u8  z
u16 flags (reserved, 0)
i32 x, i32 y
u32 gen
u32 n                        boxes
f32 × 16n (2D) | 20n (3D)    MultiMesh instance buffer (TRANSFORM_2D|3D + color + custom)
i32 × n                      node ids
u32 nl                       labels
nl × { i32 id, u8 kind, u8 r, g, b, f32 x, y, w, h, top, u16 len, utf8 × len }
u32 nb                       text blocks
nb × { i32 file, u16 col, u16 seg, u16 rows, f32 x, y, w, h, top, u32 key }
```

- Coordinates are tile-local (0..1).
- Instance custom data = `(edge mask, kind, depth, trueMin / pieceWidth)`:
  - the edge mask marks the box's real edges in this tile (1 left, 2 top, 4 right, 8 bottom);
  - kind 0 is a directory, 1 a file, 2 + k/10 a scope of kind k (0 block, 1 func, 2 type, 3 namespace);
  - depth is the nesting depth (for scopes: inside their file).
- Label kind: low nibble 0 dir, 1 file, 2 scope; high nibble the scope kind. `r, g, b` is the box's outline color.

### 3: text block

```
u8  type (3), u8 0
u16 col
i32 file
u16 seg
u16 rows
u32 gen
u32 key
RGBA8 × texW·rows    premultiplied syntax color × "has a glyph" (mipmapped by the viewer)
RG8   × texW·rows    glyph atlas cell per character (u16)
```

### 4: font atlas

```
u8 type (4), u8 0
u16 cols, rows, cellW, cellH
L8 × (cols·cellW) × (rows·cellH)   glyph coverage
```
