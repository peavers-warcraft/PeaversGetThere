# PeaversGetThere — In-Game Smoke Test Checklist

Everything below was verified under simulation (139+ unit tests) but needs one
pass against the live client. Deploy with `.\local_deploy.ps1` (PowerShell) or
`./local_deploy.sh` (macOS), deploy `PeaversGetThereData`, `PeaversCommons`,
and `PeaversConfig` the same way, then `/reload`.

Enable debug output first: `/pgt debug` (surfaces the Data-addon drift and
route-failure logs referenced below).

## M0-M1 — Load, index, search

- [ ] Addon loads with zero Lua errors on a fresh login and on `/reload`.
- [ ] Login index build causes no visible hitch (spread across frames; budget ~12ms/frame). With debug on, no "yielded no entries" warnings appear.
- [ ] `/pgt` and `/getthere` both open the search frame; `/pgt help` lists commands.
- [ ] Typing `dorn` puts **Dornogal** first; `mara` finds the **Maraudon** entrance (visit Desolace-discovered EJ data or check it appears once entrances are known); `ah` finds the **Auction Houses** via alias tags.
- [ ] **EditBox `OnArrowPressed`**: up/down arrows move the selection highlight while the search box is focused; Enter selects; Escape closes.
- [ ] Result rows show a distance ("1,234 yd") when the result is on your continent, blank otherwise.
- [ ] Taxi results show real flight point names; `isUndiscovered` flagging: an undiscovered flight point shows "Flight (unknown)".

## M2 — Guidance

- [ ] Selecting a result sets the Blizzard map pin and the native 3D beacon (super-track). On maps that refuse waypoints, the pin lands on the parent map instead.
- [ ] **Atlas names**: the world-map pin and minimap pin render the `Waypoint-MapPin-Untracked` / `Waypoint-MapPin-Minimap-Untracked` art, not the fallback square icon (fallback = atlas name drifted; harmless but report it).
- [ ] Status frame shows "2,340 yds NW" style text that updates ~2×/second and matches the actual compass direction.
- [ ] Walk within the arrival radius: "You have arrived" on screen, ping sound (if enabled), pins clear (if enabled).
- [ ] With TomTom installed and the setting on: a TomTom waypoint appears on select and disappears on clear/arrival. A waypoint you set *manually* mid-guidance survives our clear.
- [ ] Enter a dungeon: status shows "Guidance paused - no position data" — no errors.

## M3 — Teleport suggestions

- [ ] On a mage targeting Valdrakken from another continent: **Teleport: Valdrakken** appears top-ranked as a clickable secure button; clicking it casts (once — no "Another action is in progress" double-fire; this validates the click-edge CVar handling).
- [ ] **Cooldown API variants**: cooldown swipes render on suggestion icons after using a teleport (validates `C_Spell.GetSpellCooldown` table shape and `C_Item.GetItemCooldown` on 12.x).
- [ ] Hearthstone suggested when the bind inn is nearest; only ONE hearthstone row even if you own several hearth toys.
- [ ] Enter combat with the panel open, change targets, leave combat: rows update only after combat, "Suggestions update after combat" shows meanwhile, zero taint/`ADDON_ACTION_BLOCKED` errors.
- [ ] Fresh/low-level character (empty teleport portfolio): panel simply stays hidden; search and guidance still work; no errors while dead/ghost-running.

## M4 — Routes

- [ ] From Dornogal, target **Uldum**: route = walk to the portal room → portal to Stormwind/Orgrimmar → walk to the Uldum portal → portal to Ramkahen → walk. **Coordinate spot-check per portal room**: each walk step's pin lands on the actual portal, not a wall (data coords are best-effort; report offsets).
- [ ] Legs advance automatically: proximity for walk steps, landing zone changes for portal/teleport steps; current step highlights, completed steps dim.
- [ ] Take a *different* portal than planned (ahead of plan): the route fast-forwards to the matching step instead of stranding.
- [ ] Portal into a continent the route never mentions: route recomputes from the new position.
- [ ] Route computation is instant (<10ms; no frame hitch on selection).
- [ ] Level-10 character: routes avoid flying assumptions (ground-speed walking) and undiscovered flight points; still produce sane portal chains.

## M6 — Arrow, taxi assist, extras

- [ ] Direction arrow points at the objective, rotates smoothly at 60fps, blends green→yellow→red as you turn away; distance + ETA text updates; hides indoors/instances where facing/position is unavailable.
- [ ] Arrow is draggable and remembers position + scale across `/reload`.
- [ ] **FlightMapFrame pin template**: with a route's taxi leg active, opening the flight map glows the destination pin (if no glow appears, the `FlightMap_FlightPointPinTemplate`/`taxiNodeData` internals drifted — the chat hint still prints). Opening the taxi map later with no route leaves no stale glow.
- [ ] Auto-select flight setting ON: the correct flight is taken automatically; unreachable nodes are never auto-taken.
- [ ] Minimap button: click opens search, drag moves it around the rim, position survives `/reload`.
- [ ] Keybinding appears under Options → Keybindings → AddOns and toggles the search frame.
- [ ] `/pgt elwynn forest 34 52` guides to those coordinates; `/pgt config` still opens settings (parser leaves subcommands alone).

## Stability sweep

- [ ] Full raid night (or LFR) with the addon active and a route pending: zero taint errors, zero `ADDON_ACTION_BLOCKED`.
- [ ] War mode on: portals in shared zones may be phased — confirm the deviation recompute recovers if a catalog portal isn't there for you.
- [ ] Disable PeaversGetThereData (out-of-sync simulation — requires temporarily removing the TOC dependency): addon prints the "missing or outdated" notice, search still covers client data, no Lua errors.
- [ ] Memory after login settles under ~5 MB (`/console scriptProfile 1` or an addon profiler).
