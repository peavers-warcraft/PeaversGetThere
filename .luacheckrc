-- PeaversGetThere luacheck config. Thin wrapper over the shared Peavers base (../wow-api).
-- The base supplies the lua51+wow standard, ignore/exclude policy, and stds.wow (WoW API:
-- generated from /papidump when present, else curated). allow_defined_top is off, so every
-- global this addon creates must be listed below — that list is its documented _G footprint.
-- Run: ../wow-api/scripts/lint.sh   (override package path with WOW_API_DIR)

local apiDir = (os and os.getenv and os.getenv("WOW_API_DIR")) or "../wow-api"
local loadBase = loadfile(apiDir .. "/config/luacheckrc.base.lua")

max_line_length = false
codestyle = false

if loadBase then
	local base = loadBase(apiDir)
	std = base.std
	ignore = base.ignore
	exclude_files = base.exclude
	allow_defined_top = base.allow_defined_top
	stds.wow = base.wow

	-- base.globals (PeaversChangelogs, SlashCmdList) + this addon's SavedVariables.
	globals = base.globals
	for _, g in ipairs({"PeaversGetThereDB"}) do globals[#globals + 1] = g end
else
	-- Degraded mode without the ../wow-api checkout: syntax and local-variable
	-- checks still run, but the WoW API surface can't be validated, so global
	-- warnings (11x) are suppressed rather than false-positive on every C_* call.
	std = "lua51"
	allow_defined_top = true
	ignore = {"11"}
	exclude_files = {}
end

-- Vendored HereBeDragons stays lint-exempt
exclude_files[#exclude_files + 1] = "Libs/**/*.lua"

-- Defined at load time by the vendored HereBeDragons-Pins library.
read_globals = {"HBD_PINS_WORLDMAP_SHOW_WORLD"}
