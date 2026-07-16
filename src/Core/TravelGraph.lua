local _, PGT = ...

local TravelGraph = {}
PGT.TravelGraph = TravelGraph

local PeaversCommons = _G.PeaversCommons
local Events = PeaversCommons.Events
local HBD = LibStub("HereBeDragons-2.0")

-- Session graph over the Data addon's travel network plus the character's
-- discovered flight points. Known modeling gap: war-mode phasing can hide
-- individual portals in shared zones; the graph assumes catalog portals
-- exist for everyone (worst case the player walks past a missing portal
-- and the deviation recompute picks a new plan).
-- Layout:
--   nodes           [id] = { id, kind, map, x, y, name, wx, wy, instance }
--   adjacency       [id] = { { to, cost, method }, ... }   (static edges)
--   taxiByInstance  [instance] = { taxiNodeId, ... }
--   nodesByInstance [instance] = { nodeId, ... }
-- Walk/fly, taxi-hop and teleport edges are injected by Router at query time.
local graph
local dirty = false

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
			Utils.Debug(PGT, "TravelGraph: " .. apiName
				.. " yielded no data (Data addon missing or format drift)")
		end
	end
	return result
end

local function AddNode(id, kind, map, x, y, name)
	local wx, wy, instance = HBD:GetWorldCoordinatesFromZone(x, y, map)
	if not wx then
		return nil -- unprojectable maps can't participate in world routing
	end
	local node = {
		id = id, kind = kind, map = map, x = x, y = y, name = name,
		wx = wx, wy = wy, instance = instance,
	}
	graph.nodes[id] = node
	local list = graph.nodesByInstance[instance]
	if not list then
		list = {}
		graph.nodesByInstance[instance] = list
	end
	list[#list + 1] = id
	return node
end

local function Build()
	graph = { nodes = {}, adjacency = {}, taxiByInstance = {}, nodesByInstance = {} }

	local nodes = GetDataTable("GetTravelNodes", "nodes")
	if nodes then
		for id, node in pairs(nodes) do
			if type(node) == "table" and node.map
				and PGT.Capabilities:MeetsRequirements(node) then
				AddNode(id, node.kind, node.map, node.x or 0.5, node.y or 0.5, node.name)
			end
		end
	end

	for _, taxi in ipairs(PGT.LocationIndex:GetTaxiNodes()) do
		if not taxi.undiscovered and taxi.nodeID then
			local node = AddNode("taxi:" .. taxi.nodeID, "taxi",
				taxi.map, taxi.x, taxi.y, taxi.name)
			if node then
				node.taxiNodeID = taxi.nodeID
				local list = graph.taxiByInstance[node.instance]
				if not list then
					list = {}
					graph.taxiByInstance[node.instance] = list
				end
				list[#list + 1] = node.id
			end
		end
	end

	local edges = GetDataTable("GetTravelEdges", "edges")
	if edges then
		for _, edge in ipairs(edges) do
			-- endpoints already passed faction/req filtering or they're absent
			if type(edge) == "table" and graph.nodes[edge.from] and graph.nodes[edge.to]
				and (not edge.req or PGT.Capabilities:MeetsRequirements(edge)) then
				local list = graph.adjacency[edge.from]
				if not list then
					list = {}
					graph.adjacency[edge.from] = list
				end
				list[#list + 1] = {
					to = edge.to,
					cost = edge.cost or 15,
					method = edge.method or "portal",
				}
			end
		end
	end
end

-- Lazy accessor: builds on first use after the location index is up,
-- rebuilds after an invalidation (new taxi discoveries).
function TravelGraph:Get()
	if not PGT.LocationIndex:IsReady() then
		return nil
	end
	if not graph or dirty then
		dirty = false
		Build()
	end
	return graph
end

function TravelGraph:Invalidate()
	dirty = true
end

function TravelGraph:Initialize()
	Events:RegisterEvent("TAXIMAP_OPENED", function()
		-- new flight points are discovered at flight masters; refresh this
		-- zone's flags and rebuild lazily on the next route request
		PGT.LocationIndex:RefreshTaxiDiscovery(HBD:GetPlayerZone())
		dirty = true
	end)
end
