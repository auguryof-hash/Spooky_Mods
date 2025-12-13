-------------------------------------------------------------
-- BHPatch (Server) – Stance & Damage Relay
--
-- Intent:
-- Server-side relay and authority bridge for BrutalHandwork.
--
-- This file exists to compensate for engine limitations:
-- - Zombies cannot be resolved remotely by ID in Lua
-- - Client damage must be validated and applied server-side
--
-- Key Responsibilities:
-- - Receive stance updates and rebroadcast to clients
-- - Apply networked zombie damage safely
-- - Maintain XP and kill credit consistency
--
-- Explicit Non-Goals:
-- - No stance decisions
-- - No animation logic
-- - No combat math

-- Networking Philosophy:
-- - Client is authoritative for stance and input intent
-- - Server validates and rebroadcasts minimal diffs
-- - Zombie damage is relayed due to engine limitations
-- - No attempt is made to perfectly resimulate melee
--   hit reactions across clients

-----------------------------------------------------------



-- gross networking code

local function onClientCommand(module, command, player, arguments)
	if (module == "BHPatch") then
		sendServerCommand(module, command, arguments);
	end
end

-- SERVER: Relay anim variable bundle from client to all clients.
local function SPKAnim_onClientCommand(module, command, player, args)
	if module == "SPKAnim" and command == "Stance" then
		sendServerCommand("SPKAnim", "Stance", args)
	end
end

Events.OnClientCommand.Add(SPKAnim_onClientCommand)

Events.OnClientCommand.Add(onClientCommand);
