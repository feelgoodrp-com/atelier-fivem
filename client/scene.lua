--- Scene — the preview stage: mannequin, camera, lighting, routing bucket.
---
--- Owns nothing but the stage. It never talks to the NUI and never registers a
--- NUI callback; main.lua drives it. Everything this file switches on is
--- switched off again in Scene.close(), which is also wired to onResourceStop.
---
--- Surface:
---   Scene.open(gender)            -> ped | nil, reason
---   Scene.setGender(gender)       -> ped | nil, reason
---   Scene.ped() / Scene.getPed()  -> ped | nil          (same function)
---   Scene.setViewport(l,r,w,h)    -> px offset from the screen centre
---   Scene.camera(opts)            -> cameraState        (preset/zoom/height/
---                                                        autoRotate/light)
---   Scene.cameraState()           -> the same table, for the NUI echo
---   Scene.setInputEnabled(bool), Scene.isOpen(), Scene.gender(), Scene.close()
---
--- The mannequin has to stay VISIBLE while the menu is open: the NUI paints two
--- sidebars and leaves a free strip between them, and Scene.setViewport is how
--- this file learns how wide those bars are so the ped lands in that strip.
Scene = {}

-- Tunables that are not worth a Config key (they only change how the camera
-- feels, not what the resource does).
local DIST_DEFAULT   = 1.90
local DIST_MIN       = 0.70
local DIST_MAX       = 3.40
local ZOOM_STEP      = 0.15
local ROT_SPEED      = 12.0   -- degrees per unit of mouse delta
local FRAME_SPEED    = 1.20   -- metres per unit of mouse delta
local CAM_FOV        = 40.0   -- VERTICAL fov; SetCamFov takes the vertical angle
local MODEL_TIMEOUT  = 10000  -- ms; a bounded wait, never `while true`
local AUTO_ROT_SPEED = 18.0   -- degrees per second while autoRotate is on
local FRAMING_MIN    = 0.05   -- metres above the feet: the lowest the camera looks

--- Bones we measure to derive the camera presets. Every preset height comes out
--- of the rig instead of a magic number, so it stays right if a server swaps the
--- mannequin for a taller/shorter model.
--- UNVERIFIED: the bone ids are the standard GTA V skeleton hashes but were not
--- read back from a running game here. Each measurement is range-checked and
--- falls back to a fraction of the measured body height, so a wrong id degrades
--- to "roughly right" instead of putting the camera underground.
local BONES = {
    head   = 31086, -- SKEL_Head
    chest  = 24818, -- SKEL_Spine3
    pelvis = 11816, -- SKEL_Pelvis
    knee   = 63931, -- SKEL_L_Calf
    foot   = 14201, -- SKEL_L_Foot
}

--- Fallback heights as a fraction of the measured body height, used when a bone
--- measurement lands outside its sane range.
local BONE_FALLBACK = {
    head = 0.92, chest = 0.72, pelvis = 0.52, knee = 0.28, foot = 0.06,
}

--- Each preset is "how close" (0..1, fed through the same zoom mapping the wheel
--- uses). The look-at height is derived from the rig, see presetFrame().
local PRESET_ZOOM = {
    full  = 0.10,
    upper = 0.55,
    head  = 0.90,
    legs  = 0.55,
    feet  = 0.85,
}

-- Controls we disable so the mouse can be read as a delta. A control has to be
-- disabled before GetDisabledControlNormal reports anything.
local DISABLED_CONTROLS = {
    1, 2,        -- LookLeftRight / LookUpDown
    24, 25,      -- Attack (LMB) / Aim (RMB)
    14, 15,      -- WeaponWheelNext / Prev (wheel on some setups)
    241, 242,    -- CursorScrollUp / CursorScrollDown
    21, 22, 30, 31, 32, 33, 34, 35, -- sprint/jump/movement, so the player stays put
    44, 37, 199, 200,               -- cover, weapon wheel, pause menus
}

--- Timecycle modifiers behind the `light` contract value. Dark garments on a
--- dark backdrop are unreadable, which is the whole reason this switch exists.
--- UNVERIFIED: 'NEW_MP_Garage_L' and 'superDARK' are the names in common use for
--- "flat showroom light" and "very dark"; they were not confirmed against a
--- running game here. A server can override the whole table by setting
--- Config.scene.lights = { bright = '...', dark = '...' } — an unknown modifier
--- name is a no-op in the engine, so the worst case is "the button does nothing".
local LIGHT_FALLBACK = { bright = 'NEW_MP_Garage_L', dark = 'superDARK' }

local state = {
    open         = false,
    ped          = nil,
    cam          = nil,
    gender       = 'male',
    heading      = 0.0,
    dist         = DIST_DEFAULT,
    framing      = 0.65,  -- metres above the mannequin's feet the camera looks at
    headOffset   = 1.00,  -- filled in from the head bone once the ped exists
    rig          = nil,   -- measured bone heights above the feet, see measureRig
    camYaw       = 0.0,   -- fixed: we rotate the ped, not the camera
    inputEnabled = true,
    camDirty     = true,
    bucketActive = false,
    playerFrozen = false,
    timecycle    = nil,
    -- layout / camera contract
    preset       = 'full',
    light        = 'studio',
    autoRotate   = false,
    dragging     = false, -- a manual drag is in progress; it beats autoRotate
    viewport     = { left = 0, right = 0, width = 0, height = 0 },
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function clamp01(v)
    return clamp(v, 0.0, 1.0)
end

--------------------------------------------------------------------------------
-- routing bucket
--------------------------------------------------------------------------------

-- A client cannot change its own routing bucket — SetPlayerRoutingBucket is a
-- server native. So this is a hook: it fires a conventional server event, and
-- main.lua may replace Scene.requestBucket with whatever server/main.lua really
-- listens for.
-- UNVERIFIED: the event name below is a convention, not something read out of
-- server/main.lua (that file is written by another stream). If the server uses
-- a different name, override Scene.requestBucket in main.lua — the teardown
-- path calls it with `false`, which is what puts the player back in bucket 0.
function Scene.requestBucket(active)
    TriggerServerEvent('atelier-fivem:bucket', active and true or false)
end

local function bucketEnter()
    if not (Config.scene and Config.scene.useBucket) then return end
    if state.bucketActive then return end
    state.bucketActive = true
    Scene.requestBucket(true)
end

local function bucketLeave()
    if not state.bucketActive then return end
    state.bucketActive = false
    Scene.requestBucket(false)
end

--------------------------------------------------------------------------------
-- model / mannequin
--------------------------------------------------------------------------------

--- Returns the model hash, or nil PLUS a human-readable reason. The reason is
--- carried all the way out of Scene.open so main.lua can report something better
--- than "it didn't work".
local function loadModel(model)
    local hash = (type(model) == 'string') and joaat(model) or model
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        return nil, ('ped model "%s" is not valid or not streamed by this server'):format(tostring(model))
    end
    if HasModelLoaded(hash) then return hash end

    RequestModel(hash)
    local deadline = GetGameTimer() + MODEL_TIMEOUT
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then
            return nil, ('ped model "%s" did not load within %d ms'):format(tostring(model), MODEL_TIMEOUT)
        end
        Wait(10)
    end
    return hash
end

--- A freemode ped without head blend data renders with an undefined grey face.
--- Setting a neutral blend is not cosmetic polish — without it the preview is
--- simply wrong.
local function setNeutralFace(ped)
    SetPedHeadBlendData(ped, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.0, false)
    -- Guarded: these are plain quality-of-life natives, and a guard costs
    -- nothing if a build does not expose one of them.
    if SetPedEyeColor then SetPedEyeColor(ped, 0) end
    if SetPedHairColor then SetPedHairColor(ped, 0, 0) end
end

local function measureHead(ped)
    -- 31086 = SKEL_Head. Used only to clamp the vertical framing between the
    -- feet and the top of the head.
    local base = GetEntityCoords(ped)
    local head = GetPedBoneCoords(ped, BONES.head, 0.0, 0.0, 0.0)
    local dz = head.z - base.z
    if dz > 0.3 and dz < 2.5 then
        return dz + 0.18
    end
    return 1.00 -- fallback; freemode peds are ~1.0 m from feet to head bone
end

--- Height of one bone above the ped's base (its feet), or nil when the reading
--- is not believable. Everything is relative to GetEntityCoords, so this is
--- independent of where the mannequin stands.
local function boneHeight(ped, boneId, top)
    if not boneId then return nil end
    local base = GetEntityCoords(ped)
    local bone = GetPedBoneCoords(ped, boneId, 0.0, 0.0, 0.0)
    local dz = bone.z - base.z
    -- A bone that reads at exactly the entity origin means "bone not found":
    -- the native returns the entity position rather than failing.
    if dz > 0.01 and dz < (top + 0.5) then return dz end
    return nil
end

--- Measure the bones the camera presets are built on. Called once per spawned
--- mannequin, because a female model is not a male model with a different skin.
local function measureRig(ped, top)
    local rig = {}
    for name, id in pairs(BONES) do
        rig[name] = boneHeight(ped, id, top) or (BONE_FALLBACK[name] * top)
    end
    return rig
end

local function destroyPed()
    if state.ped and DoesEntityExist(state.ped) then
        SetEntityAsMissionEntity(state.ped, true, true)
        DeletePed(state.ped)
    end
    state.ped = nil
end

--- Returns the ped handle, or nil PLUS the reason it could not be created.
local function spawnMannequin(gender)
    local coords = Config.scene.coords
    local modelName = Config.peds[gender] or Config.peds.male
    local hash, reason = loadModel(modelName)
    if not hash then return nil, reason end

    destroyPed()

    -- isNetwork = false: this mannequin is a purely local prop. Nobody else has
    -- to know about it, and a non-networked ped cannot be culled by another
    -- client's entity budget.
    local ped = CreatePed(4, hash, coords.x, coords.y, coords.z, coords.w, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or not DoesEntityExist(ped) then
        return nil, ('CreatePed returned no entity for "%s"'):format(tostring(modelName))
    end

    SetEntityCoordsNoOffset(ped, coords.x, coords.y, coords.z, false, false, false)
    SetEntityHeading(ped, coords.w + 0.0)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedCanBeTargetted(ped, false)
    SetEntityCanBeDamaged(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, false)
    SetEntityInvincible(ped, true)

    setNeutralFace(ped)

    -- Start from the documented naked base so the first pack item is shown on a
    -- known state and not on top of whatever the model ships with.
    if Apply and Apply.clearAll then
        Apply.clearAll(ped)
    end

    state.ped     = ped
    state.gender  = gender
    state.heading = coords.w + 0.0
    state.headOffset = measureHead(ped)
    state.rig     = measureRig(ped, state.headOffset)
    state.camDirty = true
    return ped
end

--------------------------------------------------------------------------------
-- camera: aimed at the free strip between the two NUI bars, not the screen centre
--------------------------------------------------------------------------------

--- How far (in pixels) the mannequin should sit from the centre of the SCREEN so
--- that it sits in the centre of the FREE STRIP the NUI leaves between its two
--- bars. Negative means "left of the screen centre".
---
---   free strip   = width - left - right
---   its centre   = left + free/2
---   offset       = that - width/2  ==  (left - right)/2
---
--- Nothing is hardcoded: with left=320, right=340 on a 1920-wide screen this is
--- (320-340)/2 = -10 px, i.e. the strip centre at x=950 — but it holds for any
--- resolution and any bar width, including a bar of width 0.
local function aimOffsetPx()
    local vp = state.viewport
    if not vp or (vp.width or 0) <= 0 or (vp.height or 0) <= 0 then return 0.0 end
    local free = vp.width - vp.left - vp.right
    -- Bars wider than the window (a very narrow client): there is no strip to
    -- aim at, so fall back to the screen centre rather than aiming off-screen.
    if free <= 0 then return 0.0 end
    return (vp.left - vp.right) * 0.5
end

--- The pixel offset above, converted to metres in the world at the mannequin's
--- distance from the camera.
---
--- With a vertical FOV the visible height at distance d is 2*d*tan(fov/2), and
--- the visible width is that times the aspect ratio (width/height). Metres per
--- horizontal pixel is therefore
---     (2*d*tan(fov/2) * (width/height)) / width  ==  2*d*tan(fov/2) / height
--- — the window width cancels out, which is why only the height is used here.
---
--- THE ONE TUNABLE LINE: Config.scene.aimScale (default 1.0). If the ped sits
--- slightly off-centre in the free strip in-game, correct it there and nowhere
--- else. UNVERIFIED: exact screen-space alignment cannot be checked without a
--- running game, and any FOV/aspect handling the engine does behind SetCamFov
--- would show up as a constant factor exactly here.
local function aimShiftMetres()
    local px = aimOffsetPx()
    if px == 0.0 then return 0.0 end
    local vp = state.viewport
    local metresPerPx = (2.0 * state.dist * math.tan(math.rad(CAM_FOV) * 0.5)) / vp.height
    local scale = (Config.scene and tonumber(Config.scene.aimScale)) or 1.0
    -- Moving the camera to its own right pushes the subject to the LEFT of the
    -- frame, hence the minus.
    return -px * metresPerPx * scale
end

local function updateCam()
    if not state.cam or not DoesCamExist(state.cam) then return end
    local coords = Config.scene.coords
    local yaw = math.rad(state.camYaw)
    -- Fixed azimuth: the mannequin turns under a still camera, which keeps the
    -- lighting on the garment stable while the user inspects it.
    local fx, fy = math.sin(yaw), -math.cos(yaw)  -- unit vector camera -> mannequin
    local rx, ry = fy, -fx                        -- the camera's right, horizontal (no roll)

    -- Off-centring is a LATERAL TRANSLATION, not a rotation: the camera and its
    -- look-at point move by the same vector, so the view direction is unchanged
    -- and only the subject slides across the frame. Rotating the camera instead
    -- (aiming it off to one side) would change the angle light hits the garment
    -- at, so a jacket would visibly change shade when the sidebars resize — the
    -- one thing a clothing preview must never do.
    local shift = aimShiftMetres()

    local aimX = coords.x + rx * shift
    local aimY = coords.y + ry * shift
    local aimZ = coords.z + state.framing

    SetCamCoord(state.cam, aimX - fx * state.dist, aimY - fy * state.dist, aimZ)
    PointCamAtCoord(state.cam, aimX, aimY, aimZ)
    SetCamFov(state.cam, CAM_FOV)
    state.camDirty = false
end

--- Tell the scene how much of the screen the NUI is covering on each side, so
--- the mannequin ends up centred in the gap instead of behind a sidebar.
--- Called from the "viewport" NUI callback in main.lua on open and on resize.
---
--- Takes EITHER four numbers or the rect table straight off the NUI message:
---   Scene.setViewport(320, 340, 1920, 1080)
---   Scene.setViewport({ left = 320, right = 340, width = 1920, height = 1080 })
--- Both are in use — main.lua forwards the message table as-is, while the
--- four-argument form is the one written down in the contract. Accepting both
--- costs three lines and removes a whole class of "silently centred anyway".
function Scene.setViewport(left, right, width, height)
    if type(left) == 'table' then
        local rect = left
        left, right, width, height = rect.left, rect.right, rect.width, rect.height
    end

    local vp = state.viewport
    vp.left   = math.max(0.0, tonumber(left) or 0.0)
    vp.right  = math.max(0.0, tonumber(right) or 0.0)
    local w, h = tonumber(width), tonumber(height)
    -- A zero/absent size would divide by zero downstream; keep the last known
    -- good one instead, and the mapping simply stays where it was.
    if w and w > 0 then vp.width = w end
    if h and h > 0 then vp.height = h end
    state.camDirty = true
    -- Returned for logging/debugging: how far off the screen centre we now aim.
    return aimOffsetPx()
end

local function createCam()
    if state.cam and DoesCamExist(state.cam) then return state.cam end
    local coords = Config.scene.coords
    -- Camera stands in front of the mannequin's initial heading.
    state.camYaw = (coords.w + 180.0) % 360.0
    state.cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        coords.x, coords.y, coords.z + state.framing,
        0.0, 0.0, 0.0, CAM_FOV, false, 2)
    SetCamActive(state.cam, true)
    RenderScriptCams(true, false, 0, true, true)
    state.camDirty = true
    updateCam()
    return state.cam
end

local function destroyCam()
    RenderScriptCams(false, false, 0, true, true)
    if state.cam and DoesCamExist(state.cam) then
        DestroyCam(state.cam, false)
    end
    state.cam = nil
end

--------------------------------------------------------------------------------
-- camera controls (presets, zoom, height, auto-rotate, light)
--------------------------------------------------------------------------------

-- The NUI speaks 0..1 for zoom and height; the scene speaks metres. These two
-- pairs are the only place that mapping lives, so the wheel, the drag and the
-- NUI all stay on the same scale.
local function zoomToDist(zoom)     -- 0 = far, 1 = close
    return DIST_MAX - clamp01(zoom) * (DIST_MAX - DIST_MIN)
end

local function distToZoom(dist)
    return clamp01((DIST_MAX - dist) / (DIST_MAX - DIST_MIN))
end

local function heightToFraming(h)   -- 0 = feet, 1 = top of head
    local top = state.headOffset
    return FRAMING_MIN + clamp01(h) * (top - FRAMING_MIN)
end

local function framingToHeight(framing)
    local top = state.headOffset
    if top <= FRAMING_MIN then return 0.0 end
    return clamp01((framing - FRAMING_MIN) / (top - FRAMING_MIN))
end

local function setDist(d)
    state.dist = clamp(d, DIST_MIN, DIST_MAX)
    state.camDirty = true
end

local function setFraming(f)
    state.framing = clamp(f, FRAMING_MIN, state.headOffset)
    state.camDirty = true
end

--- Look-at height (metres above the feet) and zoom for a named preset. Heights
--- come out of the measured rig, so "head" is where this model's head actually
--- is rather than a number that happens to suit one ped.
local function presetFrame(name)
    local rig = state.rig or {}
    local top = state.headOffset
    local z
    if name == 'upper' then
        z = rig.chest or (BONE_FALLBACK.chest * top)
    elseif name == 'head' then
        z = rig.head or (BONE_FALLBACK.head * top)
    elseif name == 'legs' then
        -- Between hip and knee: that is where trousers are actually judged.
        local hip  = rig.pelvis or (BONE_FALLBACK.pelvis * top)
        local knee = rig.knee   or (BONE_FALLBACK.knee * top)
        z = (hip + knee) * 0.5
    elseif name == 'feet' then
        -- A little above the ankle bone, or shoes sit on the bottom edge.
        z = (rig.foot or (BONE_FALLBACK.foot * top)) + 0.08
    else -- 'full'
        z = top * 0.52
    end
    return z, (PRESET_ZOOM[name] or PRESET_ZOOM.full)
end

local function applyPreset(name)
    if not PRESET_ZOOM[name] then return false end
    local z, zoom = presetFrame(name)
    state.preset = name
    setFraming(z)
    setDist(zoomToDist(zoom))
    return true
end

--- Timecycle modifier for a light mode, or nil for "no modifier at all".
local function lightModifier(mode)
    local cfg = (Config.scene and Config.scene.lights) or {}
    if mode == 'studio' then
        return cfg.studio or (Config.scene and Config.scene.timecycle)
    elseif mode == 'bright' then
        return cfg.bright or LIGHT_FALLBACK.bright
    elseif mode == 'dark' then
        return cfg.dark or LIGHT_FALLBACK.dark
    end
    return nil -- 'none'
end

local function applyLight(mode)
    if mode ~= 'bright' and mode ~= 'dark' and mode ~= 'none' then mode = 'studio' end
    state.light = mode

    -- Remember the choice but touch nothing while the stage is down: a stray
    -- "camera" message after close must not leave a timecycle modifier running
    -- over normal gameplay. Scene.open applies whatever is remembered here.
    if not state.open then return end

    local name = lightModifier(mode)
    if name then
        SetTimecycleModifier(name)
        SetTimecycleModifierStrength(1.0)
        state.timecycle = name
        return
    end

    -- 'none', or 'studio' on a server that configured no studio timecycle.
    -- Only actively clear if we had set one: with no timecycle configured the
    -- documented behaviour is to leave the world's own lighting alone.
    if state.timecycle then
        ClearTimecycleModifier()
        SetTimecycleModifier('default')
        SetTimecycleModifierStrength(1.0)
    end
    state.timecycle = nil
end

--- Auto-rotate turns the PED, never the camera — same reason as the drag: the
--- light stays put and the garment turns through it. A manual drag wins while
--- it lasts, and the rotation resumes by itself when the button is released.
local function autoRotateTick()
    if not state.autoRotate or state.dragging then return end
    local ped = state.ped
    if not ped or not DoesEntityExist(ped) then return end
    state.heading = (state.heading + AUTO_ROT_SPEED * GetFrameTime()) % 360.0
    SetEntityHeading(ped, state.heading)
end

--- The camera contract from the NUI. Every field is optional; an absent field
--- leaves that aspect alone. A preset is applied first so that an explicit zoom
--- or height in the same message can still override part of it.
--- Returns the resulting state, ready to be echoed back to the NUI.
function Scene.camera(opts)
    if type(opts) ~= 'table' then return Scene.cameraState() end

    if type(opts.preset) == 'string' then applyPreset(opts.preset) end

    local zoom = tonumber(opts.zoom)
    if zoom then setDist(zoomToDist(zoom)) end

    local height = tonumber(opts.height)
    if height then setFraming(heightToFraming(height)) end

    if opts.autoRotate ~= nil then
        state.autoRotate = opts.autoRotate and true or false
    end

    if opts.light ~= nil then applyLight(opts.light) end

    state.camDirty = true
    return Scene.cameraState()
end

--- Current camera values in the NUI's units, for the { action = "camera" } echo.
--- `preset` is the last preset that was applied: dragging or scrolling afterwards
--- moves zoom/height away from it without renaming it, because the contract only
--- allows the five preset names.
function Scene.cameraState()
    return {
        preset     = state.preset,
        zoom       = distToZoom(state.dist),
        height     = framingToHeight(state.framing),
        autoRotate = state.autoRotate,
        light      = state.light,
    }
end

--------------------------------------------------------------------------------
-- input (mouse drag / wheel)
--------------------------------------------------------------------------------

-- The mannequin is turned by dragging the FREE STRIP between the two sidebars.
--
-- That needs two things, and neither alone is enough:
--   1. main.lua calls SetNuiFocusKeepInput(true) alongside SetNuiFocus(true, true).
--      Without it CEF owns the cursor, the game reports no mouse delta and every
--      branch below is dead — `pointer-events: none` in the CSS only stops the
--      DOM from eating the drag, it does not hand the mouse back to the game.
--   2. The drag is ignored unless the cursor is over the free strip (below).
--      Otherwise dragging a slider in a sidebar would spin the ped as well.
local function cursorInFreeStrip()
    local vp = state.viewport
    -- No viewport yet (the NUI reports it right after open): treat the whole
    -- screen as free rather than blocking input entirely.
    if not vp or not vp.width or vp.width <= 0 then return true end
    local x = GetControlNormal(0, 239) * vp.width -- INPUT_CURSOR_X, 0..1
    return x > (vp.left or 0) and x < (vp.width - (vp.right or 0))
end

local function handleInput()
    for i = 1, #DISABLED_CONTROLS do
        DisableControlAction(0, DISABLED_CONTROLS[i], true)
    end
    if not state.inputEnabled or not cursorInFreeStrip() then
        -- No mouse (or the cursor is over a sidebar): end any drag in progress,
        -- otherwise it would block auto-rotate forever.
        state.dragging = false
        return
    end

    -- LMB drag turns the PED. Rotating the mannequin instead of orbiting the
    -- camera keeps the studio lighting fixed relative to the room.
    state.dragging = IsDisabledControlPressed(0, 24) or IsDisabledControlPressed(0, 25)
    if IsDisabledControlPressed(0, 24) then
        local dx = GetDisabledControlNormal(0, 1)
        if dx ~= 0.0 then
            state.heading = (state.heading - dx * ROT_SPEED) % 360.0
            if state.ped and DoesEntityExist(state.ped) then
                SetEntityHeading(state.ped, state.heading)
            end
        end
    end

    -- RMB drag frames vertically, clamped between the feet and the top of the
    -- head. setFraming/setDist own the clamping, so the mouse and the NUI's
    -- 0..1 values can never disagree about the limits.
    if IsDisabledControlPressed(0, 25) then
        local dy = GetDisabledControlNormal(0, 2)
        if dy ~= 0.0 then
            setFraming(state.framing - dy * FRAME_SPEED)
        end
    end

    -- Wheel zooms. 241/242 are the cursor scroll controls; 14/15 cover setups
    -- where the wheel is bound to the weapon wheel instead.
    if IsDisabledControlJustPressed(0, 241) or IsDisabledControlJustPressed(0, 14) then
        setDist(state.dist - ZOOM_STEP)
    elseif IsDisabledControlJustPressed(0, 242) or IsDisabledControlJustPressed(0, 15) then
        setDist(state.dist + ZOOM_STEP)
    end
end

--- Let main.lua switch the Lua-side mouse handling off while the NUI has the
--- cursor, and back on for an inspection mode.
function Scene.setInputEnabled(enabled)
    state.inputEnabled = enabled and true or false
end

--------------------------------------------------------------------------------
-- open / close
--------------------------------------------------------------------------------

local function startLoop()
    CreateThread(function()
        while state.open do
            HideHudAndRadarThisFrame()
            handleInput()
            -- Outside handleInput on purpose: auto-rotate has to keep running
            -- while the NUI owns the mouse and the Lua-side input is off.
            autoRotateTick()
            if state.camDirty then updateCam() end
            Wait(0)
        end
    end)
end

--- Build the stage.
--- Returns the mannequin handle on success.
--- Returns nil PLUS a reason string when the mannequin could not be created — it
--- does not throw, so a caller that only checks pcall's ok flag would see a
--- "successful" open of an empty stage. The second return value is there so
--- main.lua can say what actually went wrong. Nothing was switched on in the
--- failure case, so there is nothing to undo.
function Scene.open(gender)
    gender = (gender == 'female') and 'female' or 'male'
    if state.open then
        if gender ~= state.gender then return Scene.setGender(gender) end
        return state.ped
    end

    local ped, reason = spawnMannequin(gender)
    if not ped then
        reason = reason or 'mannequin model failed to load'
        print('[atelier] scene could not be opened: ' .. reason)
        return nil, reason
    end

    state.open = true
    bucketEnter()

    -- The player stays where they are; only the camera travels. Freezing them
    -- stops the untended body from wandering, falling or drowning meanwhile.
    local playerPed = PlayerPedId()
    FreezeEntityPosition(playerPed, true)
    SetEntityInvincible(playerPed, true)
    state.playerFrozen = true

    createCam()
    applyPreset(state.preset or 'full')

    DisplayRadar(false)
    applyLight(state.light or 'studio')

    startLoop()
    return ped
end

--- Swap the mannequin model. Returns the NEW ped handle (nil on failure) so the
--- caller can re-apply the outfit and re-read the per-slot limits — both are
--- model-specific and neither survives the swap.
function Scene.setGender(gender)
    gender = (gender == 'female') and 'female' or 'male'
    if not state.open then
        state.gender = gender
        return nil
    end
    if gender == state.gender and state.ped and DoesEntityExist(state.ped) then
        return state.ped
    end

    local ped, reason = spawnMannequin(gender)
    if not ped then
        reason = reason or 'model did not load'
        print(('[atelier] gender swap to %s failed: %s'):format(gender, reason))
        return nil, reason
    end

    -- The new model has its own rig, so the preset heights and the framing clamp
    -- have to be recomputed; updateCam then also re-derives the viewport shift,
    -- which depends on the (possibly changed) camera distance.
    if state.preset then applyPreset(state.preset) end
    updateCam()
    return ped
end

--- The current mannequin, or nil when the scene is closed.
function Scene.ped()
    if state.ped and DoesEntityExist(state.ped) then return state.ped end
    return nil
end

--- main.lua and discovery.lua both reach for Scene.getPed. Both names are part
--- of the surface now; they are the same function, so neither caller can drift.
Scene.getPed = Scene.ped

function Scene.isOpen()
    return state.open
end

function Scene.gender()
    return state.gender
end

--- Tear the stage down. Safe to call when nothing is open, and safe to call
--- twice — every step is guarded, because this is also the resource-stop path.
function Scene.close()
    local wasOpen = state.open
    state.open = false

    destroyCam()
    destroyPed()

    if wasOpen or state.timecycle then
        ClearTimecycleModifier()
        SetTimecycleModifier('default')
        SetTimecycleModifierStrength(1.0)
        state.timecycle = nil
    end

    DisplayRadar(true)
    SetNuiFocus(false, false)

    if state.playerFrozen then
        local playerPed = PlayerPedId()
        if DoesEntityExist(playerPed) then
            FreezeEntityPosition(playerPed, false)
            SetEntityInvincible(playerPed, false)
        end
        state.playerFrozen = false
    end

    bucketLeave()

    state.dist    = DIST_DEFAULT
    state.framing = 0.65
    state.camDirty = true
    state.inputEnabled = true
    state.preset     = 'full'
    state.light      = 'studio'
    state.autoRotate = false
    state.dragging   = false
    state.rig        = nil
    -- state.viewport is deliberately NOT reset: the bar widths from the last
    -- session are a better first guess than "centre the screen", and the NUI
    -- sends a fresh "viewport" immediately after every open anyway.
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Scene.close()
end)
