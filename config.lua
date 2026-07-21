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
Config.applyDebounceMs = 120

--- Print the index probe's findings to the client console on open.
--- Leave this on until the index question in the README is answered.
Config.verboseProbe = true
