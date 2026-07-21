--==========================================================================--
-- client/indexmap.lua
--
-- Manifest item  ->  runtime drawable index.
--
-- This is THE unknown of the project. A pack is BUILT with local indices that
-- restart at 0 in every part (localIndex = the NNN in the stream file name),
-- while SetPedComponentVariation takes a GLOBAL index counted across vanilla
-- plus every loaded DLC. Nothing in the manifest states where the pack's block
-- of drawables ends up in that global list, because at build time it is not
-- knowable — it depends on what else the server streams.
--
-- Three strategies, one entry point:
--
--   'replace'  mode=="replace" items use replaceTargetId. CERTAIN: a replace
--              build overwrites an existing drawable, so the runtime index is
--              the one it overwrote. No arithmetic involved.
--
--   'offset'   vanillaCount + localIndex. ASSUMES: (a) add-on drawables are
--              appended after the vanilla ones, (b) each pack occupies one
--              contiguous block, (c) blocks are ordered the way this file
--              guesses. vanillaCount cannot be measured directly on a running
--              server (the DLCs are already loaded), so Probe derives it as
--              live - sum(manifest items in that slot); see deriveBaselines.
--
--   'browse'   no mapping at all. The caller walks the live range itself and
--              the user picks by eye. Always works, never lies. Default.
--
-- Defines exactly one global: IndexMap
--==========================================================================--

IndexMap = {}

local STRATEGIES = { 'browse', 'offset', 'replace' }
local IS_STRATEGY = { browse = true, offset = true, replace = true }

--- Deliberately 'browse': it is the only strategy that cannot be wrong.
local strategy = 'browse'

--- baselines["gender:kind:slotId"] = number of drawables that are NOT from any
--- known atelier pack (vanilla + unknown third-party DLCs).
local baselines = {}

--- blocks["dlcName|gender:kind:slotId"] = first runtime index of that dlc's
--- block in that slot.
local blocks = {}

--- ambiguous["gender:kind:slotId"] = true when more than one dlc contributes
--- drawables to the slot, which is exactly when block ordering starts to matter
--- and we cannot verify it.
local ambiguous = {}

local derived = nil -- summary of the last deriveBaselines() run

--- Packs handed over by IndexMap.build(), so a caller that only has a
--- descriptor (no full manifest item) can still be served.
local knownPacks = nil

--- Genders whose baselines have already been derived for the current ped.
local baselined = {}

local function key(gender, kind, slotId)
    return ('%s:%s:%d'):format(gender, kind, slotId)
end

local function blockKey(dlcName, gender, kind, slotId)
    return ('%s|%s'):format(dlcName, key(gender, kind, slotId))
end

--==========================================================================--
-- Strategy selection
--==========================================================================--

--- @return string[] the strategy names, in "safest first" order
function IndexMap.strategies()
    local out = {}
    for i = 1, #STRATEGIES do out[i] = STRATEGIES[i] end
    return out
end

--- @return boolean whether the name was accepted
function IndexMap.setStrategy(name)
    if not IS_STRATEGY[name] then
        print(('[atelier] indexmap: unknown strategy %q — keeping %q'):format(tostring(name), strategy))
        return false
    end
    strategy = name
    return true
end

function IndexMap.getStrategy()
    return strategy
end

function IndexMap.reset()
    baselines, blocks, ambiguous, derived = {}, {}, {}, nil
    baselined = {}
end

--- Hand the merged packs over so the map can serve callers that only have a
--- descriptor, and so baselines can be derived the moment a ped exists.
---
--- Called before the mannequin is spawned (the packs are known long before the
--- scene opens), so this only caches: the measuring happens on first use, when
--- there is something to measure. Safe to call again after a rescan.
--- @param packs table[] output of Discovery.merge()
function IndexMap.setPacks(packs)
    knownPacks = packs
    baselined = {}
    return true
end

--- Alias: client/main.lua binds this name.
IndexMap.build = IndexMap.setPacks

function IndexMap.getPacks()
    return knownPacks
end

--==========================================================================--
-- Baselines / blocks (filled in by Probe)
--==========================================================================--

function IndexMap.setBaseline(gender, kind, slotId, count)
    baselines[key(gender, kind, slotId)] = count
end

function IndexMap.getBaseline(gender, kind, slotId)
    return baselines[key(gender, kind, slotId)]
end

function IndexMap.setBlock(dlcName, gender, kind, slotId, firstIndex)
    blocks[blockKey(dlcName, gender, kind, slotId)] = firstIndex
end

function IndexMap.getBlock(dlcName, gender, kind, slotId)
    return blocks[blockKey(dlcName, gender, kind, slotId)]
end

function IndexMap.lastDerivation()
    return derived
end

--- Work out, per slot, how many drawables are NOT ours, and where each dlc's
--- block would start if the assumptions above hold.
---
--- The arithmetic: the engine reports `live` drawables for a slot. Every item
--- in every known manifest for that slot is one drawable. Whatever is left over
--- is vanilla plus any DLC we know nothing about:
---
---     baseline = live - (number of manifest items in that slot)
---
--- Then each dlc's block starts after the baseline and after every dlc ordered
--- before it.
---
--- UNVERIFIED: the order of the blocks. Within one project the parts are laid
--- out in part order, which is the best guess available. ACROSS projects the
--- real order is decided by resource start order and the game's dlc list, which
--- this code cannot see. Whenever more than one dlc feeds a slot the result is
--- flagged ambiguous and 'offset' should not be trusted there.
---
--- @param ped integer the mannequin, already wearing the right model
--- @param logicalPacks table[] output of Discovery.merge()
--- @return table summary { gender, slots = { [key] = {...} }, negatives = n }
function IndexMap.deriveBaselines(ped, logicalPacks)
    logicalPacks = logicalPacks or knownPacks
    local gender = Discovery.genderOf(ped)
    local summary = { gender = gender, slots = {}, negatives = 0, ambiguousSlots = 0 }
    if not gender then
        derived = summary
        return summary
    end

    -- Only drop what we are about to re-measure: a probe run on the male
    -- mannequin must not wipe what an earlier run learned about the female one.
    local prefix = gender .. ':'
    for k in pairs(baselines) do
        if k:sub(1, #prefix) == prefix then baselines[k] = nil end
    end
    for k in pairs(ambiguous) do
        if k:sub(1, #prefix) == prefix then ambiguous[k] = nil end
    end
    for k in pairs(blocks) do
        if k:find('|' .. prefix, 1, true) then blocks[k] = nil end
    end

    -- tally[slotKey] = { order = { dlcName, ... }, count = { [dlcName] = n }, total = n }
    local tally = {}
    for _, pack in ipairs(logicalPacks or {}) do
        for _, item in ipairs(pack.items or {}) do
            if item.gender == gender and item.mode ~= 'replace' then
                -- replace items do not add a drawable, they overwrite one, so
                -- they must not shift anybody's block.
                local k = key(gender, item.kind, item.slotId)
                local t = tally[k]
                if not t then
                    t = { order = {}, count = {}, total = 0 }
                    tally[k] = t
                end
                if not t.count[item.dlcName] then
                    t.count[item.dlcName] = 0
                    t.order[#t.order + 1] = item.dlcName
                end
                t.count[item.dlcName] = t.count[item.dlcName] + 1
                t.total = t.total + 1
            end
        end
    end

    local slots = {}
    for _, c in ipairs(Discovery.componentSlots()) do slots[#slots + 1] = { 'component', c } end
    for _, a in ipairs(Discovery.propAnchors()) do slots[#slots + 1] = { 'prop', a } end

    for _, sl in ipairs(slots) do
        local kind, slotId = sl[1], sl[2]
        local k = key(gender, kind, slotId)
        local live = Discovery.liveCount(ped, kind, slotId)
        local t = tally[k]
        local ours = t and t.total or 0
        local baseline = live - ours

        local entry = { kind = kind, slotId = slotId, live = live, ours = ours, baseline = baseline, dlcs = {} }

        if baseline < 0 then
            -- The manifest claims more drawables than the engine has: the pack
            -- is not (fully) streamed, or something else is off. Refuse to
            -- guess rather than hand out indices that are certainly wrong.
            summary.negatives = summary.negatives + 1
            entry.baseline = nil
            entry.problem = 'manifest lists more drawables than the engine reports — pack not streamed?'
        else
            baselines[k] = baseline
            local cursor = baseline
            if t then
                if #t.order > 1 then
                    ambiguous[k] = true
                    summary.ambiguousSlots = summary.ambiguousSlots + 1
                end
                for _, dlc in ipairs(t.order) do
                    blocks[blockKey(dlc, gender, kind, slotId)] = cursor
                    entry.dlcs[#entry.dlcs + 1] = { dlcName = dlc, first = cursor, count = t.count[dlc] }
                    cursor = cursor + t.count[dlc]
                end
            end
        end

        summary.slots[k] = entry
    end

    derived = summary
    return summary
end

--==========================================================================--
-- Resolution
--==========================================================================--

--- The valid runtime range for a slot on this ped.
--- Components start at 0. Props start at -1, which means "no prop" — a prop is
--- removed with ClearPedProp, never with index -1 through SetPedPropIndex.
--- @return integer min, integer max
--- An empty slot returns max < min, so `for i = min, max` simply does not run.
function IndexMap.range(kind, slotId, ped)
    local live = Discovery.liveCount(ped, kind, slotId)
    if kind == 'prop' then
        return -1, live - 1
    end
    return 0, live - 1
end

--- Map one manifest item to a runtime drawable index.
---
--- mode=="replace" is honoured under EVERY strategy, because it is the one
--- case that needs no guessing at all.
---
--- @param item table normalised manifest item
--- @param ped integer
--- @return integer|nil index, table info
---   info.source     'replace' | 'offset' | 'browse' | 'none'
---   info.confidence 'certain' | 'guess' | 'unknown'
---   info.min/max    the live range (for the browse fallback)
---   info.reason     why there is no index, when index is nil
function IndexMap.resolve(item, ped)
    if type(item) ~= 'table' then
        return nil, { source = 'none', confidence = 'unknown', strategy = strategy, reason = 'no item' }
    end

    ped = ped or Discovery.currentPed()

    -- Accept a bare descriptor {dlcName, gender, kind, slotId, localIndex} as
    -- well as a full manifest item. A descriptor carries no mode and no
    -- replaceTargetId, so a replace item would silently be treated as an
    -- add-on and dress the mannequin in the wrong thing — look the real item up
    -- instead, and only fall back to the descriptor if it is genuinely unknown.
    if item.uid == nil or item.textures == nil then
        local found = knownPacks and Discovery.findItem(knownPacks, {
            kind = item.kind, slotId = item.slotId, localIndex = item.localIndex,
            dlcName = item.dlcName, gender = item.gender,
        })
        item = found or {
            kind = item.kind,
            gender = item.gender or Discovery.genderOf(ped),
            slotId = item.slotId,
            localIndex = item.localIndex,
            dlcName = item.dlcName,
            textures = item.textures or 1,
            mode = item.mode or 'addon',
            replaceTargetId = item.replaceTargetId,
        }
    end

    -- Derive baselines on first use: build() runs before the mannequin exists,
    -- and the counts can only be read off a living ped.
    if strategy == 'offset' and knownPacks then
        local gender = item.gender or Discovery.genderOf(ped)
        local pedGender = Discovery.genderOf(ped)
        -- Derive when the ped agrees with the item, OR when the ped's gender
        -- cannot be determined at all. Refusing on an unknown ped would mean
        -- no baseline, hence resolve() = nil, hence every add-on item silently
        -- unapplicable — a far worse outcome than measuring a ped we are not
        -- certain about, which the read-back catches anyway.
        if gender and not baselined[gender] and (pedGender == gender or pedGender == nil) then
            baselined[gender] = true
            IndexMap.deriveBaselines(ped, knownPacks)
        end
    end

    local min, max = IndexMap.range(item.kind, item.slotId, ped)
    local info = { source = 'none', confidence = 'unknown', min = min, max = max, strategy = strategy }

    if item.mode == 'replace' and item.replaceTargetId then
        info.source = 'replace'
        info.confidence = 'certain'
        return item.replaceTargetId, info
    end

    if strategy == 'replace' then
        -- Nothing to go on: an add-on item never overwrote anything.
        info.reason = 'add-on item has no replaceTargetId; strategy "replace" cannot map it'
        return nil, info
    end

    if strategy == 'offset' then
        local k = key(item.gender, item.kind, item.slotId)
        local first = blocks[blockKey(item.dlcName, item.gender, item.kind, item.slotId)]
        local base = first or baselines[k]
        if not base then
            info.reason = 'no baseline for this slot — run Probe.run() first'
            return nil, info
        end
        info.source = 'offset'
        info.confidence = 'guess'
        info.baseline = base
        info.blockResolved = first ~= nil
        info.ambiguous = ambiguous[k] == true
        return base + item.localIndex, info
    end

    -- 'browse': deliberately no mapping. The caller iterates min..max.
    info.source = 'browse'
    info.reason = 'browse strategy: the caller walks the live range itself'
    return nil, info
end

--- Browse aid: which live drawables in this slot have exactly as many texture
--- variations as the manifest promises for this item.
---
--- This is a filter, not proof — several drawables can share a texture count.
--- But when a pack adds four-texture hoodies to a slot whose vanilla drawables
--- have one or two, the shortlist is usually very short, and if the 'offset'
--- guess is not in the shortlist it is definitely wrong.
---
--- @param limit integer|nil stop after this many hits (default 32)
--- @return integer[] candidate indices, boolean truncated
function IndexMap.candidates(item, ped, limit)
    limit = limit or 32
    local out, truncated = {}, false
    local min, max = IndexMap.range(item.kind, item.slotId, ped)
    local from = math.max(min, 0)

    for i = from, max do
        local textures
        if item.kind == 'prop' then
            textures = GetNumberOfPedPropTextureVariations(ped, item.slotId, i)
        else
            textures = GetNumberOfPedTextureVariations(ped, item.slotId, i)
        end
        if textures == item.textures then
            if #out >= limit then
                truncated = true
                break
            end
            out[#out + 1] = i
        end
    end

    return out, truncated
end
