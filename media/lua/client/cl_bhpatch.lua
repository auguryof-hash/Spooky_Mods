-----------------------------------------------------------
-- BHPatch (Client) – Combat & Stance Replication Bridge
--
-- Intent:
-- Client-side glue between BrutalAttack, FancyHandwork,
-- and multiplayer replication.
--
-- This file owns:
-- - Client-authoritative stance diffing
-- - Minimal stance replication to server
-- - Client-side melee hit forwarding
--
-- Key Responsibilities:
-- - Detect stance changes (canted, clombat, hand masks)
-- - Send only changed variables to the server
-- - Override vanilla melee behavior safely
--
-- Design Principle:
-- Client decides *how it looks and feels*.
-- Server only validates and rebroadcasts state.
--
-- Explicit Non-Goals:
-- - No animation selection
-- - No UI rendering
-- - No direct server-side logic

-- Networking Philosophy:
-- - Client is authoritative for stance and input intent
-- - Server validates and rebroadcasts minimal diffs
-- - Zombie damage is relayed due to engine limitations
-- - No attempt is made to perfectly resimulate melee
--   hit reactions across clients

-----------------------------------------------------------



local BrutalAttack = require("BrutalAttack");

BHPatch = BHPatch or {};

---------------------------------------------------------
-- SPKAnimSync – Client-side stance replication system
---------------------------------------------------------
SPKAnimSync = SPKAnimSync or {}
SPKAnimSync.lastStance = SPKAnimSync.lastStance or {}

local function SPK_getStanceVars(player)
	return {
		RightHandMask = player:getVariableString("RightHandMask"),
		LeftHandMask  = player:getVariableString("LeftHandMask"),
		isCanted      = player:getVariableBoolean("isCanted"),
		isClombat     = player:getVariableBoolean("isClombat"),
	}
end

function SPKAnimSync.syncStance(player)
    if not player or not player.isLocalPlayer or not player:isLocalPlayer() then
        return
    end

    local id = player:getOnlineID()
    if not id then return end

    local current = SPK_getStanceVars(player)
    if type(current) ~= "table" then return end

    local last = SPKAnimSync.lastStance[id] or {}
    local diff = nil

    for k, v in pairs(current) do
        if last[k] ~= v then
            if not diff then diff = {} end
            diff[k] = v
        end
    end

    if not diff then
        return
    end

    SPKAnimSync.lastStance[id] = current

    if sendClientCommand then
        sendClientCommand("SPKAnim", "Stance", { id = id, vars = diff })
    end
end


-- sadly necessary to prevent zomboid from doing a vanilla hit on a zombie whenever ConnectSwing is called and a zombie slips out of our punch range
local function nearZombies(centerSquare, level)
	local objs = centerSquare:getMovingObjects();
	for i=0, objs:size()-1 do
		if instanceof(objs:get(i), "IsoZombie") then
			return true;
		end
	end
	
	if level == 0 then return false end;

	local startDir = 0;
	for i=0, 7 do
		local dir = (startDir + i) % 8;
		local square = centerSquare:getAdjacentSquare(IsoDirections.fromIndex(dir));
		if nearZombies(square, level - 1) then
			return true;
		end
	end
	
	return false;
end

---
-- START - copied directly from BrutalAttack.lua and modified for networking
---

local addToHitList = function(list, obj, player, weapon, extraRange, vec)
	local zed = instanceof(obj, "IsoZombie")
	if zed and obj:isZombie() and obj:isAlive() then
		obj:getPosition(vec)
		if player:IsAttackRange(weapon, obj, vec, extraRange) then
			-- Add our zed, cache the distance to the player
			list[#list+1] = { obj = obj, dist = obj:DistTo(player) }
			if isDebugEnabled() then
				print("Found: " .. tostring(#list) .. " | Distance: " .. tostring(list[#list].dist))
			end
		end
	end
end

local directions = {
	[0] = IsoDirections.N,
	[1] = IsoDirections.NW,
	[2] = IsoDirections.W,
	[3] = IsoDirections.SW,
	[4] = IsoDirections.S,
	[5] = IsoDirections.SE,
	[6] = IsoDirections.E,
	[7] = IsoDirections.NE,
}

local getAttackSquares = function(player)
	local psquare = player:getSquare()
	if not psquare then return nil end
	local squares = {psquare}
	local currentDir = player:getDir():index()
	local leftIndex = currentDir+1
	if leftIndex > 7 then leftIndex=0 end
	--local middleIndex = currentDir
	local rightIndex = currentDir-1
	if rightIndex < 0 then rightIndex=7 end
	-- this should collect any additional squares, only if we nothing is in the way
	local sq = psquare:getAdjacentSquare(directions[leftIndex])
	if sq and not sq:isBlockedTo(psquare) then
		squares[#squares+1] = sq
	end
	sq = psquare:getAdjacentSquare(directions[currentDir])
	if sq and not sq:isBlockedTo(psquare) then
		squares[#squares+1] = sq
	end
	sq = psquare:getAdjacentSquare(directions[rightIndex])
	if sq and not sq:isBlockedTo(psquare) then
		squares[#squares+1] = sq
	end
	return squares
end

BrutalAttack.FindAndAttackTargets = function(player, weapon, extraRange)
	-- we want a player, and a hand weapon
	if not (player and instanceof(weapon, "HandWeapon")) then return end

	-- honor the max hit
	local maxHit = (SandboxVars.MultiHitZombies and weapon:getMaxHitCount()) or 1

	-- this seems to be the default sooooooooo
	if extraRange == nil then extraRange = true end
	extraRange = true

	-- We do everything so we can attack non-zeds too
	--local objs = getCell():getObjectList()
	local found = {}
	local psquare = player:getSquare()
	if not psquare then return end -- can't attack
	local attackSquares = getAttackSquares(player)
	if not attackSquares then return end -- no squares?
	local vec = Vector3.new() -- reuse this
	for i=1, #attackSquares do
		local objs = attackSquares[i]:getMovingObjects()
		if objs then
			for j=0, objs:size()-1 do
				addToHitList(found, objs:get(j), player, weapon, extraRange, vec)
			end
		end
	end

	if #found > 0 then
		-- sort our found list by the closest zed
		table.sort(found, function(a,b)
			if a.obj:isZombie() then return true end
			if b.obj:isZombie() then return false end
			return a.dist < b.dist
		end)
		local count = 1 
		local sound = false
		for _,v in ipairs(found) do
			-- hit em!
			local damage, dmgDelta = BrutalAttack.calcDamage(player, weapon, v.obj, count)
			if isDebugEnabled() then
				print("Damage: " .. tostring(damage) .. " | Delta: " .. tostring(dmgDelta))
			end
			
			--v.zed:splatBloodFloor()
			if not sound then 
				-- if we haven't played the sound yet, do so
				sound = true
				local zSound = weapon:getZombieHitSound()
				if zSound then v.obj:playSound(zSound) end
			end
			
			local dmg = BHPatch.Hit(v.obj, weapon, player, damage, false, dmgDelta)
			if (isClient()) then
				sendClientCommand("BHPatch", "BHPatch_DamageZombie", {v.obj:getOnlineID(), player:getOnlineID(), dmg})
			end
			
			-- stop at maxhit
			if count >= maxHit then break end
			count = count + 1
		end

		luautils.weaponLowerCondition(weapon, player)
	else
		local primary = player:getPrimaryHandItem()
		if not primary or not primary:isRanged() then
		-- Swing and collide with anything not a zed
			if not nearZombies(player:getSquare(), 2) then
				SwipeStatePlayer.instance():ConnectSwing(player, weapon)
			end
		end
	end
end

---
-- END - copied directly from BrutalAttack.lua and modified for networking
---

local function getZombieByOnlineID(onlineID)
    local zombies = getCell():getZombieList();
	
    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i);
        if (zombie:getOnlineID() == onlineID) then
            return zombie;
        end
    end
	
	return nil;
end

-- gross networking code

function BHPatch.Hit(victim, weapon, attacker, damage, idfklmao, dmgDelta)
	local outdmg = victim:Hit(weapon, attacker, damage, idfklmao, dmgDelta);
	triggerEvent("OnWeaponHitXp", attacker, weapon, victim, outdmg);
	
	if (weapon:getCategories():contains("Unarmed")) then
		attacker:getEmitter():playSound("PunchImpact");
	end
	
	return outdmg;
end

function BHPatch.DamageZombieNet(victimID, attackerID, damage)
	local victim = getZombieByOnlineID(victimID);
	local attacker = getPlayerByOnlineID(attackerID);
	if (not victim or not attacker) then return end
	
	victim:setHealth(victim:getHealth() - damage);
    victim:setHitReaction("Shot");
	if (victim:getHealth() < 0.1) then
		victim:setHealth(0);
        victim:Kill(attacker);
        attacker:setZombieKills(attacker:getZombieKills() + 1);
    end
end

local function onServerCommand(module, command, arguments)
	if (module == "BHPatch") then
		if (command == "BHPatch_DamageZombie") then
			BHPatch.DamageZombieNet(arguments[1], arguments[2], arguments[3]);
		end
	end
end



Events.OnServerCommand.Add(function(module, command, args)
    if module == "SPKAnim" and command == "Stance" then
        local target = getPlayerByOnlineID(args.id)
        if target and args.vars then
            for k, v in pairs(args.vars) do
                target:setVariable(k, v)
            end
        end
    end
end)


Events.OnServerCommand.Add(onServerCommand);
