local _, PGT = ...

local Guidance = {}
PGT.Guidance = Guidance

local PeaversCommons = _G.PeaversCommons
local Events = PeaversCommons.Events
local HBD = LibStub("HereBeDragons-2.0")

local TICKER_KEY = "PGT_Guidance"
local TICK_INTERVAL = 0.5
local PAUSED_LINE = "Guidance paused - no position data"
local LEG_RADIUS = 40 -- intermediate waypoints; the final leg uses arrivalRadius

-- Legs that complete via a zone/instance change rather than proximity
local TRANSIT_KINDS = {
	portal = true, teleport = true, boat = true,
	zeppelin = true, tram = true, taxi = true,
}

-- Status line while standing at a transit leg's departure point (the
-- destination is on another continent, so there is no distance to show)
local TRANSIT_LINES = {
	portal = "Take the portal",
	teleport = "Use your teleport",
	taxi = "Take the flight",
	boat = "Board the boat",
	zeppelin = "Board the zeppelin",
	tram = "Ride the tram",
}

-- HBD:GetWorldVector angles run counterclockwise from north (0 = N, pi/2 = W)
local COMPASS = { "N", "NW", "W", "SW", "S", "SE", "E", "NE" }

local target
local route, legIndex
local targetX, targetY, targetInstance
local statusFrame, nameText, distText
local lastLine
local zoneCallbackRegistered = false

local function SetLine(line)
	if line ~= lastLine then
		lastLine = line
		distText:SetText(line)
	end
end

-- Points pins and the status header at the current objective: the active
-- route leg's destination, or the target itself in single-target mode.
local function ApplyCurrentTarget()
	if route then
		local leg = route.legs[legIndex]
		-- On a transit leg you board the conveyance at its DEPARTURE point, not by
		-- walking to the arrival - which can even share this world instance (the
		-- Silvermoon<->Stormwind portal and the Deeprun Tram both stay in instance
		-- 0). Aim the arrow/pin at the departure so guidance leads to the portal,
		-- not across the map toward the far side.
		local aim = (TRANSIT_KINDS[leg.kind] and leg.from) or leg.to
		targetX, targetY, targetInstance = aim.wx, aim.wy, aim.instance
		PGT.MapPins:SetTarget({ map = aim.map, x = aim.x, y = aim.y, name = leg.to.name })
		nameText:SetText(("Step %d/%d - %s"):format(legIndex, #route.legs, leg.to.name or ""))
	else
		targetX, targetY, targetInstance = HBD:GetWorldCoordinatesFromZone(
			target.x, target.y, target.map)
		PGT.MapPins:SetTarget(target)
		nameText:SetText(target.name)
	end
	lastLine = nil
	distText:SetText("")
	if PGT.Arrow then
		PGT.Arrow:ResetSmoothing() -- the objective moved; old ETA samples lie
	end
end

local function OnArrive()
	local entry = target
	target = nil
	route, legIndex = nil, nil
	Events:UnregisterOnUpdate(TICKER_KEY)
	statusFrame:Hide()

	if PGT.Config.announceArrival then
		local message = "You have arrived at " .. entry.name
		if UIErrorsFrame then
			UIErrorsFrame:AddMessage(message, 0.2, 1.0, 0.2)
		else
			print(message)
		end
	end
	if PGT.Config.arrivalSound and PlaySound and SOUNDKIT and SOUNDKIT.MAP_PING then
		PlaySound(SOUNDKIT.MAP_PING)
	end
	if PGT.Config.clearOnArrival then
		PGT.MapPins:Clear()
	end
	if PGT.RoutePanel then
		PGT.RoutePanel:Refresh()
	end
	if PGT.Arrow then
		PGT.Arrow:Refresh()
	end
end

local function AdvanceLeg()
	if legIndex >= #route.legs then
		OnArrive()
		return
	end
	legIndex = legIndex + 1
	ApplyCurrentTarget()
	if PGT.RoutePanel then
		PGT.RoutePanel:SetCurrentStep(legIndex)
	end
end

-- Runs every 0.5s only while a target is active; no table allocation here.
local function Tick()
	if not target then
		return
	end
	local px, py, instance = HBD:GetPlayerWorldPosition()
	-- A transit leg is completed by boarding the conveyance and arriving on the
	-- far map (handled in OnZoneChanged), never by walking to the arrival. Show
	-- the instruction and stop, so we neither aim the arrow at nor auto-advance
	-- toward an arrival that may share this world instance (the Silvermoon<->
	-- Stormwind portal and the Deeprun Tram both sit in instance 0, which the old
	-- instance-change gate silently missed).
	if route and TRANSIT_KINDS[route.legs[legIndex].kind] then
		SetLine(TRANSIT_LINES[route.legs[legIndex].kind] or "In transit")
		return
	end
	if not px or not targetX or instance ~= targetInstance then
		SetLine(PAUSED_LINE)
		return
	end
	local angle, distance = HBD:GetWorldVector(instance, px, py, targetX, targetY)
	if not angle then
		SetLine(PAUSED_LINE)
		return
	end
	local finalLeg = not route or legIndex >= #route.legs
	local threshold = finalLeg and PGT.Config.arrivalRadius or LEG_RADIUS
	if distance <= threshold then
		if finalLeg then
			OnArrive()
		else
			AdvanceLeg()
		end
		return
	end
	local sector = math.floor((math.deg(angle) + 22.5) / 45) % 8
	SetLine(BreakUpLargeNumbers(math.floor(distance + 0.5)) .. " yds " .. COMPASS[sector + 1])
end

local function EnsureStatusFrame()
	if statusFrame then
		return
	end
	local W = PeaversCommons.Widgets

	statusFrame = W:CreatePanel(UIParent, { name = "PeaversGetThereStatus", width = 260, height = 48 })
	statusFrame:SetPoint("TOP", UIParent, "TOP", 0, -140)
	statusFrame:SetMovable(true)
	statusFrame:EnableMouse(true)
	statusFrame:RegisterForDrag("LeftButton")
	statusFrame:SetScript("OnDragStart", statusFrame.StartMoving)
	statusFrame:SetScript("OnDragStop", statusFrame.StopMovingOrSizing)
	statusFrame:SetClampedToScreen(true)
	statusFrame:Hide()

	nameText = W:CreateLabel(statusFrame, "", { color = W.Colors.accentLight })
	nameText:SetPoint("TOPLEFT", 10, -8)
	nameText:SetPoint("TOPRIGHT", -28, -8)
	nameText:SetJustifyH("LEFT")
	nameText:SetWordWrap(false)

	distText = W:CreateLabel(statusFrame, "", { font = "GameFontHighlight" })
	distText:SetPoint("BOTTOMLEFT", 10, 8)

	local close = CreateFrame("Button", nil, statusFrame)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	local closeLabel = W:CreateLabel(close, "x", { color = W.Colors.textMuted })
	closeLabel:SetPoint("CENTER", 0, 1)
	close:SetScript("OnClick", function()
		Guidance:Clear()
	end)
	close:SetScript("OnEnter", function()
		closeLabel:SetTextColor(unpack(W.Colors.danger))
	end)
	close:SetScript("OnLeave", function()
		closeLabel:SetTextColor(unpack(W.Colors.textMuted))
	end)
end

local function OnZoneChanged(_, newMap)
	if not target then
		return
	end
	if route then
		local leg = route.legs[legIndex]
		local px, py, pinstance = HBD:GetPlayerWorldPosition()
		local prevInstance = legIndex > 1 and route.legs[legIndex - 1].to.instance
			or route.startInstance

		-- transit legs complete on landing at their destination map
		if TRANSIT_KINDS[leg.kind] and newMap == leg.to.map then
			AdvanceLeg()
			Tick()
			return
		end

		if pinstance and pinstance ~= prevInstance then
			-- new continent: fast-forward to the LATEST remaining leg it
			-- satisfies (current-leg transit landing, clicking a later
			-- teleport row, hearthing ahead of the plan, ...)
			for i = #route.legs, legIndex, -1 do
				if route.legs[i].to.instance == pinstance then
					if i == legIndex then
						if TRANSIT_KINDS[leg.kind] then
							AdvanceLeg()
							Tick()
						end
					else
						-- a satisfied transit leg is done; resume at its successor
						legIndex = (TRANSIT_KINDS[route.legs[i].kind] and i < #route.legs)
							and (i + 1) or i
						ApplyCurrentTarget()
						if PGT.RoutePanel then
							PGT.RoutePanel:SetCurrentStep(legIndex)
						end
						Tick()
					end
					return
				end
			end

			-- deviation: no remaining leg expects this continent - the plan
			-- is stale, recompute from the new position
			local entry = target
			Guidance:SetTarget(entry)
			return
		end
	end
	Tick()
end

local function RegisterZoneCallback()
	if zoneCallbackRegistered then
		return
	end
	zoneCallbackRegistered = true
	-- Position data (dis)appears on zone/instance transitions; react
	-- immediately instead of waiting out the ticker interval.
	HBD.RegisterCallback(Guidance, "PlayerZoneChanged", OnZoneChanged)
end

function Guidance:SetTarget(entry)
	local wx = HBD:GetWorldCoordinatesFromZone(entry.x, entry.y, entry.map)
	if not wx then
		-- No world projection (interior/unmapped): distance guidance could
		-- never leave "paused", so refuse rather than strand a dead target
		PeaversCommons.Utils.Print(PGT, entry.name .. " has no world position to guide to.")
		return
	end

	EnsureStatusFrame()
	target = entry
	route, legIndex = nil, nil

	-- Multi-leg route when the graph finds one; single-target mode otherwise
	if PGT.Router then
		local ok, result = pcall(function()
			return PGT.Router:FindRoute(entry)
		end)
		if ok then
			route = result
		else
			PeaversCommons.Utils.Debug(PGT, "Guidance: route computation failed - " .. tostring(result))
		end
		if route then
			legIndex = 1
		end
	end

	ApplyCurrentTarget()
	statusFrame:Show()

	Events:RegisterOnUpdate(TICK_INTERVAL, Tick, TICKER_KEY)
	RegisterZoneCallback()
	Tick()

	if PGT.RoutePanel then
		PGT.RoutePanel:Refresh()
	end
	if PGT.Arrow then
		PGT.Arrow:Refresh()
	end
end

function Guidance:GetTarget()
	return target
end

-- World position of the current objective (active leg target or the
-- single-mode target); consumed by the direction arrow every frame.
function Guidance:GetObjectiveWorldPosition()
	return targetX, targetY, targetInstance
end

function Guidance:GetRoute()
	return route, legIndex
end

function Guidance:GetStatusFrame()
	return statusFrame
end

function Guidance:Clear()
	target = nil
	route, legIndex = nil, nil
	Events:UnregisterOnUpdate(TICKER_KEY)
	if statusFrame then
		statusFrame:Hide()
	end
	PGT.MapPins:Clear()
	if PGT.RoutePanel then
		PGT.RoutePanel:Refresh()
	end
	if PGT.Arrow then
		PGT.Arrow:Refresh()
	end
end
