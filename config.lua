--- Shared configuration. Everything here is safe to change without touching code.
Config = {}

--- Command that opens the viewer.
Config.command = 'atelier'

--- Who may open it.
---   'everyone'  — anyone on the server (fine for a dev/creator server)
---   'ace'       — requires the ACE permission in Config.acePermission
Config.openMode = 'ace'
Config.acePermission = 'atelier.viewer'

--- Mannequin placed for the preview. Any quiet spot works; the player is
--- teleported nowhere — only the camera moves.
Config.scene = {
    -- Vinewood Hills lookout, empty by default. Change if it clashes with a map mod.
    coords = vector4(-1449.0, -540.0, 74.0, 215.0),
    --- Put the preview into a private routing bucket so nobody else sees it.
    useBucket = true,
    --- Bucket ids the resource may hand out (one per viewing player).
    bucketRange = { from = 7100, to = 7199 },
    --- Neutral studio lighting; set to nil to keep the world's timecycle.
    timecycle = 'grave_lighting',
}

--- Ped models used as mannequins.
Config.peds = {
    male = 'mp_m_freemode_01',
    female = 'mp_f_freemode_01',
}

--- Prop anchors this codebase treats as real prop slots at RUNTIME.
--- NOTE: atelier also knows p_hip (anchor 8) on the BUILD side, but the
--- established runtime convention here is {0,1,2,6,7}. Anchor 8 is included
--- behind a flag until it is confirmed in-game — see README, "open questions".
Config.propAnchors = { 0, 1, 2, 6, 7 }
Config.includeHipAnchor = false

--- Milliseconds to wait before applying a drawable while scrubbing with the
--- arrow keys. Without this every keypress triggers a streaming request.
--- The FIRST click on a slot is never delayed — the wait only kicks in while a
--- slot is already being scrubbed.
Config.applyDebounceMs = 120

--- How a pack's local index (the NNN in the stream name, which restarts at 0 in
--- every part) is turned into the global drawable index the engine wants.
---
---   'browse'  no mapping at all. Add-on items cannot be applied by clicking
---             them; you walk the live range and pick by eye. Never wrong,
---             never useful for a pack. Only mode="replace" items work.
---   'offset'  baseline + localIndex, where the baseline is measured by the
---             probe on this server. This is a GUESS: it assumes add-on
---             drawables are appended after the vanilla ones in one contiguous
---             block, and where several packs feed the same slot it also
---             assumes an order this code cannot see. Force it only if you
---             checked the probe printout and it matches your pack.
---   'auto'    run the probe, then use 'offset' only if the probe found
---             conclusive evidence for it and contradicted it nowhere.
---             Otherwise stay on 'browse'. Default.
---
--- Note that 'auto' can still be wrong: the probe compares texture COUNTS, not
--- pixels, so it can rule a mapping out for certain but can only ever make one
--- look right. Read the probe output before trusting a dressed mannequin.
Config.indexStrategy = 'auto'

--- Print the index probe's findings to the client console on open.
--- Leave this on until the index question in the README is answered.
--- The probe itself ALWAYS runs (Config.indexStrategy = 'auto' is decided from
--- it); this switch only controls whether the findings are printed and shown.
Config.verboseProbe = true
