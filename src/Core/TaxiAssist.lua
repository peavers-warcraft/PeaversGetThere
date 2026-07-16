local _, PGT = ...

local TaxiAssist = {}
PGT.TaxiAssist = TaxiAssist

local PeaversCommons = _G.PeaversCommons
local Events = PeaversCommons.Events

local HIGHLIGHT_DELAY = 0.2 -- flight map pins build shortly after the event

-- Glow textures we created on Blizzard's pooled pins; hidden wholesale on
-- every open so a stale glow can't survive onto a recycled pin
local glows = {}

local function HideAllGlows()
	for _, glow in ipairs(glows) do
		glow:Hide()
	end
end

-- Slot lookup for the active taxi leg's destination (exposed for tests)
function TaxiAssist.FindSlot(nodes, taxiNodeID)
	if not nodes or not taxiNodeID then
		return nil
	end
	for _, node in ipairs(nodes) do
		if node.nodeID == taxiNodeID and node.slotIndex then
			return node.slotIndex, node.name, node.state
		end
	end
	return nil
end

local function HighlightPin(taxiNodeID)
	local flightMap = _G.FlightMapFrame
	if not flightMap or not flightMap.EnumeratePinsByTemplate then
		return
	end
	pcall(function()
		for pin in flightMap:EnumeratePinsByTemplate("FlightMap_FlightPointPinTemplate") do
			if pin.taxiNodeData and pin.taxiNodeData.nodeID == taxiNodeID then
				if not pin.PGTGlow then
					local glow = pin:CreateTexture(nil, "OVERLAY")
					glow:SetPoint("CENTER")
					glow:SetSize(44, 44)
					glow:SetTexture("Interface\\Cooldown\\star4")
					glow:SetBlendMode("ADD")
					glow:SetVertexColor(0.2, 1.0, 0.3, 0.9)
					pin.PGTGlow = glow
					glows[#glows + 1] = glow
				end
				pin.PGTGlow:Show()
			elseif pin.PGTGlow then
				pin.PGTGlow:Hide()
			end
		end
	end)
end

local function OnTaxiMapOpened()
	HideAllGlows() -- pooled pins may still carry a glow from a previous route

	local route, legIndex = PGT.Guidance:GetRoute()
	if not route then
		return
	end
	local leg = route.legs[legIndex]
	if not leg or leg.kind ~= "taxi" or not leg.to.taxiNodeID then
		return
	end

	local mapID = GetTaxiMapID and GetTaxiMapID()
	local nodes = mapID and C_TaxiMap.GetAllTaxiNodes(mapID)
	local slot, name, state = TaxiAssist.FindSlot(nodes, leg.to.taxiNodeID)
	if not slot then
		return
	end

	C_Timer.After(HIGHLIGHT_DELAY, function()
		HighlightPin(leg.to.taxiNodeID)
	end)

	local unreachable = Enum and Enum.FlightPathState
		and state == Enum.FlightPathState.Unreachable
	if PGT.Config.autoTakeFlight and not unreachable then
		-- TakeTaxiNode is not protected while the taxi map is open (PLAN §3.1)
		TakeTaxiNode(slot)
	else
		PeaversCommons.Utils.Print(PGT, "Your route continues to " .. (name or leg.to.name or "the next flight point") .. ".")
	end
end

function TaxiAssist:Initialize()
	Events:RegisterEvent("TAXIMAP_OPENED", OnTaxiMapOpened)
end
