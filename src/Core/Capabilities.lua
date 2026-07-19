local _, PGT = ...

local Capabilities = {}
PGT.Capabilities = Capabilities

local PeaversCommons = _G.PeaversCommons
local Events = PeaversCommons.Events

local ENGINEERING_SKILL_LINE = 202
local RESCAN_DELAY = 1.0

-- Shared teleport penalty model, used by both Router (edge costs, seconds)
-- and RoutePanel (suggestion scores, yards): random-destination teleports
-- scale their BASE value by RANDOM_MULTIPLIER, cooldown penalties are added
-- after; edges with more than COOLDOWN_DROP seconds remaining are dropped.
Capabilities.RANDOM_MULTIPLIER = 4
Capabilities.COOLDOWN_DROP = 600

-- Cached portfolio: array of { teleport = catalog entry, dest = {map,x,y,name}? }.
-- Hearthstone entries carry no dest; it resolves lazily from the bind location.
local usable
local pendingTimer
local pendingCombat = false
local hearthBind, hearthDest

local function IsSpellKnownSafe(spellID)
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		return C_SpellBook.IsSpellKnown(spellID)
	end
	return IsSpellKnown and IsSpellKnown(spellID) or false
end

-- Trade-skill lines by catalog profession name; unknown names fail closed
-- (better to hide a suggestion than offer one the player can't use).
local PROFESSION_SKILL_LINES = {
	engineering = ENGINEERING_SKILL_LINE,
	alchemy = 171,
	blacksmithing = 164,
	enchanting = 333,
	herbalism = 182,
	inscription = 773,
	jewelcrafting = 755,
	leatherworking = 165,
	mining = 186,
	skinning = 393,
	tailoring = 197,
}

local function HasProfession(profName)
	local skillLine = PROFESSION_SKILL_LINES[profName]
	if not skillLine or not GetProfessions then
		return false
	end
	local function Matches(index)
		return index and select(7, GetProfessionInfo(index)) == skillLine
	end
	local prof1, prof2 = GetProfessions()
	return Matches(prof1) or Matches(prof2)
end

local function OwnsTeleport(t)
	if t.type == "spell" then
		return IsSpellKnownSafe(t.id)
	elseif t.type == "toy" then
		return PlayerHasToy(t.id) and C_ToyBox.IsToyUsable(t.id) ~= false
	elseif t.type == "item" then
		return C_Item.GetItemCount(t.id) > 0
	end
	return false
end

local function MeetsRequirements(t, playerClass, playerFaction, playerRace)
	if t.class and t.class ~= playerClass then
		return false
	end
	if t.faction and t.faction ~= playerFaction then
		return false
	end
	if t.race and t.race ~= playerRace then
		return false
	end
	if t.prof and not HasProfession(t.prof) then
		return false
	end
	local req = t.req
	if req then
		if req.level and UnitLevel("player") < req.level then
			return false
		end
		if req.class and req.class ~= playerClass then
			return false
		end
		if req.prof and not HasProfession(req.prof) then
			return false
		end
		if req.quest then
			-- Any-of: paired quest lists carry both factions' versions
			local completed = false
			for _, questID in ipairs(req.quest) do
				if C_QuestLog.IsQuestFlaggedCompleted(questID) then
					completed = true
					break
				end
			end
			if not completed then
				return false
			end
		end
	end
	return true
end

local function GetDataTable(apiName, field)
	local api = _G.PeaversGetThereData and _G.PeaversGetThereData.API
	local getter = api and api[apiName]
	local result
	if getter then
		local ok, data = pcall(getter)
		if ok and type(data) == "table" and type(data[field]) == "table" then
			result = data[field]
		end
	end
	if not result then
		local Utils = PeaversCommons.Utils
		if Utils then
			Utils.Debug(PGT, "Capabilities: " .. apiName
				.. " yielded no data (Data addon missing or format drift)")
		end
	end
	return result
end

-- dest is a TravelNodes key or "dungeon:<journalInstanceID>" resolved against
-- DungeonEntrances; unresolvable dests (entrance DB not yet scraped) skip.
local function ResolveDest(dest, travelNodes, entrances)
	if not dest then
		return nil
	end
	local journalID = dest:match("^dungeon:(%d+)$")
	if journalID then
		local entrance = entrances and entrances[tonumber(journalID)]
		if entrance and entrance.map then
			return { map = entrance.map, x = entrance.x or 0.5, y = entrance.y or 0.5, name = entrance.name }
		end
		return nil
	end
	local node = travelNodes and travelNodes[dest]
	if node and node.map then
		return { map = node.map, x = node.x or 0.5, y = node.y or 0.5, name = node.name }
	end
	return nil
end

-- Full portfolio scan; pure reads, but deferred out of combat regardless.
-- Does not notify: the lazy path in GetUsableTeleports runs during a
-- RoutePanel refresh, and a nested Refresh would double-fill its list.
local function ScanPortfolio()
	if InCombatLockdown() then
		pendingCombat = true
		return
	end

	usable = {}
	local teleports = GetDataTable("GetTeleports", "teleports")
	if not teleports then
		return
	end

	local travelNodes = GetDataTable("GetTravelNodes", "nodes")
	local entrances = GetDataTable("GetDungeonEntrances", "entrances")
	local playerClass = select(2, UnitClass("player"))
	local playerFaction = UnitFactionGroup("player")
	local playerRace = select(2, UnitRace("player"))

	for _, t in ipairs(teleports) do
		-- menu = destination-picker teleports (Mole Machine): no fixed dest
		-- to rank against, out of scope until the route panel grows a picker
		if type(t) == "table" and t.id and t.type and not t.menu
			and MeetsRequirements(t, playerClass, playerFaction, playerRace)
			and OwnsTeleport(t) then
			if t.hearthstone then
				usable[#usable + 1] = { teleport = t }
			else
				local dest = t.dest
				-- Garrisons are the one faction-split destination pair
				if dest == "hub:garrison" and playerFaction == "Horde"
					and travelNodes and travelNodes["hub:garrison-horde"] then
					dest = "hub:garrison-horde"
				end
				local resolved = ResolveDest(dest, travelNodes, entrances)
				if resolved then
					usable[#usable + 1] = { teleport = t, dest = resolved, destID = dest }
				end
			end
		end
	end
end

-- Event-driven rescan: refresh the panel with the new portfolio
function Capabilities:Scan()
	ScanPortfolio()
	if PGT.RoutePanel then
		PGT.RoutePanel:Refresh()
	end
end

function Capabilities:GetUsableTeleports()
	if not usable then
		ScanPortfolio()
	end
	return usable or {}
end

-- Gate check against the current player for any node/edge/teleport-shaped
-- table (class/faction/race/prof fields plus the req sub-table).
function Capabilities:MeetsRequirements(t)
	return MeetsRequirements(t, select(2, UnitClass("player")),
		UnitFactionGroup("player"), select(2, UnitRace("player")))
end

local GCD_THRESHOLD = 2

-- Remaining cooldown in seconds for a catalog entry, or nil when ready
function Capabilities:GetCooldownRemaining(t)
	local start, duration
	if t.type == "spell" then
		if C_Spell and C_Spell.GetSpellCooldown then
			local info = C_Spell.GetSpellCooldown(t.id)
			start, duration = info and info.startTime or 0, info and info.duration or 0
		end
	elseif C_Item.GetItemCooldown then
		start, duration = C_Item.GetItemCooldown(t.id)
	elseif GetItemCooldown then
		start, duration = GetItemCooldown(t.id)
	end
	start, duration = start or 0, duration or 0
	if duration > GCD_THRESHOLD and (start + duration) > GetTime() then
		return start + duration - GetTime()
	end
	return nil
end

-- Bind-inn coordinates for hearthstone entries, matched against the location
-- index by the localized bind name; nil (entry omitted) when unresolved.
function Capabilities:GetHearthstoneDest()
	local bind = GetBindLocation and GetBindLocation()
	if not bind or bind == "" then
		return nil
	end
	if hearthBind ~= bind then
		if not PGT.LocationIndex:IsReady() then
			return nil -- don't cache a miss against an unbuilt index
		end
		hearthBind = bind
		local entry = PGT.LocationIndex:FindByName(bind)
		hearthDest = entry and { map = entry.map, x = entry.x, y = entry.y, name = entry.name } or nil
	end
	return hearthDest
end

function Capabilities:Initialize()
	local function QueueScan()
		if pendingTimer then
			pendingTimer:Cancel()
		end
		pendingTimer = C_Timer.NewTimer(RESCAN_DELAY, function()
			pendingTimer = nil
			Capabilities:Scan()
		end)
	end

	Events:RegisterEvent("SPELLS_CHANGED", QueueScan)
	Events:RegisterEvent("TOYS_UPDATED", QueueScan)
	Events:RegisterEvent("BAG_UPDATE_DELAYED", QueueScan)
	Events:RegisterEvent("HEARTHSTONE_BOUND", function()
		hearthBind = nil
		QueueScan()
	end)
	Events:RegisterEvent("PLAYER_REGEN_ENABLED", function()
		if pendingCombat then
			pendingCombat = false
			QueueScan()
		end
	end)
end
