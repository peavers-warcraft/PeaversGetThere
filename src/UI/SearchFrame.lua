local _, PGT = ...

local SearchFrame = {}
PGT.SearchFrame = SearchFrame

local PeaversCommons = _G.PeaversCommons
local HBD = LibStub("HereBeDragons-2.0")

local SEARCH_DELAY = 0.15
local FRAME_WIDTH = 420
local HEADER_HEIGHT = 30
local INPUT_HEIGHT = 38
local ROW_HEIGHT = 34
local MAX_ROWS = PGT.Search.MAX_RESULTS

local CATEGORY_TAGS = {
	city = { "City", 0.98, 0.75, 0.15 },
	zone = { "Zone", 0.45, 0.75, 0.98 },
	dungeon = { "Dungeon", 0.66, 0.33, 0.97 },
	service = { "Service", 0.98, 0.60, 0.20 },
	taxi = { "Flight", 0.20, 0.78, 0.35 },
	travel = { "Travel", 0.24, 0.78, 0.78 },
	poi = { "POI", 0.82, 0.83, 0.85 },
}

local frame, input, hintText
local rows = {}
local results = {}
local selectedIndex = 0
local pendingTimer

local function FormatDistance(entry)
	local px, py, playerInstance = HBD:GetPlayerWorldPosition()
	if not px then
		return nil
	end
	local wx, wy, instance = HBD:GetWorldCoordinatesFromZone(entry.x, entry.y, entry.map)
	if not wx or not instance or instance ~= playerInstance then
		return nil
	end
	local distance = HBD:GetWorldDistance(instance, px, py, wx, wy)
	return BreakUpLargeNumbers(math.floor(distance + 0.5)) .. " yd"
end

local function UpdateSelection()
	for i, row in ipairs(rows) do
		if i == selectedIndex then
			row.bg:SetColorTexture(0.66, 0.33, 0.97, 0.15)
		else
			row.bg:SetColorTexture(0, 0, 0, 0)
		end
	end
end

local function Select(index)
	local entry = results[index]
	if not entry then
		return
	end
	SearchFrame:Hide()
	PGT.Guidance:SetTarget(entry)
end

local function RenderResults()
	for i, row in ipairs(rows) do
		local entry = results[i]
		if entry then
			row.name:SetText(entry.name)

			local tag = CATEGORY_TAGS[entry.category] or CATEGORY_TAGS.poi
			row.tag:SetText(entry.undiscovered and (tag[1] .. " (unknown)") or tag[1])
			row.tag:SetTextColor(tag[2], tag[3], tag[4])

			row.zone:SetText(entry.zone or "")
			row.dist:SetText(FormatDistance(entry) or "")
			row:Show()
		else
			row:Hide()
		end
	end

	local shown = math.min(#results, MAX_ROWS)
	hintText:SetShown(shown == 0)
	frame:SetHeight(HEADER_HEIGHT + INPUT_HEIGHT + math.max(shown * ROW_HEIGHT, 24) + 12)

	selectedIndex = shown > 0 and 1 or 0
	UpdateSelection()
end

local function RunSearch()
	local ready = PGT.LocationIndex:IsReady()
	if not ready then
		PGT.LocationIndex:Build() -- no-op unless an earlier build failed
	end
	local query = input:GetText():match("^%s*(.-)%s*$")

	if not ready or #query < PGT.Search.MIN_QUERY_LENGTH then
		wipe(results)
		hintText:SetText(ready and "Type at least 2 characters..."
			or "Building location index...")
		RenderResults()
		return
	end

	local found = PGT.Search:Find(query)
	wipe(results)
	for i, entry in ipairs(found) do
		results[i] = entry
	end
	hintText:SetText("No matches")
	RenderResults()
end

local function OnTextChanged()
	if pendingTimer then
		pendingTimer:Cancel()
	end
	pendingTimer = C_Timer.NewTimer(SEARCH_DELAY, function()
		pendingTimer = nil
		RunSearch()
	end)
end

local function OnArrowPressed(_, key)
	local shown = math.min(#results, MAX_ROWS)
	if shown == 0 then
		return
	end
	if key == "DOWN" then
		selectedIndex = (selectedIndex % shown) + 1
	elseif key == "UP" then
		selectedIndex = ((selectedIndex - 2) % shown) + 1
	else
		return
	end
	UpdateSelection()
end

local function CreateRow(index)
	local row = CreateFrame("Button", nil, frame)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 6, -(HEADER_HEIGHT + INPUT_HEIGHT + (index - 1) * ROW_HEIGHT))
	row:SetPoint("RIGHT", -6, 0)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(0, 0, 0, 0)

	row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", 6, -4)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.tag = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.tag:SetPoint("LEFT", row.name, "RIGHT", 6, 0)

	row.zone = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.zone:SetPoint("BOTTOMLEFT", 6, 4)
	row.zone:SetJustifyH("LEFT")
	row.zone:SetWordWrap(false)
	row.zone:SetTextColor(0.55, 0.56, 0.60)

	row.dist = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.dist:SetPoint("RIGHT", -6, 0)
	row.dist:SetTextColor(0.82, 0.83, 0.85)

	row.name:SetPoint("RIGHT", row.dist, "LEFT", -60, 0)

	row:SetScript("OnClick", function()
		Select(index)
	end)
	row:SetScript("OnEnter", function()
		selectedIndex = index
		UpdateSelection()
	end)

	row:Hide()
	return row
end

local function EnsureFrame()
	if frame then
		return
	end
	local W = PeaversCommons.Widgets

	frame = W:CreatePanel(UIParent, { name = "PeaversGetThereSearch", width = FRAME_WIDTH, height = 100 })
	frame:SetPoint(PGT.Config.framePoint, UIParent,
		PGT.Config.frameRelativePoint, PGT.Config.frameX, PGT.Config.frameY)
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:Hide()

	local titleBar = CreateFrame("Frame", nil, frame)
	titleBar:SetPoint("TOPLEFT", 0, 0)
	titleBar:SetPoint("TOPRIGHT", 0, 0)
	titleBar:SetHeight(HEADER_HEIGHT)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	titleBar:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, relativePoint, x, y = frame:GetPoint()
		PGT.Config.framePoint = point
		PGT.Config.frameRelativePoint = relativePoint
		PGT.Config.frameX = x
		PGT.Config.frameY = y
		PGT.Config:Save()
	end)

	local title = W:CreateLabel(titleBar, "|cff3abdf7Peavers|rGetThere", {})
	title:SetPoint("LEFT", 10, 0)

	local close = CreateFrame("Button", nil, titleBar)
	close:SetSize(16, 16)
	close:SetPoint("RIGHT", -8, 0)
	local closeLabel = W:CreateLabel(close, "x", { color = W.Colors.textMuted })
	closeLabel:SetPoint("CENTER", 0, 1)
	close:SetScript("OnClick", function()
		SearchFrame:Hide()
	end)

	input = W.CreateInput(W, frame, nil, {
		width = FRAME_WIDTH - 20,
		placeholder = "Search zones, dungeons, flight points...",
		onChange = OnTextChanged,
	})
	input:SetPoint("TOPLEFT", 10, -(HEADER_HEIGHT + 4))

	-- Widgets.CreateInput owns enter/escape for generic use; the search box
	-- needs them for select/dismiss, and arrows for list navigation.
	input.editBox:SetScript("OnEnterPressed", function()
		Select(selectedIndex > 0 and selectedIndex or 1)
	end)
	input.editBox:SetScript("OnEscapePressed", function()
		SearchFrame:Hide()
	end)
	input.editBox:SetScript("OnArrowPressed", OnArrowPressed)

	hintText = W:CreateLabel(frame, "Type at least 2 characters...", {
		font = "GameFontNormalSmall",
		color = W.Colors.textMuted,
	})
	hintText:SetPoint("TOPLEFT", 16, -(HEADER_HEIGHT + INPUT_HEIGHT + 6))

	for i = 1, MAX_ROWS do
		rows[i] = CreateRow(i)
	end
end

function SearchFrame:Show()
	EnsureFrame()
	input:SetText("")
	-- SetText fired onChange and queued a debounced search; one is enough
	if pendingTimer then
		pendingTimer:Cancel()
		pendingTimer = nil
	end
	RunSearch()
	frame:Show()
	input.editBox:SetFocus()
end

function SearchFrame:Hide()
	if not frame then
		return
	end
	if pendingTimer then
		pendingTimer:Cancel()
		pendingTimer = nil
	end
	input:ClearFocus()
	frame:Hide()
end

function SearchFrame:Toggle()
	if frame and frame:IsShown() then
		self:Hide()
	else
		self:Show()
	end
end
