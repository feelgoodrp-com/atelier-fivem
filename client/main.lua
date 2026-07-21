--- Glue. Loads last, may use every other global, and is the ONLY file that
--- registers NUI callbacks.
---
--- ============================================================================
--- SIBLING CONTRACT — everything this file calls on the other globals is bound
--- once, in Bridge below. discovery/indexmap/scene/apply/probe are written in
--- parallel with this file, so if one of them landed on a different name, this
--- is the single place that changes — no call sites are scattered through the
--- rest of the file.
---
---   Discovery.scan()                -> array of manifest tables
---   Discovery.merge(raw)            -> array of packs (multi-part packs folded
---                                      together); optional, identity if absent
---   IndexMap.build(packs)           -> (re)build local -> runtime mapping
---   IndexMap.resolve(descriptor, ped) -> runtime index | nil
---        descriptor = { dlcName=, gender=, kind=, slotId=, localIndex= }
---        The ped is ALWAYS passed: without it the map measures whatever ped
---        the sibling happens to find, which is the player, not the mannequin.
---   IndexMap.setStrategy(name)      -> optional; 'browse' | 'offset' | 'replace'
---   Scene.open(gender)              -> ped handle | nil, reason
---   Scene.close()                   -> full teardown (authoritative)
---   Scene.setGender(gender)         -> swap mannequin
---   Scene.getPed() / Scene.ped()    -> ped handle currently being dressed
---   Scene.setViewport(rect)         -> optional; where the free strip is
---   Scene.camera(opts)              -> optional; preset/zoom/height/...
---   Scene.cameraState()             -> optional; the same shape, current values
---   Apply.component(ped, slotId, runtimeIndex, texture) -> readback
---   Apply.prop(ped, slotId, runtimeIndex, texture)      -> readback
---   Apply.clearSlot(ped, kind, slotId)                  -> optional
---   Apply.snapshot(ped)             -> optional; "slotId:kind" -> {index,texture}
---   Probe.run(ped, packs)           -> report table
---
--- UNVERIFIED: the argument SHAPES above were agreed from the written contract,
--- not from reading the finished sibling files. IndexMap.resolve is called with
--- a single descriptor table rather than five positional arguments, because a
--- positional mismatch between two slots of the same type (slotId/localIndex are
--- both numbers) would fail silently and dress the mannequin in the wrong item,
--- while a table mismatch fails loudly.
---
--- A readback-shaped return is normalised in readbackOf(): a bare number, or a
--- table with .readback / .index, are all accepted.
---
--- ----------------------------------------------------------------------------
--- NUI CONTRACT (this file is the only end of it)
---
---   Lua -> NUI
---     { action='open',  packs=, framework= }
---     { action='state', gender=, applied=, worn=, live= }
---         applied  ENGINE indices, straight off the ped (Apply.snapshot)
---         worn     what the USER picked: local index + dlcName, for highlight
---     { action='probe', report= }
---     { action='camera', preset=, zoom=, height=, autoRotate=, light= }
---     { action='close' }
---
---   NUI -> Lua
---     apply     { kind, slotId, localIndex, dlcName, texture } -> readback table
---     clearSlot { kind, slotId }                               -> 'ok'
---     setGender { gender }                                     -> 'ok'
---     randomize {}                                             -> 'ok'
---     viewport  { left, right, width, height }                 -> 'ok'
---     camera    { preset?, zoom?, height?, autoRotate?, light? }-> 'ok'
---     close     {}                                             -> 'ok'
---
--- The mannequin has to stay visible, so the NUI paints only two side bars and
--- leaves the middle strip transparent. `viewport` tells Lua how wide those bars
--- really rendered, so the camera can aim at the centre of the free strip
--- instead of the centre of the screen.
--- ============================================================================

local COMPONENT_IDS = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }

local CAMERA_PRESETS = { full = true, upper = true, head = true, legs = true, feet = true }
local CAMERA_LIGHTS = { studio = true, bright = true, dark = true, none = true }

local state = {
    open = false,
    opening = false, -- guards the window between /atelier and the scene existing
    gender = 'male',
    packs = {},
    bucket = nil,
    -- Two different questions, so two different records. `worn` is what the user
    -- clicked (a LOCAL index, only meaningful together with its dlcName);
    -- `applied` in the state message is what the ENGINE reports (a global index).
    -- They are not interchangeable, and labelling one with the other's name is
    -- how a mannequin ends up "wearing" an index nobody can look up.
    worn = {}, -- "slotId:kind" -> { index = localIndex, texture = n, dlcName = s }
    -- Last camera state we know of, used as the echo when Scene cannot report.
    camera = { preset = 'full', zoom = 0.5, height = 0.5, autoRotate = false, light = 'studio' },
    viewport = nil,
}

local Bridge = {}

-------------------------------------------------------------------------------
-- binding
-------------------------------------------------------------------------------

local function pick(tbl, names)
    if type(tbl) ~= 'table' then return nil end
    for i = 1, #names do
        local fn = tbl[names[i]]
        if type(fn) == 'function' then return fn end
    end
    return nil
end

local function bind()
    Bridge.scan = pick(Discovery, { 'scan' })
    Bridge.merge = pick(Discovery, { 'merge' })
    Bridge.buildIndex = pick(IndexMap, { 'build' })
    Bridge.resolveIndex = pick(IndexMap, { 'resolve' })
    Bridge.setStrategy = pick(IndexMap, { 'setStrategy' })
    Bridge.sceneOpen = pick(Scene, { 'open' })
    Bridge.sceneClose = pick(Scene, { 'close' })
    Bridge.sceneGender = pick(Scene, { 'setGender' })
    -- scene.lua exposes this as Scene.ped(); 'getPed' stays first so the name in
    -- the contract keeps winning if the scene stream renames it back.
    Bridge.scenePed = pick(Scene, { 'getPed', 'ped' })
    Bridge.sceneViewport = pick(Scene, { 'setViewport', 'viewport' })
    Bridge.sceneCamera = pick(Scene, { 'camera', 'setCamera' })
    Bridge.sceneCameraState = pick(Scene, { 'cameraState', 'getCamera' })
    Bridge.applyComponent = pick(Apply, { 'component' })
    Bridge.applyProp = pick(Apply, { 'prop' })
    Bridge.applyClear = pick(Apply, { 'clearSlot' })
    Bridge.applySnapshot = pick(Apply, { 'snapshot' })
    Bridge.probe = pick(Probe, { 'run' })

    local missing = {}
    local required = {
        scan = 'Discovery.scan', buildIndex = 'IndexMap.build', resolveIndex = 'IndexMap.resolve',
        sceneOpen = 'Scene.open', sceneClose = 'Scene.close', scenePed = 'Scene.getPed',
        applyComponent = 'Apply.component', applyProp = 'Apply.prop',
    }
    for key, label in pairs(required) do
        if not Bridge[key] then missing[#missing + 1] = label end
    end

    if #missing > 0 then
        -- Loud on purpose. A half-bound viewer that opens and then does nothing
        -- when you click is far worse to debug than a refusal that names the
        -- function it wanted.
        print('[atelier] cannot open, missing from sibling files: ' .. table.concat(missing, ', '))
        return false
    end

    -- The routing bucket is NOT the scene's to ask for. Scene.requestBucket
    -- triggers 'atelier-fivem:bucket', which no server handler registers — the
    -- server hands a bucket out through its own acquire/release handshake
    -- (atelier:server:acquire / :release) and puts the player back in bucket 0
    -- itself. Leaving the hook live would fire an unhandled net event on every
    -- open and close, so it is neutralised here rather than in scene.lua, which
    -- is written by another stream and cannot see the server's event names.
    if type(Scene) == 'table' and type(Scene.requestBucket) == 'function' then
        Scene.requestBucket = function() end
    end

    return true
end

-------------------------------------------------------------------------------
-- small helpers
-------------------------------------------------------------------------------

local function propAnchors()
    local anchors = {}
    for i = 1, #Config.propAnchors do anchors[#anchors + 1] = Config.propAnchors[i] end
    if Config.includeHipAnchor then anchors[#anchors + 1] = 8 end
    return anchors
end

local function slotKey(kind, slotId)
    -- Contract key order: "slotId:kind".
    return tostring(slotId) .. ':' .. tostring(kind)
end

local function readbackOf(result, fallback)
    if type(result) == 'number' then return result end
    if type(result) == 'table' then
        if type(result.readback) == 'number' then return result.readback end
        if type(result.index) == 'number' then return result.index end
    end
    return fallback
end

--- Ask the engine what it actually has on this slot right now. This is the
--- honest half of every apply: the engine clamps an out-of-range index instead
--- of refusing it, so "did it work" is only answerable by reading back.
local function currentIndex(ped, kind, slotId)
    if kind == 'prop' then
        return GetPedPropIndex(ped, slotId)
    end
    return GetPedDrawableVariation(ped, slotId)
end

--- Runtime variation counts for the ped as it exists right now — this is what
--- the UI needs to grey out an item the running server does not actually have.
local function liveCounts(ped, gender)
    local live = {}
    if not ped or ped == 0 then return live end

    for i = 1, #COMPONENT_IDS do
        local comp = COMPONENT_IDS[i]
        live[gender .. ':component:' .. comp] = GetNumberOfPedDrawableVariations(ped, comp)
    end

    local anchors = propAnchors()
    for i = 1, #anchors do
        local anchor = anchors[i]
        -- Counts drawables only. Props additionally have index -1 ("nothing
        -- on this anchor"), which is not part of this number.
        live[gender .. ':prop:' .. anchor] = GetNumberOfPedPropDrawableVariations(ped, anchor)
    end

    return live
end

--- What the ENGINE currently has on the ped, keyed "slotId:kind". Apply owns
--- this because only Apply knows which prop anchors count and that an empty prop
--- (-1) is omitted rather than reported; the loop below is only the stand-in for
--- a build where Apply.snapshot is missing.
local function engineSnapshot(ped)
    if not ped or ped == 0 then return {} end

    if Bridge.applySnapshot then
        local ok, snap = pcall(Bridge.applySnapshot, ped)
        if ok and type(snap) == 'table' then return snap end
    end

    local snap = {}
    for i = 1, #COMPONENT_IDS do
        local comp = COMPONENT_IDS[i]
        snap[slotKey('component', comp)] = {
            index = GetPedDrawableVariation(ped, comp),
            texture = GetPedTextureVariation(ped, comp),
        }
    end
    local anchors = propAnchors()
    for i = 1, #anchors do
        local anchor = anchors[i]
        local index = GetPedPropIndex(ped, anchor)
        -- -1 is "nothing on this anchor"; the NUI reads a missing key that way,
        -- so reporting it for every empty anchor is noise.
        if index >= 0 then
            snap[slotKey('prop', anchor)] = {
                index = index,
                texture = GetPedPropTextureIndex(ped, anchor),
            }
        end
    end
    return snap
end

local function pushState()
    if not state.open then return end
    local ped = Bridge.scenePed and Bridge.scenePed() or 0

    SendNUIMessage({
        action = 'state',
        gender = state.gender,
        -- Engine indices — the label the UI puts on this map is now true.
        applied = engineSnapshot(ped),
        -- Local indices + dlcName, which is what identifies the item the user
        -- clicked. Only this one can highlight the right tile in the grid.
        worn = state.worn,
        live = liveCounts(ped, state.gender),
    })
end

--- Echo the camera back so the NUI's controls show what the scene really does,
--- not what the NUI last asked for. When Scene cannot report (older scene
--- stream), the mirror of the last accepted request is the best available
--- answer — it is a request, not a measurement, and it is marked as such.
local function pushCamera()
    if not state.open then return end

    local cam, measured = state.camera, false
    if Bridge.sceneCameraState then
        local ok, res = pcall(Bridge.sceneCameraState)
        if ok and type(res) == 'table' then
            -- Copied field by field, never aliased: the scene may well hand back
            -- its own live state table, and the camera callback writes into this
            -- mirror — which would then be writing into the scene's internals.
            cam = {
                preset = res.preset,
                zoom = res.zoom,
                height = res.height,
                autoRotate = res.autoRotate,
                light = res.light,
            }
            measured = true
            state.camera = cam
        end
    end

    SendNUIMessage({
        action = 'camera',
        preset = cam.preset,
        zoom = cam.zoom,
        height = cam.height,
        autoRotate = cam.autoRotate,
        light = cam.light,
        measured = measured,
    })
end

--- Flat item list across all packs, with the owning pack's dlcName stapled on.
--- Items do not carry dlcName themselves (it lives in pack.dlcName), and after a
--- multi-part merge the parts sit side by side with colliding localIndex values
--- — so the dlcName has to travel with the item or the key is ambiguous.
local function allItems(gender)
    local out = {}
    for i = 1, #state.packs do
        local pack = state.packs[i]
        local packDlcName = pack.pack and pack.pack.dlcName
        local items = pack.items or {}
        for j = 1, #items do
            local item = items[j]
            if not gender or item.gender == gender then
                out[#out + 1] = {
                    item = item,
                    -- A merge may already have stamped the part's dlcName onto
                    -- the item; if not, the owning pack's is the right one.
                    dlcName = item.dlcName or packDlcName,
                }
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- preflight
-------------------------------------------------------------------------------

--- Returns nil when the viewer may open, or a human-readable reason when it may
--- not. Reasons are phrased as "what to do", not "what is wrong".
local function refusalReason(currentBucket)
    local ped = PlayerPedId()

    if IsPedInAnyVehicle(ped, true) then
        return 'Get out of the vehicle first — the viewer needs a free camera.'
    end

    if IsEntityDead(ped) or IsPlayerDead(PlayerId()) then
        return 'You cannot open the viewer while you are down.'
    end

    if IsEntityInWater(ped) or IsPedSwimming(ped) then
        return 'Get out of the water first.'
    end

    if type(currentBucket) == 'number' and currentBucket ~= 0 then
        -- Something else already moved this player into a private world
        -- (apartment, minigame, another viewer). Taking the bucket away from
        -- that script would break it, so refuse instead.
        return ('You are already in a private instance (routing bucket %d). Leave it first.'):format(currentBucket)
    end

    return nil
end

-------------------------------------------------------------------------------
-- open / close
-------------------------------------------------------------------------------

local function teardown(tellServer)
    if not state.open and not state.opening then return end

    state.open = false
    state.opening = false
    state.worn = {}
    state.viewport = nil

    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'close' })

    if Bridge.sceneClose then
        -- Scene.close is authoritative for camera, ped, timecycle and radar.
        pcall(Bridge.sceneClose)
    end

    -- Belt and braces. These are idempotent, and a teardown that half-runs
    -- because a sibling errored would leave the player stuck in a black studio
    -- with no HUD — the one failure mode that is genuinely unrecoverable
    -- without a reconnect.
    SetTimecycleModifier('default')
    ClearTimecycleModifier()
    DisplayRadar(true)
    SetNuiFocus(false, false)

    if tellServer then
        -- Server puts the player back into bucket 0 and frees the id.
        TriggerServerEvent('atelier:server:release')
    end
    state.bucket = nil
end

--- Pick the index strategy for this server. See Config.indexStrategy.
---
--- 'auto' only leaves 'browse' on evidence: the probe has to have landed on the
--- right drawable for at least one CONCLUSIVE sample (one whose texture count is
--- shared by few enough drawables in its slot to mean something) and to have been
--- contradicted by none. Anything less — no packs, weak samples only, one single
--- mismatch — and browse stays. A wrong offset does not look wrong: it silently
--- dresses the mannequin in somebody else's garment and reports success.
local function chooseStrategy(report)
    local want = Config.indexStrategy or 'auto'

    if not Bridge.setStrategy then
        if want == 'offset' then
            print('[atelier] Config.indexStrategy = "offset" ignored: IndexMap.setStrategy is missing.')
        end
        return
    end

    if want ~= 'auto' then
        -- Forced by config. setStrategy itself rejects (and names) a strategy it
        -- does not know; when it does, report what is actually in force rather
        -- than the value from the config file that was just thrown away.
        if Bridge.setStrategy(want) == false then
            print(('[atelier] index strategy: unchanged — Config.indexStrategy = %q is not a strategy.')
                :format(tostring(want)))
        else
            print(('[atelier] index strategy: %s (forced by Config.indexStrategy).'):format(tostring(want)))
        end
        return
    end

    local items = (type(report) == 'table') and report.items or nil
    local strong = tonumber(items and items.strong or 0) or 0
    local weak = tonumber(items and items.weak or 0) or 0
    local wrong = tonumber(items and items.wrong or 0) or 0

    if type(report) == 'table' and report.ok and strong > 0 and wrong == 0 then
        Bridge.setStrategy('offset')
        print(('[atelier] index strategy: offset — the probe matched %d conclusive sample(s) and contradicted none.')
            :format(strong))
        return
    end

    Bridge.setStrategy('browse')
    if type(report) ~= 'table' then
        print('[atelier] index strategy: browse — no probe report, so nothing justifies offset.')
    elseif wrong > 0 then
        print(('[atelier] index strategy: browse — the probe contradicted offset on %d sample(s). Add-on items will not apply by clicking; read the probe printout above.')
            :format(wrong))
    elseif strong == 0 and weak > 0 then
        print('[atelier] index strategy: browse — offset was consistent, but only on samples that prove nothing.')
    else
        print('[atelier] index strategy: browse — the probe found nothing that could confirm offset.')
    end
end

local function openViewer(bucketId)
    if state.open then return end

    state.opening = true
    state.bucket = bucketId

    if not bind() then
        Framework.notify('atelier failed to load (see F8 console).')
        teardown(true)
        return
    end

    -- Every sibling call on the open path is pcall'd. Not defensive habit: if
    -- one of them throws, this function dies half-way, state.opening stays true
    -- and the routing bucket the server just handed out is never released — the
    -- player ends up alone in an empty world with no viewer and no way out.
    local function fail(what, err)
        print(('[atelier] %s failed: %s'):format(what, tostring(err)))
        Framework.notify('atelier could not open (see F8 console).')
        teardown(true)
    end

    local okScan, raw = pcall(Bridge.scan)
    if not okScan or type(raw) ~= 'table' then
        fail('Discovery.scan', okScan and 'did not return a table' or raw)
        return
    end

    local packs = raw
    if Bridge.merge then
        local okMerge, merged = pcall(Bridge.merge, raw)
        if okMerge and type(merged) == 'table' then
            packs = merged
        else
            -- Merging only folds multi-part packs together; unmerged parts still
            -- list correctly, so this is a degradation, not a failure.
            print('[atelier] Discovery.merge failed, showing packs unmerged: ' .. tostring(merged))
        end
    end

    if #packs == 0 then
        Framework.notify('No atelier packs found on this server. A pack is only listed if it was built with "Viewer metadata" ticked.')
        teardown(true)
        return
    end

    state.packs = packs

    local okBuild, buildErr = pcall(Bridge.buildIndex, packs)
    if not okBuild then
        fail('IndexMap.build', buildErr)
        return
    end

    -- Scene.open returns the mannequin, or nil plus a reason. A pcall that did
    -- not throw is NOT the same as a stage that exists — the model can simply
    -- have failed to load — and going on from there gives the player a menu that
    -- dresses nothing, in a bucket nobody releases.
    local okScene, scenePed, sceneWhy = pcall(Bridge.sceneOpen, state.gender)
    if not okScene then
        fail('Scene.open', scenePed)
        return
    end

    local ped = (type(scenePed) == 'number' and scenePed ~= 0 and DoesEntityExist(scenePed)) and scenePed or nil
    if not ped then
        fail('Scene.open', sceneWhy or 'no mannequin was created (model failed to load?)')
        return
    end

    state.open = true
    state.opening = false

    -- The probe ALWAYS runs, after the scene so it measures the mannequin.
    -- Its findings are what Config.indexStrategy = 'auto' decides from, so
    -- gating the RUN on Config.verboseProbe would quietly turn a printing switch
    -- into a kill switch for add-on mapping. Only the OUTPUT is gated — the
    -- console print inside Probe.run, and the report handed to the NUI here.
    local report
    if Bridge.probe then
        -- The ped is passed explicitly. Probe falls back to the player's ped when
        -- it is not, and a probe of the player measures the wrong outfit and
        -- derives baselines nothing on the mannequin agrees with.
        local okProbe, res = pcall(Bridge.probe, ped, packs)
        if okProbe and type(res) == 'table' then
            report = res
            if Config.verboseProbe then
                SendNUIMessage({ action = 'probe', report = report })
            end
        else
            -- Not fatal: without a report 'auto' just stays on browse.
            print('[atelier] Probe.run failed: ' .. tostring(res))
        end
    end

    chooseStrategy(report)

    SendNUIMessage({
        action = 'open',
        packs = packs,
        framework = Framework.detect(),
    })
    SetNuiFocus(true, true)
    -- The cursor belongs to the NUI, but the GAME must keep receiving input —
    -- otherwise the mannequin cannot be turned by dragging in the free strip,
    -- which is the whole point of leaving that strip empty. scene.lua only acts
    -- on a drag while the cursor is actually over the strip, and every movement
    -- and attack control is in its disabled list, so nothing leaks into the world.
    SetNuiFocusKeepInput(true)
    pushState()
    -- Tell the NUI where the camera starts, so its controls open in sync with
    -- the scene instead of showing their own defaults.
    pushCamera()

    -- ESC / Backspace. The NUI can also post "close" itself; both paths land on
    -- the same teardown, and teardown is re-entrant, so a double close is fine.
    CreateThread(function()
        while state.open do
            DisableControlAction(0, 200, true) -- INPUT_FRONTEND_PAUSE (ESC)
            DisableControlAction(0, 177, true) -- INPUT_CELLPHONE_CANCEL (Backspace/ESC)
            if IsDisabledControlJustReleased(0, 200) or IsDisabledControlJustReleased(0, 177) then
                teardown(true)
                break
            end
            Wait(0)
        end
    end)
end

-------------------------------------------------------------------------------
-- apply
-------------------------------------------------------------------------------

--- Newest-wins token per slot. Holding down an arrow key fires one apply per
--- keypress, and each apply is a streaming request; without this the game spends
--- the whole scrub loading drawables nobody will look at.
local applyToken = {}

--- GetGameTimer() value up to which a slot counts as "being scrubbed". Only
--- inside that window does an apply wait; a click on a slot nobody has touched
--- goes through at once. Debouncing the first click too would have added
--- Config.applyDebounceMs of dead time to every single click, which is felt on
--- every click and helps on none of them.
local applyHotUntil = {}

local function doApply(kind, slotId, localIndex, dlcName, texture)
    local ped = Bridge.scenePed()
    if not ped or ped == 0 then
        return { ok = false, applied = -1, readback = -1, error = 'no ped' }
    end

    if type(slotId) ~= 'number' or type(localIndex) ~= 'number' then
        return { ok = false, applied = -1, readback = -1, error = 'bad item' }
    end

    -- pcall'd because this is the return path of an NUI callback: if a sibling
    -- throws here, cb() never fires and the fetch() in the UI hangs forever
    -- instead of showing an error.
    -- The mannequin is passed explicitly. IndexMap falls back to "whatever ped
    -- it can find", which is the player: the live drawable counts it would read
    -- off them belong to a different model, and every baseline derived from them
    -- is wrong for the ped being dressed.
    local okResolve, runtimeIndex = pcall(Bridge.resolveIndex, {
        dlcName = dlcName,
        gender = state.gender,
        kind = kind,
        slotId = slotId,
        localIndex = localIndex,
    }, ped)

    if not okResolve then
        print('[atelier] IndexMap.resolve failed: ' .. tostring(runtimeIndex))
        return { ok = false, applied = -1, readback = currentIndex(ped, kind, slotId), error = 'resolve failed' }
    end

    if type(runtimeIndex) ~= 'number' then
        -- Deliberately not falling back to localIndex: on a server where the
        -- pack is not running, localIndex is a perfectly valid vanilla index, so
        -- the fallback would silently dress the mannequin in a random vanilla
        -- item and look like it worked.
        return {
            ok = false,
            applied = -1,
            readback = currentIndex(ped, kind, slotId),
            error = 'unmapped',
        }
    end

    local okApply, result
    if kind == 'prop' then
        okApply, result = pcall(Bridge.applyProp, ped, slotId, runtimeIndex, texture)
    else
        okApply, result = pcall(Bridge.applyComponent, ped, slotId, runtimeIndex, texture)
    end

    if not okApply then
        print('[atelier] Apply failed: ' .. tostring(result))
        return { ok = false, applied = runtimeIndex, readback = currentIndex(ped, kind, slotId), error = 'apply failed' }
    end

    -- The read-back is taken from the engine either way: whatever Apply claims
    -- to have returned, currentIndex() is the value the ped actually carries.
    local readback = readbackOf(result, currentIndex(ped, kind, slotId))
    local ok = (readback == runtimeIndex)

    if ok then
        -- The LOCAL index, deliberately: this record answers "which tile did the
        -- user click", and a local index only means anything together with its
        -- dlcName. The engine's global index goes out in the state message's
        -- `applied` map, read straight off the ped.
        state.worn[slotKey(kind, slotId)] = {
            index = localIndex,
            texture = texture,
            dlcName = dlcName, -- additive: the UI needs it to highlight the right pack
        }
    end

    -- ok=false here means the engine clamped: it accepted the call and put
    -- something else on. The UI is supposed to surface that rather than pretend.
    return { ok = ok, applied = runtimeIndex, readback = readback }
end

-------------------------------------------------------------------------------
-- events
-------------------------------------------------------------------------------

RegisterNetEvent('atelier:client:notify', function(msg)
    Framework.notify(msg)
end)

RegisterNetEvent('atelier:client:preflight', function(currentBucket)
    if state.open or state.opening then return end

    local reason = refusalReason(currentBucket)
    if reason then
        Framework.notify(reason)
        return
    end

    -- Only now does the server hand out a bucket.
    TriggerServerEvent('atelier:server:acquire')
end)

RegisterNetEvent('atelier:client:open', function(bucketId)
    openViewer(bucketId)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- No server round trip: the server's own onResourceStop frees the bucket,
    -- and the event would not arrive before the resource is gone anyway.
    teardown(false)
end)

-------------------------------------------------------------------------------
-- NUI callbacks (this file only)
-------------------------------------------------------------------------------

RegisterNUICallback('close', function(_, cb)
    teardown(true)
    cb('ok')
end)

RegisterNUICallback('apply', function(data, cb)
    if not state.open then
        cb({ ok = false, applied = -1, readback = -1 })
        return
    end

    local kind = (data.kind == 'prop') and 'prop' or 'component'
    local slotId = tonumber(data.slotId)
    local localIndex = tonumber(data.localIndex)
    local texture = tonumber(data.texture) or 0
    local dlcName = data.dlcName

    if not slotId or not localIndex then
        cb({ ok = false, applied = -1, readback = -1 })
        return
    end

    local key = slotKey(kind, slotId)
    local token = (applyToken[key] or 0) + 1
    applyToken[key] = token

    -- cb may be answered later, so the wait happens in its own thread and the
    -- NUI callback itself returns immediately.
    CreateThread(function()
        local debounce = tonumber(Config.applyDebounceMs) or 0
        -- Leading edge: the wait only happens when this slot was applied to a
        -- moment ago, i.e. when this really is a scrub. The first click lands
        -- with no added latency.
        if debounce > 0 and (applyHotUntil[key] or 0) > GetGameTimer() then
            Wait(debounce)
        end

        if applyToken[key] ~= token or not state.open then
            -- Scrubbed past. Nothing was applied, and the readback is the slot's
            -- real current value — NOT the index that was asked for. The UI
            -- should ignore ok/readback when superseded is set.
            local ped = Bridge.scenePed and Bridge.scenePed() or 0
            cb({
                ok = true,
                superseded = true,
                applied = -1,
                readback = (ped ~= 0) and currentIndex(ped, kind, slotId) or -1,
            })
            return
        end

        applyHotUntil[key] = GetGameTimer() + debounce
        cb(doApply(kind, slotId, localIndex, dlcName, texture))
        pushState()
    end)
end)

RegisterNUICallback('clearSlot', function(data, cb)
    if not state.open then cb('ok') return end

    local kind = (data.kind == 'prop') and 'prop' or 'component'
    local slotId = tonumber(data.slotId)
    if not slotId then cb('ok') return end

    -- Cancel any in-flight debounced apply for this slot, or it would land
    -- after the clear and undo it.
    local key = slotKey(kind, slotId)
    applyToken[key] = (applyToken[key] or 0) + 1

    local ped = Bridge.scenePed()
    local cleared = false
    if ped and ped ~= 0 then
        if Bridge.applyClear then
            cleared = pcall(Bridge.applyClear, ped, kind, slotId)
        elseif kind == 'prop' then
            -- Props are not components: removal is ClearPedProp. There is no
            -- SetPedPropIndex(-1) removal path. This is exactly what
            -- Apply.clearSlot does for a prop, so the two cannot disagree.
            ClearPedProp(ped, slotId)
            cleared = true
        else
            -- No local fallback for components on purpose. "Empty" for a
            -- component is the naked base in apply.lua (torso 15, legs 21, ...),
            -- not drawable 0 — a second answer here would put the mannequin in
            -- jeans and call it undressed, and the two would drift apart the
            -- moment that table is corrected.
            print(('[atelier] cannot clear component slot %d: Apply.clearSlot is missing'):format(slotId))
        end
    end

    -- Only forget the item once the slot really was cleared; claiming an empty
    -- slot the ped is still wearing is worse than showing it as worn.
    if cleared then state.worn[key] = nil end
    cb('ok')
    pushState()
end)

RegisterNUICallback('setGender', function(data, cb)
    if not state.open then cb('ok') return end

    local gender = (data.gender == 'female') and 'female' or 'male'
    if gender == state.gender then cb('ok') return end

    state.gender = gender
    state.worn = {}
    applyToken = {}
    applyHotUntil = {}

    -- Answer first. Both calls below are into sibling files, and a throw in
    -- either of them would leave cb() unfired — the NUI's fetch() never settles,
    -- and the menu sits there with a dead gender switch and no error.
    cb('ok')

    if Bridge.sceneGender then
        local ok, err = pcall(Bridge.sceneGender, gender)
        if not ok then print('[atelier] Scene.setGender failed: ' .. tostring(err)) end
    end

    -- The mannequin is a different model now, so every runtime index the map
    -- handed out for the old one is stale.
    local okBuild, buildErr = pcall(Bridge.buildIndex, state.packs)
    if not okBuild then print('[atelier] IndexMap.build failed: ' .. tostring(buildErr)) end

    pushState()
    -- The new rig re-applies the preset, so dist/framing changed underneath the
    -- sliders. Without this echo they keep showing the old numbers.
    pushCamera()
end)

RegisterNUICallback('randomize', function(_, cb)
    if not state.open then cb('ok') return end

    -- One random item per slot that this gender actually has items for. Goes
    -- through doApply, so a clamp during randomize is recorded the same way as
    -- a clamp during a click.
    local bySlot = {}
    local entries = allItems(state.gender)
    for i = 1, #entries do
        local entry = entries[i]
        local item = entry.item
        local slotId = tonumber(item.slotId)
        if slotId then
            -- Normalise kind exactly as doApply does, so the key used to cancel
            -- a pending apply below is the same key the apply writes to.
            entry.kind = (item.kind == 'prop') and 'prop' or 'component'
            entry.slotId = slotId
            local key = slotKey(entry.kind, slotId)
            bySlot[key] = bySlot[key] or {}
            local bucket = bySlot[key]
            bucket[#bucket + 1] = entry
        end
    end

    for key, candidates in pairs(bySlot) do
        local entry = candidates[math.random(#candidates)]
        local item = entry.item
        -- Cancel pending debounced applies for this slot first, and take the
        -- slot out of its scrub window so the next click is not debounced
        -- against an apply the user did not make.
        applyToken[key] = (applyToken[key] or 0) + 1
        applyHotUntil[key] = nil
        doApply(
            entry.kind,
            entry.slotId,
            tonumber(item.localIndex),
            entry.dlcName,
            math.random(0, math.max(0, (tonumber(item.textures) or 1) - 1))
        )
    end

    cb('ok')
    pushState()
end)

-------------------------------------------------------------------------------
-- layout / camera
-------------------------------------------------------------------------------

--- @return number|nil the value clamped to 0..1, or nil when it is not a number
local function clamp01(v)
    local n = tonumber(v)
    if not n then return nil end
    if n < 0 then return 0.0 end
    if n > 1 then return 1.0 end
    return n + 0.0
end

--- Where the game is still visible. The NUI is NOT a full-screen app: it paints
--- a bar on the left and one on the right and leaves the strip between them
--- transparent, because the mannequin has to stay in view while the menu is
--- open. Those bars are sized by CSS, so their real widths are known only to the
--- browser — it reports them here after "open" and on every resize, and the
--- scene aims at the centre of the free strip instead of the centre of the
--- screen, where a bar would be covering the ped.
RegisterNUICallback('viewport', function(data, cb)
    -- Answered first, unconditionally. This fires on every resize event, and a
    -- sibling throwing while the user drags the window border would leave the
    -- fetch() unsettled and take the menu with it.
    cb('ok')
    if not state.open then return end

    data = (type(data) == 'table') and data or {}
    local rect = {
        left = math.max(0, tonumber(data.left) or 0),
        right = math.max(0, tonumber(data.right) or 0),
        width = math.max(0, tonumber(data.width) or 0),
        height = math.max(0, tonumber(data.height) or 0),
    }
    state.viewport = rect

    -- No Scene.setViewport (older scene stream): the camera stays centred, which
    -- is what it did before this message existed. Not worth a refusal.
    if not Bridge.sceneViewport then return end

    local ok, err = pcall(Bridge.sceneViewport, rect)
    if not ok then print('[atelier] Scene.setViewport failed: ' .. tostring(err)) end
end)

--- Camera controls. Every field is optional: the NUI sends whichever control the
--- user touched, and the scene keeps the rest of its state as it is.
RegisterNUICallback('camera', function(data, cb)
    cb('ok')
    if not state.open then return end

    data = (type(data) == 'table') and data or {}
    local opts = {}

    -- An unrecognised preset or light is DROPPED, not forwarded. The alternative
    -- is handing the scene a string it has no case for, which lands on whatever
    -- its else-branch happens to be — a silent, invisible wrong answer.
    if type(data.preset) == 'string' and CAMERA_PRESETS[data.preset] then opts.preset = data.preset end
    if type(data.light) == 'string' and CAMERA_LIGHTS[data.light] then opts.light = data.light end

    local zoom = clamp01(data.zoom)
    if zoom then opts.zoom = zoom end
    local height = clamp01(data.height)
    if height then opts.height = height end
    if type(data.autoRotate) == 'boolean' then opts.autoRotate = data.autoRotate end

    -- Mirror what was accepted, so the echo still says something sensible on a
    -- scene stream that cannot report its own camera back.
    for k, v in pairs(opts) do state.camera[k] = v end

    if Bridge.sceneCamera then
        local ok, err = pcall(Bridge.sceneCamera, opts)
        if not ok then print('[atelier] Scene.camera failed: ' .. tostring(err)) end
    end

    -- Echo ONLY for a preset, i.e. when Lua picked values the NUI cannot predict.
    -- Echoing a slider back would fight the user: posts are throttled, so the
    -- echo carries a stale value and the slider snaps backwards mid-drag.
    if opts.preset then pushCamera() end
end)
