-----------------------------------------------------------
-- Advanced Trajectory – Core Ballistics & Aim State
--
-- Intent:
-- This file is the authoritative logic core for Advanced
-- Trajectory / Spooky Ballistics. It owns all non-visual,
-- non-animation calculations related to aiming, recoil,
-- dispersion, penetration, and hit resolution.
--
-- This module answers the question:
--   "Given the player's state, what should the shot DO?"
--
-- Key Responsibilities:
-- - Maintain aim scalar (aimnum) and accuracy state
-- - Accumulate and decay recoil over time
-- - Apply panic, stress, pain, and movement penalties
-- - Perform raycast-based hit resolution
-- - Handle wall / object penetration logic
-- - Enforce max hit counts and penetration limits
--
-- Wall Penetration (Important):
-- - Penetration is explicitly bounded and deterministic
-- - Each object hit consumes penetration budget
-- - Shotguns are clamped to maxHit = 1 to prevent
--   multi-object overpenetration exploits
-- - Duplicate penetration checks were removed to prevent
--   unintended extra passes
-- - Doors, walls, and solid objects are treated as
--   penetration terminators unless explicitly allowed
--
-- Architectural Decisions (from iteration):
-- - No mid-world mutation of animation speed scalars
--   (engine overrides vanilla vars every tick)
-- - Penetration logic lives HERE, not in weapon scripts
-- - Client predicts visuals, but hit logic remains
--   authoritative and reproducible
--
-- Relationship to Other Systems:
-- - FancyHandwork / SPK determine stance (canted, unarmed)
-- - This file READS stance but never sets it
-- - AimTex reads output state and renders visuals
-- - BrutalAttack handles melee; never mixed here
--
-- Explicit Non-Goals:
-- - No rendering or UI
-- - No animation selection
-- - No movement or speed manipulation
-- - No networking or replication
--
-- Design Philosophy:
-- Stable math > clever tricks.
-- Predictable penetration > realism-at-all-costs.
-----------------------------------------------------------





local Advanced_trajectory = {
    table               = {},
    boomtable           = {},
    aimcursor           = nil,
    aimcursorsq         = nil,
    panel               = {
        instance = nil
    },

    -- bloom
    aimnum              = 100,
    aimnumBeforeShot    = 0,
    maxaimnum           = 100,
    minaimnum           = 0,

    aimlevels           = 0,
    
    targetDistance      = 0,
    isOverDistanceLimit = false,
    isOverCarAimLimit   = false,

    forwardCarVec       = 0,
    upperCarAimBound    = 0, 
    lowerCarAimBound    = 0, 
    
    inhaleCounter       = 0,
    exhaleCounter       = 0,
    maxFocusCounter     = 100,
    aimrate             = 0,
    missMin             = 0,
    
    crouchCounter       = 100,
    isCrouch            = false,
    isCrawl             = false,
    
    hasFlameWeapon      = false,
    
    -- for aimtex
    alpha           = 0,
    stressEffect    = 0,
    painEffect      = 0,
    panicEffect     = 0,
    
    aimtexwtable    = {},
    aimtexdistance  = 0, -- weapons containing crosshairs
    
    -- for weapon mods to add compatability
    FullWeaponTypes = {},

    damagedisplayer = {},

    hitReactions = {
        head = {
            "ShotHeadFwd", 
            "ShotHeadBwd", 
        },
        body = {
            "ShotBelly", 
            "ShotBellyStep", 
            "ShotChestL",
            "ShotChestR", 
            "ShotShoulderL", 
            "ShotShoulderR",
            "ShotChestStepL", 
            "ShotChestStepR", 
            "ShotLegL", 
            "ShotLegR",
            "ShotShoulderStepL", 
            "ShotShoulderStepR"
        }
    },
}

local gameTime
Events.OnGameTimeLoaded.Add(function()
    gameTime = GameTime.getInstance()
end)

-- lightweight debug printer (piggybacks the sandbox flag used in player bullet pos checks)
local function AT_dbg(...)
    local so = getSandboxOptions and getSandboxOptions()
    local enabled = false
    if so and so.getOptionByName then
        local opt = so:getOptionByName("Advanced_trajectory.enablePlayerBulletPosCheck")
        if opt and opt.getValue and opt:getValue() then
            enabled = true -- INTENTIONAL BUG TO TEST SYNTAX? No, fix to 'true'
        end
    end
    if enabled then
        print("[AT]", ...)
    end
end


-------------------------
--MATH FLOOR FUNC SECT---
-------------------------
local function mathfloor(number)
    return math.floor(number)
end

local function advMathFloor(number)
    return number - mathfloor(number)
end

------------------------------
--MAKE TABLE COPY FUNC SECT---``
------------------------------
local function copyTable(table2)
    local table1={}

    for i,k in pairs(table2) do
        table1[i] = table2[i]
    end
    -- print(table1)
    return table1
end

-------------
---TEXT UI---
-------------
local aimLevelText = TextDrawObject.new()
local aimLevelTextTrans = getSandboxOptions():getOptionByName("Advanced_trajectory.aimLevelTextTrans"):getValue()  
aimLevelText:setDefaultColors(1, 1, 1, aimLevelTextTrans)
aimLevelText:setOutlineColors(0, 0, 0, 1)
aimLevelText:setHorizontalAlign("right")

----------------------------------------------------------------
--REMOVE ITEM (ex. bullet projectile when collide) FUNC SECT---
----------------------------------------------------------------
function Advanced_trajectory.itemremove(worlditem)
    if worlditem == nil then return end

    -- print("Type: ", worlditem:getType())

    -- worlditem:getWorldItem():getSquare():transmitRemoveItemFromSquare(worlditem:getWorldItem())
    worlditem:getWorldItem():removeFromSquare()
end

function Advanced_trajectory.getTargetDistanceFromPlayer(player, target)
    local playerX = player:getX()
    local playerY = player:getY()

    local targetX = target:getX()
    local targetY = target:getY()

    local distance = math.sqrt((playerX - targetX)^2 + (playerY - targetY)^2)

    return distance
end

function Advanced_trajectory.isOnTopOfTarget(player, target)
    --print("KnockedDown: ", target:isKnockedDown(), " || Prone: ", target:isProne())
    if (not (target:isKnockedDown() or target:isProne())) then return false
end
    
    local distance = Advanced_trajectory.getTargetDistanceFromPlayer(player, target)
    --print("distance: ", distance)

    -- isSteppedOn, isZomProne
    --print('Aim Floor: ', player:isAimAtFloor())
    if distance < 1 and player:isAimAtFloor() then 
        return true, true
    else
        return false, true
    end
end

-- Function to calculate the dot product of two vectors
local function findVectorDotProduct(x1, y1, x2, y2)
    return x1 * x2 + y1 * y2
end

local function angleToVector(angle)
    -- Convert angle to radians (Lua's math library uses radians)
    local radians = math.rad(angle)

    -- Calculate the x and y components of the vector
    local x = math.cos(radians)
    local y = math.sin(radians)

    return x, y
end

function Advanced_trajectory.isObjectFacingZombie(objX, objY, aimDir, targetX, targetY, threshold)
    local targetXVector = targetX - objX
    local targetYVector = targetY - objY

    local aimDirX, aimDirY = angleToVector(aimDir)

    local dotProduct = findVectorDotProduct(aimDirX, aimDirY, targetXVector, targetYVector)

    --print("DotProd: ", dotProduct, " > Thresh: ", threshold)

    -- Check if the zombie is behind the character
    if dotProduct > threshold then
        -- Zombie is in front of the character, allow shooting
        return true
    else
        -- Zombie is behind the character, ignore or handle differently
        return false
	end
end

function Advanced_trajectory.determineArrowSpawn(square, isBroken)
    local player = getPlayer()
    local weaitem = player:getPrimaryHandItem()

    if weaitem == nil then return end

    local proj  = ""
    local isBow = false

    -- check if player has a bow
    if string.contains(weaitem:getAmmoType() or "","Arrow_Fiberglass") then
        proj  = InventoryItemFactory.CreateItem("Arrow_Fiberglass")
        isBow = true
    end

    if string.contains(weaitem:getAmmoType() or "","Bolt_Bear") then
        proj  = InventoryItemFactory.CreateItem("Bolt_Bear")
        isBow = true
    end


    if isBow then
        --print("Spawned broken arrow.")
        if (isBroken) then
            proj  = InventoryItemFactory.CreateItem(proj:getModData().Break)
        end
        
        square:AddWorldInventoryItem(proj, 0, 0, 0.0)
    end
end

function Advanced_trajectory.allowPVP(player, target)
    -- allow PVP if (ShowSafety ON)
    -- 1) target is not the client player (you can't shoot you)
    -- 2) target or player does not have PVP safety enabled
    -- 3) target is not in the same faction as player
    -- 4) faction PVP is enabled for either target or player
    -- 5) sandbox option IgnorePVPSafety is on

    -- allow PVP if (ShowSafety OFF)
    -- 1) target is not the client player (you can't shoot you)
    -- 3) target is not in the same faction as player
    -- 4) faction PVP is enabled for either target or player
    -- 5) sandbox option IgnorePVPSafety is on

    -- if sandbox option PVP is not on, do not allow PVP
    if not getServerOptions():getOptionByName("PVP"):getValue() then
        return false
end

    -- if either players are somehow null, return false
    if not player or not target then 
        return false
end
    
    -- return false if player is the target
    if player == target then 
        return false
end

    -- check if target and players are in same vehicle. return false if so to avoid scenarios of passengers catching up and eating the bullet
    local playerVehicle = player:getVehicle()
    local targetVehicle = target:getVehicle()
    if playerVehicle and playerVehicle == targetVehicle then
        return false
end

    local ignorePVPSafety = getSandboxOptions():getOptionByName("Advanced_trajectory.IgnorePVPSafety"):getValue()  

    if ignorePVPSafety then 
        return true
    end

    if (getSandboxOptions():getOptionByName("ATY_nonpvp_protect"):getValue() and NonPvpZone.getNonPvpZone(target:getX(), target:getY())) then 
        return false
end

    if (getSandboxOptions():getOptionByName("ATY_safezone_protect"):getValue() and SafeHouse.getSafeHouse(target:getCurrentSquare())) then 
        return false
end

    if getServerOptions():getOptionByName("ShowSafety"):getValue() then
        -- if safety is on for BOTH players, then PVP is not allowed
        if player:getSafety():isEnabled() and target:getSafety():isEnabled() then 
            return false
end
    end

    local playerFaction = Faction.getPlayerFaction(player)
    local targetFaction = Faction.getPlayerFaction(target)

    if not playerFaction or not targetFaction then
        return true
    end

    local playerFactionPvp = player:isFactionPvp()
    local targetFactionPvp = target:isFactionPvp()

    if playerFaction ~= targetFaction then
        return true
    end
    
    -- allow PVP if player and target is in the same faction and faction PVP is on
    if playerFaction == targetFaction then
        if playerFactionPvp or targetFactionPvp then
            return true
        end
    end

    -- else do not allow pvp 
    return false
end

local function getDistFromHitbox(x, y, targetX, targetY, target) 
    local bulletRadius = 0.25
    local combinedRadius = (target.radius + bulletRadius)^2
    local hitbox = target.hitbox
    local hitboxCount = #hitbox
    for i = 1, hitboxCount do
        --print('X: ', x, ' - ', (hitbox[i][1] + targetX), '|| Y: ', y, ' - ', (hitbox[i][2] + targetY))
        local dist = (x - (hitbox[i][1] + targetX))^2 + (y - (hitbox[i][2] + targetY))^2
        --print('Circle ', i, ' || dist: ', dist, ' <=? ', combinedRadius)
        if dist <= combinedRadius then 
            return dist 
        end
    end

    return false
end

-- if HIT, return dist. if MISS, return false
-- bulletTable [x, y, dir]
-- need to implement check if entity rotates and take into account of look direction to rotate the hitboxes accordingly if they stack
local function collidedWithTargetHitbox(targetX, targetY, bulletTable, target)
    local dist = getDistFromHitbox(bulletTable.x , bulletTable.y, targetX, targetY, target)

    if dist then 
        --print('+++++++HIT+++++++')
        return dist 
    end

    --print('-------MISSED------')
    return false
end

local function sortTableByDistance(targetTable) 
    -- table.sort uses quicksort which means O(N log N) in best/avg case scenario
    -- insertion sort algorithm is best since data would be nearly sorted (dataset usually small as well). Time complexity would be O(N) and space would be O(1).
    for i = 2, #targetTable do 
        local temp = targetTable[i]
        local j = i - 1

        while (j >= 1 and temp.distanceFromPlayer < targetTable[j].distanceFromPlayer) do
            targetTable[j+1] = targetTable[j]
            j = j - 1
        end

        targetTable[j + 1] = temp
    end
end

-------------------------------------------------
--BULLET HIT ZOMBIE/PLAYER DETECTION FUNC SECT---
-------------------------------------------------
function Advanced_trajectory.searchTargetNearBullet(bulletTable, playerTable, missedShot)

    -- Initialize tables to store zombies and players
    local targetTable  = {} 

    -- Purpose of set is to make sure there's no duplicates of the same zombie or player instance
    local targetSet     = {}

    -- return these {isHit, distanceFromBullet, entityType}
    local targetHitData = {false, '', 10, false}

    local player    = getPlayer()
    local playerNum = player:getPlayerNum()

    local playerPosZ = playerTable[3]

    local getTargetDistanceFromPlayer = Advanced_trajectory.getTargetDistanceFromPlayer
    local allowPVP = Advanced_trajectory.allowPVP

    local gridMultiplier = getSandboxOptions():getOptionByName("Advanced_trajectory.DebugGridMultiplier"):getValue()
    local cell = getWorld():getCell()

    local damageIndx = 0

    local playerCount = 0

    local pointBlankDist = getSandboxOptions():getOptionByName("Advanced_trajectory.pointBlankMaxDistance"):getValue()

    -- if getSandboxOptions():getOptionByName("Advanced_trajectory.enablePlayerBulletPosCheck"):getValue() then
    --     print('searchTarget -> bullet: (', bulletTable.x, ', ', bulletTable.y, ', ', bulletTable.z, ')')
    --     print('searchTarget -> player: (', playerTable[1], ', ', playerTable[2], ', ', playerTable[3], ')')
    -- end

    local function addTargetsToTable(sq, targetTable, targetSet, player)
        local movingObjects = sq:getMovingObjects()

        local isNearWall = false
        local staticObjects = sq:getObjects()
        if staticObjects then
            for i=1,staticObjects:size() do
                local locobject = staticObjects:get(i-1)
                local sprite = locobject:getSprite()
                if sprite  then
                    local Properties = sprite:getProperties()
                    if Properties then
                        local wallN = Properties:Is(IsoFlagType.WallN)
                        local doorN = Properties:Is(IsoFlagType.doorN)

                        local wallNW = Properties:Is(IsoFlagType.WallNW)
                        local wallSE = Properties:Is(IsoFlagType.WallSE)

                        local wallW = Properties:Is(IsoFlagType.WallW)
                        local doorW = Properties:Is(IsoFlagType.doorW)

                        if (wallN or doorN or wallNW or wallSE or wallW or doorW) then
                            isNearWall = true
                            break
                        end
                    end
                end
            end
        end

        -- Iterate through moving objects in the grid square
        for zz = 1, movingObjects:size() do
            local zombieOrPlayer = movingObjects:get(zz - 1)

            -- Check if the object is an IsoZombie or IsoPlayer
            if instanceof(zombieOrPlayer, "IsoZombie") then
                -- check health and zombie dupes
                if zombieOrPlayer:getHealth() > 0 and not targetSet[zombieOrPlayer] then
                    if isNearWall and not player:CanSee(zombieOrPlayer) then 
                        --print('SKIP: IS NEAR WALL AND CANT SEE -- ', player:CanSee(zombieOrPlayer))
                    else
                        local entry = { entity = zombieOrPlayer, distanceFromPlayer = getTargetDistanceFromPlayer(player, zombieOrPlayer), entityType = 'zombie'}
                        table.insert(targetTable, entry)
                        targetSet[zombieOrPlayer] = true
                    end
                end
            end
            if instanceof(zombieOrPlayer, "IsoPlayer") then
                --print("FOUND PLAYER TARGET")
                if allowPVP(player, zombieOrPlayer) and not targetSet[zombieOrPlayer] then
                    --print("player registered for a meal [it's a bullet]")
                    if isNearWall and not player:CanSee(zombieOrPlayer) then 
                        --print('SKIP: IS NEAR WALL AND CANT SEE')
                    else
                        local entry = { entity = zombieOrPlayer, distanceFromPlayer = getTargetDistanceFromPlayer(player, zombieOrPlayer),  entityType = 'player'}
                        table.insert(targetTable, entry)
                        targetSet[zombieOrPlayer] = true
                    end
                end
            end
        end
    end

    ----------------------
    ---SCAN FOR TARGETS---
    ----------------------
    -- Loop through a 3x3 grid centered around the bullet and find targets that exist in the grid
    -- Reduce call for getCell() as much as possible
    for xCell = -1, 1 do      
        for yCell = -1, 1 do

            -- Get the grid square at the calculated coordinates
            local sq = cell:getGridSquare(bulletTable.x + xCell * gridMultiplier, bulletTable.y + yCell * gridMultiplier, bulletTable.z)

            -- Check if the grid square is valid and can be seen by the player
            if sq and sq:isCanSee(playerNum) then
                addTargetsToTable(sq, targetTable, targetSet, player)

            -- make exception if bullet and player are on the same floor to prevent issue with blindness (ex. not hiting any zombies in the forest)
            elseif sq and mathfloor(bulletTable.z) == mathfloor(playerPosZ) then
                addTargetsToTable(sq, targetTable, targetSet, player)
            end
        end
    end

    -- if tables are empty then just return
    if #targetTable == 0 then 
        return false, false, damageIndx
    end

    --print('TargetCount: ', #targetTable)

    -- minimum distance from bullet to target
    local prevDistanceFromPlayer = 99
    local hitRegThreshold = getSandboxOptions():getOptionByName("Advanced_trajectory.hitRegThreshold"):getValue()

    -- prio. closest zombie to player rather than closest zombie to bullet
    sortTableByDistance(targetTable)
    
    -------------------------------------------------
    ---CHECK IF ANY ZOMBIES WERE HIT BY THE BULLET---
    -------------------------------------------------
    -- goes through zombie table which contains a number of zombies found in the 3x3 grid
    local standHumanoidHitbox = Advanced_trajectory.hitboxes.standHumanoid
    local proneHumanoidHitbox = Advanced_trajectory.hitboxes.proneHumanoid
    local sitHumanoidHitbox = Advanced_trajectory.hitboxes.sitHumanoid 
    for i, entry in pairs(targetTable) do
        local target = entry.entity
        local targetType = entry.entityType
        local targetX = target:getX()
        local targetY = target:getY()
        local distanceFromPlayer = entry.distanceFromPlayer

        local isSteppedOn, isProne = Advanced_trajectory.isOnTopOfTarget(player, target)

        if not Advanced_trajectory.isObjectFacingZombie(playerTable[1], playerTable[2], bulletTable.dir, targetX, targetY, hitRegThreshold) and not isSteppedOn then
            --print("**********Skip target behind.*************")
        else
            if isSteppedOn or (missedShot and distanceFromPlayer <= pointBlankDist) then 
                targetHitData = {target, targetType, 1}
                damageIndx = 1
                break
            end

            if missedShot then break end

            local bulletDistFromTarg = false

            if isProne or (targetType == 'player' and (target:getVariableBoolean("isCrawling") or target:getVariableBoolean("IsCrouchAim"))) then 
                bulletDistFromTarg = collidedWithTargetHitbox(targetX, targetY, bulletTable, proneHumanoidHitbox) 
            elseif (targetType == 'player' and target:isSeatedInVehicle()) then
                bulletDistFromTarg = collidedWithTargetHitbox(targetX, targetY, bulletTable, sitHumanoidHitbox) 
            else
                bulletDistFromTarg = collidedWithTargetHitbox(targetX, targetY, bulletTable, standHumanoidHitbox) 
            end

            if bulletDistFromTarg and distanceFromPlayer < prevDistanceFromPlayer then
                --print('CurrDistTarg: ', bulletDistFromTarg, ' || PrevDistTarg: ', targetHitData[3])

                if bulletDistFromTarg < targetHitData[3] then
                    prevDistanceFromPlayer = distanceFromPlayer
                    targetHitData = {target, targetType, bulletDistFromTarg}
                    damageIndx = 1
                end

                --print("+++++++----TARGET REGISTERED----+++++++")
            end
        end
    end

    -- returns BOOL on whether zombie or player was hit and limb hit
    return targetHitData[1], targetHitData[2]
end

function Advanced_trajectory.checkBulletCarCollision(bulletPos, bulletDamage, tableIndx)
    local player = getPlayer()

    -- get player's current position, not initial parameter
    local playerCurrPosZ = player:getZ() 

    -- if high ground and aiming target below, ignore car
    if playerCurrPosZ > Advanced_trajectory.aimlevels and getSandboxOptions():getOptionByName("Advanced_trajectory.enableBulletIgnoreCarFromHighLevel"):getValue() then 
        --print('carColl -> no hit')
        return false
end

    local playerCurrPosX = player:getX()
    local playerCurrPosY = player:getY()

    local offset = bulletPos[3] - Advanced_trajectory.aimlevels - 0.5
    local bulletX = bulletPos[1] - 3 * offset
    local bulletY = bulletPos[2] - 3 * offset
    local square = getWorld():getCell():getOrCreateGridSquare(bulletX, bulletY, Advanced_trajectory.aimlevels)

    local playerVehicle 
    if player then
        playerVehicle = player:getVehicle()
    end

    -- retrieve BaseVehicle obj
    local vehicle = playerVehicle or square:getVehicleContainer()
    
    -- if square has car and player is over a distance away from car, check distance between bullet and car and damage car if close enough
    -- the reason for the initial distance check is to allow the player to shoot targets beyond the car while taking cover next to the car, otherwise have bullet collide with car
    if vehicle then
        local distFromPlayer = (vehicle:getX() - playerCurrPosX)^2  + (vehicle:getY() - playerCurrPosY)^2

        if distFromPlayer > 8 then
            local hitVehicle = function()
                local distFromBullet = (vehicle:getX() - bulletX)^2  + (vehicle:getY() - bulletY)^2

                --print('carColl -> checking hit w/ dist ', distFromBullet)
                --print('carColl -> bullet: (', bulletX, ', ', bulletY, ', ', offset, ')')
                --print('carColl ->  car: (', vehicle:getX(), ', ', vehicle:getY(), ', ', vehicle:getZ(), ')')
                if distFromBullet < 2.8 then
					if getSandboxOptions():getOptionByName("AT_VehicleDamageenable"):getValue() then
						local damage = bulletDamage * 0.3
						vehicle:HitByVehicle(vehicle, damage)
						Advanced_trajectory.determineArrowSpawn(square, true)

						local bulletTable = Advanced_trajectory.table[tableIndx]
						if bulletTable then
							-- Hard stop on vehicles: no further penetration or travel
							bulletTable.damage = bulletTable.damage * 0.5  -- soften remaining bullet a bit (safety)
							bulletTable["penCount"] = 0
							bulletTable.canPassThroughWall = false
						end
					end
					return true -- signal collision => stop
				end

                --print('carColl -> no hit')
            end
            
            return hitVehicle()
        end
    end

    return false
end

----------------------------------------------------
--BULLET COLLISION WITH STATIC OBJECTS FUNC SECT---
----------------------------------------------------
-- checks the squares that the bullet travels, this means there's need to be a limit to how fast the bullet travels
-- this function determines whether bullets should "break" meaning they stop, pretty much a collision checker
-- bullet square, dirc, bullet offset, player offset, nonsfx
function Advanced_trajectory.checkObjectCollision(square, bulletDir, bulletPos, playerPos, nonsfx)

    local playerPosX = playerPos[1]
    local playerPosY = playerPos[2]
    local playerPosZ = mathfloor(playerPos[3])

    local angle = bulletDir
    if angle > 180 then
        angle = -180 + (angle-180)
    end
    if angle < -180 then
        angle = 180 + (angle+180)
    end

    local offset = 1

    -- returns an array of objects in that square, for loop and filter it to get what you want
    local objects = square:getObjects()
    local squareX = square:getX()
    local squareY = square:getY()
    local squareZ = square:getZ()
    if objects then
        for i=1,objects:size() do

            local locobject = objects:get(i-1)
            local sprite = locobject:getSprite()
            if sprite  then
                local Properties = sprite:getProperties()
                if Properties then

                    local wallN = Properties:Is(IsoFlagType.WallN)
                    local doorN = Properties:Is(IsoFlagType.doorN)

                    local wallNW = Properties:Is(IsoFlagType.WallNW)
                    local wallSE = Properties:Is(IsoFlagType.WallSE)

                    local wallW = Properties:Is(IsoFlagType.WallW)
                    local doorW = Properties:Is(IsoFlagType.doorW)

                    -- if the locoobject is "IsoWindow" which is a class and it's not smashed, smash it
                    if instanceof(locobject,"IsoWindow") and not locobject:isSmashed() and not locobject:IsOpen() then
                        locobject:setSmashed(true)
                        getSoundManager():PlayWorldSoundWav("SmashWindow",square, 0.5, 2, 0.1, true);
                        return true
                    end

                    local isAngleTrue = false

                    -- prevents wall collision when shooting targets below on roofs by ignoring wall near player
                    if Advanced_trajectory.aimlevels then 
                        --print("Aim Level | playerZ: ", Advanced_trajectory.aimlevels, " || ", playerPosZ)
                        if (wallN or doorN or wallNW or wallSE or wallW or doorW) and (Advanced_trajectory.aimlevels ~= playerPosZ) then
                            return false
						end
                    end

                    if wallNW then
                        --if shooting into corner, then break
                        -- - means player > sq
                        -- + means player < sq
                        if 
                        (angle<=135 and angle>=90) and (playerPosY  < squareY or playerPosX  > squareX) or
                        (angle<=90 and angle>=0) and (playerPosY  < squareY or playerPosX  < squareX) or
                        (angle<=0 and angle>=-45) and (playerPosY  > squareY or playerPosX  < squareX)
                        then
                            --print("----Facing outside into wallNW----")
                            --getSoundManager():PlayWorldSoundWav("BreakObject",square, 0.5, 2, 0.1, true);

                            local spawnSquare = getWorld():getCell():getOrCreateGridSquare(squareX - offset, squareY - offset, squareZ)
                            Advanced_trajectory.determineArrowSpawn(spawnSquare, true)
                            return true
                        end

                        if 
                        (angle>=135 and angle<=180) and (playerPosY  < squareY or playerPosX  > squareX) or
                        (angle>=-180 and angle<=-90) and (playerPosY  > squareY or playerPosX  > squareX) or
                        (angle>=-90 and angle<=-45) and (playerPosY  > squareY or playerPosX  < squareX) 
                        then
                            --print("----Facing inside into wallNW----")
                           -- getSoundManager():PlayWorldSoundWav("BreakObject",square, 0.5, 2, 0.1, true);

                            local spawnSquare = getWorld():getCell():getOrCreateGridSquare(squareX + offset, squareY + offset, squareZ)
                            Advanced_trajectory.determineArrowSpawn(spawnSquare, true)
                            return true
                        end

                        --print("++++Detected wallNW++++")
                    elseif wallSE then
                        if 
                        (angle<=135 and angle>=90) and (playerPosY  < squareY or playerPosX  > squareX) or
                        (angle<=90 and angle>=0) and (playerPosY  < squareY or playerPosX  < squareX) or
                        (angle<=0 and angle>=-45) and (playerPosY  > squareY or playerPosX  < squareX)
                        then
                            --print("----Facing inside into wallSE----")
                            --getSoundManager():PlayWorldSoundWav("BreakObject",square, 0.5, 2, 0.1, true);

                            local spawnSquare = getWorld():getCell():getOrCreateGridSquare(squareX - offset, squareY - offset, squareZ)
                            Advanced_trajectory.determineArrowSpawn(spawnSquare, true)
                            return true
                        end

                        if 
                        (angle>=135 and angle<=180) and (playerPosY  < squareY or playerPosX  > squareX) or
                        (angle>=-180 and angle<=-90) and (playerPosY  > squareY or playerPosX  > squareX) or
                        (angle>=-90 and angle<=-45) and (playerPosY  > squareY or playerPosX  < squareX) 
                        then
                            --print("----Facing outside into wallSE----")
                           -- getSoundManager():PlayWorldSoundWav("BreakObject",square, 0.5, 2, 0.1, true);

                            local spawnSquare = getWorld():getCell():getOrCreateGridSquare(squareX + offset, squareY + offset, squareZ)
                            Advanced_trajectory.determineArrowSpawn(spawnSquare, true)
                            return true
                        end

                        --print("++++Detected wallSE++++")
                    elseif wallN or (doorN and not locobject:IsOpen()) then
                        isAngleTrue = angle <=0 and angle >= -180
                        -- facing east into wallN
                        if (isAngleTrue) and playerPosY  > squareY then
                            --print("----Facing EAST into wallN----")
                           -- getSoundManager():PlayWorldSoundWav("BreakObject",square, 0.5, 2, 0.1, true);

                            local spawnSquare = getWorld():getCell():getOrCreateGridSquare(squareX, squareY + offset, squareZ)
                            Advanced_trajectory.determineArrowSpawn(spawnSquare, true)
                            return true
                        end

                        isAngleTrue = angle >=0 and angle <= 180
                        -- facing west into wallN
                        if (isAngleTrue) and playerPosY < squareY then
                            --print("----Facing WEST into wallN----")
                          --  getSoundManager():PlayWorldSoundWav("BreakObject",square, 0.5, 2, 0.1, true);

                            local spawnSquare = getWorld():getCell():getOrCreateGridSquare(squareX, squareY - offset, squareZ)
                            Advanced_trajectory.determineArrowSpawn(spawnSquare, true)
                            return true
                        end

                        --print("++++Detected wallN++++")
                    elseif wallW or (doorW and  not locobject:IsOpen()) then
                        isAngleTrue = (angle >=0 and angle <= 90) or (angle <=0 and angle >= -90)
                        -- facing south into wallW
                        if (isAngleTrue) and playerPosX < squareX then
                            --print("----Facing SOUTH into wallW----")
                         --   getSoundManager():PlayWorldSoundWav("BreakObject",square, 0.5, 2, 0.1, true);

                            local spawnSquare = getWorld():getCell():getOrCreateGridSquare(squareX - offset, squareY, squareZ)
                            Advanced_trajectory.determineArrowSpawn(spawnSquare, true)
                            return true
                        end

                        isAngleTrue = (angle >=90 and angle <= 180) or (angle <=-90 and angle >= -180)
                        -- facing north into wallW
                        if (isAngleTrue) and playerPosX > squareX then
                            --print("----Facing NORTH into wallW----")
                         --   getSoundManager():PlayWorldSoundWav("BreakObject",square, 0.5, 2, 0.1, true);

                            local spawnSquare = getWorld():getCell():getOrCreateGridSquare(squareX + offset, squareY, squareZ)
                            Advanced_trajectory.determineArrowSpawn(spawnSquare, true)
                            return true
                        end

                        --print("++++Detected wallW++++")
                    end
                    

                end
            end
        end
    end

    return false
end

-----------------------------
--ADD TEXTURE FX FUNC SECT---
-----------------------------
function Advanced_trajectory.additemsfx(square, itemname, x, y, z)
    --print('additemsfx -> sq: ', square, ' || item: ', itemname)
    --print('additemsfx -> (', x, ', ', y, ', ', z, ')')
    if square:getZ() > 7 then return end
    local iteminv = InventoryItemFactory.CreateItem(itemname)
    local itemin = IsoWorldInventoryObject.new(iteminv, square, advMathFloor(x), advMathFloor(y), advMathFloor(z));
    iteminv:setWorldItem(itemin)
    square:getWorldObjects():add(itemin)
    square:getObjects():add(itemin)
    local chunk = square:getChunk()
    
    if chunk then
        square:getChunk():recalcHashCodeObjects()
    else 
        return 
    end
    -- iteminv:setAutoAge();
    -- itemin:setKeyId(iteminv:getKeyId());
    -- itemin:setName(iteminv:getName());
    return iteminv
end

----------------------------------------------
--EXPLOSION SPECIAL EFFECTS LOGIC FUNC SECT---
----------------------------------------------
function Advanced_trajectory.boomontick()
    local currTable = Advanced_trajectory.boomtable

    for indx, tableSfx in pairs(currTable) do
        for kz, vz in pairs(tableSfx.item) do
            Advanced_trajectory.itemremove(tableSfx.item[tableSfx.nowSfxNum - tableSfx.offset])
        end

        if tableSfx.nowSfxNum > tableSfx.sfxNum + tableSfx.offset then
            currTable[indx] = nil
            break
        end

        if tableSfx.nowSfxNum == 1 and tableSfx.sfxCount == 0 then 

            local itemOrNone = Advanced_trajectory.additemsfx(tableSfx.square, tableSfx.sfxName..tostring(tableSfx.nowSfxNum), tableSfx.pos[1], tableSfx.pos[2], tableSfx.pos[3])
            table.insert(tableSfx.item, itemOrNone)
            tableSfx.nowSfxNum = tableSfx.nowSfxNum + 1

        elseif tableSfx.sfxCount > tableSfx.ticIndxime and tableSfx.nowSfxNum <= tableSfx.sfxNum then

            tableSfx.sfxCount = 0
            local itemOrNone = Advanced_trajectory.additemsfx(tableSfx.square, tableSfx.sfxName..tostring(tableSfx.nowSfxNum), tableSfx.pos[1], tableSfx.pos[2], tableSfx.pos[3])
            table.insert(tableSfx.item, itemOrNone)
            tableSfx.nowSfxNum = tableSfx.nowSfxNum + 1

        elseif tableSfx.sfxCount > tableSfx.ticIndxime then

            tableSfx.sfxCount = 0 
            tableSfx.nowSfxNum = tableSfx.nowSfxNum + 1

        end
            
        tableSfx.sfxCount = tableSfx.sfxCount + gameTime:getMultiplier()
    end
end

--------------------------------------
--TABLE FOR EXPLOSION SFX FUNC SECT---
--------------------------------------
function Advanced_trajectory.boomsfx(sq, sfxName, sfxNum, ticIndxime)
    local tableSfx = {
        sfxName     = sfxName or "Base.theMH_MkII_SFX",     ---1
        sfxNum      = sfxNum or 12,                         ---2
        nowSfxNum   = 1,                                    ---3
        pos         = {sq:getX(), sq:getY() ,sq:getZ()},    ---4
        square      = sq,                                   ---5
        ticIndxime  = ticIndxime or 3.5,                    ---6
        sfxCount    = 0,                                    ---7
        func        = function() return end,                ---8
        item        = {},                                   ---12
        offset      = 3                                     ---13 滞后/lag ???
    }

    table.insert(Advanced_trajectory.boomtable, tableSfx)
end

function Advanced_trajectory.limitCarAim(player) 
    if player:isSeatedInVehicle() then
        local playerForwardVector = player:getForwardDirection()
        playerForwardVector:normalize()

        local vehicle       = player:getVehicle()
        local vehicleScript = vehicle:getScript()

        --convert forward vector 3 to vector 2
        local vehicleForwardVector3f    = vehicle:getForwardVector(BaseVehicle.allocVector3f())
        local vehForwardVec             = BaseVehicle.allocVector2()
        local vehForwardVec1            = BaseVehicle.allocVector2()
        local upperBoundVec             = BaseVehicle.allocVector2()
        local lowerBoundVec             = BaseVehicle.allocVector2()

        vehForwardVec:set(vehicleForwardVector3f:x(), vehicleForwardVector3f:z())
        vehForwardVec1:set(vehicleForwardVector3f:x(), vehicleForwardVector3f:z())
        upperBoundVec:set(vehicleForwardVector3f:x(), vehicleForwardVector3f:z())
        lowerBoundVec:set(vehicleForwardVector3f:x(), vehicleForwardVector3f:z())
        
        local seat          = vehicle:getSeat(player)
        local seatPosX      = vehicleScript:getAreaById(vehicle:getPassengerArea(seat)):getX()
        local angleBoundCar = getSandboxOptions():getOptionByName("Advanced_trajectory.angleBoundCar"):getValue()

        local angleFwrd = 90
        local angleUp   = angleFwrd - angleBoundCar
        local angleLow  = angleFwrd + angleBoundCar

        -- if on right side seat, rotate vehicle's forward vector 90 degrees to the right
        if seatPosX > 0 then 
            angleFwrd = -90 
            angleUp   = angleFwrd + angleBoundCar
            angleLow  = angleFwrd - angleBoundCar
        end

        vehForwardVec:rotate(math.rad(angleFwrd))
        upperBoundVec:rotate(math.rad(angleUp))
        lowerBoundVec:rotate(math.rad(angleLow))

        vehForwardVec:normalize()
        vehForwardVec1:normalize()
        upperBoundVec:normalize()
        lowerBoundVec:normalize()

        -- find angle between player and vehicle forward vectors
        local dotProd = playerForwardVector:dot(vehForwardVec)

        Advanced_trajectory.forwardCarVec = vehForwardVec1
        Advanced_trajectory.upperCarAimBound = upperBoundVec
        Advanced_trajectory.lowerCarAimBound = lowerBoundVec
        
        if dotProd < getSandboxOptions():getOptionByName("Advanced_trajectory.carDotProdLimit"):getValue() then
            Advanced_trajectory.isOverCarAimLimit = true
        else
            Advanced_trajectory.isOverCarAimLimit = false
        end

        BaseVehicle.releaseVector2(lowerBoundVec)
        BaseVehicle.releaseVector2(upperBoundVec)
        BaseVehicle.releaseVector2(vehForwardVec1)
        BaseVehicle.releaseVector2(vehForwardVec)
        BaseVehicle.releaseVector3f(vehicleForwardVector3f)
    end
end

-----------------------------------
--ATTACHMENT EFFECTS FUNC SECT-----
-----------------------------------
-- Consider vanilla AND brita's into account
function Advanced_trajectory.getAttachmentEffects(weapon)  
    local scope     = weapon:getScope()         -- scopes/reddots/sights
    local canon     = weapon:getCanon()         -- britas: bayonets, barrels, chokes
    local stock     = weapon:getStock()         -- stocks, lasers
    local recoilPad = weapon:getRecoilpad()     -- britas: pad, pistol stock
    local sling     = weapon:getSling()         -- britas: slings, foregrips, launchers, ammobelts

    --print("Scp/Can/Stk/Rec/Slg: ", scope, " / ", canon, " / ", stock, " / ", recoilPad, " / ", sling)

    local modTable  = {scope, canon, stock, recoilPad}

    local aimingTime = 0         --1 multiply to reduceSpeed           + good
    local hitChance  = 0         --2 multiply to focusCounterSpeed     + good
    local recoil     = 0         --3 multiply to recoil                - good
    local range      = 0         --4 add to proj range                 + good
    local angle      = 0         --5                                   - good

    local effectsTable =  {
        aimingTime,         
        hitChance ,       
        recoil    ,       
        range     ,        
        angle     ,  
    }

    -- for every attachment, add all of their buffs/nerfs into var
    for indx, mod in pairs(modTable) do
        -- check if it exists first
        if mod then
            effectsTable[1]  = effectsTable[1] + mod:getAimingTime()
            effectsTable[2]  = effectsTable[2] + mod:getHitChance()
            effectsTable[3]  = effectsTable[3] + mod:getRecoilDelay()
            effectsTable[4]  = effectsTable[4] + mod:getMaxRange()
            effectsTable[5]  = effectsTable[5] + mod:getAngle()
        end
    end

    --aimingTime: flat nerf/buff                1.1 - table
    if  effectsTable[1] < 0 then
        effectsTable[1] = effectsTable[1]*2 / 100 
    else
        effectsTable[1] = effectsTable[1]*5 / 100 
    end

    --hitChance: flat nerf/buff                 2 - table
    if  effectsTable[2] < 0 then
        effectsTable[2] = effectsTable[2]*3 / 100 
    else
        effectsTable[2] = effectsTable[2]*8 / 100 
    end

    effectsTable[3]     = (effectsTable[3]*5 / 100) + 1
    effectsTable[4]     =  effectsTable[4] * 0.5
    effectsTable[5]     =  effectsTable[5] * 10

    return effectsTable
end

function Advanced_trajectory.getIsHoldingShotgun(weapon)
    if (string.contains(weapon:getAmmoType() or "","Shotgun") or string.contains(weapon:getAmmoType() or "","shotgun") or string.contains(weapon:getAmmoType() or "","shell") or string.contains(weapon:getAmmoType() or "","Shell")) then
        return true
    end

    return false
end

function Advanced_trajectory.getMissMin(aimingLevel, weapon)
    local buff = 0
    if Advanced_trajectory.getIsHoldingShotgun(weapon) then
        buff = getSandboxOptions():getOptionByName("Advanced_trajectory.shotgunHitBuff"):getValue()
    end

    local hitLevelScaling = getSandboxOptions():getOptionByName("Advanced_trajectory.hitLevelScaling"):getValue()

    Advanced_trajectory.missMin = getSandboxOptions():getOptionByName("Advanced_trajectory.missMin"):getValue() + aimingLevel*hitLevelScaling + buff
end

function Advanced_trajectory.determineHitOrMiss() 
    local player = getPlayer()

    local missMax = getSandboxOptions():getOptionByName("Advanced_trajectory.missMax"):getValue()

    local randNum = ZombRandFloat(Advanced_trajectory.missMin, missMax) 

    local enableAnnounce = getSandboxOptions():getOptionByName("Advanced_trajectory.announceHitOrMiss"):getValue()
    if Advanced_trajectory.aimnumBeforeShot > randNum then
        --Advanced_trajectory.missedShot = true
        if enableAnnounce then
            player:Say(getText("Missed: " .. Advanced_trajectory.aimnumBeforeShot .. " > " .. randNum))
        end
        return true
    else
        --Advanced_trajectory.missedShot = false
        if enableAnnounce then
            player:Say(getText("Hit: " .. Advanced_trajectory.aimnumBeforeShot .. " <= " .. randNum))
        end
        return false
	end
end


function Advanced_trajectory.getDistanceFromMouseToPlayer(player)
    local mouseX = getMouseXScaled()
    local mouseY = getMouseYScaled()

    local playerX = mathfloor(player:getX())
    local playerY = mathfloor(player:getY())
    local playerZ = mathfloor(player:getZ())
    
    local wx, wy = ISCoordConversion.ToWorld(mouseX, mouseY, playerZ)
    
    wx, wy = mathfloor(wx) + 2, mathfloor(wy) + 2

    -- comment after testing
    --wx, wy = wx + 2, wy + 2

    -- remove mathfloor after testing
    --local x = mathfloor((playerX - wx)^2)
    --local y = mathfloor((playerY - wy)^2)

    local x = (playerX - wx)^2
    local y = (playerY - wy)^2

    local dist = x + y

    --print("PlayX: ", playerX ," || PlayY: ", playerY)
    --print("Mouse X: ", x ," || Mouse Y: ", y)
    --print("Dist via Play: ", dist)

    return dist
end

-----------------------------------
--AIMNUM/BLOOM LOGIC FUNC SECT---
-----------------------------------
function Advanced_trajectory.OnPlayerUpdate()
    local player = getPlayer() 
    if not player then return end

    local weaitem = player:getPrimaryHandItem()
    local isAiming = player:isAiming()
    local hasGun = instanceof(weaitem, "HandWeapon") 
    local gameTimeMultiplier = gameTime:getMultiplier() * 16

    -- if have manual aim Z level enabled, reset aimlevel to player level when about to aim 
    if Mouse.isRightPressed() and not getSandboxOptions():getOptionByName("Advanced_trajectory.enableAutoAimZLevel"):getValue() then
        Advanced_trajectory.aimlevels = mathfloor(player:getZ())
    end

    if isAiming and hasGun then
        Advanced_trajectory.hasFlameWeapon = string.contains(weaitem:getAmmoType() or "","FlameFuel")
    end

    if isAiming and hasGun and not weaitem:hasTag("Thrown") and not Advanced_trajectory.hasFlameWeapon and not (string.contains(weaitem:getAmmoType() or "", "MandelaArrow")) and not (weaitem:hasTag("XBow") and not getSandboxOptions():getOptionByName("Advanced_trajectory.DebugEnableBow"):getValue()) and (((weaitem:isRanged() and getSandboxOptions():getOptionByName("Advanced_trajectory.Enablerange"):getValue()) or (weaitem:getSwingAnim() =="Throw" and getSandboxOptions():getOptionByName("Advanced_trajectory.Enablethrow"):getValue())) or Advanced_trajectory.FullWeaponTypes[weaitem:getFullType()]) then
        -- print(getPlayer():getCoopPVP())        -- outline visual: do not mutate MaxHitCount here
		
        if getSandboxOptions():getOptionByName("Advanced_trajectory.showOutlines"):getValue() then
            weaitem:setMaxHitCount(1)
        else
            weaitem:setMaxHitCount(0)
        end

        local modEffectsTable = Advanced_trajectory.getAttachmentEffects(weaitem)  
        --print("Rs: ", modEffectsTable[1], " / Fc: ", modEffectsTable[2], " / Re: ", modEffectsTable[3], " / Ra: ", modEffectsTable[4], " / A:", modEffectsTable[5])

        Mouse.setCursorVisible(false)
        
        ------------------------
        --AIMNUM SCALING SECT---
        ------------------------
        local realLevel     = player:getPerkLevel(Perks.Aiming)     -- 0 to 10
        local reversedLevel = 11 - realLevel  -- 11 to 1 

        local gametimemul   = gameTimeMultiplier / (reversedLevel + 10)
        local constantTime  = gameTimeMultiplier / (1 + 10)

        local maxaimnumModifier         = getSandboxOptions():getOptionByName("Advanced_trajectory.maxaimnum"):getValue() 
        local realMaxaimnum             = weaitem:getAimingTime() + (reversedLevel * maxaimnumModifier)
        local maxaimnum = Advanced_trajectory.maxaimnum

        local minaimnumModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.minaimnumModifier"):getValue() 
        local realMin           = (reversedLevel - 1) * minaimnumModifier
        local minaimnum = Advanced_trajectory.minaimnum

        local aimnum = Advanced_trajectory.aimnum
        local alpha = Advanced_trajectory.alpha
        local maxFocusCounter = Advanced_trajectory.maxFocusCounter

        -- aimbot level (sorta)
        if realLevel >= 10 then
            realMin = 5 
        end

        -- bloom reduction scaling rate capped at 8
        if realLevel > 8 then
            gametimemul = gameTimeMultiplier / (12-8 + 10)
        end

        if realLevel < 3 then
            gametimemul = gameTimeMultiplier / (12-3 + 10)
        end

        -- maxaimnum capped at 8
        if realLevel > 8 then
            realMaxaimnum = weaitem:getAimingTime() + ((11-8) * maxaimnumModifier)
        end

        local canRunNGun = false
        -- run and gun unlock
        if realLevel >= getSandboxOptions():getOptionByName("Advanced_trajectory.runNGunLv"):getValue() or player:HasTrait("RunNGun") then
            canRunNGun = true
        end

        maxaimnum = realMaxaimnum

        --------------------------------------------------------------------------------
        ---FOCUS MECHANIC SECT (IF MINAIMNUM IS REACHED, start counting down to 0)---
        --------------------------------------------------------------------------------
        -- If player moves or shoots (aimnum increases), reset counter and minaimnum.

        -- rate of reduction for minaimnum
        local maxFocusSpeed = getSandboxOptions():getOptionByName("Advanced_trajectory.maxFocusSpeed"):getValue() 

        -- max recoil delay is 100 (sniper), 50 (shotgun), 20-30 (pistol), 0 (m16/m14)
        -- lower means slower
        local recoilDelay = weaitem:getRecoilDelay() 
        local recoilDelayModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.recoilDelayModifier"):getValue() 

        local focusCounterSpeed = getSandboxOptions():getOptionByName("Advanced_trajectory.focusCounterSpeed"):getValue() 
        focusCounterSpeed = focusCounterSpeed - (recoilDelay * recoilDelayModifier)
        
        local focusLevelGained = getSandboxOptions():getOptionByName("Advanced_trajectory.focusLevel"):getValue() 
        local focusCounterSpeedScaleModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.focusCounterSpeedScaleModifier"):getValue() 
        local hasFocusSkill = true

        --if realLevel >= focusLevelGained then
        --    hasFocusSkill = true
        --end

        local focusLimit = 0

        -- focusCounterSpeed scales with flat buff
        if realLevel > focusLevelGained then
            focusCounterSpeed = focusCounterSpeed + (((realLevel-focusLevelGained) * focusCounterSpeedScaleModifier) / 10)
        end

        if realLevel < focusLevelGained then
            focusLimit = focusLimit + 20/(realLevel+1)
        end

        Advanced_trajectory.getMissMin(realLevel, weaitem)

        ------------------------
        -- MOODLE LEVELS SECT--
        ------------------------
        -- level 0 to 4 (least to severe)
        local stressLv      = player:getMoodles():getMoodleLevel(MoodleType.Stress) -- inc minaimnum
        local enduranceLv   = player:getMoodles():getMoodleLevel(MoodleType.Endurance) -- inc minaimnum, dec aim speed
        local panicLv       = player:getMoodles():getMoodleLevel(MoodleType.Panic) -- transparency
        local drunkLv       = player:getMoodles():getMoodleLevel(MoodleType.Drunk) -- scaling and pos
        local painLv        = player:getMoodles():getMoodleLevel(MoodleType.Pain)
        
        local hyperLv   = player:getMoodles():getMoodleLevel(MoodleType.Hyperthermia) -- dec aim speed
        local hypoLv    = player:getMoodles():getMoodleLevel(MoodleType.Hypothermia) -- dec aim speed
        local tiredLv   = player:getMoodles():getMoodleLevel(MoodleType.Tired) -- dec aim speed

        local heavyLv   = player:getMoodles():getMoodleLevel(MoodleType.HeavyLoad) -- add bloom

        -- add to realMin or focusLimit if want to increase minaimnum from negative moodles
        baseAimnumPenalty = 6

         -- Main purpose is to nerf lv 10 when exhausted
        if enduranceLv > 0 then    
            realMin = realMin + baseAimnumPenalty    
            maxaimnum = maxaimnum + enduranceLv*2
        end
        -----------------------------------
        --TRUE CROUCH/CRAWL (FIRST) SECT---
        -----------------------------------
        if player:getVariableBoolean("IsCrouchAim") and not hasFocusSkill then
            realMin = realMin - 15
        end

        if player:getVariableBoolean("isCrawling") and not hasFocusSkill then
            realMin = realMin - 25
        end

        Advanced_trajectory.isOverCarAimLimit = false
        if getSandboxOptions():getOptionByName("Advanced_trajectory.enableCarAimLimit"):getValue()  then
            Advanced_trajectory.limitCarAim(player) 
        end

        --------------------------------
        ---TARGET DISTANCE LIMIT SECT---
        --------------------------------
        local enableDistanceLimitPenalty    = getSandboxOptions():getOptionByName("Advanced_trajectory.enableDistanceLimitPenalty"):getValue() 
        local distanceFocusPenalty          = getSandboxOptions():getOptionByName("Advanced_trajectory.distanceFocusPenalty"):getValue() 
        local distanceLimitScaling        = getSandboxOptions():getOptionByName("Advanced_trajectory.distanceLimitScaling"):getValue() 
 
        local shotgunDistanceModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.shotgunDistanceModifier"):getValue()

        local maxDistance = getSandboxOptions():getOptionByName("Advanced_trajectory.bulletdistance"):getValue() * weaitem:getMaxRange()

        if Advanced_trajectory.getIsHoldingShotgun(weaitem) then
            --print("Holding shotgun")
            maxDistance = maxDistance * shotgunDistanceModifier
        end

        maxDistance = mathfloor((modEffectsTable[4] + maxDistance)^2)
        
        --local distanceLimit = (maxDistance * distanceLimitPenalty) + ((maxDistance * (1-distanceLimitPenalty)) * realLevel/10)
        local distanceLimit = maxDistance * realLevel/10
        distanceLimit = distanceLimit * distanceLimitScaling
        
        local targetDist = Advanced_trajectory.getDistanceFromMouseToPlayer(player)

        --print("target / maxDistance / limit: ", targetDist, " || ", maxDistance, " || ", distanceLimit)

        if targetDist > maxDistance or targetDist > 70 * 70.51 then
            targetDist = maxDistance
            Advanced_trajectory.isOverDistanceLimit = true  
        else
            Advanced_trajectory.isOverDistanceLimit = false
        end


        
        -- PANIC SECT -- 
        ----------------
        -- panic causes shakiness and penalty for aiming at farther targets is increased
        local panicPenaltyModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.panicPenaltyModifier"):getValue() 
        local panicVisualModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.panicVisualModifier"):getValue() 
        if panicLv > 1 then
            Advanced_trajectory.panicEffect = panicVisualModifier * panicLv
            distanceFocusPenalty = distanceFocusPenalty * panicPenaltyModifier * panicLv
            distanceLimit = distanceLimit * ((4-panicLv)/5)
        else
            Advanced_trajectory.panicEffect = 0
        end


        ------ STRESS SECT ------
        -------------------------
        local stressBloomModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.stressBloomModifier"):getValue() 
        local stressVisualModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.stressVisualModifier"):getValue() 
        -- no effects for lv 1 stress
        if stressLv > 1 then
            Advanced_trajectory.stressEffect = stressVisualModifier * stressLv
        else
            Advanced_trajectory.stressEffect = 0
        end

        if stressLv > 1 and realLevel < 3 then
            realMin = realMin + (stressBloomModifier * stressLv)
        end

        if stressLv > 1 and hasFocusSkill then
            focusLimit = focusLimit + baseAimnumPenalty * (stressLv-1)
        end

        ------ DRUNK 1 SECT ------
        --------------------------
        if drunkLv >= 3 and realLevel < 3 then
            realMin = realMin + (baseAimnumPenalty * drunkLv)
        end

        if drunkLv >= 3 and hasFocusSkill then
            focusLimit = focusLimit + (baseAimnumPenalty * drunkLv)
        end


        -- ARMS, HANDS DAMAGE SECT--
        ----------------------------
        local bodyDamage = player:getBodyDamage()

        -- PAIN VARIABLES float values (0 - 200)
        -- 30 lv1, 50 lv2, 100 lv3, 150-200 lv 4
        -- def reduceSpeed for all aim levels: 1.1
        local handPainL = bodyDamage:getBodyPart(BodyPartType.Hand_L):getPain()   
        local forearmPainL = bodyDamage:getBodyPart(BodyPartType.ForeArm_L):getPain()  
        local upperarmPainL = bodyDamage:getBodyPart(BodyPartType.UpperArm_L):getPain()  

        local handPainR = bodyDamage:getBodyPart(BodyPartType.Hand_R):getPain()  
        local forearmPainR = bodyDamage:getBodyPart(BodyPartType.ForeArm_R):getPain()  
        local upperarmPainR = bodyDamage:getBodyPart(BodyPartType.UpperArm_R):getPain()  

        local totalArmPain = handPainL + forearmPainL + upperarmPainL + handPainR + forearmPainR + upperarmPainR
        
        local painModifider = getSandboxOptions():getOptionByName("Advanced_trajectory.painModifier"):getValue() 

        if totalArmPain > 200 then
            totalArmPain = 200
        end

        -- limits how small minaimnum can go (affected by pain/stress)
        if totalArmPain >= 39 and painLv > 1 then
            if hasFocusSkill then
                if painLv == 2 then
                    focusLimit = focusLimit + baseAimnumPenalty
                else
                    focusLimit = focusLimit + baseAimnumPenalty * (0.5 + totalArmPain/50)
                end
            end

            Advanced_trajectory.painEffect = getSandboxOptions():getOptionByName("Advanced_trajectory.painVisualModifier"):getValue() 
        else
            Advanced_trajectory.painEffect = 0
        end



        if targetDist > distanceLimit then
            if enableDistanceLimitPenalty and (maxDistance - distanceLimit > 0) then
                focusLimit = focusLimit + (((targetDist-distanceLimit)*distanceFocusPenalty*reversedLevel) / (maxDistance-distanceLimit))
            end
        end

        ----------------------
        ---DRUNK/HEAVY SECT---
        ----------------------
        local drunkMaxBloomModifier     = getSandboxOptions():getOptionByName("Advanced_trajectory.drunkMaxBloomModifier"):getValue() 
        local heavyMaxBloomModifier     = getSandboxOptions():getOptionByName("Advanced_trajectory.heavyMaxBloomModifier"):getValue() 
        maxaimnum   = maxaimnum + (drunkLv*drunkMaxBloomModifier) + (heavyLv*heavyMaxBloomModifier)

        ----------------------------------
        -- HYPER, HYPO, TIRED, PAIN SECT--
        ----------------------------------
        -- SPEED EFFECTS (must be greater than 0, higher number means less effect)
        -- considering that you can only get hypo or hyper, there are mainly 2 moodles that can stack (temp and tired)
        -- can either stack to -100% if full severity with 0s
        -- all 1s mean stack -66%
        -- all 0s mean stack -100%
        local hyperHypoModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.hyperHypoModifier"):getValue() 
        local tiredModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.tiredModifier"):getValue() 

        -- with default modifiers of 1, it should total up to 1
        local speed = getSandboxOptions():getOptionByName("Advanced_trajectory.reducespeed"):getValue() 
        local reduceSpeed = speed 

        -- needs to subtract at most 1/3 --> 1/(x-4) = 1/3
        -- no effects for lv 1 temp serverity
        if hyperLv > 1 then
            reduceSpeed = reduceSpeed * (hyperHypoModifier  - ((hyperLv - 2) / 5))
        end

        if hypoLv > 1 then
            reduceSpeed = reduceSpeed * (hyperHypoModifier  - ((hypoLv - 2) / 5))
        end

        if tiredLv > 0 then
            reduceSpeed = reduceSpeed * (tiredModifier      - ((tiredLv - 1) / 8))
        end

        if totalArmPain >= 39 and painLv > 1 then
            reduceSpeed =  reduceSpeed * (1 - (painModifider * (0.5+totalArmPain/50)))
        end

        ------------------------
        -- SNEEZE, COUGH SECT---
        ------------------------
        -- returns 1 (sneeze) or 2 (cough)  
        local isSneezeCough = bodyDamage:getSneezeCoughActive() 
        local coughModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.coughModifier"):getValue() 

        -- COUGHING: Add onto aimnum, adds way too much for some reason (goes over maxaimnum ex. goes to 64 when max is 50)
        -- use gametime or else value goes wild (value would be added through framerate and not gametimewhich is not accurate)
        --print("coughEffect: ", coughEffect)
        if isSneezeCough == 2 then
            if aimnum < maxaimnum then
                aimnum = aimnum + coughModifier*gametimemul
            end
            maxFocusCounter = 100
        end

        -- SNEEEZING: Reset aimnum
        if isSneezeCough == 1 then
            if aimnum < maxaimnum then
                aimnum = aimnum + 4*gametimemul
            end
            maxFocusCounter = 100
        end

        ------------------------ ------------------------ ------------------------ 
        -- AIMNUM LIMITER SECT [ALL REALMIN CHANGES MUST BE DONE BEFORE THIS LINE]-
        ------------------------ ------------------------ ------------------------ 
        if realMin < focusLimit then
            realMin = realMin + (focusLimit - realMin)
        end

        -- if counter is not used, keep minaimnum as is
        if maxFocusCounter >= 100 and minaimnum ~= realMin  then
            minaimnum = minaimnum + 2*gametimemul
            if minaimnum > realMin then
                minaimnum = realMin
            end
        end

        if minaimnum > maxaimnum then
            minaimnum = maxaimnum
        end
        
        ----------------------------------
        -----RELOADING AND RACKING SECT---
        ----------------------------------
        local reloadlevel = 11-player:getPerkLevel(Perks.Reload)
        local reloadEffectModifier =  getSandboxOptions():getOptionByName("Advanced_trajectory.reloadEffectModifier"):getValue() 
        if player:getVariableBoolean("isUnloading") or player:getVariableBoolean("isLoading") or player:getVariableBoolean("isLoadingMag") or player:getVariableBoolean("isRacking") then
            aimnum = aimnum + constantTime*reloadEffectModifier*reloadlevel
            alpha = alpha - gametimemul*0.1
            maxFocusCounter = 100
        end    


        ----------------------------
        -----PENALIZE CROUCH SECT---
        ----------------------------
        local isCrouching = player:getVariableBoolean("IsCrouchAim")
        local heavyTurnEffectModifier   = getSandboxOptions():getOptionByName("Advanced_trajectory.heavyTurnEffectModifier"):getValue() 

        -- Need to check if mod is enabled or not to be safe
        if isCrouching ~= nil then
            local crouchCounterSpeed      = getSandboxOptions():getOptionByName("Advanced_trajectory.crouchCounterSpeed"):getValue() 
            local crouchPenaltyModifier   = getSandboxOptions():getOptionByName("Advanced_trajectory.crouchPenaltyModifier"):getValue() 
    
            local crouchPenaltyEffect = crouchPenaltyModifier
    
            if heavyLv > 0 then
                crouchPenaltyEffect = crouchPenaltyEffect + (heavyLv * heavyTurnEffectModifier)
            end

            -- TF of FT, then player is switching stance
            -- if TT or FF, then player is at stance
            if (isCrouching ~= Advanced_trajectory.isCrouch) and (Advanced_trajectory.crouchCounter <= 0) then
                --print("***CURRENTLY SWITCHING STANCE (CROUCH)****")
                Advanced_trajectory.crouchCounter = 100
            end

            if canRunNGun then
                crouchPenaltyEffect = crouchPenaltyEffect * 0.25
            end

            if Advanced_trajectory.crouchCounter > 0 then
                Advanced_trajectory.crouchCounter = Advanced_trajectory.crouchCounter - crouchCounterSpeed*constantTime
                aimnum = aimnum + constantTime*crouchPenaltyEffect
            end

            -- counter can not go below 0
            if Advanced_trajectory.crouchCounter < 0 then
                Advanced_trajectory.crouchCounter = 0
            end

            -- if counter reaches 0 and the stance has not been confirmed finished, confirm it. Then start focusing.
            if Advanced_trajectory.crouchCounter <= 0 and isCrouching ~= Advanced_trajectory.isCrouch then
                if isCrouching then 
                    Advanced_trajectory.isCrouch = true
                else 
                    Advanced_trajectory.isCrouch = false
                end

                local endurance = player:getStats():getEndurance()
                local staminaCrouchScale = getSandboxOptions():getOptionByName("Advanced_trajectory.staminaCrouchScale"):getValue() 
                local staminaHeavyCrouchScale    = getSandboxOptions():getOptionByName("Advanced_trajectory.staminaHeavyCrouchScale"):getValue() 

                if endurance > 0 then 
                    local effect = staminaCrouchScale * ((heavyLv*staminaHeavyCrouchScale) + 1) * (11 - player:getPerkLevel(Perks.Fitness))
                    player:getStats():setEndurance(player:getStats():getEndurance() - effect)
                end

                maxFocusCounter = 100
            end

            --print("Crouch counter: ", Advanced_trajectory.crouchCounter)
            --print("AFTER isCrouching | isCrouch: ", isCrouching, " || ", Advanced_trajectory.isCrouch)
        else
            Advanced_trajectory.isCrouch = false
        end

        ------------------
        --PENALIZE CRAWL--
        ------------------
        local isCrawling = player:getVariableBoolean("isCrawling")

        -- Need to check if mod is enabled or not to be safe
        if isCrawling ~= nil then
            if isCrawling ~= Advanced_trajectory.isCrawl then
                --print("***CURRENTLY SWITCHING STANCE (CRAWL)****")
                if isCrawling then 
                    Advanced_trajectory.isCrawl = true
                else 
                    Advanced_trajectory.isCrawl = false
                end

                local endurance = player:getStats():getEndurance()
                local staminaCrawlScale         = getSandboxOptions():getOptionByName("Advanced_trajectory.staminaCrawlScale"):getValue() 
                local staminaHeavyCrawlScale    = getSandboxOptions():getOptionByName("Advanced_trajectory.staminaHeavyCrawlScale"):getValue() 
                if endurance > 0 then 
                    local effect = staminaCrawlScale * ((heavyLv * staminaHeavyCrawlScale) + 1) * (11 - player:getPerkLevel(Perks.Fitness))
                    player:getStats():setEndurance(player:getStats():getEndurance() - effect)
                end
            end
        else
            Advanced_trajectory.isCrawl = false
        end


        ----------------------------
        -- TURNING AND MOVING SECT--
        ----------------------------
        local runNGunMultiplierBuff = 1
        if canRunNGun then
            runNGunMultiplierBuff = 0.25
        end

        local drunkActionEffectModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.drunkActionEffectModifier"):getValue() 
        if player:getVariableBoolean("isMoving") then
            local totalMoveEffect = getSandboxOptions():getOptionByName("Advanced_trajectory.moveeffect"):getValue() * runNGunMultiplierBuff * ((drunkLv*drunkActionEffectModifier)+1) * (heavyLv * heavyTurnEffectModifier + 1)
            aimnum = aimnum + gametimemul * totalMoveEffect
            maxFocusCounter = 100
        end
        

        local turningEffect = gametimemul * getSandboxOptions():getOptionByName("Advanced_trajectory.turningeffect"):getValue() * (drunkLv * drunkActionEffectModifier + 1) * (heavyLv * heavyTurnEffectModifier + 1)
        if player:getVariableBoolean("isTurning") then
            if Advanced_trajectory.isCrouch then
                aimnum = aimnum + turningEffect * getSandboxOptions():getOptionByName("Advanced_trajectory.crouchTurnEffect"):getValue() * runNGunMultiplierBuff

            elseif Advanced_trajectory.isCrawl  then
                aimnum = aimnum + turningEffect * getSandboxOptions():getOptionByName("Advanced_trajectory.proneTurnEffect"):getValue()  * runNGunMultiplierBuff
            
            else
                aimnum = aimnum + turningEffect * runNGunMultiplierBuff
            end
            maxFocusCounter = 100
        end

        --------------------------------------------
        --REDUCESPEED/AIMINGTIME ATTACHMENT EFFECT--
        --------------------------------------------
        local reduceSpeedMod = modEffectsTable[1]
        if reduceSpeedMod ~= 0 then
            reduceSpeed = reduceSpeed + reduceSpeedMod
        end

        if Advanced_trajectory.isCrouch then
            reduceSpeed = reduceSpeed + getSandboxOptions():getOptionByName("Advanced_trajectory.crouchReduceSpeedBuff"):getValue() 
        end

        if Advanced_trajectory.isCrawl  then
            reduceSpeed = reduceSpeed + getSandboxOptions():getOptionByName("Advanced_trajectory.proneReduceSpeedBuff"):getValue() 
        end

        local minReduceSpeed = 0.1
        if reduceSpeed < minReduceSpeed then
            reduceSpeed = minReduceSpeed
        end 

        if aimnum > minaimnum then
            aimnum = aimnum - gametimemul*reduceSpeed
        end
        ----------------------------
        ------- AIMNUM LIMIT SECT---
        ----------------------------
        if aimnum > maxaimnum then
            aimnum = maxaimnum
        end

        if aimnum < minaimnum then
            aimnum = minaimnum
        end
        
        ---------------------------------------------------
        --FOCUSCOUNTERSPEED/HITCHANCE ATTACHMENT EFFECT----
        ---------------------------------------------------
        focusCounterSpeedMod = modEffectsTable[2]
        if focusCounterSpeedMod ~= 0 then
            focusCounterSpeed = focusCounterSpeed + focusCounterSpeedMod
        end

        -- Prone stance means faster focus time
        local proneFocusCounterSpeedBuff = getSandboxOptions():getOptionByName("Advanced_trajectory.proneFocusCounterSpeedBuff"):getValue() 
        if Advanced_trajectory.isCrawl and hasFocusSkill then
            focusCounterSpeed = focusCounterSpeed * 1.5
            focusLimit = focusLimit * getSandboxOptions():getOptionByName("Advanced_trajectory.proneFocusLimitBuff"):getValue() 
        end

        if Advanced_trajectory.isCrouch and hasFocusSkill then
            focusLimit = focusLimit * getSandboxOptions():getOptionByName("Advanced_trajectory.crouchFocusLimitBuff"):getValue() 
        end

        -- crouching means no need to wait to get to 0 when below minaimnum (helpful when bursting)
        if hasFocusSkill then
            if Advanced_trajectory.isCrouch and aimnum < (realLevel*1.5 - (recoilDelay*2)/10) then
                maxFocusCounter = 0
            
            elseif Advanced_trajectory.isCrawl and aimnum < (realLevel*1.75 - (recoilDelay*2)/10) then
                maxFocusCounter = 0
            end
        end

        -- player unlocks max focus skill when reaching certain level
        if aimnum <= minaimnum and maxFocusCounter > 0 and hasFocusSkill then
            maxFocusCounter = maxFocusCounter - focusCounterSpeed*constantTime
        end

        -- counter can not go below 0
        if maxFocusCounter < 0 then
            maxFocusCounter = 0
        end

        -- if counter reaches 0, reduce minaimnum until its no longer greater than 0
        if maxFocusCounter <= 0  and minaimnum > focusLimit then
            minaimnum = minaimnum - gametimemul*maxFocusSpeed
        end

        --print('maxFocusCounter: ', maxFocusCounter)

        if focusLimit > maxaimnum then
            focusLimit = maxaimnum
        end

        if minaimnum < focusLimit then
            minaimnum = minaimnum + gametimemul

            if minaimnum > focusLimit then
                minaimnum = focusLimit
            end
        end

        ------------------------
        ----- ENDURANCE SECT----
        ------------------------

        local enduranceBreathModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.enduranceBreathModifier"):getValue() 
        local inhaleModifier1 = getSandboxOptions():getOptionByName("Advanced_trajectory.inhaleModifier1"):getValue() 
        local inhaleModifier2 = getSandboxOptions():getOptionByName("Advanced_trajectory.inhaleModifier2"):getValue() 
        local inhaleModifier3 = getSandboxOptions():getOptionByName("Advanced_trajectory.inhaleModifier3"):getValue() 
        local inhaleModifier4 = getSandboxOptions():getOptionByName("Advanced_trajectory.inhaleModifier4"):getValue() 

        local exhaleModifier1 = getSandboxOptions():getOptionByName("Advanced_trajectory.exhaleModifier1"):getValue() 
        local exhaleModifier2 = getSandboxOptions():getOptionByName("Advanced_trajectory.exhaleModifier2"):getValue() 
        local exhaleModifier3 = getSandboxOptions():getOptionByName("Advanced_trajectory.exhaleModifier3"):getValue() 
        local exhaleModifier4 = getSandboxOptions():getOptionByName("Advanced_trajectory.exhaleModifier4"):getValue() 

        local inhaleCounter = Advanced_trajectory.inhaleCounter
        local exhaleCounter = Advanced_trajectory.exhaleCounter

        if enduranceLv > 0 and aimnum <= minaimnum+5+(enduranceLv*3) and inhaleCounter <= 0 and exhaleCounter <= 0 then
            inhaleCounter = 100
            reduceSpeed = reduceSpeed * (1 - enduranceLv*7/100)
        end

        -- inhale, count from 100 to 0
        if inhaleCounter > 0 then

            -- three diff levels of inhale and exhale speed
            if enduranceLv == 1 then
                inhaleCounter = inhaleCounter - inhaleModifier1*constantTime
            end
            if enduranceLv == 2 then
                inhaleCounter = inhaleCounter - inhaleModifier2*constantTime
            end
            if enduranceLv == 3 then
                inhaleCounter = inhaleCounter - inhaleModifier3*constantTime
            end
            if enduranceLv == 4 then
                inhaleCounter = inhaleCounter - inhaleModifier4*constantTime
            end

            aimnum = aimnum + enduranceBreathModifier * constantTime
        
            -- exhale, steady aim
        elseif exhaleCounter > 0 then

            -- higher endurance level means less time to have steady aim
            -- three diff levels of inhale and exhale speed
            if enduranceLv == 1 then
                exhaleCounter = exhaleCounter - exhaleModifier1*constantTime
            end
            if enduranceLv == 2 then
                exhaleCounter = exhaleCounter - exhaleModifier2*constantTime
            end
            if enduranceLv == 3 then
                exhaleCounter = exhaleCounter - exhaleModifier3*constantTime
            end
            if enduranceLv == 4 then
                exhaleCounter = exhaleCounter - exhaleModifier4*constantTime
            end

        elseif inhaleCounter <= 0 and exhaleCounter <= 0 then
            exhaleCounter = 100
        end
      
        if enduranceLv == 0 then
            inhaleCounter = 0
            exhaleCounter = 0
        end

        --print("inhaleCounter / exhaleCounter: ", inhaleCounter, " / ", exhaleCounter)
        
        -- Purpose is to keep crosshair visible
        alpha = alpha + gametimemul*0.05

        local alphaMax = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairMaxTransparency"):getValue() 

        if aimnum >= Advanced_trajectory.missMin and getSandboxOptions():getOptionByName("Advanced_trajectory.enableHitOrMiss"):getValue() then 
            alphaMax = getSandboxOptions():getOptionByName("Advanced_trajectory.missMinTransparency"):getValue() 
        end

        if alpha > alphaMax then
            --alpha = alpha - gametimemul*0.1
            alpha = alphaMax
        end

        --alpha = mathfloor(alpha * 100) / 100

        if alpha < 0 then
            alpha = 0
        end

        Advanced_trajectory.alpha = alpha
        Advanced_trajectory.aimnum = aimnum
        Advanced_trajectory.inhaleCounter = inhaleCounter
        Advanced_trajectory.exhaleCounter = exhaleCounter
        Advanced_trajectory.minaimnum = minaimnum
        Advanced_trajectory.maxaimnum = maxaimnum
        Advanced_trajectory.maxFocusCounter = maxFocusCounter

        -- print("Trans/Alpha: ", Advanced_trajectory.alpha)
        -- print("Shaky Effect: ", Advanced_trajectory.stressEffect + Advanced_trajectory.painEffect + Advanced_trajectory.panicEffect)
        -- print("totalArmPain [arms]: ", totalArmPain, ", HL", handPainL ,", FL", forearmPainL ,", UL", upperarmPainL ,", HR", handPainR ,", FR", forearmPainR ,", UR", upperarmPainR)
        -- print("isSneezeCough: ", isSneezeCough)
        -- print("P", panicLv, ", E", enduranceLv ,", H", hyperLv ,", H", hypoLv ,", S", stressLv,", T", tiredLv)
        -- print("Aim Level (code): ", reversedLevel)
        -- print("Aim Level (real): ", realLevel)
        -- print("Def/Curr ReduceSpeed: ", speed, "/", reduceSpeed)
        -- print("FocusCounterSpeed: ", focusCounterSpeed)
        -- print("FocusLimit/Min/Max/Aimnum: ", focusLimit, " / ", Advanced_trajectory.minaimnum, " / ", Advanced_trajectory.maxaimnum, " / ", Advanced_trajectory.aimnum)   
		
        if not Advanced_trajectory.panel.instance and getSandboxOptions():getOptionByName("Advanced_trajectory.aimpoint"):getValue() then
            Advanced_trajectory.panel.instance = Advanced_trajectory.panel:new(0, 0, 200, 200)
            Advanced_trajectory.panel.instance:initialise()
            Advanced_trajectory.panel.instance:addToUIManager()
        end		
		
        local isspwaepon = Advanced_trajectory.FullWeaponTypes[weaitem:getFullType()]

        if weaitem:getSwingAnim() =="Throw"  or (isspwaepon and isspwaepon["islightsq"]) then

            weaitem:setPhysicsObject(nil)  
            weaitem:setMaxHitCount(0)

            --getPlayer():getPrimaryHandItem():getSmokeRange()

            if not Advanced_trajectory.aimcursor then
                -- Advanced_trajectory.thorwerinfo = {
                --     weaitem:getSmokeRange(),
                --     weaitem:getExplosionPower(),
                --     weaitem:getExplosionRange(),
                --     weaitem:getFirePower(),
                --     weaitem:getFireRange()
                -- }
                Advanced_trajectory.aimcursor = ISThorowitemToCursor:new("", "", player,weaitem)
                getCell():setDrag(Advanced_trajectory.aimcursor, 0)
            end
        end

        Advanced_trajectory.chooseAimZLevel(player)   
                
    else 
        if Advanced_trajectory.aimcursor then
            getCell():setDrag(nil, 0);
            Advanced_trajectory.aimcursor=nil
            Advanced_trajectory.thorwerinfo={}
        end
        if Advanced_trajectory.panel.instance then
            Advanced_trajectory.panel.instance:removeFromUIManager()
            Advanced_trajectory.panel.instance=nil
        end
		local constantTime = gameTimeMultiplier/(1+10)				
        -- local nonAdsEffect = 2 huh?
        Advanced_trajectory.aimnum = Advanced_trajectory.aimnum + constantTime
        Advanced_trajectory.maxFocusCounter = 100
        Advanced_trajectory.alpha = 0
    end
    
end

function Advanced_trajectory.chooseAimZLevel(player)
    local minZ = 0
    local maxZ = 7

    if getSandboxOptions():getOptionByName("Advanced_trajectory.enableAutoAimZLevel"):getValue() then
        Advanced_trajectory.autoChooseAimZLevel(player, minZ, maxZ)
    else
        if Advanced_trajectory.manualChooseAimZLevel(player, minZ, maxZ) then
            aimLevelText:AddBatchedDraw(getMouseX() + 35, getMouseY() + 35, true)
        end
    end
end

function Advanced_trajectory.manualChooseAimZLevel(player, minZ, maxZ)
    local playerZ = mathfloor(player:getZ())
    local isKeyDown = isKeyDown(Keyboard.KEY_LSHIFT)
    local chosenZ = Advanced_trajectory.aimlevels

    local str = ''

    local currZoom = getCore():getZoom(0)

    if isKeyDown then
        -- scroll up
        if Mouse.getWheelState() > 0 then
            chosenZ = chosenZ + 1
            if currZoom ~= getCore():getMinZoom() then getCore():doZoomScroll(0, 1) end

        -- scroll down
        elseif Mouse.getWheelState() < 0 then
            chosenZ = chosenZ - 1
            if currZoom ~= getCore():getMaxZoom() then getCore():doZoomScroll(0, -1) end

        elseif Mouse.isMiddlePressed() then
            chosenZ = playerZ

        end

        if chosenZ > maxZ then chosenZ = maxZ end
        if chosenZ < minZ then chosenZ = minZ end
    end

    if chosenZ == playerZ then
        str = '0'
    elseif chosenZ == 0 then
        str = 'G'
    elseif chosenZ > playerZ  then
        str = '+' .. chosenZ - playerZ
    elseif chosenZ < playerZ  then
        str = '-' .. playerZ - chosenZ
    end

    Advanced_trajectory.aimlevels = chosenZ

    if isKeyDown then
        aimLevelText:ReadString(UIFont.Large, str, -1)
        aimLevelText:setDefaultColors(1, 1, 1, 1)
    else
        aimLevelText:ReadString(UIFont.Medium, str, -1)
        aimLevelText:setDefaultColors(1, 1, 1, aimLevelTextTrans)
    end

    if chosenZ ~= playerZ or isKeyDown then 
        return true
    else
        return false
end
end

function Advanced_trajectory.autoChooseAimZLevel(player, minZ, maxZ)
    -- Get the scaled mouse coordinates
    local mouseX = getMouseXScaled()
    local mouseY = getMouseYScaled()

    -- Get the player's Z position and player number
    local playerZ = mathfloor(player:getZ())
    local playerX = mathfloor(player:getX())
    local playerY = mathfloor(player:getY())
    local playerNum = player:getPlayerNum()

    local str = ''

    local chosenZ = playerZ

    -- Get the current world cell
    local cell = getWorld():getCell()

    local function loopForTargets(start, stop, num)
        -- Loop through Z levels from 0 to 7 to search for targets
        for Z = start, stop, num do
            -- Calculate the distance difference between Z level and player's Z position
            local levelDiff = Z - playerZ

            -- Calculate world coordinates adjusted for the Z level
            local wx, wy = ISCoordConversion.ToWorld(mouseX - 3 * levelDiff, mouseY - 3 * levelDiff, Z)
            wx, wy = mathfloor(wx), mathfloor(wy)

            -- Iterate through nearby Y and Z offsets
            for x = -1, 1 do
                for y = -1, 1 do
                    -- Get the grid square at the adjusted position
                    local sq = cell:getGridSquare(wx + x + 2.2, wy + y + 2.2, Z)

                    -- make sure sq is not null
                    if sq then
                        -- if sq seen on floor Z, return true if zom is detected on that floor
                        if sq:isCanSee(playerNum) then
                            local movingObjects = sq:getMovingObjects()

                            -- Iterate through moving objects in the grid square
                            for obj = 1, movingObjects:size() do
                                local target = movingObjects:get(obj - 1)
    
                                -- Check if the object is an IsoZombie or IsoPlayer
                                if instanceof(target, "IsoGameCharacter") then
                                    -- Set the aim level and flag, then return
                                    chosenZ = Z
                                    return true
                                end
                            end
                        elseif Z == playerZ then
                            -- if sq can't be seen, just set Z to player's Z
                            local movingObjects = sq:getMovingObjects()
                            for obj = 1, movingObjects:size() do
                                local target = movingObjects:get(obj - 1)
    
                                if instanceof(target, "IsoGameCharacter") then
                                    chosenZ = Z
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if not loopForTargets(playerZ, minZ, -1) then
        loopForTargets(playerZ+1, maxZ, 1)
    end

    if chosenZ == playerZ then
        str = '0'
    elseif chosenZ == 0 then
        str = 'G'
    elseif chosenZ > playerZ  then
        str = '+' .. chosenZ - playerZ
    elseif chosenZ < playerZ  then
        str = '-' .. playerZ - chosenZ
    end

    Advanced_trajectory.aimlevels = chosenZ
end

function Advanced_trajectory.checkBowAndCrossbow(player, Zombie)
    -------------------------------------------------------------------------------------
    ------COMPATABILITY FOR BRITA'S BOWS AND CROSSBOWS (CREDITS TO LISOLA/BRITA)---------
    -------------------------------------------------------------------------------------
    local weaitem = player:getPrimaryHandItem()

    local proj  = ""
    local isBow = false
    local broke = false
    if string.contains(weaitem:getAmmoType() or "","Arrow_Fiberglass") then
        proj  = InventoryItemFactory.CreateItem("Arrow_Fiberglass")
        isBow = true
    end

    if string.contains(weaitem:getAmmoType() or "","Bolt_Bear") then
        proj  = InventoryItemFactory.CreateItem("Bolt_Bear")
        isBow = true
    end

    local bowBreakChance = 100 - getSandboxOptions():getOptionByName("Advanced_trajectory.bowBreakChance"):getValue()
    if isBow and ZombRand(100+Advanced_trajectory.aimnumBeforeShot) >= bowBreakChance then
        proj  = InventoryItemFactory.CreateItem(proj:getModData().Break)
        broke = true
    end

    if isBow then
        if isClient() then
            sendClientCommand("ATY_bowzombie", "attachProjZombie", {player:getOnlineID(), Zombie:getOnlineID(), {Zombie:getX(), Zombie:getY(), Zombie:getZ()}, proj, broke})
        end

        if Zombie and Zombie:isAlive() then
            if Zombie:getModData().stuck_Body01 == nil then
                Zombie:setAttachedItem("Stuck Body01", proj)
                Zombie:getModData().stuck_Body01 = 1
            elseif	Zombie:getModData().stuck_Body02 == nil then
                Zombie:setAttachedItem("Stuck Body02", proj)
                Zombie:getModData().stuck_Body02 = 1
            elseif	Zombie:getModData().stuck_Body03 == nil then
                Zombie:setAttachedItem("Stuck Body03", proj)
                Zombie:getModData().stuck_Body03 = 1
            elseif	Zombie:getModData().stuck_Body04 == nil then
                Zombie:setAttachedItem("Stuck Body04", proj)
                Zombie:getModData().stuck_Body04 = 1
            elseif	Zombie:getModData().stuck_Body05 == nil then
                Zombie:setAttachedItem("Stuck Body05", proj)
                Zombie:getModData().stuck_Body05 = 1
            elseif	Zombie:getModData().stuck_Body06 == nil then
                Zombie:setAttachedItem("Stuck Body06", proj)
                Zombie:getModData().stuck_Body06 = 1
            else
                Zombie:getCurrentSquare():AddWorldInventoryItem(proj, 0.0, 0.0, 0.0)
            end
        else
            Zombie:getInventory():AddItem(proj)
        end
    end
end

function Advanced_trajectory.displayDamageOnZom(zombie, damagezb)
    local damagea = TextDrawObject.new()
    damagea:setDefaultColors(1,1,0.1,0.7)
    damagea:setOutlineColors(0,0,0,1)
    damagea:ReadString(UIFont.Middle, "-" ..tostring(mathfloor(damagezb*100)), -1)
    local sx = IsoUtils.XToScreen(zombie:getX(), zombie:getY(), zombie:getZ(), 0);
    local sy = IsoUtils.YToScreen(zombie:getX(), zombie:getY(), zombie:getZ(), 0);
    sx = sx - IsoCamera.getOffX() - zombie:getOffsetX();
    sy = sy - IsoCamera.getOffY() - zombie:getOffsetY();
    sy = sy - 64
    sx = sx / getCore():getZoom(0)
    sy = sy / getCore():getZoom(0)
    sy = sy - damagea:getHeight()

    table.insert(Advanced_trajectory.damagedisplayer, {60, damagea, sx, sy, sx, sy})
end

function Advanced_trajectory.searchAndDmgClothing(playerShot, shotpart)

    local hasBulletProof= false
    local playerWornInv = playerShot:getWornItems();

    -- use this to compare shot part and covered part
    local nameShotPart = BodyPartType.getDisplayName(shotpart)

    -- use this to find coveredPart
    local strShotPart = BodyPartType.ToString(shotpart)

    local shotBloodPart = nil

    local shotBulletProofItems = {}
    local shotNormalItems = {}

    for i=0, playerWornInv:size()-1 do
        local item = playerWornInv:getItemByIndex(i);

        if item and instanceof(item, "Clothing") then
            local listBloodClothTypes = item:getBloodClothingType()

            -- arraylist of BloodBodyPartTypes
            local listOfCoveredAreas = BloodClothingType.getCoveredParts(listBloodClothTypes)   
    
            -- size of list
            local areaCount = BloodClothingType.getCoveredPartCount(listBloodClothTypes)   
    
            for i=0, areaCount-1 do
                -- returns BloodBodyPartType
                local coveredPart = listOfCoveredAreas:get(i)
                local nameCoveredPart = coveredPart:getDisplayName()
    
                if nameCoveredPart == nameShotPart then
                    shotBloodPart = coveredPart
                    
                    -- check if has bullet proof armor
                    local bulletDefense = item:getBulletDefense()
                    --print("Bullet Defense: ", bulletDefense)
                    if bulletDefense > 0 then
                        hasBulletProof = true
                        table.insert(shotBulletProofItems, item)
                    else
                        table.insert(shotNormalItems, item)
                    end
                end
            end
        end
    end

    --print("HAS BULLET PROOF: ", hasBulletProof)
    if hasBulletProof then
        for i = 1, #shotBulletProofItems do
            local item = shotBulletProofItems[i]

            -- Minimum reduction value is 1 due to integer type
            item:setCondition(item:getCondition() - 1)          

            --print(item:getName(), "'s MaxCondition / Curr: ", item:getConditionMax(), " / ", item:getCondition())
        end
    else
        for i = 1, #shotNormalItems do
            local item = shotNormalItems[i]

            -- hole is added only if the shot part initially had no hole. added hole means damage to clothing
            -- decided to add holes only so players can still wear their battlescarred clothing
            if item:getHolesNumber() < item:getNbrOfCoveredParts() then
                playerShot:addHole(shotBloodPart, true)
            end

            --print(item:getName(), "'s MaxCondition / Curr: ", item:getConditionMax(), " / ", item:getCondition())
            --print(nameShotPart, " [", item:getName() ,"] clothing damaged.")
        end
    end

    if getSandboxOptions():getOptionByName("Advanced_trajectory.DebugSayShotPart"):getValue() then
        playerShot:Say("Ow! My " .. nameShotPart .. "!")
    end
end

-- function is here for testing through voodoo
function Advanced_trajectory.damagePlayershot(playerShot, damage, baseGunDmg, playerDmgMultipliers)
    local highShot = {
        BodyPartType.Head, BodyPartType.Head,
        BodyPartType.Neck
    }
        
    -- chest is biggest target so increase its chances of being wounded; will make vest armor useful
    local midShot = {
        BodyPartType.Torso_Upper, BodyPartType.Torso_Lower,
        BodyPartType.Torso_Upper, BodyPartType.Torso_Lower,
        BodyPartType.Torso_Upper, BodyPartType.Torso_Lower,
        BodyPartType.Torso_Upper, BodyPartType.Torso_Lower,
        BodyPartType.Torso_Upper, BodyPartType.Torso_Lower,
        BodyPartType.Torso_Upper, BodyPartType.Torso_Lower,
        BodyPartType.UpperArm_L, BodyPartType.UpperArm_R,
        BodyPartType.ForeArm_L,  BodyPartType.ForeArm_R,
        BodyPartType.Hand_L,     BodyPartType.Hand_R
    }
    
    local lowShot = {
        BodyPartType.UpperLeg_L, BodyPartType.UpperLeg_R,
        BodyPartType.UpperLeg_L, BodyPartType.UpperLeg_R,
        BodyPartType.LowerLeg_L, BodyPartType.LowerLeg_R,
        BodyPartType.Foot_L,     BodyPartType.Foot_R,
        BodyPartType.Groin
    }

    local shotpart = BodyPartType.Torso_Upper

    local footChance = 5
    local headChance = 10

    local incHeadChance = 0
    if damage == playerDmgMultipliers.head then
        incHeadChance = getSandboxOptions():getOptionByName("Advanced_trajectory.headShotIncChance"):getValue()
    end

    if damage > 0 then

        local randNum = ZombRand(100)

        -- lowShot
        if randNum <= (footChance) then                   
            shotpart = lowShot[ZombRand(#lowShot) + 1]
        
        -- highShot
        elseif randNum > (footChance) and randNum <= (footChance) + (headChance + incHeadChance) then
            shotpart = highShot[ZombRand(#highShot)+1]
        
        -- midShot
        else
            shotpart = midShot[ZombRand(#midShot)+1]
        end

    end

    --print("DmgMult / BaseDmg: ", damage, " / ", baseGunDmg)
    Advanced_trajectory.searchAndDmgClothing(playerShot, shotpart)
    
    local bodypart = playerShot:getBodyDamage():getBodyPart(shotpart)
    local nameShotPart = BodyPartType.getDisplayName(shotpart)

    -- float (part, isBite, isBullet)
    -- bulletdefense is usually 100
    local defense = playerShot:getBodyPartClothingDefense(shotpart:index(),false,true)

    --print("BodyPartClothingDefense: ", defense)

    if defense < 0.5 then
        --print("WOUNDED")

        if bodypart:haveBullet() then
            local bleedTime = bodypart:getBleedingTime()
            bodypart:setBleedingTime(bleedTime)
        else
            -- Decides whether to add a bullet based on chance in sandbox settings
            if ZombRand(100) >= getSandboxOptions():getOptionByName("Advanced_trajectory.throughChance"):getValue() then
                bodypart:setHaveBullet(true, 0)
            else
                bodypart:generateDeepWound()
            end
        end
        
        -- Decides whether to inflict a fracture based on chance in sandbox settings
		if ZombRand(100) <= getSandboxOptions():getOptionByName("Advanced_trajectory.fractureChance"):getValue() then
            bodypart:setFractureTime(21)
		end

        -- Destroy bandage if bandaged
        if bodypart:bandaged() then
            bodypart:setBandaged(false, 0)
        end
    end

    local maxDefense = getSandboxOptions():getOptionByName("Advanced_trajectory.maxDefenseReduction"):getValue()
    if defense > maxDefense then
        defense = maxDefense
    end

    local playerDamageDealt = baseGunDmg * damage * (1 - defense)

    playerShot:getBodyDamage():ReduceGeneralHealth(playerDamageDealt)

    local stats = playerShot:getStats()
	local pain = math.min(stats:getPain() + playerShot:getBodyDamage():getInitialBitePain() * BodyPartType.getPainModifyer(shotpart:index()), 100)
	stats:setPain(pain)

    playerShot:updateMovementRates()
    playerShot:getBodyDamage():Update()

    playerShot:addBlood(50)

    return nameShotPart, playerDamageDealt
end

function getHitReaction(isCrit, limbShot, damage, weaponName)
    local hitReactions = Advanced_trajectory.hitReactions
    -- 0 to 2
    -- val 0.3 would be at least 30 hp (zom hp usually 1.0)
    local minDamage = getSandboxOptions():getOptionByName("Advanced_trajectory.minDamageToGetHitReaction"):getValue()

    if limbShot == 'head' or isCrit then 
        return hitReactions.head[ZombRand(#hitReactions.head)+1]
    end

    if damage >= minDamage or weaponName == 'Shotgun' then
        return hitReactions.body[ZombRand(#hitReactions.body)+1]
    end

    return false
end

function Advanced_trajectory.damageZombie(zombie, damage, isCrit, limbShot, player, weaponName) 
    --print('damageZom - damage: ', damage)
    --print('damageZom - zomHP bef: ', zombie:getHealth())

    local reaction = getHitReaction(isCrit, limbShot, damage, weaponName)
    --print('reaction: ', reaction)
    
    -- Hit(HandWeapon weapon, IsoGameCharacter wielder, float damageSplit, boolean bIgnoreDamage, float modDelta, boolean bRemote)
    --     damageSplit: is where damage is dealt to zombie (set to damage val)
    --     bIgnoreDamage: if true, zombie will receive no damage (set to false)
    --     modDelta: is where damage is dealt to zombie (also set to damage val)
    --     bRemote: if true, zombie will not have any hit reactions  (set to true)

    zombie:Hit(player:getPrimaryHandItem(), player, damage, false, damage, true)
    if reaction then
        zombie:setHitReaction(reaction)
    end
    zombie:addBlood(getSandboxOptions():getOptionByName("AT_Blood"):getValue())
    zombie:setAttackedBy(player)

    --print('damageZom - zomHP aft: ', zombie:getHealth())
end

function Advanced_trajectory.drawDamageText()
    local timemultiplier = gameTime:getMultiplier()

    for indx, val in pairs(Advanced_trajectory.damagedisplayer) do
        val[1] = val[1] - timemultiplier
        if val[1] < 0 then
            val = nil
        else
            val[3] = val[3] + timemultiplier
            val[4] = val[4] - timemultiplier
            val[2]:AddBatchedDraw(val[3], val[4], true)

            -- print(Advanced_trajectory.damagedisplayer[3] - Advanced_trajectory.damagedisplayer[5]) 
        end
    end
end

function Advanced_trajectory.blowUp(tableProj)
    if tableProj.throwinfo[2] > 0 then
        Advanced_trajectory.boomsfx(tableProj.square, tableProj["boomsfx"][1], tableProj["boomsfx"][2], tableProj["boomsfx"][3])
    end

    if not tableProj["nonsfx"]  then
        -- print("Boom")
        Advanced_trajectory.Boom(tableProj.square, tableProj.throwinfo)
    end
end

function Advanced_trajectory.removeBulletData(item)
    Advanced_trajectory.itemremove(item) 
    return nil
end

function Advanced_trajectory.killZombie(zombie, player, damage)
    if isClient() then
        sendClientCommand("ATY_killzombie","true",{zombie:getOnlineID()})
    end

    -- sets zombie hp to 0, zombie death animation is played and then zombie turns into corpse object (no longer zombie)
    zombie:Kill(player)
                
    player:setZombieKills(player:getZombieKills()+1)
    player:setLastHitCount(1)

    if not Advanced_trajectory.hasFlameWeapon then
        local killXP = getSandboxOptions():getOptionByName("Advanced_trajectory.XPKillModifier"):getValue()

        -- multiplier to 0.67
        -- OnWeaponHitXp From "KillCount",used(wielder, weapon, victim, damage)
        triggerEvent("OnWeaponHitXp", player, player:getPrimaryHandItem(), zombie, damage) 
    
        if isServer() == false then
            Events.OnWeaponHitXp.Add(player:getXp():AddXP(Perks.Aiming, killXP));
        end
    end
end

function Advanced_trajectory.giveOnHitXP(player, zombie, damage)
    local hitXP = getSandboxOptions():getOptionByName("Advanced_trajectory.XPHitModifier"):getValue()

    triggerEvent("OnWeaponHitCharacter", player, zombie, player:getPrimaryHandItem(), damage) 

    if isServer() == false then
        Events.OnWeaponHitXp.Add(player:getXp():AddXP(Perks.Aiming, hitXP));
    end
end

function Advanced_trajectory.decrementAfterEntityHit(tableProj, tableIndx)
    -- Decrement remaining entity passes and damp damage
    if not tableProj.entityPassRemaining then AT_dbg('Init entityPassRemaining for projectile', tableIndx)
        tableProj.entityPassRemaining = 1
    end
    tableProj.entityPassRemaining = tableProj.entityPassRemaining - 1

    local penDmgReduction = getSandboxOptions():getOptionByName("Advanced_trajectory.penDamageReductionMultiplier"):getValue()
    tableProj.damage = (tableProj.damage or 0) * penDmgReduction

    local minStop = tableProj.minDamageStop or 0.05
    if tableProj.entityPassRemaining <= 0 or (tableProj.damage or 0) <= minStop then AT_dbg('Entity pass exhausted OR damage floor; removing projectile', tableIndx)
        Advanced_trajectory.table[tableIndx] = nil
        return true
    end
    return false
end

function Advanced_trajectory.dealWithZombieShot(tableProj, tableIndx, zombie, damage, limbShot)
    if tableProj["wallcarzombie"] or tableProj.weaponName == "Grenade"then

        tableProj.throwinfo["zombie"] = zombie

        if tableProj.throwinfo[2] > 0 then
            Advanced_trajectory.boomsfx(tableProj.square)
        end
        if not tableProj["nonsfx"] then
            Advanced_trajectory.Boom(tableProj.square, tableProj.throwinfo)
        end
        
        Advanced_trajectory.table[tableIndx] = Advanced_trajectory.removeBulletData(tableProj.item) 

        return true

    elseif not tableProj["nonsfx"]  then
        local player = tableProj.player

        if tableProj.weaponName == "flamethrower" then
            zombie:setOnFire(true)

            -- Uncomment this section if you want to handle GrenadeLauncher differently
            -- elseif tableProj.weaponName == "GrenadeLauncher" then
            --     tanksuperboom(tableProj.square)
            -- end
        end

        damage = damage * tableProj.damage * 0.1

        -- give aim xp upon hit if weapon used is not flamethrower
        if not Advanced_trajectory.hasFlameWeapon then
            Advanced_trajectory.giveOnHitXP(player, zombie, damage)
        end

        -- display damage done to zombie from bullet 
        if getSandboxOptions():getOptionByName("ATY_damagedisplay"):getValue() then
            Advanced_trajectory.displayDamageOnZom(zombie, damage)
        end

        if isClient() then
            --print('In MP, sending clientCmd for cshotzombie')
            sendClientCommand("ATY_cshotzombie", "true", {zombie:getOnlineID(), player:getOnlineID(), damage, tableProj.isCrit, limbShot})
        else
            Advanced_trajectory.damageZombie(zombie, damage, tableProj.isCrit, limbShot, tableProj.player, tableProj.weaponName)
        end
        
        -- if zombie's health is very low, just kill it (recall full health is over 140) and give xp like usual
        if zombie:getHealth() <= 0.1 then                                                 
            if player then
                Advanced_trajectory.killZombie(zombie, player, damage)
            end 
        end

        -- no longer needed after reworking how zombie is hit
        -- >> zombie:Hit(player:getPrimaryHandItem(), player, damage, false, damage, true)
        --[[
        if getSandboxOptions():getOptionByName("Advanced_trajectory.DebugEnableBow"):getValue() then
            Advanced_trajectory.checkBowAndCrossbow(player, zombie)
        end  
        ]]
    end
end

function Advanced_trajectory.dealWithPlayerShot(tableProj, playerShot, damage, playerDmgMultipliers)
    -- isClient() returns true if the code is being run in MP
    if isClient() then
        sendClientCommand("ATY_shotplayer", "true", {tableProj.player:getOnlineID(), playerShot:getOnlineID(), damage, tableProj.damage, playerDmgMultipliers})
    else
        Advanced_trajectory.damagePlayershot(playerShot, damage, tableProj.damage, playerDmgMultipliers)
    end
end
function Advanced_trajectory.dealWithTargetShot(tableProj, tableIndx)
    local bulletPosZ = tableProj.bulletPos[3]

    -- get Z level difference between aimed target and bullet (bulletZ is always from player level)
    local zLevelDiff = tableProj["aimLevel"] - mathfloor(bulletPosZ)
    local shootLevel = bulletPosZ + zLevelDiff
    if tableProj["isparabola"] then
        shootLevel = bulletPosZ
    end

    -- displacement between each floor is 3 cells
    zLevelDiff = zLevelDiff * 3

    local bulletTable = {
        x = tableProj.bulletPos[1] + zLevelDiff,
        y = tableProj.bulletPos[2] + zLevelDiff,
        z = shootLevel,
        dir = tableProj.bulletDir,
        dirVector = tableProj.dirVector
    }

    -- returns zombie/player that was shot
    local target, targetType = Advanced_trajectory.searchTargetNearBullet(
        bulletTable,
        tableProj.playerPos,
        tableProj["missedShot"]
    )

    local zomDmgMultipliers = {
        head = getSandboxOptions():getOptionByName("Advanced_trajectory.headShotDmgZomMultiplier"):getValue(),
        body = getSandboxOptions():getOptionByName("Advanced_trajectory.bodyShotDmgZomMultiplier"):getValue()
    }

    local playerDmgMultipliers = {
        head = getSandboxOptions():getOptionByName("Advanced_trajectory.headShotDmgPlayerMultiplier"):getValue(),
        body = getSandboxOptions():getOptionByName("Advanced_trajectory.bodyShotDmgPlayerMultiplier"):getValue()
    }

    local damagezb = 0
    local damagepr = 0
    local limbShot = ""
    local saywhat = ""

    if target then
        if Advanced_trajectory.aimnumBeforeShot < 5 then
            damagezb = zomDmgMultipliers.head
            damagepr = playerDmgMultipliers.head
            saywhat = "IGUI_Headshot (STRONG): " .. Advanced_trajectory.aimnumBeforeShot
            limbShot = "head"
        else
            damagezb = zomDmgMultipliers.body
            damagepr = playerDmgMultipliers.body
            saywhat = "IGUI_Headshot (WEAK): " .. Advanced_trajectory.aimnumBeforeShot
            limbShot = "body"
        end
    else
        return
    end

    -------------------------------------
    --- DEAL WITH ALIVE PLAYER WHEN HIT ---
    -------------------------------------
    if targetType == "player" and tableProj.player and not tableProj["nonsfx"] then
        Advanced_trajectory.dealWithPlayerShot(tableProj, target, damagepr, playerDmgMultipliers)
        Advanced_trajectory.table[tableIndx] =
            Advanced_trajectory.removeBulletData(tableProj.item)
        return true
    end

    -------------------------------------
    --- DEAL WITH ALIVE ZOMBIE WHEN HIT ---
    -------------------------------------
    if targetType == "zombie" and target:isAlive() then
        -- optional callshot dialogue
        if tableProj.player and getSandboxOptions():getOptionByName("Advanced_trajectory.callshot"):getValue() then
            tableProj.player:Say(getText(saywhat))
        end

        -- “voodoo” debug feature (player self-damage mirror)
        if getSandboxOptions():getOptionByName("Advanced_trajectory.DebugEnableVoodoo"):getValue() then
            Advanced_trajectory.dealWithPlayerShot(
                tableProj,
                tableProj.player,
                damagepr,
                playerDmgMultipliers
            )
        end

        -- main damage + penetration logic
        if Advanced_trajectory.dealWithZombieShot(tableProj, tableIndx, target, damagezb, limbShot) then
            return true
        end

        Advanced_trajectory.itemremove(tableProj.item)

        -- NEW: use your penetration counter system
        if Advanced_trajectory.decrementAfterEntityHit(tableProj, tableIndx) then
            return true -- stop projectile if out of hits
        end
    end
end

-- === NEW: object penetration gate (isolated) ===
-- Object penetration gate: STOP (true) or PASS (false)
function Advanced_trajectory.updateProjectiles()
    -- changes made to currTable will also apply to the global Advanced_trajectory.table
    local currTable = Advanced_trajectory.table

    -- print(#currTable)
    -- print(gameTime:getMultiplier())

    for indx, tableProj in pairs(currTable) do

        -- Remove bullet projectile to simulate it going from one point to another
        -- If commented out, this will lead to a continous printing of projectiles at every tile it spawns (imagine a long trail of bullets)
        Advanced_trajectory.itemremove(tableProj.item)

        if tableProj.square == nil then 
            currTable[indx] = nil
            break
        end

        local bulletSpeed = tableProj.bulletSpeed 
        local halfBulletSpeed = bulletSpeed / 2

        local bulletPosX = tableProj.bulletPos[1]
        local bulletPosY = tableProj.bulletPos[2]
        local bulletPosZ = tableProj.bulletPos[3]

        -- [1]: current sq position (P)
        -- [2]: prev sq half pos (P/2)
        local squares = {}


        -- update to square that bullet is currently on
        if Advanced_trajectory.aimlevels then
            squares[1] = getWorld():getCell():getOrCreateGridSquare(bulletPosX, bulletPosY, Advanced_trajectory.aimlevels)
            if bulletSpeed > 1 then 
                squares[2] = getWorld():getCell():getOrCreateGridSquare(bulletPosX - halfBulletSpeed * tableProj.dirVector[1], bulletPosY - halfBulletSpeed * tableProj.dirVector[2], Advanced_trajectory.aimlevels)
            end
        else
            squares[1] = getWorld():getCell():getOrCreateGridSquare(bulletPosX, bulletPosY, bulletPosZ)
            if bulletSpeed > 1 then 
                squares[2] = getWorld():getCell():getOrCreateGridSquare(bulletPosX - halfBulletSpeed * tableProj.dirVector[1], bulletPosY - halfBulletSpeed * tableProj.dirVector[2], bulletPosZ)
            end
        end

        tableProj.throwinfo["pos"] = {advMathFloor(bulletPosX), advMathFloor(bulletPosY)}

        if squares[1] and squares[#squares] then
            local blowUp = Advanced_trajectory.blowUp

            -----------------------------------------------
            --CHECK IF PROJECTILE COLLIDED WITH WALL/DOOR--
            -----------------------------------------------
            local collided = false
            for i = 1, #squares do
                -- object (wall/door/window) with one-tick pass gate
                local objectHit =
                    Advanced_trajectory.checkObjectCollision(
                        squares[i],
                        tableProj.bulletDir,
                        tableProj.bulletPos,
                        tableProj.playerPos,
                        tableProj["nonsfx"]
                    )
                    and (not tableProj.canPassThroughWall)

                -- vehicle
                local carHit = Advanced_trajectory.checkBulletCarCollision(tableProj.bulletPos, tableProj.damage, indx)

                -- VEHICLE ⇒ hard stop
                if carHit then AT_dbg('Projectile', indx, 'hit VEHICLE; stopping')
                    AT_dbg('Projectile', indx, 'object BLOCK; no passes left -> stop'); Advanced_trajectory.itemremove(tableProj.item) -- prevent ghost sprite
                    if tableProj.weaponName == "Grenade" or tableProj["wallcarmouse"] or tableProj["wallcarzombie"] then
                        blowUp(tableProj)
                    end
                    currTable[indx] = Advanced_trajectory.removeBulletData(tableProj.item)
                    collided = true
                    break
                end

                -- STATIC OBJECT ⇒ A/B/C handling
                if objectHit then
                    -- (A) maxHit == 1: same-tile zombie resolve, then hard stop
                    if (tableProj.maxHit or 1) == 1 then AT_dbg('Projectile', indx, 'object BLOCK; maxHit=1 -> same-tile resolve then stop')
                        local prevSq = tableProj.square
                        local px, py = tableProj.bulletPos[1], tableProj.bulletPos[2]

                        tableProj.square = squares[i]
                        Advanced_trajectory.dealWithTargetShot(tableProj, indx)
                        tableProj.square = prevSq
                        tableProj.bulletPos[1], tableProj.bulletPos[2] = px, py

                        AT_dbg('Projectile', indx, 'object BLOCK; no passes left -> stop'); Advanced_trajectory.itemremove(tableProj.item)
                        currTable[indx] = Advanced_trajectory.removeBulletData(tableProj.item)
                        collided = true
                        break
                    end

                    -- (B) maxHit >= 2 and object passes remaining ⇒ pass once and continue
                    if (tableProj.maxHitObjects or 0) > 0 then AT_dbg('Projectile', indx, 'object PASS; maxHitObjects left =', tableProj.maxHitObjects)
                        tableProj.maxHitObjects = tableProj.maxHitObjects - 1
                        tableProj.damage = (tableProj.damage or 0) * 0.85 -- small object-only bleed
                        tableProj.canPassThroughWall = true
                        -- break out of the barrier loop for this tick; do NOT mark collided
                        break
                    end

                    -- (C) no passes left ⇒ hard stop
                    AT_dbg('Projectile', indx, 'object BLOCK; no passes left -> stop'); Advanced_trajectory.itemremove(tableProj.item)
                    currTable[indx] = Advanced_trajectory.removeBulletData(tableProj.item)
                    collided = true
                    break
                end
            end

            -- if collided, skip the rest of this projectile (continue outer loop)
-- (wrapped below with 'if not collided then ... end')

            -- reset one-tick wall pass flag
            if not collided then
            tableProj.canPassThroughWall = false


            -- reassign square so visual offset of bullet doesn't go whack
            if getWorld():getCell():getOrCreateGridSquare(bulletPosX, bulletPosY, bulletPosZ) then
                tableProj.square = getWorld():getCell():getOrCreateGridSquare(bulletPosX, bulletPosY, bulletPosZ) 
            end

            tableProj.item = Advanced_trajectory.additemsfx(tableProj.square, tableProj.projectileType .. tostring(tableProj.winddir), bulletPosX, bulletPosY, bulletPosZ)

            local spnumber          = (tableProj.dirVector[1]^2 + tableProj.dirVector[2]^2)^0.5 * bulletSpeed
            tableProj.bulletDist    = tableProj.bulletDist - spnumber
            tableProj.distTraveled  = tableProj.distTraveled + spnumber
            tableProj.currDist      = tableProj.currDist + spnumber
			
            --print('distTraveled: ', tableProj.distTraveled)

            -- NOT SURE WHAT WEAPON THIS CHECKS SINCE THERE ARE NO FLAMETHROWERS IN VANILLA
            if tableProj.weaponName == "flamethrower" then

                -- print(tableProj.currDist)
                if tableProj.currDist > 3 then
                    tableProj.currDist    = 0
                    tableProj.count       = tableProj.count + 1
                    
                    tableProj.bulletPos   = copyTable(tableProj.playerPos)
                    bulletPosX = tableProj.bulletPos[1]
                    bulletPosY = tableProj.bulletPos[2]
                    bulletPosZ = tableProj.bulletPos[3]
                end

                -- print(tableProj.count)
                if tableProj.count > 4 then
                    currTable[indx] = Advanced_trajectory.removeBulletData(tableProj.item) 
                    --print("Broke bullet FLAMETHROWER")
                    break
                end
            
            -- WHERE BULLET BREAKS WHEN OUT OF RANGE. CHECKS IF REMAINING DISTANCE IS LESS THAN 0 AND WEAPON IS NOT GRENADE.
            elseif (tableProj.bulletDist < 0 or tableProj.distTraveled > 70) and tableProj.weaponName ~= "Grenade"  then AT_dbg('Projectile', indx, 'range EXHAUSTED; stopping')

                if tableProj["wallcarmouse"] or tableProj["wallcarzombie"]then
                    blowUp(tableProj)
                end

                currTable[indx] = Advanced_trajectory.removeBulletData(tableProj.item) 

                Advanced_trajectory.determineArrowSpawn(tableProj.square, false)

                --print("Broke bullet GRENADE")
                break
            end


            tableProj.bulletDir = tableProj.bulletDir + tableProj.rotSpeed

            if tableProj.item then
                tableProj.item:setWorldZRotation(tableProj.bulletDir)
            end

            -- BREAKS GRENADE/THROWABLES 
            if  tableProj["isparabola"]  then
                bulletPosZ = 0.5 - tableProj["isparabola"] * tableProj.currDist * (tableProj.currDist - tableProj.distanceConst)
                
                if bulletPosZ <= 0.3  then AT_dbg('Projectile', indx, 'parabola detonation')
                    blowUp(tableProj)
                    currTable[indx] = Advanced_trajectory.removeBulletData(tableProj.item) 
                    --print("Broke bullet PARABOLA")

                    break
                end
            end

            if  (tableProj.weaponName ~= "Grenade" or (tableProj.throwinfo[8]or 0) > 0 or tableProj["wallcarzombie"]) and  not tableProj["wallcarmouse"] then
                --print("Check for shot targets")
                if #squares > 1 then
                    tableProj.square = squares[2]
                    tableProj.bulletPos[1] = bulletPosX - halfBulletSpeed * tableProj.dirVector[1]
                    tableProj.bulletPos[2] = bulletPosY - halfBulletSpeed * tableProj.dirVector[2]
                    Advanced_trajectory.dealWithTargetShot(tableProj, indx) 
                end
				
				-- ONLY proceed if projectile still exists (wasn’t removed above)
				if Advanced_trajectory.table[indx] then
					tableProj.square = squares[1]
					tableProj.bulletPos[1] = bulletPosX
					tableProj.bulletPos[2] = bulletPosY
					Advanced_trajectory.dealWithTargetShot(tableProj, indx)
				end

            end  

            bulletPosX = bulletPosX + bulletSpeed * tableProj.dirVector[1]
            bulletPosY = bulletPosY + bulletSpeed * tableProj.dirVector[2]
            tableProj.bulletPos = {bulletPosX, bulletPosY, bulletPosZ}
        end
        end  -- end 'if not collided' wrapper
    end

    -- print(Advanced_trajectory.table == currTable)
    -- Advanced_trajectory.table =  currTable
end

-----------------------------------
--SHOOTING PROJECTILE FUNC SECT---
-----------------------------------
function Advanced_trajectory.OnWeaponSwing(character, handWeapon)
    
    if  getSandboxOptions():getOptionByName("Advanced_trajectory.showOutlines"):getValue() and 
        (handWeapon:isRanged() and getSandboxOptions():getOptionByName("Advanced_trajectory.Enablerange"):getValue()) and
        instanceof(handWeapon, "HandWeapon") and not 
        handWeapon:hasTag("Thrown") and not 
        Advanced_trajectory.hasFlameWeapon and not 
        (handWeapon:hasTag("XBow") and not getSandboxOptions():getOptionByName("Advanced_trajectory.DebugEnableBow"):getValue()) then

        handWeapon:setMaxHitCount(0)
    end

    local playerLevel = character:getPerkLevel(Perks.Aiming)
    local modEffectsTable = Advanced_trajectory.getAttachmentEffects(handWeapon)  

    local ispass = false

    -- direction from -pi to pi OR -180 to 180 deg
    -- N (top left corner): pi,-pi  (180, -180)
    -- W (bottom left): pi/2 (90)
    -- E (top right): -pi/2 (-90)
    -- S (bottom right corner): 0

    -- get player fwrd dir vector
    local playerDir = character:getForwardDirection()
    
    if character:isSeatedInVehicle() and Advanced_trajectory.isOverCarAimLimit then
        playerDir:normalize()

        local forwardCarVec = Advanced_trajectory.forwardCarVec
        local dotProd = playerDir:dot(forwardCarVec) 

        -- if angle between is playerDir and forwardCardDir is less than 90 (dot > 0), set bullet dir to upper
        if dotProd > 0 then 
            playerDir = Advanced_trajectory.upperCarAimBound
        else 
            playerDir = Advanced_trajectory.lowerCarAimBound
        end
    end

    playerDir = playerDir:getDirection()

    -- bullet position 
    local spawnOffset = getSandboxOptions():getOptionByName("Advanced_trajectory.DebugSpawnOffset"):getValue()
    local offX = character:getX() + spawnOffset * math.cos(playerDir)
    local offY = character:getY() + spawnOffset * math.sin(playerDir)
    local offZ = character:getZ()

    --local offx = character:getX()
    --local offy = character:getY()
    --local offz = character:getZ()

    -- pi/250 = .7 degrees
    -- aimnum can go up to (77-9+40) 108 
    -- max/min -+96 degrees, and even more when drunk (6*24+108 = 252 => 208 deg)
    -- og denominator was 250

    local maxProjCone = getSandboxOptions():getOptionByName("Advanced_trajectory.MaxProjCone"):getValue()
    -- 120 as max aimnum
    local denom = 120 * math.pi / maxProjCone
    Advanced_trajectory.aimrate = Advanced_trajectory.aimnum * math.pi / denom

    --print("MaxProjCone: ", maxProjCone)
    --print("Aimrate: ", Advanced_trajectory.aimrate )
    
    -- NOTES: Aimrate, which is affected by aimnum, in combination with RNG determines how wide the bullets can spread.
    -- adding playerDir (direction player is facing) will cause bullets to go towards the general direction of where player is looking
    local dirc = playerDir + ZombRandFloat(-Advanced_trajectory.aimrate, Advanced_trajectory.aimrate)

    --print("Dirc: ", dirc)
    local deltX = math.cos(dirc)
    local deltY = math.sin(dirc)

    local projectilePlayerData = 
    {
        item = nil,                             --1 item obj
        square = nil,                           --2 square obj
        dirVector = {deltX,deltY},              --3 vector
        bulletPos = {offX, offY, offZ},         --4 offset BULLET POS
        bulletDir = dirc,                       --5 direction
        damage = nil,                           --6 damage
        bulletDist = handWeapon:getMaxRange() , --7 distance
        winddir = 1,                            --8 ballistic small categories
        weaponName = "",                        --9 types
        rotSpeed = 0,                           --10 rotation speed
        canPenetrate = false,                   --11 whether it can penetrate
        bulletSpeed = 1,                      --12 ballistic speed
        iscanbigger = 0,                        --13 can be made bigger
        projectileType = "",                    --14 ballistic name
        canPassThroughWall = true,              --15 det whether it can pass through the wall
        size = 1,                               --16 size
        currDist = 0,                           --17 current distance
        distanceConst = 0,                      --18 distance constant
        player = character,                     --19 players
        playerPos = {offX, offY, offZ},         --20 original offset PLAYER POS
        count = 0,                              --21 count
        throwinfo = {},                         --22 thrown object attributes    
        isCrit = false,                                         
        distTraveled = 0,          
    }

    projectilePlayerData["boomsfx"] = {}
    projectilePlayerData["aimLevel"] = Advanced_trajectory.aimlevels or mathfloor(projectilePlayerData.bulletPos[3])

    projectilePlayerData.throwinfo = {
        handWeapon:getSmokeRange(),
        handWeapon:getExplosionPower(),
        handWeapon:getExplosionRange(),
        handWeapon:getFirePower(),
        handWeapon:getFireRange()
    }




    projectilePlayerData.throwinfo[7] = handWeapon:getExplosionSound()
	

	local _def = ScriptManager.instance:getItem(handWeapon:getFullType())
	local AT_staticMax = (_def and tonumber(_def:getMaxHitCount())) or 1

	-- set initial budgets using the static value
	projectilePlayerData.penCount = AT_staticMax
	projectilePlayerData.maxHit   = AT_staticMax


	-- Always funnel wall/door logic through updateProjectiles barrier code
	projectilePlayerData.canPassThroughWall = false

	-- Penetration budget mapping (tune these to taste)
	-- Goal: pistols (MaxHit=1) can barely penetrate 1 wall; heavier rounds more.
	local function budgetFromMaxHit(mh)
		-- mh: MaxHitCount (entity penetration hint)
		if mh <= 1 then
			return {
				wallPass = 1,   -- allow 1 wall
				wallCoast = 1,  -- ~1 tile of travel after a wall
				doorBonus = 1,  -- 1 "free" door pass that doesn't consume wallPass
				doorCoast = 3,  -- longer coast through doors
			}
		elseif mh == 2 then
			return { wallPass = 2, wallCoast = 1.2, doorBonus = 1, doorCoast = 3 }
		elseif mh == 3 then
			return { wallPass = 3, wallCoast = 1.5, doorBonus = 2, doorCoast = 3 }
		else
			-- big rifles / high-power
			return { wallPass = math.min(mh, 5), wallCoast = 2.0, doorBonus = 2, doorCoast = 3 }
		end
	end

	local pen = budgetFromMaxHit(AT_staticMax)

	-- Flesh penetration budget: up to MaxHit bodies if flesh penetration enabled
	local fleshPenEnabled = getSandboxOptions():getOptionByName("Advanced_trajectory.enableBulletPenFlesh"):getValue()
	projectilePlayerData.entityPassRemaining = fleshPenEnabled and AT_staticMax or 1


	-- Damage floor stops ghost rounds
	projectilePlayerData.minDamageStop = 0.05

	-- Fields consumed by updateProjectiles barrier logic
	projectilePlayerData.wallPassRemaining = pen.wallPass
	projectilePlayerData.wallCoastTiles    = pen.wallCoast
	projectilePlayerData.doorPassBonus     = pen.doorBonus
	projectilePlayerData.doorCoastTiles    = pen.doorCoast

	-- Clear any legacy flags so barrier code isn’t skipped
	-- (leave as false so the collision path runs)
	projectilePlayerData.canPassThroughWall = false

    local isspweapon = Advanced_trajectory.FullWeaponTypes[handWeapon:getFullType()] 
    if isspweapon then
        for projDataKey, value in pairs(isspweapon) do
            --print('projDataKey: ', projDataKey, ' || value: ', value)
            if projDataKey == "bulletPos" then
                -- value 1-3 is bullet pos x,y,z
                projectilePlayerData.bulletPos[1] = projectilePlayerData.bulletPos[1] + value[1] * projectilePlayerData.dirVector[1]
                projectilePlayerData.bulletPos[2] = projectilePlayerData.bulletPos[2] + value[2] * projectilePlayerData.dirVector[2]
                projectilePlayerData.bulletPos[3] = projectilePlayerData.bulletPos[3] + value[3]
            else 
                projectilePlayerData[projDataKey] = value
            end
            
        end
        ispass = true
    end

    if Advanced_trajectory.aimcursorsq then
        projectilePlayerData.distanceConst = ((Advanced_trajectory.aimcursorsq:getX()+0.5-offX)^2+(Advanced_trajectory.aimcursorsq:getY()+0.5-offY)^2)^0.5
    else
        projectilePlayerData.distanceConst =handWeapon:getMaxRange(character)
    end

    local isHoldingShotgun = false
    if not ispass then  
        if getSandboxOptions():getOptionByName("Advanced_trajectory.Enablethrow"):getValue() and handWeapon:getSwingAnim() =="Throw" then  --投掷物

            if projectilePlayerData.throwinfo[1] == 0 and projectilePlayerData.throwinfo[2] == 0 and projectilePlayerData.throwinfo[4] == 0 then
                projectilePlayerData.throwinfo[6] = 0.016
                
            else
                projectilePlayerData.throwinfo[6] = 0.04 -- radian
            end
    
            projectilePlayerData.throwinfo[9] = handWeapon:canBeReused()
    
    
            projectilePlayerData.bulletDist = projectilePlayerData.distanceConst
            projectilePlayerData.weaponName="Grenade"
            projectilePlayerData.projectileType = handWeapon:getFullType()
            projectilePlayerData.winddir = ""
            projectilePlayerData.canPenetrate = false
            projectilePlayerData.canPassThroughWall = false

            projectilePlayerData.bulletPos[1] = projectilePlayerData.bulletPos[1] + 0.3 * projectilePlayerData.dirVector[1]
            projectilePlayerData.bulletPos[2] = projectilePlayerData.bulletPos[2] + 0.3 * projectilePlayerData.dirVector[2]

            projectilePlayerData.rotSpeed = 6
            projectilePlayerData.bulletSpeed = 0.3
    
            projectilePlayerData.throwinfo[10] = projectilePlayerData.projectileType
            projectilePlayerData.throwinfo[11] = handWeapon:getNoiseRange()

            projectilePlayerData["isparabola"] = projectilePlayerData.throwinfo[6]
        
            -- disabling enable range means guns don't work (no projectiles)
        elseif getSandboxOptions():getOptionByName("Advanced_trajectory.Enablerange"):getValue() and (handWeapon:getSubCategory() =="Firearm" or handWeapon:getSubCategory() =="BBGun") then 

            local hideTracer = getSandboxOptions():getOptionByName("Advanced_trajectory.hideTracer"):getValue()
            --print("Tracer hidden: ", hideTracer)

            local offset = getSandboxOptions():getOptionByName("Advanced_trajectory.DebugOffset"):getValue()

            --print("Range enabled...Weapon is Firearm.")
            if  Advanced_trajectory.getIsHoldingShotgun(handWeapon) then
                local shotgunDistanceModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.shotgunDistanceModifier"):getValue()
                
                projectilePlayerData.weaponName = "Shotgun" --weapon name

                --print("Weapon has shotgun type ammo.")

                --wpn sndfx
                if hideTracer then
                    --print("Empty")
                    projectilePlayerData.projectileType = "Empty.aty_Shotguna"    
                else
                    --print("---- Base shotgun ----")
                    projectilePlayerData.projectileType = "Base.aty_Shotguna"  
                end

                -- Shotgun's max cone spread is independent from default spread
                local maxShotgunProjCone = getSandboxOptions():getOptionByName("Advanced_trajectory.maxShotgunProjCone"):getValue()
                if (dirc > playerDir + maxShotgunProjCone or dirc < playerDir - maxShotgunProjCone) then
                    projectilePlayerData.bulletDir = playerDir + ZombRandFloat(-maxShotgunProjCone, maxShotgunProjCone)
                end

                projectilePlayerData.bulletDist = projectilePlayerData.bulletDist * shotgunDistanceModifier     --ballistic distance
                projectilePlayerData.canPassThroughWall = false                                 --isthroughwall

                projectilePlayerData.bulletPos[1] = projectilePlayerData.bulletPos[1] + offset*projectilePlayerData.dirVector[1]    --offsetx=offsetx +.6 * deltX; deltX is cos of dirc
                projectilePlayerData.bulletPos[2] = projectilePlayerData.bulletPos[2] + offset*projectilePlayerData.dirVector[2]    --offsety=offsety +.6 * deltY; deltY is sin of dirc
                projectilePlayerData.bulletPos[3] = projectilePlayerData.bulletPos[3] + 0.5                      --offsetz=offsetz +.5

                isHoldingShotgun = true
            
            elseif string.contains(handWeapon:getAmmoType() or "", "INCRound") or string.contains(handWeapon:getAmmoType() or "", "HERound") then 
                -- The idea here is to solve issue of Brita's launchers spawning a bullet along with their grenade.
                --print("Weapon has round type ammo (Brita grenades).")
                return
            elseif Advanced_trajectory.hasFlameWeapon then 
                -- Break bullet if flamethrower
                --print("Weapon is flame type.")
                return
            elseif ((handWeapon:hasTag("XBow") and not getSandboxOptions():getOptionByName("Advanced_trajectory.DebugEnableBow"):getValue()) or handWeapon:hasTag("Thrown")) then
                -- Break bullet if bow
                --print("Weapon is either bow or throwable nonexplosive.")
                return
            else
                --print("Weapon is a normal gun (revolver).")

                projectilePlayerData.weaponName = "revolver"

                --wpn sndfx
                if hideTracer then
                    --print("Empty")
                    projectilePlayerData.projectileType = "Empty.aty_revolversfx"  
                else
                    --print("---- Base normal ----")
                    projectilePlayerData.projectileType = "Base.aty_revolversfx" 
                end

                projectilePlayerData.canPassThroughWall  = false

                projectilePlayerData.bulletPos[1] = projectilePlayerData.bulletPos[1] + offset*projectilePlayerData.dirVector[1]
                projectilePlayerData.bulletPos[2] = projectilePlayerData.bulletPos[2] + offset*projectilePlayerData.dirVector[2]
                projectilePlayerData.bulletPos[3] = projectilePlayerData.bulletPos[3] + 0.5

				if getSandboxOptions():getOptionByName("Advanced_trajectory.enableBulletPenFlesh"):getValue() then
					projectilePlayerData.penCount = AT_staticMax
				else
					projectilePlayerData.penCount = 1
				end



                isHoldingShotgun = false
            end
        else
            --print("Weapon is not firearm, but ", handWeapon:getSubCategory())
            return      
        end
    end

    projectilePlayerData.square = projectilePlayerData.square or getWorld():getCell():getGridSquare(offX,offY,offZ)

    if projectilePlayerData.square == nil then return end

    --projectilePlayerData.item = Advanced_trajectory.additemsfx(projectilePlayerData.square, projectilePlayerData.projectileType .. tostring(projectilePlayerData.winddir), offX, offY, offZ)

    -- NOTES: projectilePlayerData.damage is damage, firearm damages vary from 0 to 2. Example, M16 has min to max: 0.8 to 1.4 (source wiki)
    projectilePlayerData.damage = projectilePlayerData.damage or (handWeapon:getMinDamage() + ZombRandFloat(0.1, 1.3) * (0.5 + handWeapon:getMaxDamage() - handWeapon:getMinDamage()))

    if isHoldingShotgun then
        local shotgunDamageMultiplier = getSandboxOptions():getOptionByName("Advanced_trajectory.shotgunDamageMultiplier"):getValue()
        projectilePlayerData.damage = projectilePlayerData.damage * shotgunDamageMultiplier
    end
    
    -- firearm crit chance can vary from 0 to 30. Ex, M16 has a crit chance of 30 (source wiki)
    -- Rifles - 25 to 30
    -- M14 - 0 crit but higher hit chance
    -- Pistols - 20
    -- Shotguns - 60 to 80
    -- Lower aimnum (to reduce spamming crits with god awful bloom) and higher player level means higher crit chance.
    local critChanceModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.critChanceModifier"):getValue() 
    local critChanceAdd = (Advanced_trajectory.aimnumBeforeShot*critChanceModifier) + (11-playerLevel)

    -- higher = higher crit chance
    local critIncreaseShotgun = getSandboxOptions():getOptionByName("Advanced_trajectory.critChanceModifierShotgunsOnly"):getValue() 
    if isHoldingShotgun then
        critChanceAdd = (critChanceAdd * 0) - (critIncreaseShotgun - playerLevel)
    end
    if ZombRand(100+critChanceAdd) <= handWeapon:getCriticalChance() then
        projectilePlayerData.damage = projectilePlayerData.damage * 2
        projectilePlayerData.isCrit = true
    end


    -- throwinfo[8] = projectilePlayerData.damage
    projectilePlayerData.throwinfo[8] = handWeapon:getMinDamage()

    -- projectilePlayerData.bulletDir is dirc
    local dirc1 = projectilePlayerData.bulletDir
    projectilePlayerData.bulletDir = projectilePlayerData.bulletDir * 360 / (2 * math.pi)

    -- ballistic speed
    projectilePlayerData.bulletSpeed = getSandboxOptions():getOptionByName("Advanced_trajectory.bulletspeed"):getValue() 

    -- bullet distance
    projectilePlayerData.bulletDist = projectilePlayerData.bulletDist * getSandboxOptions():getOptionByName("Advanced_trajectory.bulletdistance"):getValue() 


    ------------------------------
    -----RANGE ATTACHMENT EFFECT--
    ------------------------------
    local rangeMod = modEffectsTable[4]
    if rangeMod ~= 0 then
        projectilePlayerData.bulletDist = projectilePlayerData.bulletDist + rangeMod
    end

    local bulletnumber = getSandboxOptions():getOptionByName("Advanced_trajectory.shotgunnum"):getValue() 

    local damagemutiplier = getSandboxOptions():getOptionByName("Advanced_trajectory.ATY_damage"):getValue()  or 1

    -- NOTES: damage is multiplied by user setting (default 1)
    projectilePlayerData.damage = projectilePlayerData.damage * damagemutiplier

    local damageer = projectilePlayerData.damage

    Advanced_trajectory.aimnumBeforeShot = Advanced_trajectory.aimnum

    -- print(projectilePlayerData.bulletDir)
    if projectilePlayerData.weaponName == "Shotgun" then

        local aimtable = {}

        for shot = 1, bulletnumber do
            local adirc

            -- lower value means tighter spread
            local numpi = getSandboxOptions():getOptionByName("Advanced_trajectory.shotgundivision"):getValue() * 0.7

            --------------------------------
            -----ANGLE ATTACHMENT EFFECT---
            --------------------------------
            local angleMod = modEffectsTable[5]
            if angleMod ~= 0 then
                numpi = numpi * angleMod
            end


            adirc = dirc1 + ZombRandFloat(-math.pi * numpi,math.pi*numpi)

            projectilePlayerData.dirVector = {math.cos(adirc), math.sin(adirc)}
            projectilePlayerData.bulletPos = {projectilePlayerData.bulletPos[1], projectilePlayerData.bulletPos[2], projectilePlayerData.bulletPos[3]}
            projectilePlayerData.bulletDir = adirc * 360 / (2 * math.pi)
            projectilePlayerData.playerPos = {projectilePlayerData.bulletPos[1], projectilePlayerData.bulletPos[2], projectilePlayerData.bulletPos[3]}

            projectilePlayerData.damage = damageer / 4

            if getSandboxOptions():getOptionByName("Advanced_trajectory.enableHitOrMiss"):getValue() then
                projectilePlayerData["missedShot"] = Advanced_trajectory.determineHitOrMiss() 
            end
            

            if isClient() then
                projectilePlayerData["nonsfx"] = 1
                sendClientCommand("ATY_shotsfx","true",{projectilePlayerData, character:getOnlineID()})
            end
            projectilePlayerData["nonsfx"] = nil
            
    -- Minimal object penetration fields
    do
		local wMax = projectilePlayerData.maxHit or 1
        projectilePlayerData.maxHitObjects = math.max(0, (projectilePlayerData.maxHit or 1) - 1)
        projectilePlayerData.canPassThroughWall = false
    end
table.insert(Advanced_trajectory.table, copyTable(projectilePlayerData))
        end
    else

        -- print(projectilePlayerData.weaponName)
        if projectilePlayerData["wallcarmouse"] then
            projectilePlayerData.bulletDist = Advanced_trajectory.aimtexdistance - 1
        end
        projectilePlayerData.playerPos = {offX, offY, projectilePlayerData.bulletPos[3]}

        if getSandboxOptions():getOptionByName("Advanced_trajectory.enableHitOrMiss"):getValue() then
            projectilePlayerData["missedShot"] = Advanced_trajectory.determineHitOrMiss() 
        end

        
-- ensure object penetration fields for non-shotgun projectiles
do
    local wMax = projectilePlayerData.maxHit or AT_staticMax or 1
    projectilePlayerData.maxHitObjects = math.max(0, wMax - 1)
    projectilePlayerData.canPassThroughWall = false
end

table.insert(Advanced_trajectory.table, copyTable(projectilePlayerData))
        if isClient() then
            projectilePlayerData["nonsfx"] = 1
            sendClientCommand("ATY_shotsfx","true",{projectilePlayerData,character:getOnlineID()})
        end

        -- print(Advanced_trajectory.aimtexdistance)
    end


    local recoilModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.recoilModifier"):getValue()
    local recoilScaleModifier = getSandboxOptions():getOptionByName("Advanced_trajectory.recoilScaleModifier"):getValue()
    local proneRecoilBuff = getSandboxOptions():getOptionByName("Advanced_trajectory.proneRecoilBuff"):getValue()
    local proneExpoRecoilBuff = getSandboxOptions():getOptionByName("Advanced_trajectory.proneExpoRecoilBuff"):getValue()
    local crouchRecoilBuff = getSandboxOptions():getOptionByName("Advanced_trajectory.crouchRecoilBuff"):getValue()
    local crouchExpoRecoilBuff = getSandboxOptions():getOptionByName("Advanced_trajectory.crouchExpoRecoilBuff"):getValue()
    
    -- typ dmg from wep category

    -- recoilModifier = ?? < 10
    -- Britas 2.5 - 2.7 (rifles)
    -- Britas 3.0 - 6.0 (snipers)
    -- Britas 1.4 - 1.5 (SMG, pistols)

    -- recoilModifier = 10
    -- Vanilla 1.0 - 1.4 (light pistols)
    -- Vanilla 1.4 - 2.0 (rifles)
    -- Vanilla 2.2 - 2.7 (shotguns)

    -- recoilModifier = 10
    -- VFE 1.0 - 1.4 (SMG, pistols)
    -- VFE 2.0 - 2.7 (rifles)
    -- VFE 2.2 - 2.7 (shotguns)
    -- VFE 2.9 - 3.2 (snipers)

    -----------------------------
    --RECOIL ATTACHMENT EFFECT---
    -----------------------------
    -- recoilMod is always 0.5
    local recoilMod = modEffectsTable[3]
    local wepMaxDmg = handWeapon:getMaxDamage()
    if recoilMod ~= 0 then
        wepMaxDmg = wepMaxDmg * recoilMod
    end

    -- recoil control capped at lv 9
    if playerLevel >= 10 then
        playerLevel = 9
    end

    -- linear relationship between player level and recoil
    local recoil = (wepMaxDmg * recoilModifier) + (11-playerLevel)

    -- Prone stance means less recoil
    if Advanced_trajectory.isCrawl  then
        recoil = recoil * proneRecoilBuff
        recoilScaleModifier = recoilScaleModifier * proneExpoRecoilBuff

    elseif Advanced_trajectory.isCrouch  then
        recoil = recoil * crouchRecoilBuff
        recoilScaleModifier = recoilScaleModifier * crouchExpoRecoilBuff
    end

    -- simulates recoil control through exponential function
    -- embraces burst and tap fire but not full auto spraying
    local exponentialRecoil = 1 + ( (11-playerLevel) * (  20^((Advanced_trajectory.aimnumBeforeShot - recoilScaleModifier) * 0.01) * 0.01  ) )



    local totalRecoil = recoil * exponentialRecoil
    --print("Total / Recoil / Exponential: ", totalRecoil, " || ", recoil, " || ", exponentialRecoil)

    Advanced_trajectory.aimnum = Advanced_trajectory.aimnum + totalRecoil
    Advanced_trajectory.maxFocusCounter = 100 
    
    --print('{{{{{{ SHOT }}}}}}')
end



---------------------------------
-----UPDATE EVERY FRAME SECT-----
---------------------------------
function Advanced_trajectory.checkontick()
    Advanced_trajectory.boomontick()
    Advanced_trajectory.OnPlayerUpdate()
    Advanced_trajectory.drawDamageText()
    Advanced_trajectory.updateProjectiles()
end

Events.OnTick.Add(Advanced_trajectory.checkontick)

Events.OnWeaponSwingHitPoint.Add(Advanced_trajectory.OnWeaponSwing)

return Advanced_trajectory