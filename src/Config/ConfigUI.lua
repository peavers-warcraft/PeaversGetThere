local _, PGT = ...

local ConfigUI = {}
PGT.ConfigUI = ConfigUI

local PeaversCommons = _G.PeaversCommons
if not PeaversCommons then
	print("|cffff0000Error:|r PeaversCommons not found.")
	return
end

local W = PeaversCommons.Widgets

local function ResolveWidth(parentFrame, indent)
	local parentWidth = parentFrame:GetWidth() or 0
	if parentWidth > 100 then
		return parentWidth - (indent * 2) - 10
	end
	return 360
end

function ConfigUI:BuildGeneralPage(parentFrame)
	local y = -10
	local indent = 25
	local width = ResolveWidth(parentFrame, indent)

	local _, newY = W:CreateSectionHeader(parentFrame, "Guidance", indent, y)
	y = newY - 8

	local checkboxes = {
		{ key = "useTomTom", label = "Send waypoints to TomTom when available" },
		{ key = "showMinimapPin", label = "Show a minimap pin for the active target" },
		{ key = "clearOnArrival", label = "Clear pins on arrival" },
		{ key = "announceArrival", label = "Announce arrival on screen" },
		{ key = "arrivalSound", label = "Play a sound on arrival" },
		{ key = "showArrow", label = "Show the direction arrow" },
		{ key = "showMinimapButton", label = "Show the minimap button" },
		{ key = "autoTakeFlight", label = "Auto-select the flight when your route uses a taxi" },
	}

	for _, option in ipairs(checkboxes) do
		local checkbox = W:CreateCheckbox(parentFrame, option.label, {
			checked = PGT.Config[option.key],
			width = width,
			onChange = function(checked)
				PGT.Config[option.key] = checked
				PGT.Config:Save()
				if option.key == "showMinimapPin" or option.key == "useTomTom" then
					PGT.MapPins:Refresh()
				elseif option.key == "showArrow" then
					PGT.Arrow:Refresh()
				elseif option.key == "showMinimapButton" then
					PGT.MinimapButton:ApplySettings()
				end
			end,
		})
		checkbox:SetPoint("TOPLEFT", indent, y)
		y = y - 28
	end

	y = y - 8
	local radiusSlider = W:CreateSlider(parentFrame, "Arrival radius", {
		min = 10, max = 100, step = 5,
		value = PGT.Config.arrivalRadius,
		width = width,
		format = function(v)
			return math.floor(v + 0.5) .. " yds"
		end,
		onChange = function(value)
			PGT.Config.arrivalRadius = value
			PGT.Config:Save()
		end,
	})
	radiusSlider:SetPoint("TOPLEFT", indent, y)
	y = y - 52

	local arrowSlider = W:CreateSlider(parentFrame, "Direction arrow scale", {
		min = 0.5, max = 2.0, step = 0.1,
		value = PGT.Config.arrowScale,
		width = width,
		format = function(v)
			return string.format("%.1fx", v)
		end,
		onChange = function(value)
			PGT.Config.arrowScale = value
			PGT.Config:Save()
			PGT.Arrow:Refresh()
		end,
	})
	arrowSlider:SetPoint("TOPLEFT", indent, y)
	y = y - 52

	parentFrame:SetHeight(math.abs(y) + 30)
end

function ConfigUI:BuildSuggestionsPage(parentFrame)
	local y = -10
	local indent = 25
	local width = ResolveWidth(parentFrame, indent)

	local _, newY = W:CreateSectionHeader(parentFrame, "Teleport Suggestions", indent, y)
	y = newY - 8

	local suggestionsCheckbox = W:CreateCheckbox(parentFrame, "Suggest your fastest teleports toward the target", {
		checked = PGT.Config.showSuggestions,
		width = width,
		onChange = function(checked)
			PGT.Config.showSuggestions = checked
			PGT.Config:Save()
			PGT.RoutePanel:Refresh()
		end,
	})
	suggestionsCheckbox:SetPoint("TOPLEFT", indent, y)
	y = y - 36

	local maxSlider = W:CreateSlider(parentFrame, "Max suggestions", {
		min = 1, max = 8, step = 1,
		value = PGT.Config.maxSuggestions,
		width = width,
		onChange = function(value)
			PGT.Config.maxSuggestions = value
			PGT.Config:Save()
			PGT.RoutePanel:Refresh()
		end,
	})
	maxSlider:SetPoint("TOPLEFT", indent, y)
	y = y - 52

	parentFrame:SetHeight(math.abs(y) + 30)
end

function ConfigUI:BuildInfoPage(parentFrame)
	PeaversCommons.ConfigUIUtils.BuildInfoPage(parentFrame, "Get There", {
		"Search any place in the game - zones, cities, dungeons, flight points, " ..
			"portal hubs, even city services like the auction house - and get " ..
			"guided there with multi-leg routes, map pins, and a direction arrow.",
		{ command = "/pgt", desc = "open the search box (also /getthere)" },
		{ command = "/pgt <zone> <x> <y>", desc = "guide straight to coordinates" },
		{ command = "/pgt clear", desc = "cancel guidance and remove pins" },
		{ command = "/pgt config", desc = "open the configuration panel" },

		{ header = "Why it can't teleport you automatically" },
		"Blizzard protects all casting from addon code - no addon may cast a " ..
			"spell, use an item, or take a flight on its own. The only bridge " ..
			"allowed is a secure button that you physically click. That is " ..
			"exactly what the route panel's teleport steps are: your click casts " ..
			"the teleport, the addon just put the right button under your cursor.",

		{ header = "If the panel says suggestions update after combat" },
		"Secure buttons cannot be rewired during combat - another Blizzard " ..
			"restriction. The panel keeps its last valid buttons until combat " ..
			"ends, then refreshes.",

		{ header = "Where the travel data comes from" },
		"Zones, flight points, and dungeon entrances come from the game client " ..
			"itself, always localized and current. The portal network and " ..
			"teleport catalog ship in the PeaversGetThereData companion addon, " ..
			"refreshed automatically from game-data exports.",
	})
end

function ConfigUI:GetPages()
	return {
		-- First entry renders leftmost and is the default-selected tab
		{ key = "info", label = "Information", builder = function(f) ConfigUI:BuildInfoPage(f) end },
		{ key = "general", label = "General", builder = function(f) ConfigUI:BuildGeneralPage(f) end },
		{ key = "suggestions", label = "Suggestions", builder = function(f) ConfigUI:BuildSuggestionsPage(f) end },
	}
end

-- Legacy single-panel path, kept for the older ConfigRegistry `buildPanel` contract.
function ConfigUI:BuildIntoFrame(parentFrame)
	self:BuildGeneralPage(parentFrame)
	return parentFrame
end

function ConfigUI:OpenOptions()
	local mainFrame = _G.PeaversConfig and _G.PeaversConfig.MainFrame
	if mainFrame then
		mainFrame:Show()
		if mainFrame.SelectAddon then
			mainFrame:SelectAddon("PeaversGetThere")
		end
		return
	end

	if Settings and Settings.OpenToCategory then
		if PGT.directSettingsCategoryID then
			local success = pcall(Settings.OpenToCategory, PGT.directSettingsCategoryID)
			if success then return end
		end
		if PGT.directCategoryID then
			local success = pcall(Settings.OpenToCategory, PGT.directCategoryID)
			if success then return end
		end
	end

	if SettingsPanel then
		SettingsPanel:Open()
	end
end

function ConfigUI:Initialize()
end
