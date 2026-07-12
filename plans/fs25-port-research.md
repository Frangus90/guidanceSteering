# Research: Porting Guidance Steering (FS22) to FS25

*Research date: 2026-07-11. Sources verified online; see links inline.*

> **Scope decision (2026-07-11):** The port is justified. FS25's built-in
> Steering Assist can ONLY generate whole-field courses (verified in game code —
> see "How the built-in Steering Assist works" below): it requires the vehicle to
> be on a field the farm owns/has a contract for, and has no free A-B line
> capability at all. Guidance Steering's free-form AB lines (straight/curve/
> cardinal/snap), saved named tracks, and off-field use remain unique value.

## TL;DR

The mod's plumbing (vehicle specialization, multiplayer events, XML schema, input
actions) ports nearly 1:1 to FS25. The real work is the **GUI menu + HUD**, which
sit on systems GIANTS reworked in FS25. The strategic complication is that **FS25
ships with a built-in "Steering Assist (GPS)" feature** that covers much of this
mod's core value — a port should focus on what GS still adds on top (saved/named
tracks, AB persistence across sessions, cardinal/snap strategies, MP-shared tracks,
shop GPS configuration on vehicles).

There is **no existing FS25 port** of this mod (verified: upstream
stijnwop/guidanceSteering has no FS25 branch, no fork ports it, ModHub entry is
FS22-only). Note the upstream README states only Wopster may publish this code to
mod sites — relevant for distribution of a port.

## What we're porting (current state of this repo)

- `modDesc.xml`: `descVersion="75"` (FS22), v2.1.6.0, multiplayer, 10 input
  actions, 15 locales, single `extraSourceFiles` entry `src/loader.lua`.
- 35 Lua files: 1 vehicle specialization (`GlobalPositioningSystem.lua`),
  6 multiplayer event classes, 5 GUI files, 5 guidance strategies, FSM/state
  machine (6 files), utils.
- Bootstraps via hooks on `Mission00.load`, `Mission00.loadMission00Finished`,
  `FSBaseMission.delete`, `TypeManager.validateTypes`,
  `FSCareerMissionInfo.saveToXMLFile`, `SavegameSettingsEvent.read/writeStream`,
  plus an overwrite of `StoreItemUtil.getConfigurationsFromXML` for the shop GPS
  configuration.
- Overrides `Drivable.actionEventAccelerate/Brake/Steer` to detect manual input.
- **No i3d files** — track lines are drawn in code; assets are just a DDS UI
  atlas, icon, and 3 ogg sounds (note: `resources/sounds.xml` references `.wav`
  while the files on disk are `.ogg` — pre-existing discrepancy to check during
  the port).

## FS25 modding documentation (official)

| Resource | URL |
|---|---|
| FS25 Scripting API (LUADOC) | https://gdn.giants-software.com/documentation_scripting_fs25.php |
| GDN documentation index | https://gdn.giants-software.com/documentation.php |
| Scripting tutorials | https://gdn.giants-software.com/tutorials.php |
| i3d format docs | https://gdn.giants-software.com/documentation_i3d.php |
| Exporters (Blender/Maya) | https://gdn.giants-software.com/documentation_exporter.php |
| Tool downloads | https://gdn.giants-software.com/downloads.php |
| modDesc reference | ships with the game: `<FS25 install>/shared/xml/documentation/modDesc.html` |

Current FS25 tools: **GIANTS Editor 10.0.13**, GIANTS Studio 10.0.2 (Lua
IDE/debugger), Blender exporter 10.0.2.

The single most useful unofficial reference is the decompiled FS25 `dataS` script
dump: **https://github.com/Dukefarming/FS25-lua-scripting** — search it for any
class/function this mod touches to confirm it still exists and how it changed.

## FS22 → FS25: what changes

There is **no official migration guide** and **no automated script converter**
(GIANTS: "Script mods cannot be auto converted",
https://gdn.giants-software.com/thread.php?categoryId=25&threadId=16242).
GIANTS Editor 10's "File > Open Mod" auto-conversion handles i3d/assets only —
mostly irrelevant here since the mod has no i3d.

### Ports nearly unchanged (verified present in FS25 dataS)

- Specialization system: `SpecializationUtil.registerFunction /
  registerOverwrittenFunction / registerEventListener`, `prerequisitesPresent`.
- Multiplayer: `Event` subclassing, `g_server:broadcastEvent`,
  `streamRead*/streamWrite*` — all 6 event classes should port with little change.
- XML: `XMLFile` API and `XMLValueType`/schema registration intact.
- Input: `InputAction`, `addActionEvent`, modDesc `<actions>`/`<inputBinding>`
  schema unchanged in shape.
- GUI framework classes still exist: `TabbedMenuFrameElement` (which
  `GuidanceSteeringMenu` extends), `SmoothList`, mixins.

### Needs rework

1. **modDesc `descVersion`** — bump from 75 to FS25 range. Verified real values:
   92 (loads), 95 (~game 1.5), 107 (current in FS25_interactiveControl). Use
   100+ to be safe.
2. **HUD (`src/gui/hud/GuidanceSteeringHUD.lua`)** — FS25 introduced
   `g_overlayManager` with named slice IDs
   (`g_overlayManager:createOverlay("gui.xyz", ...)`) replacing much of the FS22
   `Overlay.new(filename, u, v, ...)` UV approach; `Overlay.lua`/`GuiOverlay.lua`
   were rebuilt around slices, and `SpeedMeterDisplay` was reworked into gauge
   modes. The HUD injection points need re-mapping and the DDS atlas may need to
   be registered as slices.
3. **GUI menu/frames + `guiProfiles.xml`** — the FS25 UI was rebuilt; the in-game
   menu is now global `g_inGameMenu` (was `g_currentMission.inGameMenu`), and GUI
   profile names changed extensively. Our profiles extend game base profiles
   (`dialogBg`, `uiInGameMenuHeader`, …) which must be re-validated against FS25's
   `guiProfiles.xml`. See https://forum.giants-software.com/viewtopic.php?t=210596.
4. **Mission/bootstrap hooks** — `Mission00`, `FSBaseMission`,
   `SavegameSettingsEvent`, `TypeManager.validateTypes`,
   `StoreItemUtil.getConfigurationsFromXML` each need verification against FS25
   dataS (names/signatures may have shifted; the pattern itself survives).
5. **Drivable overrides** — `actionEventAccelerate/Brake/Steer` must be checked
   against FS25's `Drivable.lua`; FS25 also has its own steering-assist code
   inside Drivable that we must not fight (see next section).
6. **Old XML API remnants** — the code mixes old `loadXMLFile/getXML*` with the
   new `XMLFile` API; migrate the old calls while touching those files.

### The elephant in the room: FS25 built-in GPS

FS25 base game includes "Steering Assist (GPS)": working width, headland count,
work direction, side offset, visible 3D lines, GPS retrofit for old vehicles
(official: https://www.farming-simulator.com/newsArticle.php?news_id=573, wiki:
https://farmingsimulator.wiki.gg/wiki/GPS_Steering/Farming_Simulator_25).

Consequences for the port:

- Decide the mod's FS25 value proposition: saved/named tracks per field,
  curve-AB strategy, cardinal/snap strategies, MP track sharing, headland state
  machine behavior — things base GPS lacks.
- The specialization must coexist with (or replace/extend) the base game's
  steering assist inside `Drivable` rather than assume it's the only auto-steer.
- This is also why nobody ported it: GIANTS forum thread on "Guidance Steering
  LS 25" points users to the built-in GPS
  (https://forum.giants-software.com/viewtopic.php?t=209448).

## How the built-in Steering Assist works (deep dive, verified in game code)

Verified against the decompiled FS25 dataS Lua (full dump:
https://github.com/MyGameSteamOfficial/fs25-lua-api, cross-checked against
https://github.com/rtmnet/sdk and the Dukefarming dump).

**Implementation:** vehicle specialization **`AIAutomaticSteering`**
(`spec_aiAutomaticSteering`, in `dataS/scripts/vehicles/specializations/`),
paired with `AIModeSelection` (mode toggle WORKER vs STEERING_ASSIST +
`AISettingsDialog`). Course machinery: `FieldCourse` /
`SteeringFieldCourse` / `FieldCourseManager` (`g_fieldCourseManager`), with
client→server course requests via `AIAutomaticSteering*Event` classes.

**Why it can't do free AB lines (the mod's justification):**
- `onUpdateTick` requires the vehicle to be *on a field*
  (`getDensityAtWorldPos(g_currentMission.terrainDetailId, ...) ~= 0`) AND the
  farm to have land access or an active contract
  (`accessHandler:canFarmAccessLand` / `getIsMissionWorkAllowed`). Off-field the
  course is cleared after a timeout.
- The only course source is `FieldCourse.generateByFieldPosition(...)` — a
  whole-field boundary scan + segment generation (async, server-side). There is
  no AB-line-from-two-points entry point anywhere in the spec.

**How it injects steering (coexistence-critical):**
- It does NOT touch `Drivable.actionEventSteer`. It registers **overwritten
  functions on `setSteeringInput` and `updateVehiclePhysics`** (spec-level).
- When active it replaces the player's `axisSide`, calls `superFunc`, then
  forces `self.rotatedTime = spec.steeringValue` *after* the super call — so at
  spec level, the base game wins over any class-level hook that only massages
  `axisSide` beforehand.
- Auto-disengage: any keyboard/mouse steer input disables it instantly; analog
  input >0.1 delta (after a 2.5 s grace period); driving in reverse >1 km/h;
  leaving the vehicle; implement attach/detach regenerates or drops the course.

**Per-vehicle API our spec can (and should) use for coexistence:**
- `vehicle:getAIModeSelection()` vs `AIModeSelection.MODE.STEERING_ASSIST`
- `vehicle:getAIAutomaticSteeringState()` →
  `AIAutomaticSteering.STATE.DISABLED / AVAILABLE / ACTIVE`
- `vehicle:setAIAutomaticSteeringEnabled(bool)` (MP-synced),
  `vehicle:setAIAutomaticSteeringCourse(nil)`
- Plan: GS refuses to engage while base assist state is `ACTIVE` (or force-calls
  `setAIAutomaticSteeringEnabled(false)` when GS engages), and vice-versa warn.
- Base-game inputs to avoid conflicting with: `TOGGLE_AI`,
  `TOGGLE_AI_STEERING`, `TOGGLE_AI_STEERING_LINES`.

**Reassuring precedent — EnhancedVehicle FS25** (track assistant with free AB):
- Hooks `Drivable.updateVehiclePhysics` via `Utils.overwrittenFunction` at class
  level and injects a corrected `axisSide` — the *same* hook surface as its FS22
  version, unchanged. This strongly suggests GS's steering injection
  (`DriveUtil`, Drivable overrides) ports nearly as-is.
- It disengages on its own action event for `AXIS_MOVE_SIDE_VEHICLE`
  (|value| > 0.05), does not hook `setSteeringInput`.
- It completely ignores the base steering assist (no checks) — works because
  users don't run both at once, but GS should do the explicit state check above.

**Line rendering:** base game uses `FieldCourseVisual` /
`FieldCourseVisualTile` — engine-internal, absent from all public dumps,
undocumented; input is a whole-field `SteeringFieldCourse`. Reusing it for AB
lines is a research spike at best. EnhancedVehicle just calls `drawDebugLine`
per-frame from `onDraw` — proven route; GS already draws its own lines, so this
likely ports with minimal change. The "show lines" game setting is
`GameSettings.SETTING.STEERING_ASSIST_LINES`.

## Local FS25 install as reference material

Install at `D:\SteamLibrary\steamapps\common\Farming Simulator 25`. Scripts and
GUI internals are packed (`dataS.gar` 3.17 GB — guiProfiles.xml, slice
definitions, vehicleTypes.xml, input actions all inside; use the GitHub dataS
dumps instead). But these are plain-text and valuable:

- **`shared/xml/documentation/`** — 88 HTML reference docs + 88 XSD schemas,
  including `modDesc.html` (authoritative modDesc format), `vehicle.html`,
  `specializations.html`.
- **`sdk/scriptBindingChanges.txt`** — official list of FS25 Lua binding
  changes. Confirmed breaking change relevant to us:
  **`g_gui:show*Dialog(...)` → `*Dialog.show(...)`** — this directly hits
  `GuidanceSteeringUI`'s `g_gui:showTextInputDialog()` and
  `g_gui:showInfoDialog()` calls (track naming, info popups). Read this file
  fully during the port.
- `shared/inputDevices/` — 43 readable controller/wheel XML configs.
- `data/vehicles/**/*.xml` — plain-text vehicle XMLs for checking real FS25
  vehicle configuration structure.

## Best migration references (same problem domain, already ported)

| Mod | Why useful |
|---|---|
| ZhooL EnhancedVehicle — [FS22 repo](https://github.com/ZhooL/FS22_EnhancedVehicle) vs [FS25 repo](https://github.com/ZhooL/FS25_EnhancedVehicle) | GPS/track-assistant mod with HUD, many input actions, MP. **Diffing the two repos enumerates the real API changes for exactly our kind of mod.** |
| [Courseplay_FS25](https://github.com/Courseplay/Courseplay_FS25) | Large vehicle-scripting codebase that made the jump; good for spec/event/AI patterns. |
| [FS25_AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive) | HUD + GUI + MP-heavy port reference. |
| [FS25_interactiveControl](https://github.com/TobiasF92/FS25_interactiveControl) | High-quality FS25 codebase; current `descVersion="107"` modDesc example. |
| [FS25-lua-scripting (dataS dump)](https://github.com/Dukefarming/FS25-lua-scripting) | Search target for every engine API we call. |

## Suggested porting sequence (draft — not yet an implementation plan)

1. **Scope decision — DONE (see banner at top):** GS ports as the free-form
   AB-line system the base game lacks; coexist with base assist via the
   `getAIAutomaticSteeringState()` / `setAIAutomaticSteeringEnabled(false)`
   mutual-exclusion approach described above.
2. Bump `descVersion` (100+), verify modDesc against FS25's local `modDesc.html`.
3. Get the mod to *load*: fix loader.lua bootstrap hooks against FS25 dataS
   until the specialization registers without Lua errors.
4. Port the specialization + Drivable overrides; resolve interaction with base
   steering assist.
5. Verify/port the 6 MP event classes (likely near-zero changes).
6. Rebuild HUD on `g_overlayManager`/slices.
7. Rebuild GUI XMLs + guiProfiles against FS25 profiles.
8. Savegame + shop configuration (`StoreItemUtil` overwrite) verification.
9. Fix the pre-existing sounds.xml `.wav` vs `.ogg` mismatch while in there.
10. Test: SP load, MP server+client sync, savegame round-trip, all 10 input
    actions, coexistence with base GPS.

Effort estimate: steps 2–5 are days; steps 6–7 (HUD + GUI) are the bulk of the
work and depend on how far the FS25 profile/slice systems diverge — budget the
majority of the port there.

## Distribution note

Upstream README (stijnwop/guidanceSteering): only Wopster is permitted to publish
this mod to mod sites. A private port is fine; public release needs coordination
with the original author.
