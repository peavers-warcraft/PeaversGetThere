local _, PGT = ...

local MapPins = {}
PGT.MapPins = MapPins

local PeaversCommons = _G.PeaversCommons
local FrameUtils = PeaversCommons.FrameUtils
local HBD = LibStub("HereBeDragons-2.0")
local Pins = LibStub("HereBeDragons-Pins-2.0")

local FALLBACK_TEXTURE = "Interface\\AddOns\\PeaversGetThere\\src\\Media\\Icon.tga"

local function CreatePin(size, atlas)
	local pin = CreateFrame("Frame", nil, UIParent)
	pin:SetSize(size, size)
	local texture = pin:CreateTexture(nil, "OVERLAY")
	texture:SetAllPoints()
	if C_Texture.GetAtlasInfo(atlas) then
		texture:SetAtlas(atlas)
	else
		texture:SetTexture(FALLBACK_TEXTURE)
	end
	pin:Hide()
	return pin
end

local worldPin = CreatePin(24, "Waypoint-MapPin-Untracked")
local minimapPin = CreatePin(14, "Waypoint-MapPin-Minimap-Untracked")

local active
local tomtomUid
local ownedWaypoint -- UiMapPoint we set; nil when the beacon isn't ours

-- The Blizzard waypoint drives the native 3D super-track beacon, but many
-- maps refuse it; walk up the parent chain, translating coordinates, until
-- one accepts (PLAN §3.3).
local function SetBlizzardWaypoint(map, x, y)
	while map do
		if C_Map.CanSetUserWaypointOnMap(map) then
			local point = UiMapPoint.CreateFromCoordinates(map, x, y)
			C_Map.SetUserWaypoint(point)
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
			ownedWaypoint = point
			return true
		end
		local info = C_Map.GetMapInfo(map)
		local parent = info and info.parentMapID
		if not parent or parent <= 0 then
			return false
		end
		x, y = HBD:TranslateZoneCoordinates(x, y, map, parent)
		if not x then
			return false
		end
		map = parent
	end
	return false
end

-- Only clear the Blizzard waypoint if it is still the one we set; the user
-- may have replaced it manually mid-guidance.
local function ClearBlizzardWaypoint()
	if not ownedWaypoint then
		return
	end
	local current = C_Map.GetUserWaypoint()
	if current and current.uiMapID == ownedWaypoint.uiMapID
		and current.position and ownedWaypoint.position
		and math.abs(current.position.x - ownedWaypoint.position.x) < 0.001
		and math.abs(current.position.y - ownedWaypoint.position.y) < 0.001 then
		C_Map.ClearUserWaypoint()
	end
	ownedWaypoint = nil
end

function MapPins:SetTarget(entry)
	self:Clear()
	active = entry

	if not SetBlizzardWaypoint(entry.map, entry.x, entry.y) then
		local Utils = PeaversCommons.Utils
		if Utils then
			Utils.Debug(PGT, "MapPins: no map accepts a waypoint for " .. entry.name
				.. " (map " .. entry.map .. "); HBD pins only")
		end
	end

	FrameUtils.AddTooltip(worldPin, entry.name, entry.zone)
	worldPin:EnableMouse(true)
	Pins:AddWorldMapIconMap(self, worldPin, entry.map, entry.x, entry.y,
		HBD_PINS_WORLDMAP_SHOW_WORLD)

	if PGT.Config.showMinimapPin then
		Pins:AddMinimapIconMap(self, minimapPin, entry.map, entry.x, entry.y, true, true)
	end

	local TomTom = _G.TomTom
	if PGT.Config.useTomTom and TomTom and TomTom.AddWaypoint then
		local ok, uid = pcall(TomTom.AddWaypoint, TomTom, entry.map, entry.x, entry.y, {
			title = entry.name,
			from = "PeaversGetThere",
			persistent = false,
		})
		if ok then
			tomtomUid = uid
		end
	end
end

function MapPins:Clear()
	if not active then
		return
	end
	active = nil

	Pins:RemoveWorldMapIcon(self, worldPin)
	Pins:RemoveMinimapIcon(self, minimapPin)
	ClearBlizzardWaypoint()

	local TomTom = _G.TomTom
	if tomtomUid and TomTom and TomTom.RemoveWaypoint then
		pcall(TomTom.RemoveWaypoint, TomTom, tomtomUid)
	end
	tomtomUid = nil
end

-- Re-applies pins for the active target (settings changes)
function MapPins:Refresh()
	if active then
		self:SetTarget(active)
	end
end
