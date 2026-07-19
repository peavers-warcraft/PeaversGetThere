local _, PGT = ...

local RoutePanel = {}
PGT.RoutePanel = RoutePanel

local PeaversCommons = _G.PeaversCommons
local Events = PeaversCommons.Events
local HBD = LibStub("HereBeDragons-2.0")

local MAX_BUTTONS = 8 -- fixed secure-button pool, created once at login
local TICK_INTERVAL = 1.0
local TICKER_KEY = "PGT_RoutePanel"
local HEADER_HEIGHT = 24
local ROW_HEIGHT = 36
local ICON_SIZE = 26

-- Ranking constants (yards); the random multiplier is shared with Router
-- through Capabilities so the two penalty models can't drift
local ON_COOLDOWN_PENALTY = 1e6 -- ready options always beat on-cooldown ones
local IMPROVEMENT_FACTOR = 0.9  -- must beat staying put by 10%

local panel, rows, headerText, combatText
local initialized = false
local pendingInit = false
local pendingRefresh = false
local suggestions = {}
local activeRoute -- route currently rendered as a step list, nil = suggestions
local currentStep = 1

local KIND_ICONS = {
	walk = "Interface\\Icons\\Ability_Rogue_Sprint",
	portal = "Interface\\Icons\\Spell_Arcane_PortalDalaran",
	taxi = "Interface\\Icons\\Ability_Mount_Wyvern_01",
	boat = "Interface\\Icons\\Spell_Frost_SummonWaterElemental",
	zeppelin = "Interface\\Icons\\INV_Misc_Gear_01",
	tram = "Interface\\Icons\\INV_Misc_Gear_01",
}

--------------------------------------------------------------------------------
-- Display/cooldown API wrappers (names shifted across recent client versions)
--------------------------------------------------------------------------------

local function TeleportDisplay(t)
	if t.type == "spell" then
		if C_Spell and C_Spell.GetSpellName then
			return C_Spell.GetSpellName(t.id), C_Spell.GetSpellTexture(t.id)
		end
		local name, _, icon = GetSpellInfo(t.id)
		return name, icon
	end
	-- items and toys; name/icon can lag the item cache, the ticker retries
	local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(t.id)
	local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(t.id)
		or (GetItemIcon and GetItemIcon(t.id))
	return name, icon
end

local function TeleportCooldown(t)
	if t.type == "spell" then
		local info = C_Spell.GetSpellCooldown(t.id)
		if info then
			return info.startTime or 0, info.duration or 0
		end
		return 0, 0
	end
	if C_Item and C_Item.GetItemCooldown then
		local start, duration = C_Item.GetItemCooldown(t.id)
		return start or 0, duration or 0
	end
	if GetItemCooldown then
		local start, duration = GetItemCooldown(t.id)
		return start or 0, duration or 0
	end
	return 0, 0
end

local function IsOnCooldown(t)
	return PGT.Capabilities:GetCooldownRemaining(t) ~= nil
end

--------------------------------------------------------------------------------
-- Ranking
--------------------------------------------------------------------------------

-- Fills and returns the suggestions array for the active guidance target:
-- usable teleports whose destination beats staying put, sorted by resulting
-- straight-line distance to the goal (on-cooldown pushed below ready, random
-- destinations heavily de-ranked, one row for the whole hearthstone family).
function RoutePanel:BuildSuggestions()
	wipe(suggestions)
	local target = PGT.Guidance:GetTarget()
	if not target then
		return suggestions
	end
	local tx, ty, tinstance = HBD:GetWorldCoordinatesFromZone(target.x, target.y, target.map)
	if not tx or not tinstance then
		return suggestions
	end

	local baseline = math.huge
	local px, py, pinstance = HBD:GetPlayerWorldPosition()
	if px and pinstance == tinstance then
		baseline = HBD:GetWorldDistance(tinstance, px, py, tx, ty)
	end

	local hearthDest = PGT.Capabilities:GetHearthstoneDest()
	local bestHearth

	for _, cap in ipairs(PGT.Capabilities:GetUsableTeleports()) do
		local t = cap.teleport
		local dest = t.hearthstone and hearthDest or cap.dest
		if dest then
			local wx, wy, winstance = HBD:GetWorldCoordinatesFromZone(dest.x, dest.y, dest.map)
			if wx and winstance == tinstance then
				local distance = HBD:GetWorldDistance(tinstance, wx, wy, tx, ty)
				if t.random then
					distance = distance * PGT.Capabilities.RANDOM_MULTIPLIER
				end
				if distance < baseline * IMPROVEMENT_FACTOR then
					local onCooldown = IsOnCooldown(t)
					local suggestion = {
						teleport = t,
						dest = dest,
						distance = distance,
						score = distance + (onCooldown and ON_COOLDOWN_PENALTY or 0),
						onCooldown = onCooldown,
					}
					if t.hearthstone then
						if not bestHearth or suggestion.score < bestHearth.score then
							bestHearth = suggestion
						end
					else
						suggestions[#suggestions + 1] = suggestion
					end
				end
			end
		end
	end

	if bestHearth then
		suggestions[#suggestions + 1] = bestHearth
	end

	table.sort(suggestions, function(a, b)
		if a.score ~= b.score then
			return a.score < b.score
		end
		return a.teleport.id < b.teleport.id
	end)

	local limit = math.min(PGT.Config.maxSuggestions or MAX_BUTTONS, MAX_BUTTONS)
	for i = #suggestions, limit + 1, -1 do
		suggestions[i] = nil
	end
	return suggestions
end

--------------------------------------------------------------------------------
-- Secure rows
--------------------------------------------------------------------------------

-- Out-of-combat only: secure attributes and visibility
local function ApplyAttributes(row, t)
	if not t then
		row:SetAttribute("type", nil)
		row:Hide()
		return
	end
	if t.type == "spell" then
		row:SetAttribute("type", "spell")
		row:SetAttribute("spell", t.id)
	elseif t.type == "toy" then
		row:SetAttribute("type", "toy")
		row:SetAttribute("toy", t.id)
	else
		row:SetAttribute("type", "item")
		row:SetAttribute("item", "item:" .. t.id)
	end
	row:Show()
end

-- Safe in combat: textures, texts, cooldown swipe
local function RenderRowVisuals(row, suggestion)
	local W = PeaversCommons.Widgets
	local t = suggestion.teleport
	local name, icon = TeleportDisplay(t)

	row.bg:SetColorTexture(0, 0, 0, 0)
	row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
	row.name:SetText(name or ("Loading item " .. t.id .. "..."))
	if suggestion.onCooldown then
		row.name:SetTextColor(unpack(W.Colors.textMuted))
	else
		row.name:SetTextColor(unpack(W.Colors.text))
	end
	row.dest:SetTextColor(unpack(W.Colors.textMuted))

	local destText = suggestion.dest.name or ""
	if t.random then
		destText = destText .. " (random destination)"
	end
	row.dest:SetText(destText)

	local start, duration = TeleportCooldown(t)
	if start ~= row.cdStart or duration ~= row.cdDuration then
		row.cdStart, row.cdDuration = start, duration
		row.cooldown:SetCooldown(start, duration)
	end
end

local LEG_VERBS = {
	portal = "Take the ",
	taxi = "Fly to ",
	boat = "Take the boat to ",
	zeppelin = "Take the zeppelin to ",
	tram = "Ride the tram to ",
}

local function LegText(leg)
	if leg.kind == "portal" then
		return LEG_VERBS.portal .. (leg.fromName or ("portal to " .. (leg.to.name or "")))
	end
	local verb = LEG_VERBS[leg.kind]
	if verb then
		return verb .. (leg.to.name or "")
	end
	return "Go to " .. (leg.to.name or "")
end

-- Safe in combat: step text, icons, state coloring, cooldown swipe
local function RenderLegVisuals(row, index, leg)
	local W = PeaversCommons.Widgets
	local icon, name

	if leg.kind == "teleport" then
		local t = leg.action.teleport
		local displayName, displayIcon = TeleportDisplay(t)
		icon = displayIcon
		name = index .. ". Use " .. (displayName or ("teleport " .. t.id))
		local start, duration = TeleportCooldown(t)
		if start ~= row.cdStart or duration ~= row.cdDuration then
			row.cdStart, row.cdDuration = start, duration
			row.cooldown:SetCooldown(start, duration)
		end
	else
		icon = KIND_ICONS[leg.kind] or KIND_ICONS.walk
		name = index .. ". " .. LegText(leg)
		if row.cdStart ~= 0 or row.cdDuration ~= 0 then
			row.cdStart, row.cdDuration = 0, 0
			row.cooldown:SetCooldown(0, 0)
		end
	end

	row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
	row.name:SetText(name)
	if leg.kind == "walk" then
		row.dest:SetText(("%s (~%ds)"):format(leg.to.name or "", math.floor(leg.cost + 0.5)))
	else
		row.dest:SetText(leg.to.name or "")
	end

	if index < currentStep then
		row.name:SetTextColor(unpack(W.Colors.textMuted))
		row.dest:SetTextColor(unpack(W.Colors.textMuted))
		row.bg:SetColorTexture(0, 0, 0, 0)
	elseif index == currentStep then
		row.name:SetTextColor(unpack(W.Colors.accentLight))
		row.dest:SetTextColor(unpack(W.Colors.textSec))
		row.bg:SetColorTexture(0.66, 0.33, 0.97, 0.12)
	else
		row.name:SetTextColor(unpack(W.Colors.text))
		row.dest:SetTextColor(unpack(W.Colors.textMuted))
		row.bg:SetColorTexture(0, 0, 0, 0)
	end
end

local function CreateRow(index)
	local W = PeaversCommons.Widgets
	local row = CreateFrame("Button", "PeaversGetThereRouteButton" .. index, panel,
		"SecureActionButtonTemplate")
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 6, -(HEADER_HEIGHT + (index - 1) * ROW_HEIGHT))
	row:SetPoint("RIGHT", -6, 0)
	-- Single edge matching the user's action-button CVar; registering both
	-- edges double-fires the action and breaks cast-time teleports
	row:RegisterForClicks(GetCVarBool("ActionButtonUseKeyDown") and "AnyDown" or "AnyUp")

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.04)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(0, 0, 0, 0)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ICON_SIZE, ICON_SIZE)
	row.icon:SetPoint("LEFT", 4, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	row.cooldown = CreateFrame("Cooldown", nil, row, "CooldownFrameTemplate")
	row.cooldown:SetAllPoints(row.icon)
	row.cooldown:SetDrawEdge(false)

	row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
	row.name:SetPoint("RIGHT", -4, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.dest = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.dest:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
	row.dest:SetPoint("RIGHT", -4, 0)
	row.dest:SetJustifyH("LEFT")
	row.dest:SetWordWrap(false)
	row.dest:SetTextColor(unpack(W.Colors.textMuted))

	row:Hide()
	return row
end

local function CreatePanel()
	local W = PeaversCommons.Widgets
	panel = W:CreatePanel(UIParent, { name = "PeaversGetThereRoutePanel", width = 300, height = 100 })
	panel:SetFrameStrata("MEDIUM")
	panel:Hide()

	headerText = W:CreateLabel(panel, "Fastest teleports", { color = W.Colors.gold })
	headerText:SetPoint("TOPLEFT", 10, -6)

	combatText = W:CreateLabel(panel, "Suggestions update after combat", {
		font = "GameFontNormalSmall",
		color = W.Colors.textMuted,
	})
	combatText:SetPoint("TOPRIGHT", -10, -8)
	combatText:Hide()

	rows = {}
	for i = 1, MAX_BUTTONS do
		rows[i] = CreateRow(i)
	end
end

--------------------------------------------------------------------------------
-- Refresh / combat queue
--------------------------------------------------------------------------------

local function StopTicker()
	Events:UnregisterOnUpdate(TICKER_KEY)
end

-- Cooldown swipes and late item-cache names, while the panel is visible
local function Tick()
	if activeRoute then
		local count = math.min(#activeRoute.legs, MAX_BUTTONS)
		for i = 1, count do
			if activeRoute.legs[i].kind == "teleport" then
				RenderLegVisuals(rows[i], i, activeRoute.legs[i])
			end
		end
		return
	end
	for i = 1, MAX_BUTTONS do
		local suggestion = suggestions[i]
		if suggestion and rows[i]:IsShown() then
			RenderRowVisuals(rows[i], suggestion)
		end
	end
end

local function HidePanel()
	for i = 1, MAX_BUTTONS do
		ApplyAttributes(rows[i], nil)
	end
	activeRoute = nil
	panel:Hide()
	StopTicker()
end

-- Ordered step list for an active route; teleport steps get live secure
-- buttons, other steps render as inert rows (no type attribute = no action)
local function RenderRoute()
	local legs = activeRoute.legs
	local count = math.min(#legs, MAX_BUTTONS)
	for i = 1, MAX_BUTTONS do
		local leg = i <= count and legs[i] or nil
		local row = rows[i]
		if not leg then
			ApplyAttributes(row, nil)
		else
			if leg.kind == "teleport" then
				ApplyAttributes(row, leg.action.teleport)
			else
				row:SetAttribute("type", nil)
				row:Show()
			end
			RenderLegVisuals(row, i, leg)
		end
	end
	headerText:SetText("Route")
	panel:SetHeight(HEADER_HEIGHT + count * ROW_HEIGHT + 8)
end

-- Everything protected funnels through here: attributes, Show/Hide and
-- anchoring happen only out of combat; in combat the panel keeps its last
-- valid rows (attributes still match their labels) and queues the refresh.
function RoutePanel:Refresh()
	if not initialized then
		pendingRefresh = true
		return
	end
	if InCombatLockdown() then
		pendingRefresh = true
		if panel:IsShown() then
			combatText:Show()
		end
		return
	end
	combatText:Hide()

	local target = PGT.Guidance:GetTarget()
	if not target or not PGT.Config.showSuggestions then
		HidePanel()
		return
	end

	local route, activeLeg = PGT.Guidance:GetRoute()
	if route then
		activeRoute = route
		currentStep = activeLeg or 1
		RenderRoute()
	else
		activeRoute = nil
		self:BuildSuggestions()
		if #suggestions == 0 then
			HidePanel()
			return
		end
		for i = 1, MAX_BUTTONS do
			local suggestion = suggestions[i]
			ApplyAttributes(rows[i], suggestion and suggestion.teleport)
			if suggestion then
				RenderRowVisuals(rows[i], suggestion)
			end
		end
		headerText:SetText("Fastest teleports")
		panel:SetHeight(HEADER_HEIGHT + #suggestions * ROW_HEIGHT + 8)
	end

	local statusFrame = PGT.Guidance.GetStatusFrame and PGT.Guidance:GetStatusFrame()
	if statusFrame then
		panel:ClearAllPoints()
		panel:SetPoint("TOP", statusFrame, "BOTTOM", 0, -4)
	end
	panel:Show()
	Events:RegisterOnUpdate(TICK_INTERVAL, Tick, TICKER_KEY)
end

-- Combat-safe leg advancement: only recolors/redraws step visuals; the
-- secure attributes were applied for the whole route up front.
function RoutePanel:SetCurrentStep(index)
	if not initialized or not activeRoute or not panel:IsShown() then
		return
	end
	currentStep = index
	local count = math.min(#activeRoute.legs, MAX_BUTTONS)
	for i = 1, count do
		RenderLegVisuals(rows[i], i, activeRoute.legs[i])
	end
end

local regenRegistered = false

function RoutePanel:Initialize()
	if initialized then
		return
	end

	if not regenRegistered then
		regenRegistered = true
		Events:RegisterEvent("PLAYER_REGEN_ENABLED", function()
			if pendingInit then
				pendingInit = false
				RoutePanel:Initialize()
			end
			if pendingRefresh and initialized then
				pendingRefresh = false
				RoutePanel:Refresh()
			end
		end)
	end

	-- /reload mid-combat: secure buttons cannot be created under lockdown
	if InCombatLockdown() then
		pendingInit = true
		return
	end

	CreatePanel()
	initialized = true

	if pendingRefresh then
		pendingRefresh = false
		self:Refresh()
	end
end
