-----------------------------------------------------------

-- Fancy Handwork – Hand Poses, Masks & Canted Aiming
--
-- Intent:
-- Controls visual hand poses, canted aiming masks,
-- and stance variables for first-person fidelity.
--
-- This file is the *visual authority* for:
-- - Hand masks
-- - Canted aim state
-- - Pose compatibility
--
-- Networking Model:
-- - Local player sets stance
-- - SPKAnimSync replicates deltas
--
-- Explicit Non-Goals:
-- - No combat logic
-- - No damage calculation
-- - No movement math

-- Canted Stance Policy:
-- - FancyHandwork is the sole authority for setting
--   isCanted on the local player
-- - Canted affects:
--     * visual hand masks
--     * SPK movement speed buffs
--     * Advanced Trajectory visuals
-- - Canted does NOT:
--     * modify accuracy
--     * modify penetration
--     * modify recoil math
-----------------------------------------------------------


------------------------------------------
-- Fancy Handwork Init
------------------------------------------
FancyHands = FancyHands or {}

------------------------------------------
-- Fancy Handwork Configuration
------------------------------------------

FancyHands.config = {
    applyRotationL = true
}

FancyHands.nomask = {
    ["Base.Torch"] = true,
    ["Base.HandTorch"] = true,
    ["Base.UmbrellaBlack"] = true,
    ["Base.UmbrellaWhite"] = true,
    ["Base.UmbrellaBlue"] = true
}

FancyHands.special = {
    ["Base.Generator"] = "holdinggenerator",
    ["Base.CorpseMale"] = "holdingbody",
    ["Base.CorpseFemale"] = "holdingbody"
}

-- Use the animations from this mod instead!
if getActivatedMods():contains('Skizots Visible Boxes and Garbage2') then
    FancyHands.special = {}
end

-- We will begin to store compatibility objects here
FancyHands.compat = {}
if getActivatedMods():contains('BrutalHandwork') then
    FancyHands.compat.brutal = true
end

function isFHModKeyDown()
    return isKeyDown(getCore():getKey('FHModifier'))
end

function isFHModBindDown(player)
    return isFHModKeyDown() or (player and player:isLBPressed())
end

----------------------------------------------------
-- Canted helper: centralize how we set canted state
----------------------------------------------------
local function FH_setCanted(player, enabled)
    enabled = not not enabled
    if player and player.setVariable then
        player:setVariable("isCanted", enabled)
    end
    if SPK and SPK.setCanted then
        SPK.setCanted(enabled)
    end
end

local FHswapItems = function(character)
    local primary = character:getPrimaryHandItem()
    local secondary = character:getSecondaryHandItem()
    if (primary or secondary) and (primary ~= secondary) then
        ISTimedActionQueue.add(FHSwapHandsAction:new(character, primary, secondary, 10))
    end
end

local FHswapItemsMod = function(character)
    if isFHModKeyDown() and (not SPK or not SPK.isCanted or not SPK.isCanted()) then
        FHswapItems(character)
    end
end

local FHcreateBindings = function()
    local FHbindings = {
        { name = '[FancyHandwork]' },
        { value = 'FHModifier', key = Keyboard.KEY_LCONTROL },
        { value = 'FHSwapKey', action = FHswapItems, key = 0 },
        { value = 'FHSwapKeyMod', action = FHswapItemsMod, key = Keyboard.KEY_E, swap = true },
    }

    for _, bind in ipairs(FHbindings) do
        if bind.name then
            table.insert(keyBinding, { value = bind.name, key = nil })
        else
            if bind.key then
                table.insert(keyBinding, { value = bind.value, key = bind.key })
            end
        end
    end

    local FHhandleKeybinds = function(key)
        local player = getSpecificPlayer(0)
        local action
        for _,bind in ipairs(FHbindings) do
            if key == getCore():getKey(bind.value) then
                if bind.swap then
                    if isFHModKeyDown() then
                        action = bind.action
                        break
                    end
                else
                    action = bind.action
                    break
                end
            end
        end
    
        if not action or isGamePaused() or not player or player:isDead() then
            return 
        end
        action(player)
    end

    FancyHands.addKeyBind = function(keybind)
        table.insert(FHbindings, keybind)
    end

    Events.OnGameStart.Add(function()
        Events.OnKeyPressed.Add(FHhandleKeybinds)
    end)
end

local function calcRecentMove(player)
    player:getModData().FancyHands = player:getModData().FancyHands or {
        recentMove = false,
        recentDelta = 0
    } 
    if player:isPlayerMoving() then
        player:getModData().FancyHands.recentMove = true
        player:getModData().FancyHands.recentDelta = 0
    else
        if player:getModData().FancyHands.recentMove then
            player:getModData().FancyHands.recentDelta = player:getModData().FancyHands.recentDelta + 1
            local sec = (SandboxVars.FancyHandwork and SandboxVars.FancyHandwork.TurnDelaySec) or 1
            if player:getModData().FancyHands.recentDelta >= sec * getPerformance():getFramerate() then
                player:getModData().FancyHands.recentMove = false
            end
        end
    end
end

----------------------------------------------------
-- Core pass (with simple canted masks on modifier)
----------------------------------------------------
local function fancy(player)
    if not player or player:isDead() or player:isAsleep() then return end
    local primary   = player:getPrimaryHandItem()
    local secondary = player:getSecondaryHandItem()
    local queue = ISTimedActionQueue.queues[player]
    local isCrouching = player:getVariableBoolean("IsCrouchAim")  -- true crawl compat (negates canted on crouch)
    
    if queue and #queue.queue > 0 and not queue.queue[1].FHIgnore then
        player:setVariable("FHDoingAction", true)
    else
        player:setVariable("FHDoingAction", false)
    end

    ------------------------------------------------
    -- Two-hands (primary == secondary)
    ------------------------------------------------
    if primary == secondary then
        if primary then
            -- specific props
            local spec = FancyHands.special[primary:getFullType()]
            if spec then
                player:setVariable("LeftHandMask", spec)
                player:clearVariable("RightHandMask")
                FH_setCanted(player, false)
                --updateAllowHandgunFire(player)                
				if isClient() then SPKAnimSync.syncStance(player) end
				return
            end

            -- CANTED (modifier held): ranged only
            if isFHModBindDown(player)
                and instanceof(primary, "HandWeapon")
                and player:isAiming()
                and primary:isRanged()
                and not isCrouching
            then
                player:setVariable("RightHandMask", "cantedrifleaim")
                FH_setCanted(player, true)
                --updateAllowHandgunFire(player)                
				if isClient() then SPKAnimSync.syncStance(player) end
				return
            end
            
            -- respect replacements
            if primary:getItemReplacementPrimaryHand() then
				FH_setCanted(player, false)			
				if isClient() then SPKAnimSync.syncStance(player) end
				return
            end         
        end

        -- Brutal Handwork unarmed pose (unchanged)
        if FancyHands.compat.brutal then
            local equipped = instanceof(primary, "HandWeapon") and primary:getCategories():contains("Unarmed")
            if (not primary and player:isAiming()
                and (SandboxVars.BrutalHandwork.EnableUnarmed
                    and (SandboxVars.BrutalHandwork.AlwaysUnarmed or isFHModBindDown(player))))
                or equipped
            then
                player:clearVariable("LeftHandMask")
                player:setVariable("RightHandMask", "bhunarmedaim")
                FH_setCanted(player, true)
                --updateAllowHandgunFire(player)        
				if isClient() then SPKAnimSync.syncStance(player) end
				return
            end
        end

        player:clearVariable("LeftHandMask")         
        player:clearVariable("RightHandMask")
        FH_setCanted(player, false)
        --updateAllowHandgunFire(player)
		if isClient() then SPKAnimSync.syncStance(player) end
		return
    end

    ------------------------------------------------
    -- Normal path (different items in each hand)
    ------------------------------------------------
    if primary then
        if not primary:getItemReplacementPrimaryHand() then
            if instanceof(primary, "HandWeapon") then
                if isFHModBindDown(player)
                    and player:isAiming()
                    and primary:isRanged()
                    and not isCrouching
                then
                    player:setVariable("RightHandMask", "cantedpistolaim")
                    FH_setCanted(player, true)
                    --updateAllowHandgunFire(player )   
                else
                    player:setVariable("RightHandMask", (primary:isRanged() and "holdinggunright") or "holdingitemright")
                    player:setVariable("FHExp",
                        player:getPerkLevel(Perks.Aiming) >= ((SandboxVars.FancyHandwork and SandboxVars.FancyHandwork.ExperiencedAiming) or 3)
                    )
                    FH_setCanted(player, false)
                    --updateAllowHandgunFire(player)
                end
            else
                player:clearVariable("RightHandMask")
                FH_setCanted(player, false)
                --updateAllowHandgunFire(player)                
            end
        end
    else    
        player:clearVariable("RightHandMask")
        FH_setCanted(player, false)
        --updateAllowHandgunFire(player)
    end

    -- Left hand behavior unchanged
    if secondary then
        if not secondary:getItemReplacementSecondHand() then
            if instanceof(secondary, "HandWeapon") then
                player:setVariable("LeftHandMask", (secondary:isRanged() and "holdinghgunleft") or "holdingitemleft")
            else
                player:clearVariable("LeftHandMask")
            end 
        end
    else
        player:clearVariable("LeftHandMask")
    end
	    -- === MP Stance Replication ===
    if isClient() then SPKAnimSync.syncStance(player) end
end



-- DEFAULT SYNC CURRENTLY DISABLED
local curPlayer = 0
local function fancyMP(player)
    if not player or player:isDead() or player:isAsleep() then return end
    fancy(player)
    -- one player per tick
    local players = getOnlinePlayers()
    if curPlayer > (players:size()-1) then curPlayer = 0 end
    local mPlayer = players:get(curPlayer)
    if mPlayer ~= player then
        fancy(mPlayer)
    end
    curPlayer = curPlayer + 1
end

local function FancyHandwork()
    print(getText("UI_Init_FancyHandwork"))

    -- Still never run on the server, even though we're in /shared.
    if isServer() then return end

    FHcreateBindings()

    Events.OnGameStart.Add(function()
        Events.OnPlayerUpdate.Add(function(player)
            -- Sanity guard
            if not player or player:isDead() or player:isAsleep() then
                return
            end

            -- Critical change: only evaluate stance + masks for the local player.
            if not player:isLocalPlayer() then
                return
            end

            fancy(player)
            calcRecentMove(player)
        end)
    end)
end

FancyHandwork()

