local _, PGT = ...

local MinimapButton = {}
PGT.MinimapButton = MinimapButton

local PeaversCommons = _G.PeaversCommons

local BUTTON_RADIUS = 80
local atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end

local button

local function UpdatePosition()
	local angle = math.rad(PGT.Config.minimapPos or 220)
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER",
		math.cos(angle) * BUTTON_RADIUS, math.sin(angle) * BUTTON_RADIUS)
end

local function OnDragUpdate()
	local mx, my = Minimap:GetCenter()
	local cx, cy = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	cx, cy = cx / scale, cy / scale
	PGT.Config.minimapPos = math.deg(atan2(cy - my, cx - mx)) % 360
	UpdatePosition()
end

function MinimapButton:Initialize()
	if button then
		return
	end
	button = CreateFrame("Button", "PeaversGetThereMinimapButton", Minimap)
	button:SetSize(32, 32)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("TOPLEFT", 7, -5)
	icon:SetTexture("Interface\\AddOns\\PeaversGetThere\\src\\Media\\Icon.tga")

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	button:SetScript("OnClick", function()
		PGT.SearchFrame:Toggle()
	end)
	button:SetScript("OnDragStart", function(frame)
		frame:SetScript("OnUpdate", OnDragUpdate)
	end)
	button:SetScript("OnDragStop", function(frame)
		frame:SetScript("OnUpdate", nil)
		PGT.Config:Save()
	end)
	PeaversCommons.FrameUtils.AddTooltip(button, "PeaversGetThere",
		"Click to search for a destination. Drag to move this button.")

	UpdatePosition()
	self:ApplySettings()
end

function MinimapButton:ApplySettings()
	if button then
		button:SetShown(PGT.Config.showMinimapButton)
	end
end
