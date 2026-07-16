--------------------------------------------------------------------------------
-- PeaversGetThere Configuration
-- Uses PeaversCommons.ConfigManager with AceDB-3.0 for profile management
--------------------------------------------------------------------------------

local _, PGT = ...

local PeaversCommons = _G.PeaversCommons
local ConfigManager = PeaversCommons.ConfigManager

local PGT_DEFAULTS = {
	useTomTom = true,
	clearOnArrival = true,
	showMinimapPin = true,
	announceArrival = true,
	arrivalRadius = 40,
	showSuggestions = true,
	maxSuggestions = 6,
	showArrow = true,
	arrowScale = 1.0,
	showMinimapButton = true,
	minimapPos = 220,
	autoTakeFlight = false,
	arrivalSound = true,
	DEBUG_ENABLED = false,

	-- Router walk/fly speed estimates (yd/s); not exposed in the UI yet
	groundSpeed = 14,
	flyingSpeed = 64,

	-- Direction arrow position
	arrowPoint = "CENTER",
	arrowRelativePoint = "CENTER",
	arrowX = 0,
	arrowY = -160,

	-- Search frame position (overrides CommonDefaults' centered 0,0)
	framePoint = "CENTER",
	frameRelativePoint = "CENTER",
	frameX = 0,
	frameY = 180,
}

PGT.Config = ConfigManager:NewWithAceDB(
	PGT,
	PGT_DEFAULTS,
	{
		savedVariablesName = "PeaversGetThereDB",
		profileType = "shared",
	}
)
