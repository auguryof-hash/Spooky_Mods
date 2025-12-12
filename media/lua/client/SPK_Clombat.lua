-----------------------------------------------------------
-- SPK_Clombat – Animation-Driven Unarmed Combo System
--
-- Intent:
-- Defines the logic layer for unarmed ("Clombat") combat,
-- driven entirely by animation variables and timing windows.
--
-- This file translates player input into:
-- - Combo index selection
-- - Directional attack variants
-- - Animation variable updates
--
-- Key Responsibilities:
-- - Track per-player combo state
-- - Resolve directional attack intent
-- - Coordinate with AnimSets via variables
--
-- Explicit Non-Goals:
-- - No damage calculation
-- - No movement application
-- - No networking
-----------------------------------------------------------


require "SPK_Controller"

SPK = SPK or {}
SPK.ClombatComboState = SPK.ClombatComboState or {}

-----------------------------------------------------------
-- Debug
-----------------------------------------------------------

SPK.DEBUG_CLOMBAT = false  -- flip this off later if it's too spammy

local function spkDebugClombat(player, msg)
    if not SPK.DEBUG_CLOMBAT then return end
    local prefix = "[SPK-Clombat] "
    print(prefix .. msg)
    -- Optional: have the player say it in MP/SP for quick visual feedback
    if isClient() or not isServer() then
        player:Say(prefix .. msg)
    end
end

-----------------------------------------------------------
-- Variable helpers
-----------------------------------------------------------

local function spkVarBool(player, name)
    local v = player:getVariableString(name)
    return v == "true" or v == "TRUE" or v == "1"
end

local function spkVarInt(player, name, default)
    local v = player:getVariableString(name)
    local n = tonumber(v or "")
    if n == nil then return default or 0 end
    return math.floor(n)
end

-----------------------------------------------------------
-- Helpers
-----------------------------------------------------------

local function spkGetPlayerId(player)
    return player:getOnlineID() or player:getPlayerNum() or 0
end

local function spkGetClombatState(player)
    local id = spkGetPlayerId(player)
    local s = SPK.ClombatComboState[id]
    if not s then
        s = { currentIndex = 1, wasAttacking = false }
        SPK.ClombatComboState[id] = s
    end
    return s
end

function SPK.Clombat_IsComboWindowOpen(player)
    return spkVarBool(player, "SPK_ComboWindowOpen")
end

local function spkGetNextComboIndexFromAnim(player)
    local n = spkVarInt(player, "SPK_NextComboIndex", 1)
    if n < 1 then n = 1 end
    return n
end

-----------------------------------------------------------
-- Attack input entry point (called from BH attackHook)
-----------------------------------------------------------

function SPK.Clombat_OnAttackPressed(player)
    if not player or player:isDead() then return end

    local state = spkGetClombatState(player)

    local attackingNow    = player:isAttacking() or player:isDoShove()
    local comboWindowOpen = SPK.Clombat_IsComboWindowOpen(player)

    local newIndex

    -- If the combo window is open, always chain to the next index.
    if comboWindowOpen then
        newIndex = spkGetNextComboIndexFromAnim(player)
    else
        -- No combo window:
        -- - if not currently attacking, start (or restart) at 1
        -- - if mid-attack, keep current index and ignore input
        if not attackingNow then
            newIndex = 1
        else
            newIndex = state.currentIndex or 1
        end
    end

    state.currentIndex = newIndex

    -- Direction at the moment of input
    local rawDir = SPK.getRelativeMoveDir(player) or "neutral"
    local dirForSelection = (rawDir == "neutral") and "forward" or rawDir

    local dirToken
    if     dirForSelection == "forward"  then dirToken = "Fwd"
    elseif dirForSelection == "backward" then dirToken = "Back"
    elseif dirForSelection == "left"     then dirToken = "Left"
    elseif dirForSelection == "right"    then dirToken = "Right"
    else dirToken = "Fwd"
    end

    local animId = string.format("Clom_%s_%d", dirToken, newIndex)

    -- Push variables for AnimSets
    player:setVariable("SPK_AttackIndex", tostring(newIndex))
    player:setVariable("SPK_AttackDir",   rawDir)
    player:setVariable("SPK_AttackAnim",  animId)

    spkDebugClombat(player,
        string.format("Pressed: attacking=%s comboOpen=%s newIndex=%s animId=%s curStateIndex=%s rawDir=%s",
            tostring(attackingNow),
            tostring(comboWindowOpen),
            tostring(newIndex),
            tostring(animId),
            tostring(state.currentIndex or "?"),
            tostring(rawDir))
    )
end


-----------------------------------------------------------
-- Per-tick combo cleanup (reset when attack fully ends)
-----------------------------------------------------------

function SPK.Clombat_OnPlayerUpdate(player)
    if not player or player:isDead() then return end
    if not player:isLocalPlayer() then return end

    local state = spkGetClombatState(player)

    local attackingNow    = player:isAttacking() or player:isDoShove()
    local comboWindowOpen = SPK.Clombat_IsComboWindowOpen(player)
    local nextIdxStr      = player:getVariableString("SPK_NextComboIndex") or "nil"

    if state.wasAttacking and (not attackingNow) then
        spkDebugClombat(player, "Attack ended; comboOpen=" .. tostring(comboWindowOpen))

        if not comboWindowOpen then
            state.currentIndex = 1
        end

        -- Clear vars when the attack finishes
        player:setVariable("SPK_AttackAnim", "")
        player:setVariable("SPK_AttackDir", "")
        player:setVariable("SPK_AttackIndex", "0")
    end

    state.wasAttacking = attackingNow
end

Events.OnPlayerUpdate.Add(SPK.Clombat_OnPlayerUpdate)
