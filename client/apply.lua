--- Apply — put a drawable on the mannequin and report what the engine actually did.
---
--- Every function here is synchronous and touches nothing but the ped it is
--- handed. No debounce, no NUI, no state: main.lua owns all of that.
---
--- The read-back is the point of this file. SetPedComponentVariation and
--- SetPedPropIndex do not fail loudly — an index the model does not have is
--- silently clamped to something that exists, and the ped ends up wearing a
--- different garment than the one asked for. GetPedDrawableVariation afterwards
--- is the only honest answer, so every apply returns it.
Apply = {}

--- Component ids, in the order the game uses them.
Apply.components = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }

--- The naked base for the freemode peds: bare arms, underwear, bare feet, no
--- top and no undershirt. Anything not listed goes to drawable 0.
--- UNVERIFIED: these are the values the community consistently uses for a nude
--- freemode ped; they were not confirmed against a running game here. If a
--- mannequin turns up wearing something after Apply.clearAll, this table (and
--- only this table) is what needs correcting.
local NAKED = {
    male = {
        [3] = 15,  -- torso / arms: bare
        [4] = 21,  -- legs: underwear
        [6] = 34,  -- feet: bare
        [8] = 15,  -- undershirt: none
        [11] = 15, -- top: none
    },
    female = {
        [3] = 15,
        [4] = 15,
        [6] = 35,
        [8] = 14,
        [11] = 15,
    },
}

--- Prop anchors this resource treats as real slots, honouring the hip flag.
function Apply.anchors()
    local out = {}
    for i = 1, #Config.propAnchors do
        out[#out + 1] = Config.propAnchors[i]
    end
    if Config.includeHipAnchor then
        local has = false
        for i = 1, #out do
            if out[i] == 8 then
                has = true
                break
            end
        end
        if not has then out[#out + 1] = 8 end
    end
    return out
end

--- Model hashes cross the Lua boundary as 32-bit values whose SIGN is not
--- guaranteed to agree between natives: joaat() hands back an unsigned hash,
--- while GetEntityModel can report the same hash as a negative number once the
--- top bit is set. mp_f_freemode_01 is exactly such a hash (0x9C9EFFD8), so a
--- naive `==` can decide a female mannequin is male — and then Apply.clearAll
--- dresses her from the male naked table. Normalising both sides to unsigned
--- removes the question.
local function u32(hash)
    hash = tonumber(hash) or 0
    if hash < 0 then hash = hash + 4294967296 end
    return hash
end

local function genderOf(ped)
    local model = u32(GetEntityModel(ped))
    if model == u32(joaat(Config.peds.female)) then return 'female' end
    return 'male'
end

local function dead(index)
    return { ok = false, applied = index, readback = -1, texture = 0, readbackTexture = -1, textureOk = false }
end

--- Set a component drawable and report the read-back.
--- Returns { ok, applied, readback, texture, readbackTexture, textureOk }.
--- `ok` is false whenever the engine clamped, i.e. whenever it gave us back an
--- index other than the one we asked for.
function Apply.component(ped, slotId, index, texture)
    if not ped or not DoesEntityExist(ped) then return dead(index) end
    index = tonumber(index) or 0
    texture = tonumber(texture) or 0
    if index < 0 then index = 0 end -- components have no -1; that is props only

    -- paletteId is 0 for everything a clothing pack ships; only a handful of
    -- vanilla items use another palette.
    SetPedComponentVariation(ped, slotId, index, texture, 0)

    local rbIndex = GetPedDrawableVariation(ped, slotId)
    local rbTex   = GetPedTextureVariation(ped, slotId)
    return {
        ok              = (rbIndex == index),
        applied         = index,
        readback        = rbIndex,
        texture         = texture,
        readbackTexture = rbTex,
        textureOk       = (rbTex == texture),
    }
end

--- Set a prop and report the read-back.
--- Props are not components: their empty state is -1 and it is reached with
--- ClearPedProp, never with SetPedPropIndex(ped, anchor, -1, ...). A nil or
--- negative index therefore means "take it off".
--- Returns the same shape as Apply.component.
function Apply.prop(ped, anchor, index, texture)
    if not ped or not DoesEntityExist(ped) then return dead(index or -1) end
    index = tonumber(index) or -1
    texture = tonumber(texture) or 0

    if index < 0 then
        ClearPedProp(ped, anchor)
        local rbIndex = GetPedPropIndex(ped, anchor)
        return {
            ok              = (rbIndex == -1),
            applied         = -1,
            readback        = rbIndex,
            texture         = 0,
            readbackTexture = GetPedPropTextureIndex(ped, anchor),
            textureOk       = true,
        }
    end

    SetPedPropIndex(ped, anchor, index, texture, true)

    local rbIndex = GetPedPropIndex(ped, anchor)
    local rbTex   = GetPedPropTextureIndex(ped, anchor)
    return {
        ok              = (rbIndex == index),
        applied         = index,
        readback        = rbIndex,
        texture         = texture,
        readbackTexture = rbTex,
        textureOk       = (rbTex == texture),
    }
end

--- Take a single slot off. Components fall back to their naked value (0 for
--- everything the NAKED table does not name), props are cleared.
function Apply.clearSlot(ped, kind, slotId)
    if not ped or not DoesEntityExist(ped) then return dead(-1) end
    if kind == 'prop' then
        return Apply.prop(ped, slotId, -1, 0)
    end
    local base = NAKED[genderOf(ped)] or NAKED.male
    return Apply.component(ped, slotId, base[slotId] or 0, 0)
end

--- Reset the whole ped to the naked base: every component to its base drawable,
--- every prop anchor cleared.
function Apply.clearAll(ped)
    if not ped or not DoesEntityExist(ped) then return false end
    local base = NAKED[genderOf(ped)] or NAKED.male

    for i = 1, #Apply.components do
        local slotId = Apply.components[i]
        SetPedComponentVariation(ped, slotId, base[slotId] or 0, 0, 0)
    end

    local anchors = Apply.anchors()
    for i = 1, #anchors do
        ClearPedProp(ped, anchors[i])
    end
    return true
end

--- What the ped is wearing right now, in the shape the NUI "state" message
--- expects: a map of "slotId:kind" -> { index = , texture = }.
--- Props that are empty (-1) are omitted — the NUI reads a missing key as "not
--- applied", and reporting -1 for five anchors on every state message is noise.
function Apply.snapshot(ped)
    local applied = {}
    if not ped or not DoesEntityExist(ped) then return applied end

    for i = 1, #Apply.components do
        local slotId = Apply.components[i]
        applied[slotId .. ':component'] = {
            index   = GetPedDrawableVariation(ped, slotId),
            texture = GetPedTextureVariation(ped, slotId),
        }
    end

    local anchors = Apply.anchors()
    for i = 1, #anchors do
        local anchor = anchors[i]
        local index = GetPedPropIndex(ped, anchor)
        if index >= 0 then
            applied[anchor .. ':prop'] = {
                index   = index,
                texture = GetPedPropTextureIndex(ped, anchor),
            }
        end
    end

    return applied
end

--- How many variations the RUNNING game has for a slot, which is vanilla plus
--- every DLC the connected server streams. This is the number the probe compares
--- a pack's local indices against.
--- Components count drawables directly; props return -1 when the anchor is empty
--- of content, so the count is normalised to 0.
function Apply.liveCount(ped, kind, slotId)
    if not ped or not DoesEntityExist(ped) then return 0 end
    if kind == 'prop' then
        local n = GetNumberOfPedPropDrawableVariations(ped, slotId)
        return (n and n > 0) and n or 0
    end
    return GetNumberOfPedDrawableVariations(ped, slotId) or 0
end

--- Texture count for a given drawable — used by the NUI to bound the texture
--- picker instead of trusting the manifest, which describes the build and not
--- what the server ended up streaming.
function Apply.textureCount(ped, kind, slotId, index)
    if not ped or not DoesEntityExist(ped) then return 0 end
    if kind == 'prop' then
        return GetNumberOfPedPropTextureVariations(ped, slotId, index) or 0
    end
    return GetNumberOfPedTextureVariations(ped, slotId, index) or 0
end
