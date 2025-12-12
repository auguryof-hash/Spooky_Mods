
-----------------------------------------------------------
-- Brutal Handwork – Input & Attack Orchestration
--
-- Intent:
-- High-level orchestration layer that intercepts player
-- input and routes attacks through BrutalAttack, SPK,
-- and animation-driven systems.
--
-- This file decides:
-- - When to punch vs shove
-- - Which hand attacks
-- - When combos can override melee delay
--
-- Key Responsibilities:
-- - Replace vanilla attack hooks
-- - Coordinate unarmed, dual-wield, and modkey behavior
-- - Bridge player input → combat execution
--
-- Explicit Non-Goals:
-- - No combat math
-- - No animation selection
-- - No networking
-----------------------------------------------------------


------------------------------------------
-- Brutal Handwork Init
------------------------------------------

BrutalHands = BrutalHands or {}

------------------------------------------
-- Brutal Handwork Configuration
------------------------------------------

BrutalHands.config = {}

local BrutalAttack = require("BrutalAttack")
BrutalAttack.setupGameEvents()

BrutalHands.TOC = nil
if getActivatedMods():contains("Amputation2") then
    BrutalHands.TOC = require('TOC_Compat')
end

------------------------------------------
-- Brutal Handwork Utilities
------------------------------------------

local function BrutalHandwork()
    print(getText("UI_Init_BrutalHandwork"))
end

BrutalHandwork()

local mouseDown = false

local attackHook = function(character, chargeDelta, primary)
    if not instanceof(character, "IsoPlayer") or character:isAttackStarted() or not character:isAuthorizeMeleeAction() then return end

    -- Here we check if the primary weapon is actually a weapon
    primary = (instanceof(primary, "HandWeapon") and primary) or nil

    -- Get the secondary weapon, do the same check
    local secondary = character:getSecondaryHandItem()
    secondary = (instanceof(secondary, "HandWeapon") and secondary) or nil

    -- check if we can actually use that arm, if applicable
    ---- set our weapons to nil if we don't have that arm
    --local hasRArm = true
    if BrutalHands.TOC then
        primary = (BrutalHands.TOC.hasHand(character, false) and primary) or nil
        secondary = (BrutalHands.TOC.hasHand(character, true) and secondary) or nil
        --hasRArm = BrutalHands.TOC.hasHand(character, false)
    end

    -- get our mod data
    local brutal = character:getModData().BrutalHandwork

    -- get our ModKey
    local mk = isFHModBindDown(character)
    
    -- if we are always ready to punch, or the modkey is down.
	if (SandboxVars.BrutalHandwork.AlwaysUnarmed or mk) then
		if not primary and not secondary then
			if BrutalAttack.IsClombatMode and BrutalAttack.IsClombatMode(character) then
				secondary = BrutalAttack.ClombatHands

				-- SPK: directional + combo selection for Clombat
				if SPK and SPK.Clombat_OnAttackPressed then
					SPK.Clombat_OnAttackPressed(character)
				end
			else
				secondary = BrutalAttack.BareHands
			end

		end
	end

    -- Check if its 2 handed
    local twoH = primary and (primary == secondary)

    -- If we made it here and there's still nothing equipped, then just push
    ---- This seems to set our push to start next update loop, otherwise we get a weird epic attack that is a push but it does like 100+ damage
    if not primary and not secondary then
        character:setInitiateAttack(false)
        character:setDoShove(true)
        brutal.wasShove = true
        brutal.leftAttack = false
        return
    end

    -- we could break our weapon, or just unequip it while the thing is going. bail if so
    if not secondary then
        brutal.leftAttack = false
    end

    -- override our modkey with left attack setting
    mk = secondary and not twoH and (brutal.leftAttack or mk)

    local did = false

    -- if no modkey or shoving, and we have a primary
    if not mk and primary then
        -- fall through
        ISReloadWeaponAction.attackHook(character, chargeDelta, primary or 1)
        did = true
    end

    if not did and secondary then
        ISTimedActionQueue.clear(character)

        if secondary:isRanged() then
            character:setDoShove(true)
            return
            -- Coming soon!
            -- if ISReloadWeaponAction.canShoot(secondary) then
            -- 	character:playSound(secondary:getSwingSound());
            -- 	local radius = secondary:getSoundRadius();
            -- 	if isClient() then -- limit sound radius in MP
            -- 		radius = radius / 1.8;
            -- 	end
            -- 	character:addWorldSoundUnlessInvisible(radius, secondary:getSoundVolume(), false);
            -- 	character:startMuzzleFlash()
            -- 	character:DoAttack(0);
            -- else
            -- 	character:DoAttack(0);
            -- 	character:setRangedWeaponEmpty(true);
            -- end
        -- nerf so players in vehicles cannot use melee attacks
        elseif not character:getVehicle() then
            ISTimedActionQueue.add(BHMeleeAttack:new(character, secondary, chargeDelta or 0))
        end
    end
    -- if we have a left and right weapon, and its not 2handed, and we have the option to automelee enabled
    if primary and secondary and not twoH and not primary:isRanged() and not secondary:isRanged() and SandboxVars.BrutalHandwork.DualWieldMelee then
        brutal.leftAttack = not (brutal.wasShove or brutal.leftAttack)
    else
        brutal.leftAttack = false
    end
end

-- Move this to OnGameStart so it is compatible with 
Events.OnGameStart.Add(function() 
    -- Remove the default attack hook
    Hook.Attack.Remove(ISReloadWeaponAction.attackHook)
    -- Add our own. Sorry other modders, but you'll have to hook into events or other things for compatibility.
    Hook.Attack.Add(attackHook)
end)


--[[ We are going to override this function so that doing a left hand attack cannot be canceled :)
local _isPlayerDoingActionThatCanBeCancelled = isPlayerDoingActionThatCanBeCancelled
function isPlayerDoingActionThatCanBeCancelled(playerObj)
    if not playerObj then return false end
    local queue = ISTimedActionQueue.queues[playerObj]
    if queue and #queue.queue > 0 and queue.queue[1].lHandAttack then 
        return false
    end
    return _isPlayerDoingActionThatCanBeCancelled(playerObj)
end]]

-- HANDLES NEW COMBO WINDOWS--

local function Clombat_CanIgnoreMeleeDelay(character)  
    if not BrutalAttack or not BrutalAttack.IsClombatMode then
        return false
    end
    if not BrutalAttack.IsClombatMode(character) then
        return false
    end
    if not SPK or not SPK.Clombat_IsComboWindowOpen then
        return false
    end
    return SPK.Clombat_IsComboWindowOpen(character)
end

---------------------------

local forceAttack = function(character)
    character:setDoShove(false)
    -- attackHook(character, chargeDelta, primary)
    attackHook(character, 1.0, character:getPrimaryHandItem())
    return true
end


local checkDoAttack = function(character)
    if not character or not character:isAiming() then
        return false
    end
	
    local canCombo = Clombat_CanIgnoreMeleeDelay(character)
    if (not canCombo) and character:getMeleeDelay() > 0.0 then
        return false
    end	
	
    local queue = ISTimedActionQueue.queues[character]
    if queue and #queue.queue > 0 and queue.queue[1].lHandAttack then 
        return false
    end
    local hands = (BrutalHands.TOC and BrutalHands.TOC.getHands(character)) or 11
    local primary = character:getPrimaryHandItem()
    primary = (instanceof(primary, "HandWeapon") and primary) or nil
    local secondary = character:getSecondaryHandItem()
    secondary = (instanceof(secondary, "HandWeapon") and secondary) or nil
    -- just do nothing here
    if not primary and not secondary and not (SandboxVars.BrutalHandwork.EnableUnarmed and (SandboxVars.BrutalHandwork.AlwaysUnarmed or isFHModBindDown(character))) then return false end
    if hands == 1 then 
        -- if we only have the right hand, then the attackHook will handle everything
        --if not instanceof(primary, "HandWeapon") then return forceAttack(character) end
        return false -- we'll still do the base attack, so just ignore
    elseif hands == 11 then
        -- if we have a primary weapon, then the attackHook will do the thing
        if primary then return false end
        -- otherwise, manually attack
        return forceAttack(character)
    elseif hands == 10 then
        -- just our left, do the attack
        return forceAttack(character)
    end
    return false
end

-- soooooooooo, i guess TOC makes it so you no longer do the attack hook
---- That's fine, we'll just do it ourselves
local onMouseClick = function(x,y)    
    checkDoAttack(getSpecificPlayer(0))
    mouseDown = true
end

-- This is a little hack so we can still hold the offhand attack
local onMouseUp = function(x,y)
    mouseDown = false
end

local playerUpdate = function(player)
    local num = player:getPlayerNum()
    if (num == 0 and mouseDown) or (JoypadState.players[num+1] and (getControllerAxisValue(player:getJoypadBind(), 5) > 0.90)) then
        checkDoAttack(player)
    end
end

local OnWeaponHitCharacter = function(player, target, weapon, damage)
    print("OnWeaponHitCharacter: " .. tostring(damage))
    print("IsCritical: " .. tostring(player:isCriticalHit()))
    print("Weapon: " .. weapon:getType())
end

local OnWeaponHitXp = function(player, handWeapon, character, damageSplit)
    print("Grant XP: " .. tostring(damageSplit))
end

Events.OnGameStart.Add(function()
    Events.OnMouseDown.Add(onMouseClick)
    Events.OnMouseUp.Add(onMouseUp)
    Events.OnPlayerUpdate.Add(playerUpdate)
    if isDebugEnabled() then
        Events.OnWeaponHitCharacter.Add(OnWeaponHitCharacter)
        Events.OnWeaponHitXp.Add(OnWeaponHitXp)
    end
    -- if SandboxVars.BrutalHandwork.BaseAttackOverride then
    --     --Hook.WeaponHitCharacter.Add(WeaponHitCharacter)
    --     Hook.WeaponHitCharacter.Add(BrutalAttack.OnWeaponHitCharacter)
    -- end
end)