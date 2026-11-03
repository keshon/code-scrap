# code-scrap

A zoomable map of a codebase. The whole repository is one surface:
directories, files and code scopes are nested boxes, and you zoom from the
overview down to readable, syntax-highlighted code without opening anything.
It's inspired by Rik Arends' Makepad Scope; the original design and reference
frames are preserved in the [historical specification](docs/internal/specification.md).

![overview](docs/screenshots/overview.png)

![search and fly-to](docs/screenshots/search-flyto.png)

![3D city](docs/screenshots/city.png)

## What it shows

- A flat map or 3D city of directories, files and scopes.
- Symbol/path search with fly-to, Explorer and a clickable Inspector route map.
- Import/call relations, git-history lenses and importance weighting.
- Streamed geometry/text tiles, analysis caching and file watching.
- Schema-driven settings, themes, keymaps and presets.

## Quick start

Use Go 1.26.4+ (see [scrap/go.mod](scrap/go.mod)), Git and Godot 4.7. From the
repository root on Windows, set `GODOT` to your executable if the helper's
configured path does not match your machine:

```powershell
$env:GODOT = 'C:\path\to\Godot.exe'
.\build.cmd run D:\path\to\repository
```

The viewer starts the local indexer/server when needed. For manual build/run,
controls, cache settings and packaged copies, see [Running](docs/running.md).
The implemented viewer is GDScript; the C# viewer described in old planning
material is not included.

## Documentation

| Guide | Contents |
|---|---|
| [Running](docs/running.md) | Build/run, controls, lenses, local state and troubleshooting |
| [Architecture](docs/architecture.md) | Indexing, layout, streaming, settings and process lifetime |
| [Protocol](docs/protocol.md) | JSON messages, binary frames and compatibility |
| [Conventions](docs/conventions.md) | Development checks, viewer verification and packaging |

The original [specification](SPEC.md) and [polish plan](docs/PLAN.md) point to
historical archives. Use current guides rather than their old status lists.
