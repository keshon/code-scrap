# Architecture

code-scrap has two running parts: a Go indexer/tile server and a Godot GDScript
viewer. The server performs analysis/layout; the viewer streams tiles, renders
and handles interaction. The proposed C# viewer is historical planning, not a
second implemented frontend.

## Components

| Path | What |
|---|---|
| `scrap/` | Go indexer and tile server (`scrap` command) |
| `viewer-gd/` | Godot 4.7 viewer in GDScript |
| `docs/internal/` | Historical specification and polish plan |
| `docs/reference/` | Frames of the Makepad Scope demo used for the spec |

All heavy work happens in `scrap`:

- file enumeration (`git ls-files`)
- tokenizing and scope finding (a fast heuristic pass, then a precise tree-sitter pass via [gotreesitter](https://github.com/odvcencio/gotreesitter), pure Go)
- layout
- symbol search
- tiles:
  - vector box tiles, as ready-to-upload MultiMesh buffers
  - raster code tiles: line dashes when zoomed out, Go Mono glyphs when zoomed in

The viewer streams tiles, draws them and handles the UI.

## Index and rendering flow

1. Enumerate repository files, normally through `git ls-files`; `-nogit` uses
   filesystem enumeration instead.
2. Build a fast code map, with the precise tree-sitter pass providing refined
   scopes. Syntax analysis is in `scrap/internal/syntax` and the map model in
   `scrap/internal/codemap`.
3. Pack directory/file/scope boxes with `scrap/internal/treemap`; prepare
   geometry and text tiles in `scrap/internal/tile`.
4. `scrap/internal/server` serves JSON control messages and binary tile/font
   frames over a WebSocket. A replacement map increments its generation so
   clients can distinguish stale streamed content.
5. `viewer-gd/scripts/` receives the protocol, manages selection/camera state,
   renders tiles and provides Explorer/Inspector/settings UI.

Git history is loaded in the background for metrics/co-change lenses. File
analysis and git caches reduce repeated work. File watching re-indexes changes;
these are implemented features, not outstanding milestones.

## Settings and persistence

`config/settings.schema.json` defines tunable settings. The viewer resolves
schema defaults, preset values and user overrides in that order. Shipped
keymaps/themes/presets live in `config/`; user settings and navigation state
live in Godot's user data directory. Server analysis caches live separately in
the OS user cache directory.

## Protocol and process lifetime

The viewer can start `scrap serve` if the configured local endpoint is absent.
The server's `-parent` flag lets a viewer-owned server exit when its parent
process exits. A manually started server has a separate lifetime.

The current protocol is [documented separately](protocol.md). Its version is
pinned in both `scrap/internal/server/api.go` and
`viewer-gd/scripts/scrap_client.gd`. Build matching parts when the format changes.
The protocol is local application plumbing, not a remote authenticated API.

## Limits and evidence

Import/call relations are syntax-derived and ambiguous names can be skipped;
they are navigation aids rather than a complete compiler call graph. Results
and rendering cost depend on the repository and enabled lenses/budgets.
Historical corpus measurements and design alternatives remain in
[the specification](internal/specification.md) and
[the polish plan](internal/polish-plan.md); they are not current performance
or completion guarantees.
