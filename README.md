<div align="center">

<img src="web/public/atelier-logo.png" width="116" alt="atelier" />

# atelier-fivem

**Browse your clothing packs in-game, on a real ped.**

The in-game companion to [atelier](https://github.com/feelgoodrp-com/atelier):
a viewer that finds the packs you built, dresses a mannequin with them, and
shows the labels and groups you gave them in the workbench — instead of
nameless index numbers.

![Status: in development](https://img.shields.io/badge/Status-in%20development-faa61a)
&nbsp;[![License: PolyForm NC 1.0.0](https://img.shields.io/badge/License-PolyForm%20NC%201.0.0-5865F2)](LICENSE.md)
&nbsp;![FiveM](https://img.shields.io/badge/FiveM-cerulean-1f1f1f)
&nbsp;![Standalone · ESX · qb-core · qbox](https://img.shields.io/badge/Standalone%20·%20ESX%20·%20qb--core%20·%20qbox-1f1f1f)

[**atelier**](https://github.com/feelgoodrp-com/atelier) ·
[atelier-api](https://github.com/feelgoodrp-com/atelier-api) ·
[Discord](https://discord.gg/blpd)

</div>

---

> [!WARNING]
> **In development — not yet proven in-game.**
> Everything here is written, reviewed and structurally verified, but no part of
> it has run on a live FiveM server yet. Expect rough edges, and expect the
> config and the pack-manifest format to still change.
>
> The one genuinely open question — how add-on drawables are numbered at
> runtime — is measured by the resource itself on first open, see
> [Open questions](#open-questions). If you try it, that measurement (printed to
> the client console) is the single most useful thing you can send us on
> [Discord](https://discord.gg/blpd).

## What it does

You built a pack in atelier and put it on your server. Now you want to look at
it — properly, on a ped, at the right angle, with the names you actually gave
your items.

- **Finds your packs by itself.** Every running resource is checked for an
  `atelier-pack.json`; whatever has one shows up.
- **Keeps your names.** Labels, groups and slot names come from that manifest,
  because a built resource contains nothing but indices — that is all the game
  needs, and it is why the browsing experience is otherwise numbers only.
- **Shows the ped, not a menu.** Two slim sidebars, the middle of the screen
  stays free: the mannequin stands in the gap and you drag it to turn it.
- **Camera you can aim.** Presets for full body, upper, head, legs and feet,
  plus zoom, height, auto-rotate and four lighting moods — dark garments on a
  dark backdrop are why the lighting switch exists.
- **Tells you when a pack is not really there.** A manifest whose assets are not
  streamed gets a *not loaded* badge instead of silently showing you a default
  torso.
- **Runs anywhere.** Standalone by default; ESX, qb-core and qbox are detected
  at runtime, never required.

## What it cannot do

**It shows packs that run on the server you are connected to.** FiveM loads
assets from the connected server, and there is no way to inject a clothing pack
at runtime — so a viewer cannot show a build that only exists on your hard
drive. The loop is:

```
atelier build  →  copy into the server's resources  →  ensure/restart  →  /atelier
```

For a fast loop, build straight into a local FXServer. To preview a build you
have not deployed yet, use atelier's own real-time 3D preview — that is exactly
what it is for.

## A pack is only found if you asked for it

This resource does **not** guess. It lists a pack only if the build contains an
`atelier-pack.json`, which atelier writes when you tick **Viewer metadata** in
the build dialog.

| Checkbox | Result |
| --- | --- |
| ticked | the pack shows up, with labels, groups and flags |
| not ticked | the pack does not exist for this viewer |

No heuristics, no scanning for `stream` folders, no accidentally picking up
somebody else's clothing resource. You decide per build.

## Installation

1. Clone into your `resources` folder:
   ```bash
   cd resources
   git clone https://github.com/feelgoodrp-com/atelier-fivem
   ```
2. Add it to your `server.cfg`:
   ```cfg
   ensure atelier-fivem
   ```
3. Give someone permission (or open it to everyone, see below):
   ```cfg
   add_ace group.admin atelier.viewer allow
   ```
4. In game: **`/atelier`**

No dependencies. No database. Nothing to configure to get started.

## Configuration

Everything lives in [`config.lua`](config.lua):

| Key | Default | What it does |
| --- | --- | --- |
| `Config.command` | `atelier` | the command that opens the viewer |
| `Config.openMode` | `ace` | `ace` (permission) or `everyone` |
| `Config.acePermission` | `atelier.viewer` | which ACE is required |
| `Config.scene.coords` | Vinewood lookout | where the mannequin is placed |
| `Config.scene.useBucket` | `true` | private routing bucket, so nobody sees the show |
| `Config.scene.timecycle` | `grave_lighting` | studio lighting |
| `Config.propAnchors` | `{0,1,2,6,7}` | prop anchors treated as real slots |
| `Config.applyDebounceMs` | `120` | debounce while scrubbing with the arrow keys |
| `Config.indexStrategy` | `auto` | how a pack's local index becomes a runtime index |
| `Config.verboseProbe` | `true` | print the index measurements to the client console |

## Framework support

Standalone is the normal case, not a fallback. ESX, qb-core and qbox are
detected at runtime via `GetResourceState` — there is deliberately **no**
`dependency` in the manifest, because declaring one makes a resource refuse to
start on every other setup.

Honestly: a viewer barely needs a framework at all. It is used for the
permission check and for notifications. Everything else is plain client Lua.

## Open questions

Two things cannot be answered without a running server, so the resource
measures them itself and prints the result to the client console
(`Config.verboseProbe`):

1. **How add-on drawables are numbered at runtime.** A pack is built with
   *local* indices that restart at 0 in every part, while
   `SetPedComponentVariation` takes a global index across vanilla plus every
   DLC. Three strategies exist — `replace` (certain), `offset` (a measured
   guess) and `browse` (always works, never guesses) — and `Config.indexStrategy
   = 'auto'` picks between them from the measurement. Every apply is
   **read back** from the engine, because an invalid index is silently clamped
   to a valid one: without reading back, a wrong guess looks like a success.
2. **Whether anchor 8 (`p_hip`) is a real prop anchor.** atelier knows it on the
   build side; the runtime convention here does not use it.

If your numbers disagree with the assumptions, exactly one file changes:
[`client/indexmap.lua`](client/indexmap.lua).

## Layout

```
config.lua              everything tunable
framework/resolve.lua   runtime framework detection, no hard dependency
client/discovery.lua    finds packs via LoadResourceFile across all resources
client/indexmap.lua     local (manifest) index  →  runtime index
client/scene.lua        mannequin, camera, lighting, routing bucket
client/apply.lua        component/prop application with read-back
client/probe.lua        the measurements above
client/main.lua         glue; the only file with NUI callbacks
server/main.lua         command, permission, bucket handout
web/                    the NUI (Vite + React), built into web/dist
```

The NUI is built and committed — a FiveM resource is consumed as-is, so
`web/dist` is part of the repo. To work on it:

```bash
cd web
bun install
bun run dev     # browser, with a mock pack
bun run build   # writes web/dist
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free for noncommercial use,
same as [atelier](https://github.com/feelgoodrp-com/atelier).

## Credits

Built by the **feelgood** community, alongside
[atelier](https://github.com/feelgoodrp-com/atelier).
Come say hi on [Discord](https://discord.gg/blpd).
