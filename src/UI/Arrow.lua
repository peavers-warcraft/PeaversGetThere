local _, PGT = ...

local Arrow = {}
PGT.Arrow = Arrow

local PeaversCommons = _G.PeaversCommons
local HBD = LibStub("HereBeDragons-2.0")

local UPDATE_INTERVAL = 0.05
-- Blizzard's own player arrow, rotated live via SetRotation: no vendored
-- atlas (TomTom's pre-rotated grid is not license-clean to copy), no table
-- allocation per frame, and label strings rebuilt only when the displayed
-- yard/ETA values actually change. Tinted by facing alignment.
local ARROW_TEXTURE = "Interface\\Minimap\\MinimapArrow"
local SPEED_SMOOTHING = 0.15 -- EMA weight per sample for the approach speed

local frame, arrow, infoText
local lastDistance, approachSpeed
local lastYards, lastEta = -1, -1 -- -2 = label blanked

--------------------------------------------------------------------------------
-- Pure math (exposed for tests)
--------------------------------------------------------------------------------

local PI2 = math.pi * 2

-- Signed rotation from the player's facing to the bearing, normalized to
-- (-pi, pi]; both use the HBD/GetPlayerFacing convention (0 = N, CCW).
function Arrow.ComputeRotation(bearing, facing)
	local diff = (bearing - facing) % PI2
	if diff > math.pi then
		diff = diff - PI2
	end
	return diff
end

-- Green dead ahead, yellow sideways, red behind
function Arrow.ColorForRotation(rotation)
	local alignment = (1 + math.cos(rotation)) / 2
	if alignment > 0.5 then
		return (1 - alignment) * 2, 1, 0
	end
	return 1, alignment * 2, 0
end

function Arrow.SmoothSpeed(previous, instant)
	return previous + (instant - previous) * SPEED_SMOOTHING
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local accumulator = 0

local function BlankLabel()
	if lastYards ~= -2 then
		lastYards, lastEta = -2, -2
		infoText:SetText("")
	end
end

-- Runs only while the arrow frame is shown; no table allocation here.
local function OnUpdate(_, elapsed)
	accumulator = accumulator + elapsed
	if accumulator < UPDATE_INTERVAL then
		return
	end
	local dt = accumulator
	accumulator = 0

	local tx, ty, tinstance = PGT.Guidance:GetObjectiveWorldPosition()
	local px, py, pinstance = HBD:GetPlayerWorldPosition()
	local facing = GetPlayerFacing and GetPlayerFacing()
	if not tx or not px or not facing or pinstance ~= tinstance then
		-- indoors/instances: no position or facing to steer by
		arrow:Hide()
		BlankLabel()
		return
	end
	local bearing, distance = HBD:GetWorldVector(pinstance, px, py, tx, ty)
	if not bearing then
		arrow:Hide()
		BlankLabel()
		return
	end

	local rotation = Arrow.ComputeRotation(bearing, facing)
	arrow:SetRotation(rotation)
	arrow:SetVertexColor(Arrow.ColorForRotation(rotation))
	arrow:Show()

	local instant = lastDistance and ((lastDistance - distance) / dt) or 0
	lastDistance = distance
	approachSpeed = Arrow.SmoothSpeed(approachSpeed or 0, instant)

	local yards = math.floor(distance + 0.5)
	local eta = -1
	if approachSpeed > 0.5 then
		eta = math.floor(distance / approachSpeed + 0.5)
	end
	if yards ~= lastYards or eta ~= lastEta then
		lastYards, lastEta = yards, eta
		if eta >= 0 then
			infoText:SetText(yards .. " yds - " .. math.floor(eta / 60) .. ":"
				.. string.format("%02d", eta % 60))
		else
			infoText:SetText(yards .. " yds")
		end
	end
end

local function EnsureFrame()
	if frame then
		return
	end
	local W = PeaversCommons.Widgets

	frame = CreateFrame("Frame", "PeaversGetThereArrow", UIParent)
	frame:SetSize(56, 72)
	frame:SetPoint(PGT.Config.arrowPoint, UIParent, PGT.Config.arrowRelativePoint,
		PGT.Config.arrowX, PGT.Config.arrowY)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relativePoint, x, y = self:GetPoint()
		PGT.Config.arrowPoint = point
		PGT.Config.arrowRelativePoint = relativePoint
		PGT.Config.arrowX = x
		PGT.Config.arrowY = y
		PGT.Config:Save()
	end)
	frame:SetClampedToScreen(true)
	frame:Hide()

	arrow = frame:CreateTexture(nil, "ARTWORK")
	arrow:SetSize(40, 40)
	arrow:SetPoint("TOP", 0, -4)
	arrow:SetTexture(ARROW_TEXTURE)

	infoText = W:CreateLabel(frame, "", { font = "GameFontHighlightSmall" })
	infoText:SetPoint("BOTTOM", 0, 4)

	frame:SetScript("OnUpdate", OnUpdate)
end

-- Kill the one-sample speed spike when the objective jumps (leg advance,
-- fast-forward, new target): the old distance is meaningless for the new one.
function Arrow:ResetSmoothing()
	lastDistance, approachSpeed = nil, 0
	lastYards, lastEta = -1, -1
end

-- Show while guidance is active and the arrow is enabled; called on target
-- changes and from the settings page.
function Arrow:Refresh()
	if not PGT.Config.showArrow or not PGT.Guidance:GetTarget() then
		if frame then
			frame:Hide()
		end
		return
	end
	EnsureFrame()
	frame:SetScale(PGT.Config.arrowScale or 1)
	self:ResetSmoothing()
	accumulator = UPDATE_INTERVAL -- first visible frame updates immediately
	frame:Show()
end
