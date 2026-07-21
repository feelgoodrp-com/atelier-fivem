--- Runtime framework detection.
---
--- Loaded on BOTH client and server (see fxmanifest.lua), so everything in here
--- must be safe in both environments: no client-only natives at load time, no
--- os.* on the client, no exports touched before a framework is known to exist.
---
--- HONEST SCOPE: nothing about this resource actually needs a framework.
--- Discovery, the index map, the scene and the apply path are pure natives and
--- LoadResourceFile. A framework buys us exactly two things — a nicer
--- notification toast, and (server side) the permission check — and if none is
--- present both fall back to something that still works. That is the whole
--- reason the manifest declares no dependency: the resource must start on a
--- vanilla FXServer just as happily as on qbox.
Framework = {}

--- Order matters. qbx_core does `provide 'qb-core'`, which makes
--- GetResourceState('qb-core') report 'started' on a qbox server even though
--- qb-core itself is not installed. Checking qbx_core first is what keeps a
--- qbox server from being mis-detected as qb.
local CANDIDATES = {
    { id = 'qbx', resource = 'qbx_core' },
    { id = 'qb', resource = 'qb-core' },
    { id = 'esx', resource = 'es_extended' },
}

local isServer = IsDuplicityVersion() == true

local cached = nil
local lastMiss = -1
local RECHECK_MS = 5000

local function now()
    -- GetGameTimer is the one clock available in both environments (os.* does
    -- not exist on the client). Guarded anyway: if it were ever missing, the
    -- fallback makes detection re-check every call instead of throwing.
    local ok, t = pcall(GetGameTimer)
    if ok and type(t) == 'number' then return t end
    return -1
end

local function resolveNow()
    for i = 1, #CANDIDATES do
        local candidate = CANDIDATES[i]
        if GetResourceState(candidate.resource) == 'started' then
            return candidate.id
        end
    end
    return 'none'
end

--- Returns 'qbx' | 'qb' | 'esx' | 'none'.
--- Lazy: nothing is resolved at load time, because resource start order is not
--- guaranteed and a framework that has not started yet would be cached as
--- absent forever. A positive result is cached permanently (a framework does
--- not change mid-session); a negative result is re-checked at most every
--- RECHECK_MS so a late-starting framework is still picked up.
function Framework.detect()
    if cached then return cached end

    local t = now()
    if lastMiss >= 0 and (t - lastMiss) < RECHECK_MS then
        return 'none'
    end

    local found = resolveNow()
    if found == 'none' then
        lastMiss = t
        return 'none'
    end

    cached = found
    return cached
end

local function chatFallback(msg)
    if isServer then
        print(('[atelier] %s'):format(msg))
        return
    end
    -- 'chat' may not be running either (some servers ship their own). This is a
    -- fire-and-forget event, so a missing listener is silently a no-op — hence
    -- the print as the true last resort.
    TriggerEvent('chat:addMessage', {
        color = { 200, 200, 200 },
        multiline = true,
        args = { '[atelier]', msg },
    })
    print(('[atelier] %s'):format(msg))
end

--- Show a short message to the local player.
---
--- Client only in the meaningful sense: on the server there is no player
--- context, so it prints to the server console. To reach a specific player from
--- the server, send 'atelier:client:notify' (server/main.lua does exactly that)
--- and let the client call this.
---
--- UNVERIFIED: the exact notification entry point of each framework was not
--- tested against a running server. Only the qbx export can actually fail loudly
--- (pcall catches a missing export); the qb/esx paths are plain TriggerEvent,
--- which succeeds even when nothing is listening — so if a build renamed its
--- notify event the message is silently swallowed. If that happens, fix the one
--- branch below; nothing else depends on it.
function Framework.notify(msg)
    if type(msg) ~= 'string' or msg == '' then return end

    if isServer then
        print(('[atelier] %s'):format(msg))
        return
    end

    local fw = Framework.detect()

    if fw == 'qbx' then
        local ok = pcall(function()
            exports.qbx_core:Notify(msg, 'inform')
        end)
        if ok then return end
    elseif fw == 'qb' then
        TriggerEvent('QBCore:Notify', msg, 'primary', 5000)
        return
    elseif fw == 'esx' then
        TriggerEvent('esx:showNotification', msg)
        return
    end

    chatFallback(msg)
end

--- Server-side permission check for the open command.
---
--- Deliberately implements Config.openMode and nothing more. No framework admin
--- table is consulted: ACE is the one mechanism every FXServer has, it is what
--- the README documents, and adding "…or an admin according to $framework"
--- would make the effective permission set depend on which framework happens to
--- be installed — which is the opposite of what this resource is for.
---
--- On the client this always returns false: IsPlayerAceAllowed is a server
--- native, and a client-side "yes" would be worthless anyway since the server
--- re-checks before it hands out anything.
function Framework.hasPermission(src)
    if not isServer then return false end

    local mode = Config and Config.openMode or 'ace'
    if mode == 'everyone' then return true end

    local ace = (Config and Config.acePermission) or 'atelier.viewer'
    return IsPlayerAceAllowed(src, ace)
end
