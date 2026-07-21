# atelier-fivem

In-game viewer for clothing packs built with [atelier](https://github.com/feelgoodrp-com/atelier).
Browse a pack on a mannequin, with the labels and groups you gave the items in
the workbench — instead of clicking through nameless index numbers.

Standalone. ESX, qb-core and qbox are detected at runtime and used only where a
framework actually adds something (permissions, notifications).

---

## What this can and cannot do

**It shows packs that are running on the server you are connected to.**

FiveM loads assets from the connected server. There is no way to inject a
clothing pack at runtime, so a viewer cannot show a build that only exists on
your hard drive. The loop is:

```
atelier build  →  copy into the server's resources  →  ensure/restart  →  /atelier
```

For a fast loop, build straight into a local FXServer. For previewing a build
you have not deployed yet, use atelier's own 3D preview — that is what it is for.

## A pack is only found if you asked for it

The viewer does **not** guess. It only lists packs whose build contains an
`atelier-pack.json`, which atelier writes when you tick **"Viewer metadata"** in
the build dialog. No tick → no file → the pack does not exist for this viewer.

That file is also the only place the human-readable information survives: the
built resource itself contains nothing but indices, because that is all the game
needs. Labels, groups and slot names live in the manifest.

## Install

1. Clone into your `resources` folder and `ensure atelier-fivem`.
2. Grant the permission (or set `Config.openMode = 'everyone'`):
   ```cfg
   add_ace group.admin atelier.viewer allow
   ```
3. In game: `/atelier`

## Open questions this resource helps answer

Two things could not be verified without a running server. The resource prints
its findings to the client console on open (`Config.verboseProbe`):

1. **How add-on drawables appear at runtime.** A pack is built with *local*
   indices that restart at 0 in every part, while `SetPedComponentVariation`
   takes a global index across vanilla plus all DLCs. The probe reports the
   live drawable counts per slot and whether a read-back after applying an
   index returns what was asked for — the engine silently clamps invalid
   indices, so a read-back is the only honest test.
2. **Whether anchor 8 (`p_hip`) behaves like a prop slot** — atelier knows it on
   the build side, the runtime convention here does not use it.

If the numbers say something different from what the plan assumed, the mapping
in `client/indexmap.lua` is the one place that changes.

## Layout

```
config.lua            everything tunable
framework/resolve.lua runtime framework detection (no hard dependency)
client/discovery.lua  finds packs via LoadResourceFile over every resource
client/indexmap.lua   local (manifest) index  ->  runtime index
client/scene.lua      mannequin, camera, lighting, routing bucket
client/apply.lua      component/prop application with read-back
client/probe.lua      the measurements described above
web/                  NUI menu (Vite + React)
```
