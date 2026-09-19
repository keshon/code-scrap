# Polish plan

Status: approved · 2026-09-19 · baseline commit `d18af10` · Phase 1–5 done, theme A (Calm) first

This plan turns the prototype into a tool: a data-driven core, a real UI shell, and a viewport that reads well. It covers the 20 review points from 2026-09-19. The phases are ordered so that each one builds on the previous: first the foundations everything else plugs into, then fixes, then the shell, then viewport polish.

---

## Guiding rules

1. **Everything tunable lives in settings.** Every number, color, width, toggle and key binding comes from one settings schema. It can be saved as a preset file and edited in an auto-generated settings panel. No magic constants in scripts.
2. **Every visual encoding has a legend.** If a color, width or height means something, the viewport says what.
3. **Lenses are optional.** Defaults show the plain map (see memory: everything is toggleable).
4. **Shared across both viewers.** The settings schema, presets, keymaps and lens descriptions are plain JSON at the repo root, so the C# viewer reuses them unchanged.

---

## Phase 1 — Foundations (data-driven core)

Everything later hangs off these, so they come first.

> **Done (2026-09-19).** Autoloads `Settings`, `Keymap` and `Style` (`viewer-gd/scripts/core/`), a generated settings panel (`scripts/ui/settings_panel.gd`), Maya and Classic keymaps, Calm and FUI theme tokens, IBM Plex fonts, UI scale with a physical-resolution 3D viewport, text tunables as shader globals, and server `options` for importance weights and the git window. Still to come: in-panel key rebinding (edit keymap JSON for now), server layout constants (terrace steps, padding), and "Reset group".

### 1.1 Settings system (points 12, 13, 17)
- `config/settings.schema.json` holds every parameter: `id`, group, type (bool / int / float / enum / color / px / key-binding), default, range, label, description, and the scope it applies to (`viewer` | `server` | `both`).
- `config/presets/*.json` are named presets that override defaults, e.g. `default`, `scope-classic`, `reading`, `fui`. User presets live in `user://presets/`.
- **Settings service** (autoload singleton): load → merge (defaults < preset < user overrides) → notify listeners on change. Live preview: changing a value updates the viewport immediately.
- **Settings panel** is generated from the schema: group → FoldableContainer, each field an appropriate control (SpinBox, slider, ColorPickerButton, OptionButton, key-capture button). Search field on top. "Save as preset…", "Reset group".
- Server-side settings (importance weights, git window, layout constants such as terrace steps and padding) travel in the existing `options` op, so they're also saved in presets.

### 1.2 Input map (point 7)
- `config/keymaps/maya.json` is the default; `softimage.json`, `modo.json` and `blender.json` follow later. Each binding maps an **action** to mouse button + modifiers + key.
- Actions: `orbit`, `pan`, `dolly`, `zoom_wheel`, `frame_selected` (F), `frame_all` (A), `deselect` (Q, or click on empty space), `select`, `select_parent`, `toggle_view` (Tab), `search` (/), `bookmark_1..9`, `toggle_display_menu`, …
- Maya preset: **Alt+LMB orbit · Alt+MMB pan · Alt+RMB dolly · wheel zoom to cursor**. In 2D, orbit maps to pan.
- A `KeymapService` turns input events into actions, and both views consume actions, never raw events. Rebinding happens in the settings panel.

### 1.3 UI scale / DPI (point 5)
- `ui_scale` setting (0.75–2.5, default = OS DPI scale), applied through `Window.content_scale_factor` for the whole app.
- Separate knobs for **viewport label size** and **code text minimum readable size**, because the viewport doesn't scale with the UI.

### 1.4 Theme tokens (point 4)
- Godot has everything needed built in, so there's nothing to invent. The Control nodes (Panel, TabContainer, FoldableContainer, Tree, PopupMenu, MenuButton, OptionButton, SpinBox, slider, ColorPickerButton, SplitContainer) are all styled by a **Theme** resource.
- A `ThemeBuilder` script generates the Theme from **design tokens** in the preset: surface levels, border, radius, spacing, font sizes, accent and shadow. A preset can therefore switch between styles (see the decision at the end).

---

## Phase 2 — Stability, correctness, cleanup (points 3, 8, 16)

> **Done (2026-09-19).**
> - **Flicker:**
>   - Text blocks are content-keyed (`TextKey` = path + layout + place, protocol v2), so a new generation keeps loaded text.
>   - Shown blocks get a 1.5× priority bonus at the budget cutoff, and blocks fade in and out over 150 ms.
>   - Missing tiles fall back to loaded ancestors *or* children.
>   - The 2D level has hysteresis.
>   - Diagnostics HUD on F12.
> - **Lines:** 2D outlines snap to pixels with an exact width. Line widths, the smallest outlined box and a nesting tone are settings.
> - **Cleanup:**
>   - `main.gd` split into `Toolbar`, `StatusBar`, `Inspector`, `SearchPanel`, `Hud` and `SettingsPanel` (`scripts/ui/`), plus `TestDriver`.
>   - Shared tile fallback and label placement moved to `ViewCommon`; `_code_mat` and `SCRAP_DEBUG` removed.
>   - `docs/protocol.md` added, versioned by `hello.protocol`.
>   - Fixture tests for classification, secrets, layout, imports, calls, importance weights, search and text-key stability.
> - **Deferred:**
>   - One server `Options` type: `View` now carries the weights and the git window sits on `Server`, so there's little left to gain.
>   - Lens descriptors from the server: moved to Phase 3 with point 14.
>   - Tile cross-fades: child/ancestor fallback removed the visible holes, so they may not be needed; the HUD will tell.

### 2.1 Flicker (point 16): root causes found in code
| Cause | Where | Fix |
|---|---|---|
| Every `hello` (precise pass finishes, git loads, any lens change) calls `TextLayer.reset()` and **drops all text** until it reloads | `map_view.gd`, `city_view.gd` `_on_hello` | Keep the old text: text content doesn't change between generations, only placement does. Re-key blocks by (file, col, seg) and reposition them from the new tiles' block lists. |
| Hard text budget `slice(0, 220)`, re-sorted every frame: blocks near the cutoff blink on/off | `_update_text` | Hysteresis: blocks that are already shown keep priority; budget comes from settings; fade in/out over ~150 ms instead of popping. |
| Tile cache eviction and ancestor-fallback swaps | tile update | Keep drawing a tile until its replacement has been visible for one frame; cross-fade on level change. |
| (to verify) floating-origin recentre causing a one-frame offset | 3D camera | Recentre between frames, before placing any node. |

Add a **diagnostics HUD** (toggle, F12): tiles wanted/pending/cached, text blocks wanted/visible, evictions per second, generation changes, frame time. That confirms these fixes and catches future regressions.

### 2.2 Line rendering (point 8, "some lines are thinner")
There's no intentional perspective effect. The line width varies because:
1. Outline opacity fades with each box's size on screen (`smoothstep(3, 9, true_px)`), so smaller boxes get fainter lines.
2. Nothing snaps to pixels: a 1 px line that falls between two pixels renders 2 px wide at half strength.
3. Nested boxes with small padding put two outlines 1–2 px apart, which read as one thick line.

Fix: edge distance measured in real screen pixels with pixel-center alignment. Width becomes a setting (`line.width.default`, `line.width.selected`, `line.width.hover`). Nesting is shown with a separate, explicit **depth tone** (a setting) instead of the accidental opacity fade.

### 2.3 Code cleanup
- **Viewer:**
  - Split `main.gd` (753 lines) into components: `AppShell`, `Toolbar`, `Sidebar`, `StatusBar`, `Inspector`, `SearchPanel`, `SettingsPanel`.
  - Extract shared pieces from `map_view.gd` and `city_view.gd`: label placement, selection/hover state, tile streaming bookkeeping.
  - Remove dead code: `_code_mat`, and the `SCRAP_DEBUG` print, which moves into the HUD.
  - Move the automation flags (`--shot`, `--wheel`, …) into a `TestDriver` node, so they stop cluttering the app shell.
- **Server:**
  - Drop the raster code-tile path from the protocol; keep it only for the `render` preview.
  - Move `View` and settings into one `Options` type.
  - Lens descriptors come from the server (point 14).
  - Add unit tests for layout, classification, resolver and calls, using fixtures instead of the live repo.
- **Protocol:** document it in one place (`docs/protocol.md`), versioned via `hello.protocol`.

---

## Phase 3 — UI shell (points 4, 5, 6, 14, 15)

> **Done (2026-09-19).**
> - **Zones as sketched below:**
>   - top bar: repository menu with recent folders, 2D|3D, preset, search/command field, settings;
>   - left **Display panel**: lenses with descriptions, importance weights, git window, overlays;
>   - **viewport header**: collapsing, clickable breadcrumb, Camera menu, ☰ display toggles;
>   - **legend** (bottom right): area swatches (click to frame) or metric ramp with quantiles and unit, relation and search colors;
>   - right panel: Inspector with clickable relation lists, Search results;
>   - status bar with fps.
> - **Lens descriptors** come from the server (protocol v3), along with legend data and breadcrumb ancestors.
> - **Search:**
>   - file rows select files; a click selects, and double-click or Enter flies;
>   - a "Fly" toggle;
>   - `>` switches to command mode (frame, toggles, theme, keymap…).
> - **Also:** every viewport display option is a setting, `SettingRow` is shared by the settings and Display panels, and scripted runs no longer write to the user's settings.
> - **Not done:** the minimap (Phase 5 has it) and panel docking/resizing beyond split containers.

### 3.1 Zones, in the Modo / Softimage tradition (point 6)
```
┌──────────────────────────────── Top bar ────────────────────────────────┐
│ app ▾ │ repo ▾ (open, recent) │ 2D|3D │ preset ▾ │   ⌕ search / command   │
├────────────┬───────────────── Viewport ───────────────────┬─────────────┤
│  LEFT      │ ┌ viewport header ────────────────────────┐   │  RIGHT      │
│  Display   │ │ breadcrumb › path › here    cam ▾  ☰ ▾ │   │  Inspector  │
│  panel     │ └─────────────────────────────────────────┘   │  ───────    │
│            │                                               │  Relations  │
│  Lenses    │                                               │  (imports,  │
│  · height  │                                               │   callers,  │
│  · color   │                                               │   lists)    │
│  · weights │                                               │  ───────    │
│  Overlays  │                        ┌── legend ──┐         │  Search     │
│  · imports │                        │ color ramp │         │  results    │
│  · calls   │  ┌─ minimap ─┐         │ arc colors │         │             │
│  · labels  │  └───────────┘         └────────────┘         │             │
├────────────┴───────────────────────────────────────────────┴─────────────┤
│ status: hover path · line │ hint: Alt+LMB orbit … │ index/git ● │ fps  │
└───────────────────────────────────────────────────────────────────────────┘
```
Where today's controls move, and why:

| Today | Moves to | Why |
|---|---|---|
| Hover path, progress, server dot (toolbar) | **Status bar** | Transient state belongs at the bottom (Maya/Modo convention); the toolbar is for commands |
| Height / color / importance / imports / calls (toolbar) | **Left Display panel** ("command panel" in 3ds Max terms) | These are persistent viewing modes with parameters; they need room for sliders and descriptions |
| Viewport display options (none yet) | **Viewport header ☰ menu, top-right** | The classic placement: selection style, labels, scope outlines, edges, fog, text |
| Legend (a toolbar label) | **Viewport overlay, bottom-right** | It explains what you're looking at, so it sits next to it |
| Search field (right tab) | **Top bar**: one field for search and commands (Ctrl+K) | Always reachable; results in the right panel |
| Inspector | **Right panel**, now with Relations lists | Properties of the selection |
| Breadcrumb (none yet) | **Viewport header, left** | "Where am I", clickable to go up |

Mouse hints in the status bar follow the active keymap ("Alt+LMB orbit · Alt+MMB pan · F frame · A all · Q deselect"), as Modo does.

### 3.2 Lens descriptors (point 14)
The server sends each lens as `{id, short, long, description, unit, needsGit, direction}`. For example, churn: "Churn · Commits touching the file in the history window · high = changed often". The UI shows the long name and description in the Display panel and tooltips, and the legend shows the unit.

### 3.3 Search (point 15)
- Results tree: **file rows are clickable** (select file) and line rows select the symbol. Double-click or Enter flies.
- "Fly to result" toggle, plus a setting for the default. When off, the selection just highlights and the camera stays put.
- Result count, paging and timing in the panel header; clear with Esc.

### 3.4 Style direction (point 4): decision needed
- **A. Calm / layered** (the Anthropic-like concept): rounded surfaces, soft elevation, generous spacing, few borders, one restrained accent.
- **B. FUI:** hairline borders, corner brackets, uppercase monospace labels, grid texture, thin dividers, instrument-panel feel.
- **C. Hybrid (recommended):** calm panels for the shell, FUI treatment only inside the viewport (header, legend, minimap, labels, HUD). The tool chrome stays quiet and the viewport feels like an instrument.

All three are token presets on the same components, so switching later is cheap.

---

## Phase 3.1 — UI map (review of 2026-09-19)

After testing Phase 3, the rule: **every control has exactly one home.** A setting's `surface` in the schema names it; the settings panel shows only tunables (no surface).

| Home | Owns | Not here |
|---|---|---|
| **Top bar** | app-level: Explorer toggle, repository (open, recent), 2D/3D, preset, the one search/command field, settings | camera commands, viewing modes |
| **Explorer** (left, optional) | the tree: folders → files → functions; follows the selection | — |
| **Viewport header**, three islands | breadcrumb (segment = select, › = what is inside), **Camera** (frame all/selected, deselect, parent, 2D/3D), **☰ display** (labels, code text, hover, search highlights, arcs, legend, diagnostics) | lenses |
| **Right pane** | **Inspector** (selection, metrics, clickable relations) · **View** (height, grayed in 2D · color · importance + weights · git window · import/call arcs) | display toggles |
| **Search dropdown** | under the top-bar field: files and folders by path, symbols by name prefix, `>` commands; ↑↓ Enter Esc | a separate results tab |
| **Settings** | tunables: widths, colors, budgets, speeds, theme, keymap, scale | toggles that have a home above |
| **Legend** (viewport corner) | explains colors, arcs, highlights; areas are clickable | — |

The Frame all / Frame selected buttons that used to sit in the top bar now live only in the Camera island.

Done (2026-09-19). Protocol v4 adds `children` (tree and breadcrumb menus), path hits in `search`, and `node` by `path` (ids change between generations, paths do not).

---

## Phase 4 — Viewport polish (points 8–11, 13, 16, 18)

> **Done (2026-09-19).**
> - **Highlights:** selection and hover styles (outline, depth tested / x-ray / off) plus roof fill opacity; 3D labels are depth-tested `Label3D`s, with "Labels through buildings" in ☰.
> - **Scopes:** scope outlines are styled by kind (rounded solid functions, dashed classes, types and namespaces), fade with nesting, and are tunable.
> - **Labels:** folders get hue tabs, files an extension chip, scopes a legend cut into their border; priority is dir > file > scope, with a spacing setting.
> - **Legend:** now also shows the height lens in 3D, selection and hover colors and the dimmed classes, and can collapse.
> - **Arcs:** direction, most arcs, height, arrowheads, through-buildings, and screen-space grouping of small endpoints (thicker arcs by count).
> - **Importance:** glob rules (`glob = weight; …`) plus a repo-local `.scrap.json`.
> - **Look:** mono / auto / syntax roof text, roof lift, bevels, a directional light (direction, height, strength) or flat, contact shading, dotted ground grid with a horizon glow, and a reading assist.
> - **Deferred to Phase 5:**
>   - hover tooltips on arcs;
>   - folder names on plinth walls (3D labels are billboards at the roof edge);
>   - focus + context dimming;
>   - palette presets;
>   - SSAO (the look stays unshaded and tunable);
>   - hierarchical edge bundling.

### 4.1 Selection and hover styles (point 8), in the ☰ menu and settings
- **Style:** outline only (default) · outline + roof tint · x-ray outline (through geometry) · off.
- **Outline:** width (px), color. Silhouette edges only, depth-tested by default, so it no longer crosses code.
- **Roof fill:** none · transparent tint (opacity) · solid. Default: none.
- **Hover:** same knobs, separate values.
- **Labels through geometry:** on/off (default off: occluded labels hide or fade).

### 4.2 Scope outlines inside files (point 9)
What the "big zone" is: scope boxes are the code's own structure. A big rectangle inside a file is a top-level scope covering most of it (a class, a `type … struct` with its methods, a module-level wrapper). The file block itself is geometry; scope boxes are drawn on its roof. They look the same today, which is why they're confusing.

The fix is to style them by **kind** and make each kind tunable:
- **Namespace / type / class:** rounded corners, dashed line, name tab on the border (fieldset-legend style).
- **Function:** rounded corners, solid thin line, name on hover or when big enough.
- **Nested scopes:** indented, lower opacity per level.
- Settings per kind: visible, opacity, width (px), corner radius, dash, label mode.

### 4.3 Labels / badges (point 10)
Today every label is the same pill, floating and interleaved, so containers and contents blur together. Redesign:
- **Directories:** a **tab docked to the box's top edge**, like a folder tab: hue-colored left stripe, bold, the box's outline running into the tab. It reads as "the name of this container".
- **Files:** smaller, lighter, inside the box's top-left corner, with an extension color chip.
- **Scopes:** a legend cut into the scope border (see 4.2), no pill.
- In 3D, directory names go **on the plinth's front wall** and file names on the roof edge. Distance fade and occlusion follow the setting.
- Collision priority: directory > file > scope, with a density setting.

### 4.4 Legend (point 11)
A viewport overlay (bottom-right, collapsible) generated from what's active: color lens ramp with unit, height meaning, arc colors (imports out/in, calls out/in), selection/hover/search colors, file classes (grey = data/assets, dim = vendored). Every new encoding has to register a legend entry, so none can be added without one.

### 4.5 Relation arcs (point 13)
- **Params per relation (imports, calls):** visible, color out/in, width, opacity, arc height, depth-tested vs through geometry, max arcs, direction (out / in / both), show arrowheads.
- **Aggregation:** when endpoints are small on screen, group arcs by folder (one thick arc per folder pair, width ∝ count). This fixes the overlap and blended colors in the screenshots.
- **Bundling** (hierarchical edge bundling, Holten 2006) as an option later.
- Hovering an arc highlights both ends and shows a tooltip "a.ts → b.ts (import)".
- Arc endpoints listed in the Inspector's Relations section; click to select, double-click to fly.

### 4.6 Importance, tunable (point 12)
- Per-class factor sliders: vendored, test, generated/minified, asset, data, docs.
- **Custom rules:** glob → factor (e.g. `src/legacy/** = 0.3`, `**/*.stories.tsx = 0.2`).
- Rules live in presets; an optional repo-local `.scrap.json` overrides them for that repo.

### 4.7 Making the viewport read better (point 18): ideas
- **Reading assist:** as you zoom into code, the camera eases toward a top-down reading angle, and eases back when you pull out. This is the biggest comfort win for code on roofs.
- **Contact shading:** walls darken near their base (cheap, in-shader), so plinth steps read without real lighting.
- **Ground:** dotted infinite grid, like Scope's canvas, plus a faint horizon gradient instead of flat black.
- **Focus + context:** when relations or search are active, dim everything unrelated (an opacity setting).
- **Code roofs:** a slightly lifted roof tone behind text for contrast, and a line-spacing setting.
- **Palettes as presets:** Scope pastel, neutral grey (Modo-like), FUI cyan.
- **Roof text color: syntax / mono / auto** (from the Scope reference). From a distance, syntax colors on roofs carry no information and add visual load, so Scope shows near-monochrome roofs. "Auto" fades from mono to syntax colors as lines become readable. The mono tone and the fade range are settings.
- **Bevels:** buildings and plinths get a chamfered top edge that catches light, as in the reference. Bevel size is relative to box size, drawn in the shader or with a bevelled mesh variant; on/off and size are settings.
- **Lighting model:** today it's unshaded with a fake directional term. Options: flat · directional + ambient · directional + SSAO (Godot's environment, with the city shader switched to a lit one). The goal is readable shadows and highlights between terraces, as in the reference. Light direction and intensity are settings.

---

## Phase 5 — Extras (point 19)

> **Done (2026-09-19).**
> - **Minimap** (bottom-left, ☰): shows the view rectangle in 2D and the ground footprint in 3D; click or drag it to move.
> - **Bookmarks:** Ctrl+1..9 saves and 1..9 goes back, per repository (view, camera, selection by path).
> - **Startup cache:**
>   - per-file analysis is cached by path + size + mtime, and git history by HEAD + day + window, in the user cache folder;
>   - on yougile a warm start takes 0.3 s for the fast pass (already precise) + 0.3 s for the precise pass + 49 ms for git, instead of 1.6 s + 7.5 s + 0.55 s cold.
> - **Stable layout** (View tab): siblings are ordered by name.
> - **Relations explorer:** `]` / `[` step through the Inspector's relation list; the list stays anchored to where you started.
> - **File watching:** polls every 2 s and re-indexes from the cache (tens of ms); a new git HEAD re-reads history. Turn off with `scrap serve -no-watch` (and `-no-cache`).
> - **From Phase 4:**
>   - 2D focus + context dimming (Settings → Look);
>   - 2D arc tooltips;
>   - area palettes (pastel / neutral / cyan);
>   - folder names printed on the terrace wall that faces the camera.
> - **Also fixed:** after a wheel zoom in 3D, two height drivers kept the camera from ever resting, so the view redrew every frame. An idle city now costs 0 redraws (5 ms/frame instead of 20). The HUD shows redraws per second and what caused them.
> - **Not planned:**
>   - SSAO: the city is shaded in its own unshaded shader, which contact shading and bevels already cover;
>   - hierarchical edge bundling: screen-space grouping solves the overlap in practice;
>   - dimming in 3D.

- **Minimap** (bottom-left): the whole repo with the current view rectangle. Keeps context while deep in code.
- **Bookmarks:** Ctrl+1..9 saves a camera + selection, 1..9 recalls it.
- **Startup cache:** persist the precise pass and git results keyed by content hash; restarts become instant.
- **Stable layout option:** layout by name, so lenses and edits don't reshuffle the map.
- **Relations explorer:** step through callers/callees with the keyboard.
- **File watching:** incremental re-index on save.

---

## Phase 6 — review of 2026-09-19 (third round)

| # | Point | Done |
|---|---|---|
| 1 | Volume hard to read; specular control | Settings → Look: **Light follows** camera (a headlight, as in Softimage) or world (a sun); ambient; specular strength and glossiness |
| 2 | Bevels on vertical edges | Rounded vertical edges with a radius setting; the segment count grows with the radius. Real geometry, shaped per box in the vertex shader, only at real corners. The 2D map rounds its corners from the same setting. The cap chamfer was tried and dropped (not worth its trouble); the fake roof-band bevel is gone |
| 3 | Selection: tint or a clean outline | Styles: **silhouette** (one outline around the box, no inner edges, drawn over everything, stencil based) · tint (the box itself glows) · both · off. The same for hover |
| 4 | Diffuse-only top planes | **Diffuse-only roofs**: all · selected only · none |
| 5 | Code glued to the left edge | A gutter: line numbers (☰ → Line numbers) or 2 characters of padding. Scope outlines and search hits start after it (server, protocol v7) |
| 6 | 2D: folder tab hides the first file's name | A label that collides tries fallback spots; a file name steps below the folder tab |
| 7 | 3D labels on walls or inside neighbours | Labels sit centred on their own roof. **Hidden labels**: dim (a faint copy through buildings) · hide · show. **Distance fade** for far boxes |
| 8 | Breadcrumb arrows did nothing | Fixed (the menu opened with a zero size) |
| 9 | Overwriting a preset | **Save** overwrites your own preset in one click; *Save as…* is prefilled with its name; a dot marks unsaved changes |
| 10–12 | Top bar | Repository, then Explorer toggle; preset next to settings; the search field centred and at most 480 px wide |
| 13 | Viewport corners | The viewport is a rounded frame that clips the map and its overlays |
| 14 | ☰ checkmarks | Update while the menu is open; the menu now lists every display setting from the schema (Minimap, Ground grid and Line numbers were missing) |
| 15 | Mixed icon/text buttons | Camera and display are icons; the display menu has an eye icon |
| 16 | Shadows under floating islands | Removed; a hairline edge instead |
| 17 | Paddings | Panels with scrolling content (Explorer, right pane) keep the scrollbar close to the edge |
| 18 | Map order is incomprehensible | View tab → **Layout**: order (size · name · folders first) and algorithm (squarified, or **strip**: rows in reading order). Squarified alternates vertical and horizontal strips, which is why its order looked random |

Next, to decide together: the "colored roofs" look from the early screenshot (see the end of this review).

---

## Naming (point 2)

The project deserves a name that describes zooming from altitude down to the text. Options:

| Name | Idea | Notes |
|---|---|---|
| **Loupe** | The jeweler's / map-reader's magnifier: close inspection of something large | Short, verb-able ("loupe the repo"). Check collisions |
| **Overlook** | A high vantage point over a landscape | Clear metaphor; common word |
| **Strata** | Layers: the terraced city | Fits the 3D view; used by some products |
| **Vantage** | A position giving a strategic view | Neutral, professional |
| **Cartograph** | The map-maker | Descriptive, longer |
| **Aerie** | A high nest, bird's-eye | Distinctive, less obvious meaning |
| **Topo** | Topographic map | Short; many existing uses |
| **Plinth** | The base a building stands on | Playful nod to the 3D terraces |

The server binary can take a short derived name (e.g. `loupe` / `loupe serve`). Rename after the choice: module path, binaries, window title, README.

---

## Decisions needed
1. **Name** (point 2).
2. **Style direction:** A calm, B FUI, or C hybrid (recommended).
3. **Order:** Phase 1 → 2 → 3 → 4 as listed, or bring viewport fixes (Phase 2 + 4.1) forward before the shell.
