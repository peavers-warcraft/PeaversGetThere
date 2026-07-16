# PeaversGetThere — Implementation Plan

> **One-liner:** Type any place in WoW into a search box with autocomplete, and the addon gets you there — direction, map pins, and one-click suggestions for the portals, teleports, toys, and items you already own.

This is the most complex Peavers addon to date: it combines a search index, a personalized travel graph with Dijkstra routing, secure-button teleport integration, and a new data-scraper module. The plan below is staged so every milestone ships something usable on its own.

---

## 1. Product definition

### Features (in priority order)

1. **Search any location** — floating search box (slash command `/pgt` or `/getthere`, optional minimap/keybind) with instant autocomplete over zones, cities, dungeons/raids, flight points, portal hubs, and notable POIs. Results are localized (zone names come from the client).
2. **Guide the player there** — on selection:
   - Sets the Blizzard map pin (`C_Map.SetUserWaypoint`) and enables super-tracking so the native 3D beacon points the way.
   - Places pins on the world map and minimap (HereBeDragons-Pins).
   - Shows distance + compass direction ("2,340 yds NW"), later a TomTom-style arrow.
   - If TomTom is installed, also emits a TomTom waypoint (respect user setting).
3. **Suggest smart routes** — a step-by-step route panel: "1. Click ▶ Teleport: Stormwind → 2. Take the Portal to Valdrakken in the Mage Tower → 3. Fly northwest to X". Teleport/item/toy steps are clickable secure buttons; travel steps set waypoints.
4. **Use what the player owns** — the route engine only suggests teleports the character actually has: class teleports, hearthstone (+ toy variants), Dalaran/Garrison hearthstones, engineering wormholes, M+ dungeon teleports, faction-appropriate portals, discovered flight points. Cooldowns shown, and on-cooldown teleports are de-prioritized (not hidden).

### Non-goals (explicit)

- **No automated movement or casting.** Addons cannot cast spells, use items, or take flights on the player's behalf from insecure code (see §3). Every teleport is a secure button the *user* clicks.
- **No in-instance navigation.** Player coordinates are unavailable in dungeons/raids; guidance pauses inside instances and resumes outside.
- **No mesh/terrain pathfinding.** Point-to-point legs are straight-line bearings, like TomTom. The graph handles the macro-routing; the player handles micro-navigation.
- **No quest/objective integration in v1.** (Possible later: auto-route to the super-tracked quest, QuickRoute-style.)

---

## 2. Existing prior art (validated, mid-2026)

| Project | License | What we take from it |
|---|---|---|
| [Mapzeroth](https://github.com/tr0tsky0/Mapzeroth) | **MIT** | The architecture blueprint AND a fork-able curated node/edge dataset (per-continent node files + edges with method/cost/requirements, Dijkstra pathfinder, multi-leg routes). |
| [QuickRoute](https://github.com/CybotTM/wow-quickroute) | **MIT** | Player teleport scanning w/ cooldown-aware edge costs, walk/fly step merging, test-suite pattern (7,754 assertions, luacheck CI). |
| [HereBeDragons-2.0](https://github.com/Nevcairiel/HereBeDragons) | LibStub lib (permissive) | All coordinate math (world↔zone), cross-zone distance/bearing, minimap + world-map pin management. |
| TomTom | — | Crazy-arrow implementation reference (108-cell pre-rotated sprite atlas); integration target (`TomTom:AddWaypoint`). |
| [HandyNotes_TravelGuide](https://github.com/Dathwada/handynotes-travelguide) | **none** | Cross-check/validation only (freshest curated portal/boat/zeppelin positions). Do not redistribute its data without permission. |
| [TomeOfTeleportation](https://github.com/davidmeen/TomeOfTeleportation), [TeleportMenu](https://github.com/Justw8/TeleportMenu) | **none** | Reference for teleport ID coverage and detection/secure-button patterns; we curate our own ID list. |
| [FarstriderLib](https://www.curseforge.com/wow/addons/farstriderlib) | GPLv3 | Design reference only (GPL — don't copy code into our repo). |
| [WowDbScripts](https://github.com/thespags/WowDbScripts) | BSD-2 | Template for a wago.tools DB2-CSV → Lua scraper. |

Mapzeroth and QuickRoute prove the entire concept works within Blizzard's restrictions. Our differentiators: fleet integration (PeaversCommons UI/config, peavers.io, PeaversConfig), a *search-first* UX (theirs are map/waypoint-first), automated data freshness via the scraper fleet, and the polish bar of the Peavers suite.

---

## 3. Hard platform constraints (design around these)

1. **Protected casting.** `CastSpellByID`, `UseToy`, `UseItemByName`, `RunMacroText` are protected. The only bridge is `SecureActionButtonTemplate`:
   ```lua
   local btn = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
   btn:SetAttribute("type", "spell")    -- or "item", "toy", "macro"
   btn:SetAttribute("spell", 3561)      -- Teleport: Stormwind
   btn:RegisterForClicks("AnyDown", "AnyUp")  -- 10.x+ default is key-down
   ```
   The click must be a hardware event. **Exception:** `TakeTaxiNode(slotIndex)` is *not* protected while the taxi map is open — we may auto-select the right flight destination.
2. **Combat lockdown.** Secure frames cannot be created/moved/shown/hidden or have attributes changed while `InCombatLockdown()`. Queue all secure-button rebuilds to `PLAYER_REGEN_ENABLED`. Route *display* is unrestricted.
3. **One user waypoint.** `C_Map.SetUserWaypoint` holds a single pin; gate every set with `C_Map.CanSetUserWaypointOnMap(uiMapID)` (false on many dungeon/micro maps — fall back to the parent zone map). Our own HBD pins are unlimited; the Blizzard pin is just the super-track beacon.
4. **No player position in instances.** `C_Map.GetPlayerMapPosition` returns nil in dungeons/raids/BGs; `GetPlayerFacing()` can be nil indoors. Guidance UI must degrade gracefully (hide arrow, keep step list).
5. **Localization.** Zone/map/taxi/dungeon names from `C_Map.GetMapInfo`, `C_TaxiMap.GetTaxiNodesForMap`, `C_EncounterJournal.GetDungeonEntrancesForMap` are client-localized for free. Scraped data must carry IDs (uiMapID, spellID, itemID, journalInstanceID) and resolve names at runtime wherever possible; free-text names in scraped data are a fallback and initially enUS-only.

---

## 4. System architecture

Three deliverables, following the established IconSearch pattern (UI addon + data addon + supplier Lambda):

```
┌──────────────────────┐   TOC hard dep    ┌────────────────────────┐
│   PeaversGetThere    │ ────────────────► │  PeaversGetThereData   │
│  (logic + UI addon)  │                   │  (generated data addon)│
│  deps: Data, Commons,│                   │  no deps, always loaded│
│  Config; vendors HBD │                   └───────────▲────────────┘
└──────────────────────┘                               │ PRs (auto-merged)
                                           ┌───────────┴────────────┐
                                           │  getthere-module       │
                                           │  (Java Lambda in       │
                                           │  PeaversAddonDataSupplier)
                                           │  wago.tools CSVs +     │
                                           │  curated seed data     │
                                           └────────────────────────┘
```

- **PeaversGetThere** — search UI, guidance, routing engine, capability scan. Runtime data (localized names, taxi discovery, dungeon entrances) harvested from the client; static data from the Data addon.
- **PeaversGetThereData** — generated Lua tables: travel graph (portals/boats/zeppelins/trams), teleport catalog (spells/items/toys with destinations), taxi-node DB (positions/edges for routing *before* discovery data matters), dungeon-entrance DB (fills the "only discovered instances" gap in the client API), plus a POI search-index supplement.
- **getthere-module** — new Gradle module in `PeaversAddonDataSupplier`, same shape as `iconsearch-module`: fetch → parse → `LuaGeneratorService` → GitHub PR via the `peavers-data-scrapers` app; EventBridge-scheduled.

### 4.1 Repository layouts

**PeaversGetThere**
```
PeaversGetThere/
  PeaversGetThere.toc
  Changelog.lua                    -- auto-generated at release
  Libs/
    HereBeDragons/                 -- vendored: HereBeDragons-2.0.lua, HereBeDragons-Pins-2.0.lua
  src/
    Main.lua                       -- bootstrap (PeaversCommons.AddonInit:Setup)
    Core/
      LocationIndex.lua            -- searchable index build (runtime + Data merge)
      Search.lua                   -- matcher (IconSearch blob-scan pattern)
      TravelGraph.lua              -- graph assembly (static edges + runtime taxi + player edges)
      Capabilities.lua             -- known teleport spells/items/toys/professions scan
      Router.lua                   -- Dijkstra + route → step-list rendering model
      Guidance.lua                 -- active route state machine (leg advancement, arrival)
    UI/
      SearchFrame.lua              -- editbox + autocomplete results dropdown
      RoutePanel.lua               -- step list with secure action buttons
      MapPins.lua                  -- HBD-Pins world map/minimap pins + supertrack + TomTom emit
      Arrow.lua                    -- direction arrow (M6)
    Config/
      ConfigUI.lua                 -- PeaversCommons settings pages + PeaversConfig registration
  .pkgmeta  .peavers.yml  catalog-info.yaml  .luacheckrc  .luarc.json
  .github/workflows/{release,validate-issues}.yml
  local_deploy.ps1  local_deploy.sh
```

TOC (conventions copied from PeaversIconSearch):
```
## Interface: 120001, 120005, 120007      # match fleet at time of scaffold
## Title: |cff3abdf7Peavers|rGetThere
## Notes: Search any location and get guided there
## Dependencies: PeaversGetThereData, PeaversCommons, PeaversConfig
## SavedVariables: PeaversGetThereDB
## X-Curse-Project-ID: <assigned at first release>
Libs\HereBeDragons\HereBeDragons-2.0.lua
Libs\HereBeDragons\HereBeDragons-Pins-2.0.lua
Changelog.lua
src\Core\LocationIndex.lua
... (explicit manifest, Main.lua last)
```

**PeaversGetThereData**
```
PeaversGetThereData/
  PeaversGetThereData.toc          -- NO dependencies (pure provider)
  Changelog.lua
  src/
    Data/
      TravelNodes.lua              -- graph nodes (portals, docks, tram stations, hub anchors)
      TravelEdges.lua              -- typed edges between nodes
      Teleports.lua                -- teleport catalog: spells/items/toys → destination node
      TaxiNodes.lua                -- flight points (from DB2) + intra-continent edge hints
      DungeonEntrances.lua         -- JournalInstanceEntrance-derived, faction-flagged
      SearchExtras.lua             -- extra searchable names/aliases (chunked-string blob)
    Api/Api.lua                    -- _G.PeaversGetThereData.API accessors
    Media/Icon.tga
```
Every data file follows the fleet convention:
```lua
local addonName, addonTable = ...
addonTable.TravelNodes = addonTable.TravelNodes or {}
-- Auto-generated by getthere-module (PeaversAddonDataSupplier) from wago.tools
-- db2 exports (build 12.x.x.xxxxx) + curated seed data. Do not edit by hand.
local data = { updated = "2026-07-16 04:00:00", ... }
```
`Api.lua` promotes `_G.PeaversGetThereData.API`. Small structured tables (graph, teleports) stay plain Lua tables; only the search-extras blob uses the IconSearch chunked-string + `Take...()` ownership-transfer pattern (it's the only one big enough to care).

---

## 5. Data model

### 5.1 Travel graph

Node — a physical location you can stand at (or arrive at):
```lua
-- TravelNodes.lua
[nodeID] = {                       -- stable string key, e.g. "portal:stormwind:valdrakken"
  kind    = "portal_src" | "portal_dst" | "dock" | "tram" | "taxi" | "hub" | "poi",
  map     = uiMapID,
  x, y    = normalized map coords (0–1),
  name    = "Portal to Valdrakken",   -- enUS fallback; resolve localized where an ID exists
  faction = nil | "Alliance" | "Horde",
  req     = nil | { quest = {...}, level = n, prof = "engineering", class = "MAGE", ... },
}
```

Edge — a way to move between nodes:
```lua
-- TravelEdges.lua
{ from = nodeID, to = nodeID,
  method = "portal" | "boat" | "zeppelin" | "tram" | "taxi" | "walkhint",
  cost   = seconds,                -- fixed for transports (incl. avg wait + loading screen)
  req    = ... }                   -- same requirement shape as nodes
```

Runtime-injected edges (never shipped in data):
- **walk/fly** — generated on demand between any two nodes on the same continent: `cost = HBD:GetWorldDistance(...) / speed` (speed by mount capability: ground ~14 yd/s, skyriding ~64 yd/s avg — configurable constants), clamped like Mapzeroth (2–300 s).
- **teleport** — from the player's *virtual position node* to a destination node, for every usable entry in the teleport catalog; `cost = castTime + loadingScreen + cooldownPenalty` (on cooldown: add remaining time, or drop if > threshold).
- **taxi** — between discovered taxi nodes (`isUndiscovered == false`), cost from TaxiPath data or straight-line estimate.
- **hearthstone** — special teleport edge to the bound inn. Destination resolved by matching `GetBindLocation()` text against the location index; if unresolved, the edge is omitted (v1 accepted limitation).

### 5.2 Teleport catalog

```lua
-- Teleports.lua
{ id = 3561,   type = "spell", dest = "hub:stormwind",   class = "MAGE" },
{ id = 140192, type = "item",  dest = "hub:dalaran-legion" },
{ id = 110560, type = "item",  dest = "hub:garrison",    req = { quest = {34378, 34586} } },
{ id = 172924, type = "toy",   dest = "region:shadowlands", random = true, prof = "engineering" },
{ id = 445416, type = "spell", dest = "dungeon:2213", journalInstanceID = 2652 }, -- M+ teleport
{ id = 6948,   type = "item",  hearthstone = true },
{ id = 54452,  type = "toy",   hearthstone = true },
```
Detection at runtime (Capabilities.lua): `C_SpellBook.IsSpellKnown` (fallback `IsSpellKnown`), `PlayerHasToy` + `C_ToyBox.IsToyUsable`, `C_Item.GetItemCount`, `C_QuestLog.IsQuestFlaggedCompleted`, `GetProfessions()` for engineering, `UnitFactionGroup`/class checks. Flyout enumeration (`GetFlyoutInfo`/`GetFlyoutSlotInfo`) as a safety net for mage teleport books and M+ "Hero's Path" flyouts. `random = true` teleports (wormholes) are suggested with a "(random destination)" tag and a generous cost penalty, never as a guaranteed leg.

### 5.3 Location index (search corpus)

Built at login (< 1 s), rebuilt on locale-irrelevant events never; merged from:

| Source | How | Localized? |
|---|---|---|
| All zones/continents/dungeons maps | `C_Map.GetMapChildrenInfo(946, nil, true)` + brute force `C_Map.GetMapInfo(1..3000)` (HBD already does this — reuse `hbd:GetAllMapIDs()`/`GetLocalizedMap`) | ✅ |
| Flight points | `C_TaxiMap.GetTaxiNodesForMap(zone)` per zone map | ✅ |
| Dungeon/raid entrances | `C_EncounterJournal.GetDungeonEntrancesForMap` (discovered) **+ Data.DungeonEntrances** (undiscovered fill) | ✅ / enUS |
| Portal hubs, docks, notable POIs, aliases ("AH", "portal room", "barber") | `Data.SearchExtras` blob | enUS v1 |

Index entry: `display name → { map, x, y, category, icon, nodeID? }`. Serialized into one lowercase blob (IconSearch pattern) as `name<TAB>category tags\n` lines with a parallel Lua array for payloads; zone-map entries have center-of-map coords (`0.5, 0.5`) unless a better anchor exists.

---

## 6. Core engine design

### 6.1 Search (IconSearch pattern, adapted)

- `SearchFrame`: `PeaversCommons.Widgets.CreateInput` editbox; debounce `C_Timer.NewTimer(0.15)` cancelled per keystroke; `MIN_QUERY_LENGTH = 2`; dropdown shows top ~15 results (name, category icon, zone breadcrumb, distance from player).
- Matcher: case-insensitive multi-token substring AND over the blob; longest token is the primary scan needle; results ranked by: exact-prefix match > word-prefix > substring, then by category weight (city/hub > zone > dungeon > taxi > poi), then alphabetical. (Ranking is the one deliberate upgrade over IconSearch's data-order results — a search for "storm" must put Stormwind first.)
- Keyboard: up/down + enter selection, escape closes; `/way`-style direct syntax `\pgt <zone> <x> <y>` supported for power users.

### 6.2 Routing (Mapzeroth/QuickRoute pattern)

1. Build the session graph once (static nodes/edges + discovered taxi nodes), refresh player edges on demand (cheap: teleport portfolio changes rarely; cooldowns read at query time).
2. On search selection: insert virtual `start` node (player world position via `hbd:GetPlayerWorldPosition()`) and `goal` node (target coords); connect `start` to same-continent nodes with walk/fly edges and to all teleport destinations with teleport edges; connect graph nodes near the goal with walk/fly edges to `goal`.
3. Dijkstra (binary-heap priority queue; graph is ~1–2k nodes — trivially fast, but keep it O(E log V) and run it in one frame; if profiling says otherwise, slice with a coroutine).
4. Post-process: merge consecutive walk/fly legs (QuickRoute pattern); drop routes only marginally better than walking ("just fly there" answer); produce 1 primary route + up to 2 alternatives (e.g. "without hearthstone").
5. Recompute triggers: player crosses a leg boundary, teleport used (zone change), cooldown state change on a suggested teleport, or manual refresh. Debounced via `PeaversCommons.UpdateCoordinator` (`combatBehavior = "defer"`).

### 6.3 Guidance state machine (`Guidance.lua`)

States: `Idle → RouteActive(leg n) → Arrived`. Leg advancement: proximity check (`hbd:GetWorldDistance` < threshold, e.g. 40 yd for waypoints, zone-change detection for portals/teleports via `hbd.RegisterCallback("PlayerZoneChanged")`). Each advancement moves the Blizzard pin + supertrack to the next leg target and updates the RoutePanel highlight. Arrival: clear pin (optional setting), play subtle sound, show "You have arrived".

### 6.4 Route panel + secure buttons

- Step list rendered with PeaversCommons Widgets; each teleport step owns a pre-created `SecureActionButtonTemplate` button from a **fixed pool** (e.g. 12 buttons created at login, attributes assigned out of combat only; in combat the panel shows the step as text with a "waiting for combat end" shimmer and applies queued attributes on `PLAYER_REGEN_ENABLED`).
- Cooldown swipe via `CooldownFrame:SetCooldown` fed by `C_Spell.GetSpellCooldown` / `C_Item.GetItemCooldown`.
- Taxi steps: when the player opens the flight map (`TAXIMAP_OPENED`), if the active leg is a taxi edge, highlight/auto-select the destination via `GetAllTaxiNodes` slotIndex + `TakeTaxiNode` (setting-gated auto-fly, default *confirm click*).

---

## 7. Data pipeline (getthere-module)

New Gradle module in `PeaversAddonDataSupplier`, mirroring `iconsearch-module`:

- **Inputs**
  1. `https://wago.tools/db2/{TaxiNodes,TaxiPath,TaxiPathNode,UiMap,UiMapAssignment,AreaTable,JournalInstanceEntrance,JournalInstance}/csv?build=<latest>` (builds from `https://wago.tools/api/builds`; schema changes tracked against `wowdev/WoWDBDefs`). World→uiMap coordinate conversion done offline using UiMapAssignment (port the known transform algorithm; validate against in-game `C_Map.GetMapPosFromWorldPos` spot checks).
  2. **Curated seed data** — `getthere-module/src/main/resources/seed/{nodes,edges,teleports}.json`, hand-maintained in the supplier repo via normal PRs. This is the portal/boat/zeppelin/tram graph and teleport catalog. Initial population: fork **Mapzeroth's MIT data** (attribute in README/LICENSE-THIRD-PARTY), convert to our schema, validate against HandyNotes_TravelGuide in-game (do not copy its data).
- **Processing**: merge scraped + seed → validate (every edge endpoint exists, every uiMapID exists in UiMap.csv, faction/req shapes valid, no orphan nodes) → render via `LuaGeneratorService` (same header conventions, `updated` timestamp).
- **Output**: PR against `PeaversGetThereData` master (`getthere-update-<db>-<timestamp>` branches, GitHub App `peavers-data-scrapers`), auto-merged by the shared `auto-merge.yml`.
- **Schedule**: EventBridge weekly (`cron(0 5 ? * MON *)`) + on-demand via the existing `trigger-scrapers.yml` dispatch — this data only changes on game patches; patch-day runs are manual triggers. Data repo `release.yml` on the fleet-standard 6 h cron picks up merged changes.
- **Testing**: JUnit on parsers + validators; golden-file test for the Lua renderer; a "graph reachability" test (every node reachable from Stormwind AND Orgrimmar respecting faction) that fails the run before a broken graph ships.

---

## 8. Implementation stages

Each milestone is releasable. Ship after M2, iterate publicly.

### M0 — Scaffold (½ day)
- Create both repos from fleet conventions (TOC, .pkgmeta, .peavers.yml, catalog-info.yaml, workflows from `workflow-templates`, luacheck configs, local_deploy scripts, FUNDING).
- Vendor HereBeDragons; bootstrap via `PeaversCommons.AddonInit:Setup`; register with PeaversConfig; `/pgt` opens a placeholder frame.
- Data addon with hand-written stub tables (a dozen Stormwind/Orgrimmar/Valdrakken/Dornogal portals) so the pipeline shape exists before the scraper does.
- ✅ *Accept: both addons load clean in-game (no luacheck errors, `/pgt` responds, Data API returns stub table).*

### M1 — Location index + search UI (2–3 days)
- `LocationIndex` (runtime enumeration + taxi + entrances + Data extras), `Search` matcher with ranking, `SearchFrame` with keyboard navigation.
- ✅ *Accept: typing "dorn" surfaces Dornogal first; "mara" finds Maraudon (entrance); results < 5 ms per keystroke (measure with debugprofilestop).*

### M2 — Guidance MVP (2–3 days) → **first public release**
- On selection: Blizzard pin + supertrack (with `CanSetUserWaypointOnMap` parent-map fallback), HBD world-map + minimap pins, distance/direction text, TomTom emit if present, arrival detection.
- Settings page (pin behavior, TomTom preference, clear-on-arrival).
- ✅ *Accept: search → select → native beacon guides to target across a continent; pins clean up on arrival/cancel; works with and without TomTom.*

### M3 — Teleport portfolio + suggestions (3–4 days)
- `Capabilities` scan, teleport catalog in Data addon (curated full list: class TPs, hearth toys, engineering, M+ teleports, housing), RoutePanel v1 = flat "fastest teleports toward target" list with secure buttons + cooldowns (no graph yet — rank by resulting straight-line distance to goal).
- Combat-lockdown queueing; button pool.
- ✅ *Accept: on a mage, searching Valdrakken suggests Teleport: Valdrakken as a clickable button; hearthstone suggested when bind inn is nearest; nothing errors in combat; suggestions filtered by faction/class/quest gates.*

### M4 — Travel graph + multi-leg routing (4–6 days, the hard one)
- Full graph load, runtime edge injection, Dijkstra, leg merging, `Guidance` state machine, RoutePanel v2 = ordered step list with auto-advancement.
- ✅ *Accept: from Dornogal, routing to Uldum produces portal-room → Orgrimmar/Stormwind → portal → fly chain with sane times; leg advancement fires on zone changes; recompute-on-deviation works; Dijkstra < 10 ms.*

### M5 — Scraper + data automation (3–4 days, parallelizable with M4)
- `getthere-module` (CSV ingestion, seed merge, validators, Lua renderer, GitHub PR), CDK schedule, data-repo auto-merge + 6 h release cron, reachability tests.
- ✅ *Accept: Lambda dry-run produces byte-identical Lua from golden inputs; end-to-end PR lands and auto-merges in the Data repo; graph validation gates failures.*

### M6 — Arrow + polish (2–3 days)
- TomTom-style direction arrow (108-cell atlas, `GetVectorToIcon` + `GetPlayerFacing`, hide when facing unavailable), taxi-map auto-highlight/auto-select, minimap button, keybind, alias polish for SearchExtras, sound/visual arrival flourish.
- ✅ *Accept: arrow tracks smoothly at 60 fps with zero GC churn (no per-frame table allocation); taxi step highlights destination at flight master.*

### M7 — Hardening + launch (2 days)
- QuickRoute-style Lua test suite for Router/Capabilities/Index (headless via busted or in-game test command), edge-case sweep (dead player, instances, war-mode/sharding, level-10 fresh character, cross-faction guild alt), performance pass (login index build budget < 1 s, memory < 5 MB), README + screenshots, CurseForge project IDs into TOC/.peavers.yml, first tagged releases of both addons.
- ✅ *Accept: clean run on a fresh character AND a maxed engineer-mage; no taint errors in a full raid night with the addon active.*

**Total estimate: ~3–4 weeks of focused work**, with M4+M5 parallelizable.

---

## 9. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Curated graph data drifts (Blizzard moves/adds portals) | Wrong routes | Weekly scraper diff vs DB2 + in-game validation mode (`/pgt validate` walks nearby nodes and flags mismatches); community issue templates. |
| Secure button taint bugs | Blizzard UI errors, user trust | Fixed pre-created pool, attributes only out of combat, no reparenting/resizing of secure frames at runtime; taint-test during a raid encounter before every release. |
| `CanSetUserWaypointOnMap` false on target map | No native beacon | Project pin to parent map via `C_Map.GetUserWaypointPositionForMap` logic; HBD pins + arrow still work. |
| Hearthstone bind coords unresolvable from `GetBindLocation()` text | Missing hearth edge | Match against location index; ship curated inn list later; omit edge when unknown (route still valid, just slower). |
| Mapzeroth data fork goes stale upstream | Data debt | We own the fork in seed JSON from day 1; scraper validation + community PRs keep it alive independently. |
| wago.tools schema/build changes | Scraper break | Pin schemas to WoWDBDefs, fail-fast validators, manual trigger path for patch day. |
| Interface bumps each patch | Addon flagged outdated | Fleet-wide TOC bump process already exists — include both repos. |

## 10. Licensing & attribution

- Fork Mapzeroth data/algorithm ideas under MIT with attribution (LICENSE-THIRD-PARTY in both repos).
- HereBeDragons vendored per its license (standard WoW lib practice).
- HandyNotes_TravelGuide, TomeOfTeleportation, TeleportMenu: **no license — reference only**, no data/code copying. Optionally ask Dathwada for permission to use TravelGuide data as a validation corpus in CI.
- Our repos: same license as the rest of the fleet.

## 11. API cheat sheet (verified against warcraft.wiki.gg, mid-2026)

```lua
-- Where am I / where is that
C_Map.GetBestMapForUnit("player") ; C_Map.GetPlayerMapPosition(map, "player")  -- nil in instances
C_Map.GetMapInfo(id)  -- {name (localized), mapType, parentMapID}; nil ⇒ invalid id (enumerable 1..3000)
C_Map.GetWorldPosFromMapPos / GetMapPosFromWorldPos  -- zone↔world coords

-- Beacon
C_Map.CanSetUserWaypointOnMap(map)
C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(map, x, y)) ; C_Map.ClearUserWaypoint()
C_SuperTrack.SetSuperTrackedUserWaypoint(true)   -- native 3D beacon
C_SuperTrack.SetSuperTrackedMapPin(Enum.SuperTrackingMapPinType.TaxiNode, nodeID)
-- events: USER_WAYPOINT_UPDATED, SUPER_TRACKING_CHANGED

-- HereBeDragons-2.0
hbd:GetPlayerWorldPosition() ; hbd:GetWorldDistance(inst, x1,y1,x2,y2)
hbd:GetWorldVector(inst, ...) -- angle (rad) + distance → arrow
hbd:GetAllMapIDs() ; hbd:GetLocalizedMap(id) ; callback "PlayerZoneChanged"
pins:AddMinimapIconMap(ref, icon, map, x, y, showInParent, floatOnEdge)
pins:AddWorldMapIconMap(ref, icon, map, x, y, HBD_PINS_WORLDMAP_SHOW_WORLD)
pins:GetVectorToIcon(icon)

-- Capabilities
C_SpellBook.IsSpellKnown(spellID)  -- (IsSpellKnown deprecated 11.2, still works)
PlayerHasToy(itemID) ; C_ToyBox.IsToyUsable(itemID)   -- listen TOYS_UPDATED
C_Item.GetItemCount(itemID) ; C_QuestLog.IsQuestFlaggedCompleted(questID)
C_Spell.GetSpellCooldown(spellID) ; C_Item.GetItemCooldown(itemID)
GetBindLocation() ; GetProfessions() ; GetFlyoutInfo/GetFlyoutSlotInfo

-- Taxi
C_TaxiMap.GetTaxiNodesForMap(map)  -- anywhere; .isUndiscovered (11.0+) = per-char discovery!
C_TaxiMap.GetAllTaxiNodes(map)     -- only at flight master; .slotIndex → TakeTaxiNode(slot) (NOT protected)

-- POIs
C_EncounterJournal.GetDungeonEntrancesForMap(map)  -- discovered only
C_AreaPoiInfo.GetAreaPOIForMap(map) / GetAreaPOIInfo(map, poiID)  -- .linkedUiMapID for portal-ish POIs
```

## 12. Open questions (decide during M0–M1, none block starting)

1. **Addon name of the data repo's search-extras aliases** — start enUS-only, or invest in locale tables from the scraper (UiMap Name_lang columns carry all locales)? *Recommendation: enUS-only v1; the heavy hitters (zones, taxi, dungeons) are already client-localized.*
2. **Skyriding vs ground-mount speed constant** — read `C_MountJournal`/zone flight capability, or a simple user setting? *Recommendation: setting with smart default (skyriding speed when in a skyriding-enabled zone at 80).*
3. **Publish to Wago in addition to CurseForge?** The fleet currently ships CurseForge-only (`X-Curse-Project-ID`); nothing in this plan depends on the answer.
