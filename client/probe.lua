--==========================================================================--
-- client/probe.lua
--
-- The measurement pass. It answers the two questions the README lists as open,
-- on the server the user is actually connected to:
--
--   1. How do add-on drawables appear at runtime — does 'offset' (vanillaCount
--      + localIndex) land on the item the manifest describes, or is browsing
--      the live range the only honest option?
--   2. Does prop anchor 8 (p_hip) behave like a real anchor?
--
-- Everything here is measured, never assumed: after every apply the value is
-- read back, because the engine silently CLAMPS an out-of-range index instead
-- of failing. Asking for drawable 900 and getting 184 looks exactly like
-- success from the outside unless you read back.
--
-- Probe.run() borrows the mannequin for a moment and puts it back exactly as
-- it found it, including on error.
--
-- Defines exactly one global: Probe
--==========================================================================--

Probe = {}

--- How many manifest items to actually try. Kept small: every sample applies a
--- drawable and walks a slot's texture counts.
local MAX_ITEM_TESTS = 6

--- Packs to test against, if the caller does not pass them to run().
local cachedPacks = nil

--- Safe to call outside a coroutine (does nothing there).
local function yield()
    if coroutine.isyieldable() then Wait(0) end
end

--- Anchors the probe touches: the configured ones plus 8, which is the one
--- under investigation and therefore has to be tested even when Config leaves
--- it out.
local function probedAnchors()
    local out, seen = {}, {}
    for _, a in ipairs(Discovery.propAnchors()) do
        if not seen[a] then seen[a] = true; out[#out + 1] = a end
    end
    if not seen[8] then out[#out + 1] = 8 end
    table.sort(out)
    return out
end

--==========================================================================--
-- Save / restore — the probe must leave no trace on the ped
--==========================================================================--

local function snapshot(ped)
    local snap = { comps = {}, props = {} }
    for _, c in ipairs(Discovery.componentSlots()) do
        snap.comps[c] = {
            d = GetPedDrawableVariation(ped, c),
            t = GetPedTextureVariation(ped, c),
            p = GetPedPaletteVariation(ped, c),
        }
    end
    for _, a in ipairs(probedAnchors()) do
        snap.props[a] = {
            d = GetPedPropIndex(ped, a),
            t = GetPedPropTextureIndex(ped, a),
        }
    end
    return snap
end

local function restore(ped, snap)
    if not snap or not DoesEntityExist(ped) then return end
    for c, v in pairs(snap.comps) do
        SetPedComponentVariation(ped, c, v.d, v.t, v.p)
    end
    for a, v in pairs(snap.props) do
        -- Props are not components: there is no index -1 to set. "No prop" is
        -- ClearPedProp, and SetPedPropIndex(-1) is not the way back.
        if v.d < 0 then
            ClearPedProp(ped, a)
        else
            SetPedPropIndex(ped, a, v.d, v.t, true)
        end
    end
end

--==========================================================================--
-- Single measurements
--==========================================================================--

--- Which indices are worth trying in a slot with `live` drawables: both ends,
--- the middle, and two indices that must be out of range so we can see the
--- clamp happen.
local function testIndices(live)
    local raw = { 0, 1, math.floor(live / 2), live - 1, live, live + 13 }
    local out, seen = {}, {}
    for _, i in ipairs(raw) do
        if i >= 0 and not seen[i] then
            seen[i] = true
            out[#out + 1] = i
        end
    end
    table.sort(out)
    return out
end

local function testComponent(ped, slotId, idx)
    SetPedComponentVariation(ped, slotId, idx, 0, 0)
    local got = GetPedDrawableVariation(ped, slotId)
    return { asked = idx, got = got, exact = got == idx }
end

local function testProp(ped, anchor, idx)
    SetPedPropIndex(ped, anchor, idx, 0, true)
    local got = GetPedPropIndex(ped, anchor)
    return { asked = idx, got = got, exact = got == idx }
end

--==========================================================================--
-- Manifest sampling
--==========================================================================--

--- Pick items worth testing: this ped's gender, one per slot so a single broken
--- slot cannot eat the whole sample, and within a slot the item with the most
--- texture variations.
---
--- That last part is what makes the test worth anything. The only evidence
--- available is "does the drawable at the guessed index have as many textures
--- as the manifest promises", and a one-texture item matches almost everything
--- in the slot, so it proves nothing. A four-texture item usually narrows the
--- slot down to a handful of candidates.
local function sampleItems(packs, gender)
    local perSlot, order = {}, {}
    for _, pack in ipairs(packs or {}) do
        for _, item in ipairs(pack.items or {}) do
            if item.gender == gender then
                local k = ('%s:%d'):format(item.kind, item.slotId)
                local held = perSlot[k]
                if not held then
                    perSlot[k] = item
                    order[#order + 1] = k
                elseif item.textures > held.textures then
                    perSlot[k] = item
                end
            end
        end
    end

    local picks = {}
    for _, k in ipairs(order) do picks[#picks + 1] = perSlot[k] end

    -- Most distinctive first, so the budget is spent on the informative slots.
    table.sort(picks, function(a, b)
        if a.textures ~= b.textures then return a.textures > b.textures end
        return a.uid < b.uid
    end)

    local out = {}
    for _, item in ipairs(picks) do
        out[#out + 1] = item
        if #out >= MAX_ITEM_TESTS then break end
    end
    return out
end

local function testItem(ped, item)
    local record = {
        label = item.label,
        dlcName = item.dlcName,
        part = item.part,
        kind = item.kind,
        slot = item.slot,
        slotId = item.slotId,
        localIndex = item.localIndex,
        mode = item.mode,
        wantTextures = item.textures,
    }

    -- Ask IndexMap for its best arithmetic guess. 'offset' is what we are here
    -- to test; replace items resolve the same under any strategy.
    local previous = IndexMap.getStrategy()
    IndexMap.setStrategy('offset')
    local idx, info = IndexMap.resolve(item, ped)
    IndexMap.setStrategy(previous)

    record.source = info.source
    record.guess = idx
    record.baseline = info.baseline
    record.ambiguous = info.ambiguous == true

    -- The browse shortlist: live drawables whose texture count matches what the
    -- manifest promises. Not proof, but a guess outside this list is wrong.
    local cands, truncated = IndexMap.candidates(item, ped, 12)
    record.candidates = cands
    record.candidatesTruncated = truncated

    if not idx then
        record.verdict = 'no-guess'
        record.note = info.reason
        return record
    end

    local applied
    if item.kind == 'prop' then
        applied = testProp(ped, item.slotId, idx)
        record.gotTextures = GetNumberOfPedPropTextureVariations(ped, item.slotId, applied.got)
    else
        applied = testComponent(ped, item.slotId, idx)
        record.gotTextures = GetNumberOfPedTextureVariations(ped, item.slotId, applied.got)
    end
    record.readback = applied.got
    record.exact = applied.exact

    local inList = false
    for _, c in ipairs(cands) do
        if c == idx then inList = true break end
    end
    record.guessInCandidates = inList

    -- How much a "plausible" here is actually worth. If a dozen drawables in
    -- the slot share the manifest's texture count, landing on one of them is
    -- luck, not evidence.
    record.strength = (not truncated and #cands > 0 and #cands <= 3) and 'strong' or 'weak'

    if not applied.exact then
        record.verdict = 'clamped'
        record.note = ('asked %d, engine gave %d — the guess is past the end of the slot'):format(idx, applied.got)
    elseif record.gotTextures == item.textures then
        record.verdict = 'plausible'
    else
        record.verdict = 'mismatch'
        record.note = ('index %d exists but has %d textures, the manifest says %d')
            :format(idx, record.gotTextures or -1, item.textures)
    end

    return record
end

--==========================================================================--
-- Probe.run
--==========================================================================--

--- Packs to use when run() is called without them.
--- @param packs table[] output of Discovery.merge()
function Probe.setPacks(packs)
    cachedPacks = packs
end

--- Measure the ped. Call this from inside a thread (it yields between applies).
--- The ped is restored to its exact previous appearance before returning.
---
--- Both call shapes work:
---   Probe.run(ped, packs)   the documented one
---   Probe.run(packs)        client/main.lua's shape; the mannequin is taken
---                           from Scene, which is the only ped worth probing
--- @return table report — plain data, safe to hand straight to the NUI
function Probe.run(ped, packs)
    if type(ped) == 'table' then
        ped, packs = packs, ped
    end
    ped = ped or Discovery.currentPed()
    packs = packs or cachedPacks or IndexMap.getPacks()

    local report = {
        ok = true,
        at = GetGameTimer(),
        strategy = IndexMap.getStrategy(),
        gender = Discovery.genderOf(ped),
        components = {},
        props = {},
        hip = nil,
        items = { tested = {}, verdict = 'not tested' },
        warnings = {},
    }

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        report.ok = false
        report.error = 'no ped to probe'
        return report
    end
    if not report.gender then
        report.warnings[#report.warnings + 1] =
            'ped model is not one of Config.peds — manifest items cannot be matched to it'
    end

    local snap = snapshot(ped)

    local ok, err = pcall(function()
        ------------------------------------------------------------------
        -- Components
        ------------------------------------------------------------------
        for _, slotId in ipairs(Discovery.componentSlots()) do
            local live = GetNumberOfPedDrawableVariations(ped, slotId)
            local entry = {
                slotId = slotId,
                slot = Discovery.slotName('component', slotId) or tostring(slotId),
                live = live,
                tests = {},
                clamps = 0,
            }
            if live > 0 then
                for _, idx in ipairs(testIndices(live)) do
                    local t = testComponent(ped, slotId, idx)
                    entry.tests[#entry.tests + 1] = t
                    if not t.exact then entry.clamps = entry.clamps + 1 end
                end
                -- Restore this slot immediately so later slots are measured on
                -- a ped that still looks like the one we were handed.
                local s = snap.comps[slotId]
                SetPedComponentVariation(ped, slotId, s.d, s.t, s.p)
            end
            report.components[#report.components + 1] = entry
            yield()
        end

        ------------------------------------------------------------------
        -- Props (including anchor 8, the one under investigation)
        ------------------------------------------------------------------
        for _, anchor in ipairs(probedAnchors()) do
            -- Count does NOT include the "no prop" state: valid range is
            -- -1 .. live-1, where -1 is reached with ClearPedProp.
            local live = GetNumberOfPedPropDrawableVariations(ped, anchor)
            local entry = {
                anchor = anchor,
                name = Discovery.slotName('prop', anchor) or tostring(anchor),
                configured = false,
                live = live,
                tests = {},
                clamps = 0,
            }
            for _, a in ipairs(Discovery.propAnchors()) do
                if a == anchor then entry.configured = true break end
            end

            -- Does removal actually remove?
            ClearPedProp(ped, anchor)
            entry.clearedTo = GetPedPropIndex(ped, anchor)
            entry.clearOk = entry.clearedTo == -1

            if live > 0 then
                for _, idx in ipairs(testIndices(live)) do
                    local t = testProp(ped, anchor, idx)
                    entry.tests[#entry.tests + 1] = t
                    if not t.exact then entry.clamps = entry.clamps + 1 end
                end
            end

            local s = snap.props[anchor]
            if s.d < 0 then ClearPedProp(ped, anchor) else SetPedPropIndex(ped, anchor, s.d, s.t, true) end

            report.props[#report.props + 1] = entry

            if anchor == 8 then
                local usable = live > 0 and entry.tests[1] ~= nil and entry.tests[1].exact
                report.hip = {
                    anchor = 8,
                    configured = entry.configured,
                    live = live,
                    clearOk = entry.clearOk,
                    usable = usable,
                    verdict = usable
                        and ('anchor 8 accepted a prop index and read it back — it behaves like a real anchor (%d drawables)'):format(live)
                        or (live == 0
                            and 'anchor 8 reports 0 drawables on this ped — nothing is streamed for it, so it cannot be confirmed here'
                            or 'anchor 8 has drawables but did not read back what was set — treat it as not usable'),
                }
            end
            yield()
        end

        ------------------------------------------------------------------
        -- Manifest items: does 'offset' land where the manifest says?
        ------------------------------------------------------------------
        if packs and #packs > 0 and report.gender then
            report.baselines = IndexMap.deriveBaselines(ped, packs)

            local samples = sampleItems(packs, report.gender)
            local strong, weak, wrong, skipped = 0, 0, 0, 0

            for _, item in ipairs(samples) do
                local rec = testItem(ped, item)
                report.items.tested[#report.items.tested + 1] = rec

                -- Only offset-derived results say anything about offset. A
                -- replace item resolves by its own target and would otherwise
                -- inflate the score; a no-guess is offset declining to answer,
                -- which is not the same as offset being wrong.
                if rec.source ~= 'offset' or rec.verdict == 'no-guess' then
                    skipped = skipped + 1
                elseif rec.verdict == 'plausible' then
                    if rec.strength == 'strong' then strong = strong + 1 else weak = weak + 1 end
                else
                    wrong = wrong + 1
                end

                if item.kind == 'prop' then
                    local s = snap.props[item.slotId]
                    if s then
                        if s.d < 0 then ClearPedProp(ped, item.slotId) else SetPedPropIndex(ped, item.slotId, s.d, s.t, true) end
                    else
                        ClearPedProp(ped, item.slotId)
                    end
                else
                    local s = snap.comps[item.slotId]
                    if s then SetPedComponentVariation(ped, item.slotId, s.d, s.t, s.p) end
                end
                yield()
            end

            local testable = strong + weak + wrong
            report.items.strong, report.items.weak = strong, weak
            report.items.wrong, report.items.skipped = wrong, skipped

            if #report.items.tested == 0 then
                report.items.verdict = 'no items for this gender to test'
            elseif testable == 0 then
                report.items.verdict = ('nothing testable: all %d samples were replace items or had no baseline'):format(skipped)
            elseif wrong == 0 and strong > 0 then
                report.items.verdict = ('offset landed on the right drawable for all %d testable samples (%d of them conclusive) — "offset" looks usable'):format(testable, strong)
            elseif wrong == 0 then
                report.items.verdict = ('offset was consistent on %d samples, but every one of them has a texture count shared by many drawables in its slot — inconclusive, stay on "browse"'):format(testable)
            elseif strong + weak == 0 then
                report.items.verdict = ('offset was wrong on all %d testable samples — stay on "browse"'):format(testable)
            else
                report.items.verdict = ('offset matched only %d of %d testable samples — not reliable, stay on "browse"'):format(strong + weak, testable)
            end
        else
            report.items.verdict = 'no packs loaded — index mapping could not be tested'
        end
    end)

    restore(ped, snap)

    if not ok then
        report.ok = false
        report.error = tostring(err)
    end

    if Config and Config.verboseProbe then
        Probe.print(report)
    end

    return report
end

--==========================================================================--
-- Printing — this is what the user reads off their own server, so it has to be
-- legible, not a dump.
--==========================================================================--

local function testsToString(tests)
    local parts = {}
    for _, t in ipairs(tests) do
        if t.exact then
            parts[#parts + 1] = ('%d->%d'):format(t.asked, t.got)
        else
            parts[#parts + 1] = ('%d->%d!'):format(t.asked, t.got)
        end
    end
    return table.concat(parts, '  ')
end

local function line(fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or fmt
    print('[atelier] ' .. msg)
end

function Probe.print(report)
    line('---- index probe ------------------------------------------------')
    if not report.ok then
        line('probe failed: %s', tostring(report.error))
        return
    end

    line('mannequin: %s   strategy: %s', tostring(report.gender or 'unknown model'), tostring(report.strategy))
    for _, w in ipairs(report.warnings or {}) do
        line('warning: %s', w)
    end

    line('')
    line('components — "asked->readback", "!" = engine clamped it')
    line('  id  slot   live   read-back')
    for _, c in ipairs(report.components) do
        if c.live > 0 then
            line('  %2d  %-5s  %4d   %s', c.slotId, c.slot, c.live, testsToString(c.tests))
        else
            line('  %2d  %-5s  %4d   (nothing streamed for this slot)', c.slotId, c.slot, c.live)
        end
    end

    line('')
    line('props — index -1 means "no prop" and is reached with ClearPedProp')
    line('  anchor        live   clear   read-back')
    for _, p in ipairs(report.props) do
        line('  %d %-10s %4d   %-5s   %s',
            p.anchor,
            p.name .. (p.configured and '' or '*'),
            p.live,
            p.clearOk and 'ok' or ('->' .. tostring(p.clearedTo)),
            #p.tests > 0 and testsToString(p.tests) or '(nothing streamed)')
    end
    line('  * not in Config.propAnchors — probed anyway')

    if report.hip then
        line('')
        line('anchor 8 (p_hip): %s', report.hip.verdict)
        if report.hip.usable and not report.hip.configured then
            line('  -> set Config.includeHipAnchor = true to use it')
        end
    end

    if report.baselines then
        local b = report.baselines
        line('')
        line('baselines (live drawables minus the ones this pack claims):')
        local shown = 0
        local rows = {}
        for _, c in ipairs(report.components) do
            rows[#rows + 1] = { c.slot, ('%s:component:%d'):format(b.gender, c.slotId) }
        end
        for _, p in ipairs(report.props) do
            rows[#rows + 1] = { 'p:' .. p.name, ('%s:prop:%d'):format(b.gender, p.anchor) }
        end
        for _, row in ipairs(rows) do
            local e = b.slots and b.slots[row[2]]
            if e and e.ours and e.ours > 0 then
                shown = shown + 1
                if e.baseline then
                    line('  %-11s live %4d   ours %3d   baseline %4d%s',
                        row[1], e.live, e.ours, e.baseline,
                        #e.dlcs > 1 and '   (several dlcs — block order unverified)' or '')
                else
                    line('  %-11s live %4d   ours %3d   %s', row[1], e.live, e.ours, e.problem)
                end
            end
        end
        if shown == 0 then line('  (no slot on this ped carries items from a loaded pack)') end
    end

    line('')
    line('manifest items:')
    if #report.items.tested == 0 then
        line('  %s', report.items.verdict)
    else
        for _, r in ipairs(report.items.tested) do
            line('  %-24s %-4s %-7s local %-3d  via %-7s guess %-5s readback %-5s  textures %d/%d  -> %s%s',
                (r.label or ''):sub(1, 24),
                r.kind == 'prop' and 'prop' or 'comp',
                tostring(r.slot),
                r.localIndex,
                tostring(r.source),
                tostring(r.guess or '-'),
                tostring(r.readback or '-'),
                r.gotTextures or 0, r.wantTextures or 0,
                r.verdict,
                (r.verdict == 'plausible' and r.strength == 'weak') and ' (weak: many drawables share that texture count)' or '')
            if r.note then line('      %s', r.note) end
            line('      browse shortlist (same texture count): %s%s',
                #r.candidates > 0 and table.concat(r.candidates, ', ') or 'none',
                r.candidatesTruncated and ', ...' or '')
        end
        line('  verdict: %s', report.items.verdict)
        line('  reminder: this compares texture COUNTS, not pixels. It can rule a')
        line('  mapping out for certain; it can only make one look right.')
    end

    line('-----------------------------------------------------------------')
end
