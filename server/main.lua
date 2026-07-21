--- Server side. Deliberately tiny.
---
--- Two jobs, nothing else:
---   1. own the open command and its permission check
---   2. own the routing bucket, because SetPlayerRoutingBucket is server-only
---
--- Everything the viewer actually does (discovery, index mapping, scene, apply)
--- is client-side and needs no server round trip.
---
--- Event contract with client/main.lua:
---   S -> C  atelier:client:notify     (string message)
---   S -> C  atelier:client:preflight  (number currentBucket)  "you may open, here
---                                      is your bucket so you can refuse yourself"
---   S -> C  atelier:client:open       (number|nil bucketId)   scene may start
---   C -> S  atelier:server:acquire                            preflight passed
---   C -> S  atelier:server:release                            closed / aborted

local BUCKET_FROM = (Config.scene.bucketRange and Config.scene.bucketRange.from) or 7100
local BUCKET_TO = (Config.scene.bucketRange and Config.scene.bucketRange.to) or 7199

--- bucketId -> src, and the inverse. Two tables so both lookups stay O(1);
--- they are always written together.
local bucketOwner = {}
local playerBucket = {}

local function acquireBucket(src)
    -- Re-entrant: a player who somehow opens twice keeps the bucket they have
    -- instead of burning a second one that nothing would ever release.
    if playerBucket[src] then return playerBucket[src] end

    for id = BUCKET_FROM, BUCKET_TO do
        if not bucketOwner[id] then
            bucketOwner[id] = src
            playerBucket[src] = id
            SetPlayerRoutingBucket(src, id)
            return id
        end
    end

    return nil
end

--- Safe to call for a player who holds nothing, and safe to call for a player
--- who has already dropped — which is exactly why the pool cannot leak: every
--- exit path (close, abort, drop, resource stop) funnels through here.
local function releaseBucket(src, playerStillOnline)
    local id = playerBucket[src]
    if not id then return end

    playerBucket[src] = nil
    bucketOwner[id] = nil

    if playerStillOnline then
        -- Putting the player back in bucket 0 is the half that actually matters
        -- to them; freeing the id only matters to the pool.
        SetPlayerRoutingBucket(src, 0)
    end
end

RegisterCommand(Config.command, function(src)
    src = tonumber(src) or 0

    if src == 0 then
        print('[atelier] /' .. Config.command .. ' is a player command; there is nothing to show on the console.')
        return
    end

    if not Framework.hasPermission(src) then
        TriggerClientEvent('atelier:client:notify', src,
            ('You are not allowed to open atelier (missing "%s").'):format(Config.acePermission))
        return
    end

    -- The client owns the refusal rules (vehicle / dead / water / already
    -- bucketed) because three of the four are client-side natives. The one it
    -- cannot read for itself is its own routing bucket, so it is handed down
    -- here. No bucket is allocated yet — allocating before the client has said
    -- "I can open" is how buckets end up leaked to players who never opened.
    TriggerClientEvent('atelier:client:preflight', src, GetPlayerRoutingBucket(src))
end, false)

RegisterNetEvent('atelier:server:acquire', function()
    local src = source

    -- Re-checked, never trusted: the client asking to open is a net event and
    -- anyone can fire it, so the permission gate lives here as well as in the
    -- command.
    if not Framework.hasPermission(src) then
        TriggerClientEvent('atelier:client:notify', src,
            ('You are not allowed to open atelier (missing "%s").'):format(Config.acePermission))
        return
    end

    if not Config.scene.useBucket then
        TriggerClientEvent('atelier:client:open', src, nil)
        return
    end

    local id = acquireBucket(src)
    if not id then
        TriggerClientEvent('atelier:client:notify', src,
            ('No free routing bucket (%d-%d are all in use). Try again in a moment.'):format(BUCKET_FROM, BUCKET_TO))
        return
    end

    TriggerClientEvent('atelier:client:open', src, id)
end)

RegisterNetEvent('atelier:server:release', function()
    releaseBucket(source, true)
end)

AddEventHandler('playerDropped', function()
    -- The player is already gone, so only free the id; SetPlayerRoutingBucket on
    -- a dropped source would throw.
    releaseBucket(source, false)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Without this, restarting the resource strands everyone who had the viewer
    -- open in a private bucket with no way back.
    for src in pairs(playerBucket) do
        releaseBucket(src, true)
    end
end)
