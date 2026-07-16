local _, PGT = ...

local LocationIndex = {}
PGT.LocationIndex = LocationIndex

local HBD = LibStub("HereBeDragons-2.0")

-- The index is one lowercase blob of "id:name<TAB>category" lines scanned by
-- Search.lua (IconSearch pattern), plus a parallel payload array holding the
-- display data: { name, map, x, y, category, zone, nodeID?, undiscovered? }.
local blobLower
local payloads = {}
local building = false

-- Enumeration runs in a coroutine resumed once per frame so a full build
-- (~2k maps, taxi + entrance scans per zone) never blocks a single frame.
local BUDGET_MS = 12
local sliceStart = 0

local function Checkpoint()
	if debugprofilestop() - sliceStart > BUDGET_MS then
		coroutine.yield()
	end
end

local lines = {}

-- Taxi payloads doubled up for the travel graph (discovery-aware)
local taxiEntries = {}
local taxiByNodeID = {}

-- tags are extra searchable words (SearchExtras aliases); they join the
-- blob line but never the display name.
local function AddEntry(name, map, x, y, category, zone, nodeID, undiscovered, tags)
	if not name or name == "" or not map then
		return nil
	end
	name = name:gsub("[\t\n\r]", " ") -- externally-sourced names must not break the blob
	local id = #payloads + 1
	local payload = {
		name = name,
		map = map,
		x = x,
		y = y,
		category = category,
		zone = zone,
		nodeID = nodeID,
		undiscovered = undiscovered,
	}
	payloads[id] = payload
	local line = id .. ":" .. name .. "\t" .. category
	if tags and tags ~= "" then
		line = line .. " " .. tags:gsub("[\n\r]", " ")
	end
	lines[#lines + 1] = line
	return payload
end

-- Maps: everything HBD knows about, filtered to the types a player would
-- search for. Cosmic/World/Micro/Orphan maps only duplicate zone names.
-- Dungeon-type maps are collected and only indexed after the Encounter
-- Journal scan, which supplies better (outdoor) entrance entries.
local function AddMaps(zoneMaps, dungeonMaps)
	local mapIDs = HBD:GetAllMapIDs()
	table.sort(mapIDs)

	local Continent = Enum.UIMapType.Continent
	local Zone = Enum.UIMapType.Zone
	local Dungeon = Enum.UIMapType.Dungeon
	local seen = {}

	for _, mapID in ipairs(mapIDs) do
		local info = C_Map.GetMapInfo(mapID)
		local mapType = info and info.mapType
		if mapType == Continent or mapType == Zone or mapType == Dungeon then
			local name = HBD:GetLocalizedMap(mapID) or info.name
			-- Multi-floor and phased maps repeat names; keep the first
			-- (lowest) mapID per name.
			local key = tostring(mapType) .. "\t" .. (name or ""):lower()
			if name and not seen[key] then
				seen[key] = true
				local parentInfo = info.parentMapID and info.parentMapID > 0
					and C_Map.GetMapInfo(info.parentMapID) or nil
				local parentName = parentInfo and parentInfo.name
				if mapType == Dungeon then
					dungeonMaps[#dungeonMaps + 1] = { id = mapID, name = name, parent = parentName }
				else
					AddEntry(name, mapID, 0.5, 0.5, "zone", parentName)
				end
			end
			if mapType == Zone then
				zoneMaps[#zoneMaps + 1] = { id = mapID, name = name }
			end
		end
		Checkpoint()
	end
end

local function AddTaxiNodes(zoneMaps)
	local seen = {}
	for _, zone in ipairs(zoneMaps) do
		local nodes = C_TaxiMap.GetTaxiNodesForMap(zone.id)
		if nodes then
			for _, node in ipairs(nodes) do
				local key = node.nodeID or node.name
				if node.name and node.position and key and not seen[key] then
					seen[key] = true
					local x, y = node.position:GetXY()
					local payload = AddEntry(node.name, zone.id, x, y, "taxi", zone.name,
						node.nodeID, node.isUndiscovered)
					if payload then
						taxiEntries[#taxiEntries + 1] = payload
						if node.nodeID then
							taxiByNodeID[node.nodeID] = payload
						end
					end
				end
			end
		end
		Checkpoint()
	end
end

local function AddDungeonEntrances(zoneMaps, dungeonMaps)
	local seen = {}
	local named = {}
	for _, zone in ipairs(zoneMaps) do
		local entrances = C_EncounterJournal.GetDungeonEntrancesForMap(zone.id)
		if entrances then
			for _, entrance in ipairs(entrances) do
				local key = entrance.journalInstanceID or entrance.name
				if entrance.name and entrance.position and not seen[key] then
					seen[key] = true
					named[entrance.name:lower()] = true
					local x, y = entrance.position:GetXY()
					AddEntry(entrance.name, zone.id, x, y, "dungeon", zone.name)
				end
			end
		end
		Checkpoint()
	end

	-- Instances without a discovered entrance still deserve a hit; index
	-- their own map when it projects to world space (skip pure interiors)
	for _, dungeon in ipairs(dungeonMaps) do
		if not named[dungeon.name:lower()]
			and HBD:GetWorldCoordinatesFromZone(0.5, 0.5, dungeon.id) then
			AddEntry(dungeon.name, dungeon.id, 0.5, 0.5, "dungeon", dungeon.parent)
		end
		Checkpoint()
	end
end

-- Static extras from the Data addon (PeaversGetThereData/src/Api/Api.lua):
--  * GetTravelNodes() -> { updated, nodes = { [nodeID] = node } }; index the
--    hub/poi/portal_src kinds (portal_dst/dock/tram are arrival points the
--    SearchExtras travel entries already name; region is routing-only).
--  * TakeSearchExtras() -> { updated, payloads, chunks } where each chunk
--    holds "payloadIndex:Display Name<TAB>search tags" lines and
--    payloads[i] = { map, x, y, category, nodeID? }.
-- Both guarded — the Data addon evolves independently and a format drift
-- must not break the index — but never silently: zero entries is reported.
local function AddDataExtras()
	local Utils = _G.PeaversCommons and _G.PeaversCommons.Utils
	local function ReportEmpty(source)
		if Utils then
			Utils.Debug(PGT, "LocationIndex: " .. source
				.. " yielded no entries (Data addon missing, empty, or format drift)")
		end
	end

	local data = _G.PeaversGetThereData
	local api = data and data.API
	if not api then
		ReportEmpty("PeaversGetThereData.API")
		return
	end

	local playerFaction = UnitFactionGroup("player")

	local added = 0
	if api.GetTravelNodes then
		local ok, travel = pcall(api.GetTravelNodes)
		local nodes = ok and type(travel) == "table" and type(travel.nodes) == "table"
			and travel.nodes or nil
		if nodes then
			for nodeID, node in pairs(nodes) do
				if type(node) == "table" and node.name and node.map
					and (node.kind == "hub" or node.kind == "poi" or node.kind == "portal_src")
					and (not node.faction or node.faction == playerFaction) then
					local zoneName = HBD:GetLocalizedMap(node.map)
					AddEntry(node.name, node.map, node.x or 0.5, node.y or 0.5,
						node.kind == "hub" and "city" or "poi", zoneName, nodeID)
					added = added + 1
				end
				Checkpoint()
			end
		end
	end
	if added == 0 then
		ReportEmpty("GetTravelNodes")
	end

	added = 0
	if api.TakeSearchExtras then
		local ok, extras = pcall(api.TakeSearchExtras)
		local chunks = ok and type(extras) == "table" and type(extras.chunks) == "table"
			and extras.chunks or nil
		local extraPayloads = ok and type(extras) == "table" and type(extras.payloads) == "table"
			and extras.payloads or nil
		if chunks and extraPayloads then
			local blob = table.concat(chunks, "\n")
			for line in blob:gmatch("[^\n]+") do
				local idx, name, tags = line:match("^(%d+):([^\t]+)\t(.*)$")
				local payload = idx and extraPayloads[tonumber(idx)]
				if type(payload) == "table" and payload.map then
					local zoneName = HBD:GetLocalizedMap(payload.map)
					AddEntry(name, payload.map, payload.x or 0.5, payload.y or 0.5,
						payload.category or "poi", zoneName, payload.nodeID, nil, tags)
					added = added + 1
				end
				Checkpoint()
			end
		end
	end
	if added == 0 then
		ReportEmpty("TakeSearchExtras")
	end
end

local function BuildWorker()
	local zoneMaps = {}
	local dungeonMaps = {}
	AddMaps(zoneMaps, dungeonMaps)
	AddTaxiNodes(zoneMaps)
	AddDungeonEntrances(zoneMaps, dungeonMaps)
	AddDataExtras()

	-- string.lower only folds ASCII bytes, so byte offsets stay aligned with
	-- the original names, including multi-byte UTF-8 (IconSearch pattern).
	blobLower = table.concat(lines, "\n"):lower()
	lines = nil
end

local co

local function Resume()
	sliceStart = debugprofilestop()
	local ok, err = coroutine.resume(co)
	if not ok then
		-- Drop the partial build so the next Build() call starts clean
		-- (SearchFrame retries whenever a search runs before the index is up)
		building = false
		co = nil
		payloads = {}
		lines = {}
		taxiEntries = {}
		taxiByNodeID = {}
		blobLower = nil
		local Utils = _G.PeaversCommons and _G.PeaversCommons.Utils
		if Utils then
			Utils.Debug(PGT, "LocationIndex: build failed - " .. tostring(err))
		end
		geterrorhandler()(err)
		return
	end
	if coroutine.status(co) == "dead" then
		building = false
		co = nil
	else
		C_Timer.After(0, Resume)
	end
end

-- Kick off the async build (idempotent: no-op while building or once built).
function LocationIndex:Build()
	if building or blobLower then
		return
	end
	building = true
	co = coroutine.create(BuildWorker)
	Resume()
end

function LocationIndex:IsReady()
	return blobLower ~= nil
end

function LocationIndex:GetBlob()
	return blobLower
end

function LocationIndex:GetEntry(id)
	return payloads[id]
end

-- All harvested taxi payloads ({ name, map, x, y, nodeID, undiscovered });
-- the travel graph consumes the discovered subset.
function LocationIndex:GetTaxiNodes()
	return taxiEntries
end

-- Re-check per-character discovery for one zone map's flight points (cheap;
-- called when the taxi map opens, where new discoveries happen).
function LocationIndex:RefreshTaxiDiscovery(mapID)
	if not mapID then
		return
	end
	local nodes = C_TaxiMap.GetTaxiNodesForMap(mapID)
	if not nodes then
		return
	end
	for _, node in ipairs(nodes) do
		local entry = node.nodeID and taxiByNodeID[node.nodeID]
		if entry then
			entry.undiscovered = node.isUndiscovered
		end
	end
end

local NAME_LOOKUP_WEIGHT = { city = 1, zone = 2 }

-- Exact display-name lookup (case-insensitive), preferring city > zone >
-- anything else. Used to resolve GetBindLocation() to hearthstone coords.
function LocationIndex:FindByName(name)
	if not blobLower or not name or name == "" then
		return nil
	end
	local wanted = name:lower()
	local best, bestWeight
	for _, entry in ipairs(payloads) do
		if entry.name:lower() == wanted then
			local weight = NAME_LOOKUP_WEIGHT[entry.category] or 3
			if not best or weight < bestWeight then
				best, bestWeight = entry, weight
			end
		end
	end
	return best
end
