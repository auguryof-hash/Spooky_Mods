    -----------------------------------------------------------
    -- SPK_Controller – Player Kinetics & Stance Effects
    --
    -- Intent:
    -- Core movement and stance controller for SPK systems.
    -- This is the physical behavior layer beneath animations.
    --
    -- Owns:
    -- - Canted movement speed buff
    -- - Direction-relative movement sampling
    -- - Velocity bursts from animation events
    -- - Optional movement locking
    --
    -- Design Philosophy:
    -- Animations *request* motion.
    -- SPK decides *how motion is applied*.
    --
    -- Explicit Non-Goals:
    -- - No animation selection
    -- - No combat resolution
    -- - No networking
    
    -- Movement Design Constraints:
    -- - Speed buffs are additive and MovementUtil-style
    -- - No direct animation scalar overrides are used
    -- - Pathfinding and auto-walk intentionally bypass SPK buffs
    -- - Canted speed bonus is capped and stance-driven
    -----------------------------------------------------------
    
    
    SPK = SPK or {}
    
    SPK.active       = SPK.active       or {}  -- active velocity move per player
    SPK._lastPos     = SPK._lastPos     or {}  -- last position (for relative direction)
    SPK._lastMoveVec = SPK._lastMoveVec or {}  -- last sampled movement delta
    SPK._moveLocked  = SPK._moveLocked  or {}  -- movement lock state
    
    -- Stance / speed state
    SPK._isCanted   = SPK._isCanted   or false
    SPK._speedFlags = SPK._speedFlags or {}    -- per-player stance flags
    
    -- Speed buff state (MovementUtil-style)
    SPK._buffLastPos = SPK._buffLastPos or {}  -- last position used by speed buff
    SPK._buffLastMs  = SPK._buffLastMs  or {}  -- last time used by additive mode
    
    -- Debug
    SPK.DEBUG_SPEED   = SPK.DEBUG_SPEED   or false
    SPK._lastSpeedLog = SPK._lastSpeedLog or 0
    
    -----------------------------------------------------------
    -- Helpers
    -----------------------------------------------------------
    
    local function spkNowMs()
        return getTimestampMs()
    end
    
    local function spkGetPlayerId(player)
        return player:getOnlineID() or player:getPlayerNum() or 0
    end
    
    -- Toggle canted state (called from FancyHandwork / unarmed handler)
    function SPK.setCanted(enable)
        SPK._isCanted = not not enable
    end
    
    function SPK.isCanted()
        return SPK._isCanted == true
    end
    
    -- Generic stance flags: "unarmed", "heavyGuard", etc.
    function SPK.setSpeedFlag(player, flagName, enabled)
        if not player or not flagName then return end
        local id    = spkGetPlayerId(player)
        local flags = SPK._speedFlags[id]
        if not flags then
            flags = {}
            SPK._speedFlags[id] = flags
        end
        flags[flagName] = not not enabled
    end
    
    local function spkAlmostEqual(a, b, tolerance)
        tolerance = tolerance or 0.001
        return math.abs(a - b) < tolerance
    end
    
    -----------------------------------------------------------
    -- Aim-relative direction vector
    -----------------------------------------------------------
    
    local function spkGetDirVector(player, mode)
        local dirObj = player:getDir()
        local dir = 0
    
        if dirObj then
            if type(dirObj.index) == "function" then
                dir = dirObj:index()
            elseif type(dirObj.index) == "number" then
                dir = dirObj.index
            end
        end
    
        local angleIndex = dir
    
        -- Offsets relative to facing:
        -- forward: in front of aim
        -- backward: behind aim
        -- left/right: strafe relative to aim
        if mode == "forward" or mode == "neutral" then
            angleIndex = (dir + 4) % 8
        elseif mode == "backward" then
            angleIndex = dir % 8
        elseif mode == "left" then
            angleIndex = (dir + 6) % 8
        elseif mode == "right" then
            angleIndex = (dir + 2) % 8
        else
            angleIndex = (dir + 4) % 8  -- default to forward
        end
    
        -- IsoDirections 0 = North; rotate so 0 = East for math
        angleIndex = (angleIndex - 2) % 8
    
        local angle = angleIndex * (math.pi / 4)
        local vx = math.cos(angle)
        local vy = -math.sin(angle)
    
        return vx, vy
    end
    
    SPK._getDirVector = spkGetDirVector
    
    -----------------------------------------------------------
    -- Movement sampling (for relative direction)
    -----------------------------------------------------------
    
    local function spkUpdateLastMoveVector(player)
        local id = spkGetPlayerId(player)
        local x, y = player:getX(), player:getY()
    
        local last = SPK._lastPos[id]
        if not last then
            SPK._lastPos[id]     = { x = x, y = y }
            SPK._lastMoveVec[id] = { x = 0.0, y = 0.0 }
            return
        end
    
        local dx = x - last.x
        local dy = y - last.y
        last.x, last.y = x, y
        SPK._lastMoveVec[id] = { x = dx, y = dy }
    end
    
    -- High-level relative movement direction (forward/back/left/right/neutral)
    function SPK.getRelativeMoveDir(player)
        local id = spkGetPlayerId(player)
        local mv = SPK._lastMoveVec[id]
        if not mv then return "neutral" end
    
        local dx, dy = mv.x, mv.y
        local len = math.sqrt(dx*dx + dy*dy)
        if len < 0.0005 then return "neutral" end
    
        -- Forward vector from aim
        local fx, fy = spkGetDirVector(player, "forward")
        local fl = math.sqrt(fx*fx + fy*fy)
        if fl < 0.0001 then return "neutral" end
        fx, fy = fx/fl, fy/fl
    
        -- Right vector (perpendicular)
        local rx, ry = -fy, fx
    
        local fDot = fx*dx + fy*dy
        local sDot = rx*dx + ry*dy
    
        if math.abs(fDot) >= math.abs(sDot) then
            if fDot > 0 then
                return "forward"
            else
                return "backward"
            end
        else
            if sDot > 0 then
                return "right"
            else
                return "left"
            end
        end
    end
    
    -----------------------------------------------------------
    -- Movement lock (anim-driven)
    -----------------------------------------------------------
    
    -- If/when you want lockMovement back, uncomment this and the call in OnPlayerUpdate.
    --[[
    local function spkUpdateMovementLock(player)
        local id      = spkGetPlayerId(player)
        local current = SPK._moveLocked[id] or false
    
        local v    = player:getVariableString("SPK_LockMovement")
        local want = (v == "true" or v == "TRUE" or v == "1")
    
        -- failsafe: unlock if attack state ended
        if current and not (player:isAttacking() or player:isDoShove()) then
            want = false
        end
    
        if want ~= current then
            player:setBlockMovement(want)
            SPK._moveLocked[id] = want
        end
    end
    ]]
    
    -----------------------------------------------------------
    -- Speed buff (MovementUtil-style, with mode toggle)
    -----------------------------------------------------------
    
    local function spkSaveBuffPos(player)
        local id = spkGetPlayerId(player)
        SPK._buffLastPos[id] = { x = player:getX(), y = player:getY() }
    end
    
    -- MovementUtil-style speed modifier: base 1.0, plus stance buffs
    local function spkGetMovSpeedMod(player)
        local modifier = 1.0
    
        -- Canted aiming buff (like original MovementUtil: +35%)
        if SPK.isCanted() then
            modifier = modifier + 0.25
        end
    
        -- Extra stance flags (you can tune these)
        local id    = spkGetPlayerId(player)
        local flags = SPK._speedFlags[id]
        if flags then
            if flags.unarmed then
                modifier = modifier + 0.10
            end
            if flags.heavyGuard then
                modifier = modifier - 0.15
            end
        end
    
        return modifier
    end
    
    --[[local function spkIsPathfinding(player)
        local pfb = player:getPathFindBehavior2()
        return pfb and not pfb:getIsCancelled()
    end]]-- pathfinding suppresses ctrl/modifier. We may need this in the future tho.
    
    local function spkBuffIsActive(player, movSpeedMod)
        local id = spkGetPlayerId(player)
        if player:getVehicle()
            or player:isBlockMovement()
            or not player:isLocalPlayer()
            or not player:getCurrentSquare()
            or not SPK._buffLastPos[id]
            or spkAlmostEqual(movSpeedMod, 1.0) then
            return false
        end
        return true
    end
    
    local function spkBuffHasMove(dx, dy)
        return dx ~= 0 or dy ~= 0
    end
    
    local function spkBuffCanDoMove(player, dx, dy)
        local x = player:getX() + (dx or 0)
        local y = player:getY() + (dy or 0)
        local z = player:getZ()
        if not getWorld():isValidSquare(x, y, z) then return false end
        local grid = getCell():getGridSquare(x, y, z)
        if not grid or grid ~= player:getCurrentSquare() then return false end
        return true
    end
    
    -- Multiplier mode: direct port of LSMovUtil.getMovDeltas for non-pathfinding.
    -- We re-use the same "double + 1" behaviour the original MovementUtil used.
    local function spkGetMovDeltas_Multiplier(player, lastPos, movSpeedMod)
        local deltaX = player:getX() - lastPos.x
        local deltaY = player:getY() - lastPos.y
    
        -- If there's effectively no motion, don't add noise.
        if math.abs(deltaX) < 0.0005 and math.abs(deltaY) < 0.0005 then
            return 0.0, 0.0
        end
    
        -- Original MovementUtil non-pathfinding formula:
        --   multiplier = (movSpeedMod - 1) * 2 + 1
        -- We don't bother with the pathfinding branch because
        -- SPK stances can't be used while auto-walking.
        local multiplier = (movSpeedMod - 1) * 2 + 1
    
        -- Return the scaled displacement, same as LSMovUtil.getMovDeltas.
        return deltaX * multiplier, deltaY * multiplier
    end
    
    -- Main MovementUtil-style speed buff
    local function spkUpdateSpeedBuff(player)
        local movSpeedMod = spkGetMovSpeedMod(player)
        local id          = spkGetPlayerId(player)
    
        -- First pass: if nothing to do, just refresh our last known position
        if not spkBuffIsActive(player, movSpeedMod) then
            spkSaveBuffPos(player)
            return
        end
    
        -- Match MovementUtil: if aiming and NOT canted, skip buff
        if player:isAiming() and not SPK.isCanted() then
            spkSaveBuffPos(player)
            return
        end
    
        local lastPos = SPK._buffLastPos[id] or { x = player:getX(), y = player:getY() }
    
        local dx, dy
        dx, dy = spkGetMovDeltas_Multiplier(player, lastPos, movSpeedMod)
    
    
        if spkBuffHasMove(dx, dy) and spkBuffCanDoMove(player, dx, dy) then
            player:setX(player:getX() + dx)
            player:setY(player:getY() + dy)
        end
    
        spkSaveBuffPos(player)
    
        --[[if SPK.DEBUG_SPEED then
            local now = spkNowMs()
            if now - (SPK._lastSpeedLog or 0) > 250 then
                local addLen = math.sqrt(dx*dx + dy*dy)
                print(string.format(
                    "[SPK] SpeedBuff(%s): mod=%.3f dx=%.5f dy=%.5f addLen=%.5f canted=%s",
                    movSpeedMod, dx, dy, addLen, tostring(SPK.isCanted())
                ))
                SPK._lastSpeedLog = now
            end
        end]]
    end
    
    -----------------------------------------------------------
    -- Velocity bursts (VEL_START / VEL_END)
    -----------------------------------------------------------
    
    local function spkStartVelocityMove(player)
        -- read from anim vars as strings
        local dirVar = player:getVariableString("SPK_MoveDir")
        local dir = (dirVar ~= "" and dirVar) or "forward"
    
        local speedStr = player:getVariableString("SPK_MoveSpeed")
        local speed = tonumber(speedStr) or 0
        --[[if speed <= 0 then
            print(string.format("[SPK] spkStartVelocityMove aborted: dir=%s speed=%s",
                tostring(dir), tostring(speedStr)))
            return
        end]]
    
        -- optional explicit world-space velocity
        local vxStr = player:getVariableString("SPK_MoveVX")
        local vyStr = player:getVariableString("SPK_MoveVY")
        local vxVar = tonumber(vxStr)
        local vyVar = tonumber(vyStr)
    
        local vx, vy
    
        if vxVar and vyVar and (vxVar ~= 0 or vyVar ~= 0) then
            vx, vy = vxVar, vyVar
        else
            local fx, fy = spkGetDirVector(player, dir)
            local fl = math.sqrt(fx*fx + fy*fy)
            --[[if fl < 0.0001 then
                print(string.format("[SPK] spkStartVelocityMove failed: bad dir vec for mode=%s",
                    tostring(dir)))
                return
            end]]
            fx, fy = fx/fl, fy/fl
            vx = fx * speed
            vy = fy * speed
        end
    
        --[[print(string.format(
            "[SPK] spkStartVelocityMove: dir=%s speed=%.3f vx=%.4f vy=%.4f",
            tostring(dir), speed, vx or 0, vy or 0
        ))]]
    
        SPK.active[player] = {
            kind   = "velocity",
            vx     = vx,
            vy     = vy,
            lastMs = spkNowMs(),
        }
    end
    
    local function spkStop(player)
        --[[if SPK.active[player] then
            print("[SPK] spkStop: stopping active velocity move")
        end]]
        SPK.active[player] = nil
    end
    
    local function spkUpdateMove(player, state)
        local now = spkNowMs()
        local dt  = (now - (state.lastMs or now)) / 1000.0
        state.lastMs = now
        --[[if dt <= 0 then
            print(string.format("[SPK] spkUpdateMove: dt<=0 (dt=%.6f)", dt))
            return
        end]]
    
        local vx = state.vx or 0
        local vy = state.vy or 0
    
        local dx = vx * dt
        local dy = vy * dt
    
        local oldX, oldY = player:getX(), player:getY()
    
        --[[print(string.format(
            "[SPK] spkUpdateMove: dt=%.4f vx=%.4f vy=%.4f dx=%.4f dy=%.4f from (%.4f, %.4f)",
            dt, vx, vy, dx, dy, oldX, oldY
        ))]]
    
        if MovePlayer and MovePlayer.canDoMoveTo then
            if MovePlayer.canDoMoveTo(player, dx, dy, 0) then
                player:setX(oldX + dx)
                player:setY(oldY + dy)
            --[[else
                print("[SPK] spkUpdateMove: MovePlayer blocked movement")]]
            end
        else
            player:setX(oldX + dx)
            player:setY(oldY + dy)
        end
    
        local newX, newY = player:getX(), player:getY()
       --[[ print(string.format(
            "[SPK] spkUpdateMove: new pos (%.4f, %.4f)",
            newX, newY
        ))]]
    end
    
    -----------------------------------------------------------
    -- Main update
    -----------------------------------------------------------
    
    function SPK.OnPlayerUpdate(player)
        if not player or player:isDead() then return end
        if not player:isLocalPlayer() then return end
        if player:getVehicle() then return end
    
        -- 1) Sample movement for relative direction / clombat
        spkUpdateLastMoveVector(player)
    
        -- 2) Movement lock from anim (if you re-enable it)
        --spkUpdateMovementLock(player)
    
        -- 3) Process velocity bursts from XML anim vars
        local raw = player:getVariableString("SPK_MoveID")
        if raw and raw ~= "" then
            local speed = player:getVariableString("SPK_MoveSpeed")
            local dir   = player:getVariableString("SPK_MoveDir")
    
            --[[print(string.format(
                "[SPK] MoveID=%s dir=%s speed=%s",
                tostring(raw), tostring(dir), tostring(speed)
            ))]]
    
            if raw == "VEL_START" then
                spkStartVelocityMove(player)
            elseif raw == "VEL_END" then
                spkStop(player)
            end
            player:setVariable("SPK_MoveID", "")
        end
    
        local state = SPK.active[player]
        if state then
            spkUpdateMove(player, state)
        end
    
        -- 4) Finally, apply stance-based speed buff on top of everything else
        spkUpdateSpeedBuff(player)
    end
    
    -- Dev-safe: avoid stacking multiple handlers on reload
    Events.OnPlayerUpdate.Remove(SPK.OnPlayerUpdate)
    Events.OnPlayerUpdate.Add(SPK.OnPlayerUpdate)
