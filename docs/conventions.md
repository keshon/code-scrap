# Conventions

## Development and checks

Use Go 1.26.4+ in the `scrap/` module and Godot 4.7 for the viewer. From the
repository root on Windows, `build.cmd test` runs vet and Go tests; an optional
pattern filters tests with `-run`. Independently of the helper:

```bash
cd scrap
go vet ./...
go test ./...
```

The Go tests exercise layout, map relations, git metrics, server behavior and
text tiles. They do not verify every Godot UI or GPU path. After a viewer
change, run the first-start checklist in [Running](running.md#verify-a-first-run).

## Ownership rules

- **Invariant:** analysis and layout belong to the server. Viewer interactions
  request/query data rather than building a second map model from source files.
- **Invariant:** protocol changes update server/viewer version constants and
  [protocol.md](protocol.md) together. A mismatched pair cannot safely interpret
  each other's frames. Runtime handshake checks report the mismatch.
- **Practice:** expose tunables through `config/settings.schema.json` and use the
  viewer settings/keymap interfaces. Avoid adding a second preference store.
- **Practice:** retain one current description of each control in
  [Running](running.md). Planning notes do not define present behavior.

## Screenshots and packaging

`build.cmd shot out.png [viewer args]` starts a scripted viewer run on its own
port, waits, saves a screenshot and exits. It is a viewer smoke check, not a
Go unit test; use it when a visual change warrants inspection.

`build.cmd dist` requires Godot export templates and replaces `dist/` with a
packaged viewer, server and `config/`. `build.cmd import` rebuilds Godot imports;
`build.cmd clean` removes build output/import cache and stops matching server
processes. Review the helper before invoking these mutating developer commands.
No packaging or process-stopping action is required for a prose-only change.

## Documentation

The README owns orientation and first launch. [Running](running.md) owns user
controls, command examples and local state; [Architecture](architecture.md)
owns components/flows; [Protocol](protocol.md) owns wire formats. This document
owns contributor workflows. Preserve the specification and completed planning
work under `docs/internal/` as dated evidence, linked through their original
forwarding pages.

Apply the repository's [docs-pattern skill](../.agents/skills/docs-pattern/SKILL.md).
Verify flags, protocol constants, relative links and heading fragments against
source. Describe observed performance with its corpus/context rather than
carrying an old measurement forward as a guarantee.
