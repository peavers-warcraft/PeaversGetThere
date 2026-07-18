local addonName, PGT = ...

-- Access the PeaversCommons library
local PeaversCommons = _G.PeaversCommons

-- Initialize addon namespace
PGT.name = addonName
PGT.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "1.0.0"

-- Keybinding surface (Bindings.xml calls the global toggle)
_G.BINDING_HEADER_PEAVERSGETTHERE = "PeaversGetThere"
_G.BINDING_NAME_PEAVERSGETTHERE_TOGGLESEARCH = "Toggle location search"
function _G.PeaversGetThere_ToggleSearch()
	PGT.SearchFrame:Toggle()
end

-- Register slash commands (config/help are added automatically). The alias
-- must exist before Register assigns SlashCmdList, which scans SLASH_* then.
_G.SLASH_PGT2 = "/getthere"
PeaversCommons.SlashCommands:Register(addonName, "pgt", {
	default = function()
		PGT.SearchFrame:Toggle()
	end,
	clear = function()
		PGT.Guidance:Clear()
	end,
})

-- Power syntax on top of the subcommand dispatch: "/pgt elwynn forest 34 52"
-- guides straight to coordinates (0-100 scale). Anything else falls through.
local baseSlashHandler = SlashCmdList["PGT"]
SlashCmdList["PGT"] = function(msg, ...)
	local name, x, y = PGT.Search:ParseWaypointCommand(msg or "")
	if name then
		local entry = PGT.LocationIndex:FindByName(name) or PGT.Search:Find(name)[1]
		if entry then
			PGT.Guidance:SetTarget({
				map = entry.map,
				x = x / 100,
				y = y / 100,
				name = ("%s (%.0f, %.0f)"):format(entry.name, x, y),
				zone = entry.zone,
			})
			return
		end
	end
	baseSlashHandler(msg, ...)
end

-- Initialize the addon
PeaversCommons.Events:Init(addonName, function()
	PGT.Config:Initialize()

	-- The TOC hard-dependency normally guarantees the Data addon, but Curse
	-- installs can desync; every consumer is pcall-guarded, so just say so.
	if not _G.PeaversGetThereData or not _G.PeaversGetThereData.API then
		PeaversCommons.Utils.Print(PGT,
			"PeaversGetThereData is missing or outdated - portals, teleports and routes are disabled until it is installed.")
	end

	if PGT.ConfigUI and PGT.ConfigUI.Initialize then
		PGT.ConfigUI:Initialize()
	end

	PGT.Capabilities:Initialize()
	PGT.TravelGraph:Initialize()
	PGT.RoutePanel:Initialize()
	PGT.TaxiAssist:Initialize()
	PGT.MinimapButton:Initialize()

	-- The search corpus needs live map/taxi/entrance data; build it once the
	-- world is loaded, spread across frames by LocationIndex itself.
	local function OnEnteringWorld()
		PeaversCommons.Events:UnregisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
		PGT.LocationIndex:Build()
	end
	PeaversCommons.Events:RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)

	-- Use the centralized SettingsUI system from PeaversCommons
	C_Timer.After(0.5, function()
		PeaversCommons.SettingsUI:CreateRedirectPage(PGT, addonName, "Peavers Get There")
	end)

	-- Register with PeaversConfig registry
	if PeaversCommons.ConfigRegistry then
		PeaversCommons.ConfigRegistry:Register({
			name = addonName,
			displayName = "Get There",
			description = "Search any location and get guided there",
			addonRef = PGT,
			config = PGT.Config,
			pages = PGT.ConfigUI:GetPages(),
			order = 10,
		})
	end
end, {
	suppressAnnouncement = true
})
