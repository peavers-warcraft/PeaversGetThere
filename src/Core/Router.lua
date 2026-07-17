local _, PGT = ...

local Router = {}
PGT.Router = Router

local HBD = LibStub("HereBeDragons-2.0")

-- Walk clamp (seconds): applied to legs AND the direct baseline so the
-- improvement comparison stays clamp-for-clamp fair
local WALK_MIN, WALK_MAX = 2, 900
local TAXI_SPEED = 64             -- yd/s straight-line estimate
local TAXI_OVERHEAD = 5           -- seconds mount/dismount
local TELEPORT_COST = 8           -- 5s cast + 3s loading screen
local IMPROVEMENT = 0.85          -- route must beat direct travel by >15%

--------------------------------------------------------------------------------
-- Binary min-heap (lazy-delete Dijkstra: duplicates allowed, settled skipped)
--------------------------------------------------------------------------------

local Heap = {}
Heap.__index = Heap
Router.Heap = Heap -- exposed for tests

function Heap.New()
	return setmetatable({ costs = {}, ids = {}, size = 0 }, Heap)
end

function Heap:Push(cost, id)
	local costs, ids = self.costs, self.ids
	local i = self.size + 1
	self.size = i
	costs[i], ids[i] = cost, id
	while i > 1 do
		local parent = math.floor(i / 2)
		if costs[parent] <= costs[i] then
			break
		end
		costs[i], costs[parent] = costs[parent], costs[i]
		ids[i], ids[parent] = ids[parent], ids[i]
		i = parent
	end
end

function Heap:Pop()
	local size = self.size
	if size == 0 then
		return nil
	end
	local costs, ids = self.costs, self.ids
	local topCost, topId = costs[1], ids[1]
	costs[1], ids[1] = costs[size], ids[size]
	costs[size], ids[size] = nil, nil
	size = size - 1
	self.size = size
	local i = 1
	while true do
		local child = 2 * i
		if child > size then
			break
		end
		if child + 1 <= size and costs[child + 1] < costs[child] then
			child = child + 1
		end
		if costs[i] <= costs[child] then
			break
		end
		costs[i], costs[child] = costs[child], costs[i]
		ids[i], ids[child] = ids[child], ids[i]
		i = child
	end
	return topCost, topId
end

--------------------------------------------------------------------------------
-- Route search
--------------------------------------------------------------------------------

-- Ground speed keeps taxi edges competitive (at flying speed a straight-line
-- taxi could never beat the parallel walk edge); the smart flyable/skyriding
-- speed heuristic stays deferred per PLAN §12.2.
local function TravelSpeed()
	return PGT.Config.groundSpeed or 14
end

local function WalkCost(instance, x1, y1, x2, y2)
	local distance = HBD:GetWorldDistance(instance, x1, y1, x2, y2)
	local cost = distance / TravelSpeed()
	if cost < WALK_MIN then
		return WALK_MIN
	elseif cost > WALK_MAX then
		return WALK_MAX
	end
	return cost
end

-- Finds the cheapest multi-leg route to an index entry, or nil when direct
-- travel is (nearly) as good or no position/graph data is available.
-- Route: { legs = { { kind, cost, to = {map,x,y,name,wx,wy,instance},
--                     action?, fromName? } }, totalCost, target, startInstance }
function Router:FindRoute(targetEntry)
	local graph = PGT.TravelGraph:Get()
	if not graph then
		return nil
	end
	local px, py, pinstance = HBD:GetPlayerWorldPosition()
	if not px then
		return nil
	end
	local gx, gy, ginstance = HBD:GetWorldCoordinatesFromZone(
		targetEntry.x, targetEntry.y, targetEntry.map)
	if not gx then
		return nil
	end

	-- direct baseline through the SAME cost function as walk legs, so the
	-- >15% comparison is clamp-for-clamp fair
	local directCost = math.huge
	if pinstance == ginstance then
		directCost = WalkCost(ginstance, px, py, gx, gy)
	end

	-- teleport edges out of the virtual start; landings that aren't graph
	-- nodes (hearthstone inns, dungeon entrances) become virtual nodes
	local teleportEdges = {}
	local virtualNodes = {}
	local hearthDest = PGT.Capabilities:GetHearthstoneDest()
	for i, cap in ipairs(PGT.Capabilities:GetUsableTeleports()) do
		local t = cap.teleport
		local dest = t.hearthstone and hearthDest or cap.dest
		if dest then
			-- shared penalty model (Capabilities): random scales the base
			-- cost only, the cooldown remainder is added afterwards
			local cost = TELEPORT_COST
			if t.random then
				cost = cost * PGT.Capabilities.RANDOM_MULTIPLIER
			end
			local remaining = PGT.Capabilities:GetCooldownRemaining(t)
			if remaining and remaining >= PGT.Capabilities.COOLDOWN_DROP then
				cost = nil
			elseif remaining then
				cost = cost + remaining
			end
			if cost then
				local toId = cap.destID and graph.nodes[cap.destID] and cap.destID
				if not toId then
					local wx, wy, winstance = HBD:GetWorldCoordinatesFromZone(dest.x, dest.y, dest.map)
					if wx then
						toId = "@tp:" .. i
						virtualNodes[toId] = {
							map = dest.map, x = dest.x, y = dest.y, name = dest.name,
							wx = wx, wy = wy, instance = winstance,
						}
					end
				end
				if toId then
					teleportEdges[#teleportEdges + 1] = { to = toId, cost = cost, action = cap }
				end
			end
		end
	end

	local dist = { ["@start"] = 0 }
	local pred = {}
	local settled = {}
	local heap = Heap.New()
	heap:Push(0, "@start")

	local function Relax(fromId, toId, cost, kind, action)
		if settled[toId] then
			return
		end
		local candidate = dist[fromId] + cost
		-- bound prune: anything already costlier than the best known path
		-- to the goal can never improve it (all edge costs are positive)
		if candidate >= (dist["@goal"] or math.huge) then
			return
		end
		if candidate < (dist[toId] or math.huge) then
			dist[toId] = candidate
			pred[toId] = { from = fromId, kind = kind, cost = cost, action = action }
			heap:Push(candidate, toId)
		end
	end

	local function RelaxNeighborhood(fromId, node)
		local adjacency = graph.adjacency[fromId]
		if adjacency then
			for _, edge in ipairs(adjacency) do
				Relax(fromId, edge.to, edge.cost,
					edge.method == "walkhint" and "walk" or edge.method)
			end
		end
		if node.kind == "taxi" then
			local taxis = graph.taxiByInstance[node.instance]
			if taxis then
				for _, id in ipairs(taxis) do
					if id ~= fromId then
						local other = graph.nodes[id]
						local flight = HBD:GetWorldDistance(node.instance,
							node.wx, node.wy, other.wx, other.wy) / TAXI_SPEED + TAXI_OVERHEAD
						Relax(fromId, id, flight, "taxi")
					end
				end
			end
		end
		local sameInstance = graph.nodesByInstance[node.instance]
		if sameInstance then
			for _, id in ipairs(sameInstance) do
				if id ~= fromId then
					local other = graph.nodes[id]
					Relax(fromId, id, WalkCost(node.instance,
						node.wx, node.wy, other.wx, other.wy), "walk")
				end
			end
		end
		if node.instance == ginstance then
			Relax(fromId, "@goal", WalkCost(ginstance, node.wx, node.wy, gx, gy), "walk")
		end
	end

	while true do
		local _, u = heap:Pop()
		if not u or u == "@goal" then
			break
		end
		if not settled[u] then
			settled[u] = true
			if u == "@start" then
				for _, edge in ipairs(teleportEdges) do
					Relax("@start", edge.to, edge.cost, "teleport", edge.action)
				end
				local sameInstance = graph.nodesByInstance[pinstance]
				if sameInstance then
					for _, id in ipairs(sameInstance) do
						local node = graph.nodes[id]
						Relax("@start", id, WalkCost(pinstance, px, py, node.wx, node.wy), "walk")
					end
				end
				if pinstance == ginstance then
					Relax("@start", "@goal", WalkCost(pinstance, px, py, gx, gy), "walk")
				end
			else
				local node = graph.nodes[u] or virtualNodes[u]
				if node then
					RelaxNeighborhood(u, node)
				end
			end
		end
	end

	local total = dist["@goal"]
	if not total or total >= directCost * IMPROVEMENT then
		return nil
	end

	-- rebuild the predecessor chain into forward legs
	local chain = {}
	local cursor = "@goal"
	while cursor ~= "@start" do
		local step = pred[cursor]
		chain[#chain + 1] = { id = cursor, edge = step }
		cursor = step.from
	end

	local legs = {}
	for i = #chain, 1, -1 do
		local step = chain[i]
		local toDesc
		if step.id == "@goal" then
			toDesc = {
				map = targetEntry.map, x = targetEntry.x, y = targetEntry.y,
				name = targetEntry.name, wx = gx, wy = gy, instance = ginstance,
			}
		else
			local node = graph.nodes[step.id] or virtualNodes[step.id]
			toDesc = {
				map = node.map, x = node.x, y = node.y, name = node.name,
				wx = node.wx, wy = node.wy, instance = node.instance,
				taxiNodeID = node.taxiNodeID, -- taxi-map assist matches on this
			}
		end
		local fromNode = graph.nodes[step.edge.from]
		legs[#legs + 1] = {
			kind = step.edge.kind,
			cost = step.edge.cost,
			to = toDesc,
			-- departure descriptor: guidance aims a transit leg at the conveyance
			-- (the portal/tram), not its far-side arrival
			from = fromNode and {
				map = fromNode.map, x = fromNode.x, y = fromNode.y, name = fromNode.name,
				wx = fromNode.wx, wy = fromNode.wy, instance = fromNode.instance,
			} or nil,
			action = step.edge.action,
			fromName = fromNode and fromNode.name,
		}
	end

	-- merge consecutive walk legs (QuickRoute pattern)
	local merged = {}
	for _, leg in ipairs(legs) do
		local last = merged[#merged]
		if last and last.kind == "walk" and leg.kind == "walk" then
			last.to = leg.to
			last.cost = last.cost + leg.cost
		else
			merged[#merged + 1] = leg
		end
	end

	-- a pure walk "route" is just direct travel with extra steps
	if #merged == 1 and merged[1].kind == "walk" then
		return nil
	end

	return {
		legs = merged,
		totalCost = total,
		target = targetEntry,
		startInstance = pinstance,
	}
end
