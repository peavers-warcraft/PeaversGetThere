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

	_, newY = W:CreateSectionHeader(parentFrame, "Teleport Suggestions", indent, y)
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
