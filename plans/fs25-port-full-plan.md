# FS25 Port — Full Plan (Master)

*Drafted 2026-07-11. This is the end-to-end plan for porting Guidance Steering
v2.1.6.0 (FS22) to FS25. Every API claim was verified against the FS25 dataS
Lua dumps, the FS25 runtime globals dump, and shipping FS25 mods
(EnhancedVehicle, Courseplay, AutoDrive, InteractiveControl, HeadlandManagement,
RealisticHarvesting). Background: `fs25-port-research.md`. Phase 1 detail:
`fs25-port-phase1-loading.md`.*

## The one-paragraph version

The mod's engine plumbing survived FS22→FS25 almost entirely: bootstrap hooks,
specialization system, multiplayer events, XML, input, sounds, line drawing
(`drawDebugLine`), 3D text, network position compression — all verified
unchanged. Three areas need real work, in ascending size: **(1)** the shop
configuration injection (API moved and became class-based — small, has a
template), **(2)** the HUD (hook points survive but the speedometer atlas
constants it borrowed are gone — medium), **(3)** the GUI menu (the code
mechanism survives 1:1, but ~10 of the 12 base-game profiles our XML styling
inherits from were renamed/removed in FS25's UI redesign — this is the single
largest task). On top of that sits one new design obligation: coexisting with
FS25's built-in Steering Assist.

## What stays vs. what changes (verified)

| Area | FS25 status |
|---|---|
| Bootstrap (`Mission00`/`FSBaseMission`/`TypeManager` hooks, `addModEventListener`) | ✅ unchanged — EnhancedVehicle FS25 uses the identical pattern |
| Specialization registration + all 13 spec events | ✅ unchanged |
| Drivable overwrites (`actionEventAccelerate/Brake/Steer`) | ✅ exist; `Steer` gained params but our vararg forwarding is compatible |
| 6 multiplayer event classes, `streamRead*/Write*`, `NetworkUtil` compressed positions, `FARM_ID_SEND_NUM_BITS` | ✅ unchanged |
| Savegame (`XMLFile`, `FSCareerMissionInfo.saveToXMLFile`) | ✅ unchanged |
| Line rendering (`drawDebugLine`), `renderText3D`, `renderText`/`setText*` | ✅ all exist; EV25 ships track lines with `drawDebugLine` |
| `Overlay.new` with our own DDS atlas + `GuiUtils.getUVs` | ✅ still supported — **no slice migration required** |
| Input binding APIs, our 10 modDesc actions | ✅ unchanged (keybind collision audit needed vs new `TOGGLE_AI_STEERING`) |
| Sounds (`loadSampleFromXML`), `g_messageCenter`, `showBlinkingWarning` | ✅ unchanged |
| `modDesc.xml` | ⚠️ descVersion 75 → 100+ |
| Terrain node | ⚠️ `g_currentMission.terrainRootNode` → `g_terrainNode` (canonical) |
| Dialogs | ⚠️ `g_gui:showTextInputDialog/showInfoDialog` → `TextInputDialog.show()` / `InfoDialog.show()` |
| `TabbedMenu` | ⚠️ exists; constructor lost its service args; `addPageTab` gained `iconSliceId` param |
| Shop config injection | ❌ `StoreItemUtil.getConfigurationsFromXML` gone → `ConfigurationUtil` + `g_vehicleConfigurationManager` + `VehicleConfigurationItem` instances |
| HUD atlas constants (`SpeedMeterDisplay.UV/.COLOR`) | ❌ removed (gauge redesign) — hooks (`storeScaledValues`/`draw`) survive |
| GUI profiles our XML extends | ❌ ~10 of 12 parents dead (`dialogBg`, `uiInGameMenuHeader*`, `ingameMenuSettingsLayout`, `multiTextOption*`, `settingsBox`, `list`, `listItem`…); survivors: `buttonBack`, `emptyPanel`, `baseReference`. FS25 equivalents exist (`fs25_dialogBg`, `fs25_settingsLayout`, `fs25_settingsMultiTextOption`, `fs25_listSlider`…) |
| New obligation | ➕ coexistence with built-in `AIAutomaticSteering` (mutual exclusion) |

---

## Phase 0 — Dev environment (size: XS)

- Branch `fs25-port` off `develop`.
- Deploy script: zip working tree → `F:\FS25\mods\FS25_guidanceSteering.zip`.
- Enable dev console (`game.xml` → `<development><controls>true`).
- **Verify:** game starts; `log.txt` location known.

## Phase 1 — Load & bootstrap (size: M) — detailed in `fs25-port-phase1-loading.md`

1. `modDesc.xml`: descVersion → 100; validate against local
   `shared/xml/documentation/modDesc.html`; keybind audit vs `TOGGLE_AI_STEERING`.
2. `loader.lua`: hooks unchanged; guard the `SavegameSettingsEvent` MP-sync hook
   (only unverifiable API — fallback: sync via our own event classes).
3. **Shop configuration rework** (the phase's real work): overwrite
   `ConfigurationUtil.getConfigurationsFromXML` (new `manager` first arg);
   `g_vehicleConfigurationManager:addConfigurationType(name, title, key,
   VehicleConfigurationItem)`; build config entries as
   `VehicleConfigurationItem` instances. Template:
   exekx/FS25_RealisticHarvesting `src/settings/RHM_Configuration.lua`.
4. Guard GUI + HUD init behind a temporary flag so nothing parses FS22 GUI XML.
5. Spec load-path fixes: `g_terrainNode` (with fallback), sounds.xml
   `.wav`→`.ogg` mismatch.
- **Verify:** mod activates; log clean; spec present on vehicles; GS actions in
  F1 menu; shop shows GPS config; savegame round-trip.

## Phase 2 — Core guidance & steering (size: S–M)

The strategies, FSM, DriveUtil, and GuidanceUtil should run nearly unchanged —
this phase is validation plus the coexistence design.

1. Runtime-validate the Drivable overwrites actually steer (EV25 proves the
   hook surface works; our exact trio is untested in FS25).
2. Line rendering: `drawDebugLine` + `renderText3D` verified — expect it to
   just work; check draw distance/height (`g_terrainNode` queries).
3. **Coexistence with built-in Steering Assist** (design decided in research
   doc): before GS engages, check
   `vehicle:getAIAutomaticSteeringState() ~= AIAutomaticSteering.STATE.ACTIVE`;
   optionally force `setAIAutomaticSteeringEnabled(false)`; show a blinking
   warning if the base assist is active. Also make sure GS's manual-override
   detection doesn't fight `AIAutomaticSteering`'s own `setSteeringInput`
   overwrite when only one system is active.
4. Headland detection / `fieldGroundSystem:getGroundAngleMaxValue()` — verified
   unchanged; test headland warning + turn states in-game.
- **Verify:** create A→B line on and off a field; vehicle follows it; manual
  steering disengages GS; base-game GPS and GS never both steer; headland
  warning fires.

## Phase 3 — HUD (size: M)

Hook points survive (`SpeedMeterDisplay.storeScaledValues`/`draw`,
`scalePixelToScreenVector/Height`, `HUDElement.new(Overlay.new(...))`), and our
own DDS atlas keeps working. What broke: we borrowed
`SpeedMeterDisplay.UV.GEARS_BAR` / `.COLOR.GEARS_BG` and positioned relative to
`speedMeterDisplay.gearIcon` — all gone in FS25's gauge redesign.

1. Replace borrowed base-game UV/COLOR constants with our own (model:
   EV25's `FS25_EnhancedVehicle_HUD.lua` — own atlas, own constants,
   `HUDDisplayElement`).
2. Re-anchor the widget: position relative to `g_currentMission.hud.speedMeter`
   with `scalePixelToScreenVector`, not the removed `gearIcon`.
3. Any `g_baseHUDFilename` UVs re-derived (atlas layout changed).
4. Text sizing: `getCorrectTextSize` likely gone — use
   `speedMeter:scalePixelToScreenHeight(px)`.
- **Verify:** HUD widget renders in correct spot at 1080p/1440p/UI-scale
  settings; state (active/track name/lane number) updates live.

## Phase 4 — GUI menu (size: L — the largest task)

The *mechanism* ports 1:1 (`loadProfiles`, `loadGui(..., isFrame)`,
`showGui`, `registerControls`, FocusManager, element XML tags unchanged —
Courseplay/AutoDrive prove full custom menus work). The *styling layer* does
not: ~10 of 12 parent profiles our `guiProfiles.xml` extends, and most of the
42 base profile names referenced directly in our menu/frame XMLs, are dead.

1. Re-parent `resources/gui/guiProfiles.xml` onto FS25 profiles
   (`fs25_dialogBg`, `fs25_settingsLayout`, `fs25_settingsMultiTextOption`,
   `fs25_settingsTextInput`, `fs25_listSlider(-Box)`, trait profiles via the
   new `with=` attribute…). Reference: EV25's `FS25_EnhancedVehicle_UI.xml`,
   AutoDrive's and Courseplay's FS25 guiProfiles.
2. Sweep `GuidanceSteeringMenu.xml` + both frame XMLs: replace every dead
   `profile=` reference; expect layout iteration in-game.
3. Code changes: `TabbedMenu.new(target, custom_mt)` (drop FS22 service args);
   `addPageTab` new `iconSliceId` param; dialog calls →
   `TextInputDialog.show()` / `InfoDialog.show()` (exact signature: check local
   dataS extract or Courseplay usage).
4. Un-guard the phase-1 UI flag; wire `GS_SHOW_UI` back up.
- **Fallback option if effort balloons:** rebuild as a simpler EV25-style
  dialog (single `showDialog` screen) instead of the full tabbed menu — less
  faithful, much less profile work. Decision point mid-phase.
- **Verify:** menu opens via Ctrl+S; all settings round-trip to spec state;
  track list create/save/load/delete works; gamepad/keyboard focus navigation
  works; no log warnings about unknown profiles.

## Phase 5 — Multiplayer & savegame hardening (size: S–M)

1. All 6 event classes: verified API-compatible; test host+client (dedicated
   server exe ships in the install).
2. Resolve the `SavegameSettingsEvent` question from phase 1's guard — if
   broken, move settings sync into our own events.
3. Track sharing between farms/players, permission checks
   (`FARM_ID_SEND_NUM_BITS` verified), late-join state sync
   (`onReadStream/onWriteStream`).
- **Verify:** two-player session — tracks created on one client appear on the
  other; join-in-progress gets full state; savegame on server persists tracks.

## Phase 6 — Polish & release (size: S)

1. Full keybind pass (defaults vs FS25 base actions), F1 help texts.
2. i18n: 15 locale files carry over; add keys for any new warnings
   (base-GPS-conflict message).
3. Icon per FS25 ModHub spec; modDesc metadata; version reset (e.g. 3.0.0.0).
4. Test matrix: new game / old FS25 save without mod / UI scales / MP.
5. **Licensing:** upstream README permits only Wopster to publish to mod sites
   — coordinate with him before any public release (GitHub fork with credit is
   the interim path).
6. CHANGELOG.md entry per repo rules (`## [X.Y.Z] - Unreleased`).

---

## Suggested order & effort

| Phase | Size | Depends on | Playable milestone after |
|---|---|---|---|
| 0 Dev env | XS | — | game + deploy loop |
| 1 Load & bootstrap | M | 0 | mod loads clean, shop config |
| 2 Core steering | S–M | 1 | **AB lines drivable via keybinds (no UI)** |
| 3 HUD | M | 2 | on-screen feedback |
| 4 GUI menu | L | 1 (parallel w/ 2–3 possible) | full feature parity |
| 5 MP & savegame | S–M | 2 | multiplayer-ready |
| 6 Polish & release | S | all | shippable |

Rough shape: phases 0–2 get the mod *usable* (keybind-driven, like early GS
versions); phase 4 is roughly as much work as phases 1–3 combined.

## Risk register

| Risk | Phase | Likelihood | Mitigation |
|---|---|---|---|
| GUI profile rework balloons (layout iteration in-game) | 4 | High (it's the known cost center) | fs25_* equivalents enumerated; fallback: simple-dialog UI |
| `SavegameSettingsEvent` hook broken | 1/5 | Medium | guarded; fallback own event |
| Drivable overwrite trio misbehaves at runtime | 2 | Low–Med | EV25 precedent; test first thing in phase 2 |
| Base Steering Assist fights GS when both engaged | 2 | Medium | state-check mutual exclusion designed |
| `TextInputDialog.show` signature unknown | 4 | Low | check local dataS extract / Courseplay |
| `addConfigurationType` tail params | 1 | Low | 4-arg call; local extract if issues |
| Draw-call limits on per-frame `drawDebugLine` | 2 | Low | EV25 ships this exact approach |

## Verification strategy

Static side (agents can do): luacheck-style pass, grep for dead API usage,
diff review. Runtime side (requires you launching FS25): each phase ends with
an in-game checklist; after each run, share
`F:\FS25\log.txt` (likely — user has relocated the game settings dir) and I'll
triage errors.
Quick unverified-item cleanup (minutes, first game session): confirm
`TextInputDialog.show` signature, `list`/`listItem` profile fate, and
`drawDebugLine` rendering for a non-dev user profile.
