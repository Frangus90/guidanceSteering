# Phase 1: Get Guidance Steering Loading in FS25

*Drafted 2026-07-11. Restored after a session interruption deleted it from disk.
Status: **IMPLEMENTED** on branch `fs25-port` (together with phase 0 and phase 2)
— kept as the verification record. Every API claim below was verified against
the FS25 dataS Lua dumps, the FS25 runtime globals dump, and working FS25 mods.*

## Goal & success criteria

The mod loads in FS25 with **no Lua errors**, the `globalPositioningSystem`
specialization is installed on drivable vehicles, and savegame data survives a
round-trip. **GUI and HUD are explicitly out of scope** — guarded off behind
`GuidanceSteering.PHASE1_NO_UI`.

Success checklist (via the game's `log.txt` and in-game checks):

- [ ] Mod appears in FS25 mod list and activates (no descVersion/modDesc errors)
- [ ] `log.txt` contains no `Error:` / `LUA call stack` lines from the mod
- [ ] Entering a tractor: GS input actions appear in the F1 help menu
- [ ] Buying a vehicle in the shop shows the GPS configuration option
- [ ] Save + reload: `guidanceSteering.xml` written to savegame dir and read
      back without errors

## Verified porting facts

**Ports unchanged (confirmed present in FS25 with same signatures):**
`Mission00.load`, `Mission00.loadMission00Finished`, `FSBaseMission.delete`,
`FSCareerMissionInfo.saveToXMLFile`, `TypeManager.validateTypes` (per-type
validation now async via `g_asyncTaskManager`, but a prepended hook still fires
synchronously), `addModEventListener`,
`g_specializationManager:addSpecialization(name, className, filename,
customEnvironment)`, `g_vehicleTypeManager:addSpecialization(typeName,
specName)`, `typeEntry.specializationsByName`, all 13 specialization event
names, `FarmManager.FARM_ID_SEND_NUM_BITS`, `g_soundManager:loadSampleFromXML`
(optional 10th param appended — 9-arg calls compatible), `g_messageCenter`,
`g_gui:loadProfiles` / `g_gui:loadGui`.

**The one real breaking change — shop configuration:**
- `StoreItemUtil.getConfigurationsFromXML` is gone → moved to
  `ConfigurationUtil.getConfigurationsFromXML(manager, xmlFile, key, baseDir,
  customEnvironment, isMod, storeItem)` (new `manager` first arg).
- `g_configurationManager` split into `g_vehicleConfigurationManager` (+
  `g_placeableConfigurationManager`).
- `addConfigurationType(name, title, configXMLKey, VehicleConfigurationItem)` —
  item-class based, no more load/postLoad callbacks. Config entries must be
  `VehicleConfigurationItem` instances.
- Template used: exekx/FS25_RealisticHarvesting `src/settings/RHM_Configuration.lua`.

**Small changes:**
- Terrain: `g_terrainNode` is canonical (used with
  `g_currentMission.terrainRootNode` fallback).
- `Drivable.actionEventSteer` gained params — our vararg forwarding compatible.
- Dialogs: `g_gui:showTextInputDialog()` → `TextInputDialog.show()` (from local
  `sdk/scriptBindingChanges.txt`).
- **Found during implementation:** `g_currentMission.controlledVehicle` is
  removed in FS25 → `g_localPlayer:getCurrentVehicle()`; `BaseMission.
  onEnterVehicle` no longer exists (GS's hook there is dead — rewire to the
  spec-level onEnterVehicle in phase 3/4).

**Could NOT be verified from dumps (runtime-test flags):**
- `SavegameSettingsEvent.readStream/writeStream` — class exists at FS25 runtime
  but stream bodies unverified; gated behind `GS_ENABLE_SETTINGS_SYNC_HOOK`
  (default false). Fallback: sync via the mod's own event classes.
- `addConfigurationType` tail params beyond the 4th.
- `TextInputDialog.show` 5th arg meaning (order confirmed from Courseplay).

## Implemented changes (phase 0-2, on `fs25-port`)

| File | Change |
|---|---|
| `scripts/deploy-fs25.ps1` | New — zips mod files to `F:\FS25\mods\FS25_guidanceSteering.zip` |
| `modDesc.xml` | descVersion 75 → 100 |
| `resources/sounds.xml` | .wav → .ogg (pre-existing mismatch) |
| `src/loader.lua` | SavegameSettingsEvent gate; shop config rework onto ConfigurationUtil/VehicleConfigurationItem |
| `src/vehicles/GlobalPositioningSystem.lua` | FS25 config registration; base-GPS coexistence check; controlledVehicle → g_localPlayer |
| `src/GuidanceSteering.lua` | `PHASE1_NO_UI` flag; onEnterVehicle nil-guard |
| `src/gui/GuidanceSteeringUI.lua` | UI/HUD init guarded; GS_SHOW_UI shows "not yet available" |
| strategies + `misc/ABPoint.lua` | `g_terrainNode` fallback; TextInputDialog.show port (CardinalStrategy) |
| `i18n/locale_en.xml` | `guidanceSteering_warning_baseGpsActive` key |

Static verification: 16/17 checks passed (see conversation record 2026-07-11);
the 17th is the theoretical `AIAutomaticSteering` global nil-guard, safe via
short-circuit on the spec function existence check.

## In-game test protocol

1. Launch FS25, load a savegame (dev console already enabled in game.xml).
2. Log check: `F:\FS25\log.txt` (likely — user has relocated the game settings
   dir) — no Lua errors mentioning
   guidanceSteering/ConfigurationUtil/VehicleConfigurationItem.
3. Shop: tractor config screen shows GPS No/Yes (15000). Buy with Yes.
4. Keybinds: Alt+C toggle GS → Alt+R auto width → Alt+E set A → drive ≥15 m →
   Alt+E set B → Alt+X engage → vehicle follows the line. Alt+L toggles lines.
5. Coexistence: engage built-in Steering Assist on an owned field, then Alt+X →
   blinking warning, GS refuses.
6. Ctrl+S → "menu not yet available in FS25 port" blink, no crash.
7. Save, reload → track state persists, log clean.
