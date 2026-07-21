--==========================================================================--
-- client/discovery.lua
--
-- Finds atelier packs among the resources that are actually running, turns
-- their manifests into one normalised shape, merges the parts of a project
-- back into one logical pack, and reports what the engine really has loaded
-- on a ped right now.
--
-- Defines exactly one global: Discovery
--==========================================================================--

Discovery = {}

local SCHEMA_PREFIX = 'feelgood.atelier.pack/'
local MANIFEST_FILE = 'atelier-pack.json'

--- The twelve ped component slots. Fixed by the engine, not by us.
local COMPONENT_SLOTS = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }

--- Cosmetic only — used for the probe printout and as a fallback label.
local COMPONENT_NAMES = {
    [0] = 'face', [1] = 'mask', [2] = 'hair', [3] = 'uppr',
    [4] = 'lowr', [5] = 'bags', [6] = 'feet', [7] = 'chai',
    [8] = 'accs', [9] = 'task', [10] = 'decl', [11] = 'jbib',
}

--- Cosmetic only. 6/7 (watch / bracelet) are the established convention;
--- 8 is the one this resource is trying to confirm — see client/probe.lua.
local PROP_NAMES = {
    [0] = 'hat', [1] = 'glasses', [2] = 'ears', [3] = 'mouth',
    [6] = 'watch', [7] = 'bracelet', [8] = 'hip',
}

local VALID_KIND = { component = true, prop = true }
local VALID_GENDER = { male = true, female = true }
local VALID_MODE = { addon = true, replace = true }

local function say(fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or fmt
    print('[atelier] discovery: ' .. msg)
end

local function str(v)
    if type(v) ~= 'string' then return nil end
    local s = v:match('^%s*(.-)%s*$')
    if s == '' then return nil end
    return s
end

local function int(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.floor(n)
    return n
end

--==========================================================================--
-- Slot helpers (shared with probe.lua — discovery.lua loads first)
--==========================================================================--

--- @return integer[] copy of the component slot list
function Discovery.componentSlots()
    local out = {}
    for i = 1, #COMPONENT_SLOTS do out[i] = COMPONENT_SLOTS[i] end
    return out
end

--- The prop anchors this resource treats as real at runtime.
--- Config.propAnchors plus anchor 8 when Config.includeHipAnchor is on.
--- @return integer[]
function Discovery.propAnchors()
    local out = {}
    local seen = {}
    local cfg = (type(Config) == 'table' and type(Config.propAnchors) == 'table') and Config.propAnchors or { 0, 1, 2, 6, 7 }
    for _, a in ipairs(cfg) do
        local n = int(a)
        if n and not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
    if type(Config) == 'table' and Config.includeHipAnchor and not seen[8] then
        out[#out + 1] = 8
    end
    table.sort(out)
    return out
end

--- @return string|nil human label for a slot, cosmetic only
function Discovery.slotName(kind, slotId)
    if kind == 'prop' then return PROP_NAMES[slotId] end
    return COMPONENT_NAMES[slotId]
end

--- The ped being dressed, for callers that did not pass one. Scene owns the
--- mannequin; it loads after this file, so the global is looked up lazily.
---
--- Both accessor names are tried. Falling through to PlayerPedId() is a real
--- hazard and not a harmless default: a probe or an index derivation that runs
--- on the PLAYER measures the player's outfit and hands back baselines for the
--- wrong ped. Callers that have the mannequin should always pass it.
--- @return integer ped handle (0 when there is nothing to work with)
function Discovery.currentPed()
    local scene = Scene
    if type(scene) == 'table' then
        local getter = scene.getPed or scene.ped
        if type(getter) == 'function' then
            local ok, ped = pcall(getter)
            if ok and ped and ped ~= 0 then return ped end
        end
    end
    return PlayerPedId()
end

--- Model hashes cross the Lua boundary as 32-bit values whose SIGN is not
--- guaranteed to agree between natives: GetHashKey hands back an unsigned hash,
--- GetEntityModel can report the same hash negative once the top bit is set.
--- mp_f_freemode_01 is exactly such a hash (0x9C9EFFD8), so a naive `==` can
--- decide a female mannequin is neither gender. This function is load-bearing:
--- a nil here means IndexMap derives no baseline, resolve() returns nil, and
--- EVERY add-on item silently stops applying. (Same normalisation as in
--- apply.lua's local genderOf — keep the two in step.)
local function u32(hash)
    hash = tonumber(hash) or 0
    if hash < 0 then hash = hash + 4294967296 end
    return hash
end

--- Which mannequin gender a ped currently is, by model hash.
--- @return 'male'|'female'|nil
function Discovery.genderOf(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    local model = u32(GetEntityModel(ped))
    local peds = (type(Config) == 'table' and Config.peds) or {}
    if model == u32(GetHashKey(peds.male or 'mp_m_freemode_01')) then return 'male' end
    if model == u32(GetHashKey(peds.female or 'mp_f_freemode_01')) then return 'female' end
    return nil
end

--==========================================================================--
-- Manifest validation
--
-- Rule for everything below: a malformed manifest is SKIPPED with a print,
-- it never raises. A pack file is written by an external tool and can be any
-- shape at all; the viewer must survive that.
--==========================================================================--

--- @return table|nil item, string|nil reason
local function normalizeItem(pack, raw, ordinal)
    if type(raw) ~= 'table' then return nil, 'item #' .. ordinal .. ' is not an object' end

    local kind = str(raw.kind)
    if not kind or not VALID_KIND[kind] then
        return nil, ('item #%d has kind %q (expected "component" or "prop")'):format(ordinal, tostring(raw.kind))
    end

    local gender = str(raw.gender)
    if not gender or not VALID_GENDER[gender] then
        return nil, ('item #%d has gender %q'):format(ordinal, tostring(raw.gender))
    end

    local slotId = int(raw.slotId)
    if not slotId or slotId < 0 then
        return nil, ('item #%d has slotId %q'):format(ordinal, tostring(raw.slotId))
    end
    if kind == 'component' and slotId > 11 then
        return nil, ('item #%d is a component with slotId %d (0..11 only)'):format(ordinal, slotId)
    end

    local localIndex = int(raw.localIndex)
    if not localIndex or localIndex < 0 then
        return nil, ('item #%d has localIndex %q'):format(ordinal, tostring(raw.localIndex))
    end

    local mode = str(raw.mode) or 'addon'
    if not VALID_MODE[mode] then mode = 'addon' end

    local replaceTargetId = int(raw.replaceTargetId)
    if mode == 'replace' and not replaceTargetId then
        -- A replace item without a target cannot be resolved; treat it as an
        -- add-on so it is at least browsable instead of dropping it entirely.
        say('%s: item #%d is mode="replace" without replaceTargetId — treated as addon', pack.resource, ordinal)
        mode = 'addon'
        replaceTargetId = nil
    end

    local textures = int(raw.textures)
    if not textures or textures < 1 then textures = 1 end

    local flags = type(raw.flags) == 'table' and raw.flags or {}
    local slot = str(raw.slot) or Discovery.slotName(kind, slotId) or tostring(slotId)

    return {
        kind = kind,
        gender = gender,
        ped = str(raw.ped),
        slot = slot,
        slotId = slotId,
        localIndex = localIndex,
        textures = textures,
        label = str(raw.label) or ('%s %d'):format(slot, localIndex),
        groupId = str(raw.groupId),
        mode = mode,
        replaceTargetId = replaceTargetId,
        flags = {
            highHeels = flags.highHeels == true,
            firstPerson = flags.firstPerson ~= false, -- default true
            hairScale = tonumber(flags.hairScale),
        },
        -- Carried from the pack. The item key is (dlcName, gender, slotId,
        -- localIndex): localIndex restarts at 0 in every part, so it is
        -- meaningless on its own.
        dlcName = pack.dlcName,
        part = pack.part,
        resource = pack.resource,
        uid = ('%s:%s:%s:%d:%d'):format(pack.dlcName, gender, kind, slotId, localIndex),
    }
end

--- @return table|nil pack, string|nil reason
local function normalizePack(resource, raw)
    local p = type(raw.pack) == 'table' and raw.pack or nil
    if not p then return nil, 'no "pack" object' end

    local dlcName = str(p.dlcName)
    if not dlcName then
        -- Without a dlcName every item key collides across parts. Refuse the
        -- pack rather than show items that cannot be told apart.
        return nil, 'pack.dlcName is missing'
    end

    return {
        projectId = str(p.projectId) or ('resource:' .. resource),
        name = str(p.name) or resource,
        resource = str(p.resource) or resource,
        dlcName = dlcName,
        part = int(p.part) or 1,
        partCount = int(p.partCount) or 1,
    }
end

local function normalizeGroups(raw)
    local out, seen = {}, {}
    if type(raw) ~= 'table' then return out end
    for _, g in ipairs(raw) do
        if type(g) == 'table' then
            local id = str(g.id)
            if id and not seen[id] then
                seen[id] = true
                out[#out + 1] = { id = id, name = str(g.name) or id }
            end
        end
    end
    return out
end

--- Turn one decoded json blob into a normalised manifest.
--- @return table|nil manifest, string|nil reason
local function normalizeManifest(resource, decoded)
    if type(decoded) ~= 'table' then return nil, 'manifest is not an object' end

    local schema = str(decoded.schema)
    if not schema or schema:sub(1, #SCHEMA_PREFIX) ~= SCHEMA_PREFIX then
        return nil, ('schema %q is not %s*'):format(tostring(decoded.schema), SCHEMA_PREFIX)
    end

    local pack, reason = normalizePack(resource, decoded)
    if not pack then return nil, reason end

    local items, skipped = {}, 0
    if type(decoded.items) == 'table' then
        for i, rawItem in ipairs(decoded.items) do
            local item, why = normalizeItem(pack, rawItem, i)
            if item then
                items[#items + 1] = item
            else
                skipped = skipped + 1
                if skipped <= 3 then say('%s: %s', resource, why) end
            end
        end
    end
    if skipped > 3 then
        say('%s: %d more malformed items were skipped', resource, skipped - 3)
    end

    return {
        schema = schema,
        generatedAt = str(decoded.generatedAt),
        tool = str(decoded.tool),
        resource = resource,
        pack = pack,
        groups = normalizeGroups(decoded.groups),
        items = items,
        skippedItems = skipped,
    }
end

--==========================================================================--
-- Scanning
--==========================================================================--

--- @return boolean true for 'started' and for 'starting' (server still booting)
local function isRunning(state)
    if type(state) ~= 'string' then return false end
    return state:sub(1, 5) == 'start'
end

--- Walk every resource on the server and collect the atelier manifests.
---
--- UNVERIFIED: client-side LoadResourceFile only sees files that were actually
--- shipped to the client, i.e. files the pack's own fxmanifest lists in
--- `files {}`. atelier generates that manifest and is expected to list
--- 'atelier-pack.json' there. If a pack is running but its manifest never
--- shows up here, that listing is the first thing to check — the fallback is
--- to read the file server-side and hand the result to Discovery.ingest().
--- @return table[] normalised manifests, sorted by resource name
function Discovery.scan()
    local found = {}
    local total = GetNumResources()

    for i = 0, total - 1 do
        local resource = GetResourceByFindIndex(i)
        if resource and isRunning(GetResourceState(resource)) then
            -- LoadResourceFile returns nil (not an error) when the file is absent,
            -- which is the normal case for the overwhelming majority of resources.
            local raw = LoadResourceFile(resource, MANIFEST_FILE)
            if raw and raw ~= '' then
                local ok, decoded = pcall(json.decode, raw)
                if not ok or decoded == nil then
                    say('%s: %s could not be parsed as json — skipped', resource, MANIFEST_FILE)
                else
                    local manifest, reason = normalizeManifest(resource, decoded)
                    if manifest then
                        found[#found + 1] = manifest
                    else
                        say('%s: %s — skipped', resource, reason)
                    end
                end
            end
        end
    end

    table.sort(found, function(a, b) return a.resource < b.resource end)
    return found
end

--- Feed manifests in from somewhere other than a client-side file read (the
--- server, a test fixture). Same validation, same shape as scan().
--- @param blobs table[] raw decoded manifests, or { resource = string, data = table }
--- @return table[] normalised manifests
function Discovery.ingest(blobs)
    local out = {}
    if type(blobs) ~= 'table' then return out end
    for i, entry in ipairs(blobs) do
        local resource, decoded
        if type(entry) == 'table' and entry.data ~= nil then
            resource, decoded = str(entry.resource) or ('ingest#' .. i), entry.data
        else
            resource, decoded = ('ingest#' .. i), entry
        end
        if type(decoded) == 'string' then
            local ok, parsed = pcall(json.decode, decoded)
            decoded = ok and parsed or nil
        end
        local manifest, reason = normalizeManifest(resource, decoded)
        if manifest then
            out[#out + 1] = manifest
        else
            say('%s: %s — skipped', resource, reason or 'invalid')
        end
    end
    table.sort(out, function(a, b) return a.resource < b.resource end)
    return out
end

--==========================================================================--
-- Merging parts back into logical packs
--==========================================================================--

--- Group manifests by pack.projectId, order their parts, dedupe groups by id
--- (first part wins) and flatten the items.
--- @param manifests table[] output of scan()/ingest()
--- @return table[] logical packs { projectId, name, parts, groups, items }
function Discovery.merge(manifests)
    if type(manifests) ~= 'table' then return {} end

    local byProject, order = {}, {}
    for _, m in ipairs(manifests) do
        local pid = m.pack.projectId
        local bucket = byProject[pid]
        if not bucket then
            bucket = {}
            byProject[pid] = bucket
            order[#order + 1] = pid
        end
        bucket[#bucket + 1] = m
    end

    local packs = {}
    for _, pid in ipairs(order) do
        local parts = byProject[pid]

        -- Part order matters: item localIndex restarts at 0 in every part, so
        -- the parts have to be presented (and later index-mapped) in order.
        table.sort(parts, function(a, b)
            if a.pack.part ~= b.pack.part then return a.pack.part < b.pack.part end
            return a.resource < b.resource
        end)

        local logical = {
            projectId = pid,
            name = parts[1].pack.name,
            partCount = parts[1].pack.partCount,
            parts = {},
            groups = {},
            items = {},
        }

        local groupSeen = {}
        for _, m in ipairs(parts) do
            logical.parts[#logical.parts + 1] = {
                part = m.pack.part,
                partCount = m.pack.partCount,
                resource = m.resource,
                dlcName = m.pack.dlcName,
                itemCount = #m.items,
                generatedAt = m.generatedAt,
                tool = m.tool,
            }
            for _, g in ipairs(m.groups) do
                if not groupSeen[g.id] then
                    groupSeen[g.id] = true
                    logical.groups[#logical.groups + 1] = { id = g.id, name = g.name }
                end
            end
            for _, item in ipairs(m.items) do
                logical.items[#logical.items + 1] = item
            end
        end

        -- The NUI is typed against the RAW manifest shape, which carries its
        -- metadata in a `pack` sub-table. A logical pack is flat, so without
        -- this the UI reads pack.pack.name as nil and every item loses the
        -- dlcName it is keyed by. Part-specific fields are taken from the FIRST
        -- part: after a merge the other parts still carry their own dlcName on
        -- every item, which is the value that actually identifies an item.
        logical.pack = {
            projectId = pid,
            name = logical.name,
            resource = parts[1].resource,
            dlcName = parts[1].pack.dlcName,
            part = parts[1].pack.part,
            partCount = logical.partCount,
        }

        -- A part that is not running is simply absent from `parts`; the gap is
        -- visible to the UI because part numbers are no longer contiguous.
        packs[#packs + 1] = logical
    end

    table.sort(packs, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.projectId < b.projectId
    end)
    return packs
end

--==========================================================================--
-- What the engine actually has loaded
--==========================================================================--

--- Live variation counts for the ped, keyed "gender:kind:slotId" per the NUI
--- contract. This is how a pack that is in a manifest but NOT streamed
--- (assets missing, resource stopped, wrong dlc order) is told apart from one
--- that really is live: the manifest promises drawables, this says how many
--- the engine has.
---
--- Note on props: GetNumberOfPedPropDrawableVariations does NOT count the
--- "no prop" state, so the valid prop range is -1 .. count-1, while a
--- component range is 0 .. count-1.
--- @return table<string, number>
function Discovery.liveCounts(ped)
    local out = {}
    if not ped or ped == 0 or not DoesEntityExist(ped) then return out end

    local gender = Discovery.genderOf(ped) or 'male'

    for _, c in ipairs(COMPONENT_SLOTS) do
        out[('%s:component:%d'):format(gender, c)] = GetNumberOfPedDrawableVariations(ped, c)
    end
    for _, a in ipairs(Discovery.propAnchors()) do
        out[('%s:prop:%d'):format(gender, a)] = GetNumberOfPedPropDrawableVariations(ped, a)
    end

    return out
end

--- Find the manifest item an NUI "apply" payload refers to.
--- The payload carries {kind, slotId, localIndex, dlcName}; together with the
--- gender currently on the mannequin that is the full item key. localIndex on
--- its own is NOT a key — it restarts at 0 in every part.
--- @param packs table[] output of Discovery.merge()
--- @param q table { kind, slotId, localIndex, dlcName, gender }
--- @return table|nil item
function Discovery.findItem(packs, q)
    if type(packs) ~= 'table' or type(q) ~= 'table' then return nil end
    local slotId, localIndex = int(q.slotId), int(q.localIndex)
    if not slotId or not localIndex then return nil end

    local fallback = nil
    for _, pack in ipairs(packs) do
        for _, item in ipairs(pack.items or {}) do
            if item.kind == q.kind and item.slotId == slotId and item.localIndex == localIndex then
                if item.dlcName == q.dlcName and (not q.gender or item.gender == q.gender) then
                    return item
                end
                -- Same slot and local index but a different part: remember it,
                -- so a caller that forgot the dlcName still gets something,
                -- but only after an exact match has been ruled out.
                if not fallback and (not q.gender or item.gender == q.gender) then
                    fallback = item
                end
            end
        end
    end
    return fallback
end

--- Convenience for the same key format used by liveCounts().
function Discovery.liveKey(gender, kind, slotId)
    return ('%s:%s:%d'):format(gender, kind, slotId)
end

--- Is a pack actually streamed, or only described?
--- A manifest is just a text file: it survives the assets being missing, the
--- pack resource being stopped, or a dlc that never loaded. The honest test is
--- whether the engine has at least as many drawables in a slot as the manifest
--- claims to have put there.
--- @param packs table[] output of Discovery.merge()
--- @return table[] one entry per pack { projectId, name, claimed, shortfall, streamed }
function Discovery.packLiveness(ped, packs)
    local out = {}
    local gender = Discovery.genderOf(ped)
    for _, pack in ipairs(packs or {}) do
        local claimed, shortfall, slots = 0, 0, {}
        for _, item in ipairs(pack.items or {}) do
            if item.gender == gender and item.mode ~= 'replace' then
                claimed = claimed + 1
                local k = item.kind .. ':' .. item.slotId
                slots[k] = (slots[k] or 0) + 1
            end
        end
        for k, want in pairs(slots) do
            local kind, slotId = k:match('^(%a+):(%d+)$')
            local live = Discovery.liveCount(ped, kind, tonumber(slotId))
            if live < want then shortfall = shortfall + (want - live) end
        end
        out[#out + 1] = {
            projectId = pack.projectId,
            name = pack.name,
            claimed = claimed,
            shortfall = shortfall,
            -- Not proof of the right assets, only that there is room for them.
            streamed = claimed > 0 and shortfall == 0,
        }
    end
    return out
end

--- How many drawables the engine reports for one slot right now.
--- @return integer
function Discovery.liveCount(ped, kind, slotId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return 0 end
    if kind == 'prop' then
        return GetNumberOfPedPropDrawableVariations(ped, slotId)
    end
    return GetNumberOfPedDrawableVariations(ped, slotId)
end
