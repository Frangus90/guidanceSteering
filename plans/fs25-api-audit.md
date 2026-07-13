# FS22 → FS25 API Audit — GuidanceSteering

Branch `fs25-port`. Sweep of `src/**/*.lua`, `resources/gui/*.xml`, `modDesc.xml`,
`resources/sounds.xml`. Verdicts are grounded in the FS25 engine sources under
`.claude/skills/fs25-modding/references/lua-source-index/` (cited as `ref:elements/X.lua:NN`)
and the extracted live mods in the scratchpad (Courseplay = `cp`, VehicleControlAddon = `vca`,
precisionFarming = `pf`, VehicleFruitHud = `fruit`, FuelConsumptionHUD = `fuel`). GUI/HUD
verdicts never use the banned decompiled MyGameSteamOfficial repo.

Purpose: stop discovering breakage one crash at a time. Each referenced base-game symbol is
verdicted VERIFIED-FS25 / DEAD / CHANGED-BEHAVIOR / UNKNOWN.

---

## 1. Executive summary

| Category | Count | Meaning |
|---|---|---|
| STILL-PRESENT DEAD (in shipping code/config) | 4 groups | Dead symbols/attributes still present. All **non-crashing** (inert or nil-guarded). None is a live crash. |
| Potential still-present **functional bug** | 1 | `attribute="title"` on the track-list cell — track names may render blank. |
| CHANGED-BEHAVIOR | 3 | Behaves differently in FS25; needs attention. |
| UNKNOWN / risk | 5 | Cannot verify either way from available ground truth. |
| VERIFIED-FS25 | ~55 symbols | Confirmed present with same contract. |

**Headline:** there are **no live-crash dead references** left in executable paths. The FS25
notes for the known corpses (`g_currentMission.controlledVehicle`, `MathUtil.clamp/degToRad`,
`checkedOption`, `FlowLayout`, `registerControls`, `storeScaledValues`, `SpeedMeterDisplay.UV/COLOR/SIZE`)
are all **comment-only** — the executable code already migrated. What remains is dead-but-inert
config, one likely GUI-data bug, and a set of MP/savegame paths that are untested (phase 5).

---

## 2. STILL-PRESENT DEAD (report only — do NOT fix per task)

Ordered most-notable first. All are non-crashing.

| # | Dead symbol | Where (our code) | Replacement / correct form | Status |
|---|---|---|---|---|
| D1 | `BaseMission.onEnterVehicle` / `BaseMission.onLeaveVehicle` hooked via `Utils.appendedFunction` | `src/GuidanceSteering.lua:103-104` | These base methods do not exist in FS25 (vehicle enter/leave are **spec events**). The mod already registers them correctly as spec event listeners on the GPS spec (`GlobalPositioningSystem.lua:90-91`, handlers at `:98`/`:110`), which do the `ui:setVehicle(...)` work. The `GuidanceSteering:onEnterVehicle/:onLeaveVehicle` funcs (`GuidanceSteering.lua:408,423`) they point at are therefore dead. | STILL PRESENT. Inert: `appendedFunction(nil, fn)` just assigns a field the engine never calls. Redundant with the spec events. Also re-appends on every `loadMission` (see CB2). Recommend deleting lines 103-104 and the two dead handlers. |
| D2 | GUI profile attributes `screenAlign` + `positionOrigin` | `resources/gui/guiProfiles.xml:88-89` (gsTooltipText), `212-213` (gsStrategyLeftColumn), `221-222` (gsStrategyRightColumn), `231-232` (trackList) | Never read by FS25 `GuiElement:loadProfile`/`loadFromXML` — only `pivot`, `position`, `size`, `anchors` are read (`ref:elements/GuiElement.lua:317-324`, `246`). The lever is **`anchors`** (order `{xMin,xMax,yMin,yMax}`). | STILL PRESENT, inert. The frame XMLs already compensate with element-level `anchors="0 0 1 1"` (SettingsFrame.xml:46, StrategyFrame.xml:34). The profile lines are pure corpses. Recommend removal for hygiene. |
| D3 | SmoothList profile attributes `itemsPerCol`, `listItemHeight`, `listItemWidth`, `rowBackgroundProfile`, `rowBackgroundProfileAlternate` | `resources/gui/guiProfiles.xml:236-240` (trackList profile) | Not read by FS25 `SmoothListElement:loadProfile` (`ref:elements/SmoothListElement.lua:208-235` reads `isHorizontalList`, `showHighlights`, `selectOnScroll`, spacings — none of these five). Row height/width come from the **ListItem profile's own `size`** (`trackListItem` = `590px 47px`, guiProfiles.xml:248). | STILL PRESENT, inert. `isHorizontalList` (235) and `selectOnScroll` (234) on the same profile ARE valid. Recommend dropping the five dead ones. |
| D4 | `SpeedMeterDisplay.draw` hook installed with no restore in `delete()` | `src/gui/hud/GuidanceSteeringHUD.lua:45` (install), `:50` (delete does not restore) | The hook itself is VERIFIED-correct (see V-list). The defect is lifecycle: it is installed in `GuidanceSteeringHUD:new` (→ per `loadMission`) but `GuidanceSteeringHUD:delete` never restores the original. | STILL PRESENT. Not dead per se, but violates pitfalls/what-doesnt-work.md #20 (hook accumulation). See CB2. |

Note: `g_currentMission.controlledVehicle` appears 4× but **only in comments** (GuidanceSteering.lua:410, CardinalStrategy.lua:46, GlobalPositioningSystem.lua:1011,1060) — not a live reference. `CurveABStrategy.lua` exists on disk but is **not** `source()`d by `loader.lua` (dead file, curved-AB was rejected) so its symbols are out of scope.

### Potential still-present FUNCTIONAL BUG (non-crashing, verify at runtime)

| # | Symbol | Where | Evidence it may be wrong | Impact |
|---|---|---|---|---|
| **B1** | `attribute="title"` on the track-list cell child | `resources/gui/GuidanceSteeringStrategyFrame.xml:88`; read via `cell:getAttribute("title")` at `GuidanceSteeringStrategyFrame.lua:231` | Courseplay's **working** FS25 list cells declare children with **`name="title"` / `name="icon"`** (`cp/config/gui/pages/CourseManagerFrame.xml:47-48,64-65`) and read them with the identical `cell:getAttribute("title")` (`cp/scripts/gui/pages/CpCourseManagerFrame.lua:339,354`). No live FS25 mod XML in the scratchpad uses `attribute=`. `getAttribute`'s definition is not in the curated engine index, so I could not confirm the key directly — but the CP counter-evidence is strong that the lookup keys off the child's **`name`**, not an `attribute` property. The in-code comment (StrategyFrame.xml:86-87, .lua:225) asserts the opposite ("reads the child's 'attribute' property (not 'name')") with no cited source. | If `getAttribute` keys off `name`, `cell:getAttribute("title")` returns nil → nil-guarded at `.lua:232` → **track-list rows render blank** (no track names). No crash. HIGH priority to verify visually; likely fix is `attribute="title"` → `name="title"`. |

---

## 3. CHANGED-BEHAVIOR

| # | Item | Where | Change | Action |
|---|---|---|---|---|
| CB1 | `modDesc descVersion="100"` | `modDesc.xml:2` | FS25's current schema is **104** (basics/modDesc.md: "FS25 uses descVersion=104"; live mods use 105/108; one older uses 91). `100` is an intermediate/stale value. | May load with a warning or be rejected by strict validation. Recommend bumping to `104`. Low risk but easy. |
| CB2 | Hook accumulation on savegame reload | `GuidanceSteering.lua:103-104` (dead BaseMission hooks) and `GuidanceSteeringHUD.lua:45` (SpeedMeterDisplay.draw) | These are installed inside `GuidanceSteering:new` → called from `loadMission` → runs **again** every time a savegame is (re)loaded in one session; `delete()` never restores them. Each reload stacks another layer (pitfalls #20). The `loader.lua init()` hooks (FSBaseMission.delete, Mission00.load, ConfigurationUtil.*, TypeManager.*) are safe — `init()` is called once at file scope (`loader.lua:319`), not per mission. | The stacked `SpeedMeterDisplay.draw` copies all call the *current* hud's `onDraw`, so the HUD draws N× after N reloads — wasteful, not corrupting. The BaseMission copies are dead. Fix: restore originals in `delete()` or use a HookManager. Savegame-phase item. |
| CB3 | `g_gui:loadGui(file, name, target, true)` 4-arg form + custom-profile rules | `GuidanceSteeringUI.lua:85-87` | FS25 `loadGui` exists (pitfalls #6 confirms `g_gui:loadGui`/`showGui`). Our profiles correctly **extend `fs25_*`** or are fully self-contained (pitfalls #5), and the `TextInput` profile carries the required `maxInputTextWidth` (guiProfiles.xml:175) that prevents the per-frame `TextInputElement:draw` nil-arithmetic. Behaviorally sound. | No action — noted as the pattern to keep. |

---

## 4. UNKNOWN / risk (cannot verify from available ground truth)

| # | Symbol | Where | Risk if wrong / how it shows | Priority |
|---|---|---|---|---|
| U1 | `Drivable.actionEventAccelerate` / `actionEventBrake` / `actionEventSteer` as `overwrittenFunction` targets | `GlobalPositioningSystem.lua:441-443` | `Drivable.lua` is not in the curated engine index and no live mod overwrites these names. If FS25 renamed/removed these Drivable action-event callbacks, `overwrittenFunction(nil, fn)` installs a wrapper whose `superFunc` is nil that the engine never calls → GPS's throttle/brake/steer interception (feeds `spec.axisAccelerate` while auto-steering, `.lua:446-453`) silently no-ops. Auto-drive would not modulate throttle. Verify against the FS25 `Drivable` spec. | HIGH (driving path) |
| U2 | MP settings sync path | `loader.lua:80-83` gates `SavegameSettingsEvent.readStream/writeStream` behind `GS_ENABLE_SETTINGS_SYNC_HOOK=false`; savegame load is **server-only** (`loader.lua:144` gates on `getIsServer`) | With the hook off, a joining MP client has no path through `SavegameSettingsEvent` to receive settings/tracks; it must come from the mod's own event classes on join. That initial-sync-to-client path is untested. Symptom: MP clients see no saved tracks / default settings. Also `SavegameSettingsEvent.readStream/writeStream` signatures are unverified for FS25. | HIGH (MP) |
| U3 | Own-event stream round-trip order & versioning | `src/events/*.lua`, `GlobalPositioningSystem.lua:405-466,555-560`, `src/utils/stream.lua` | Stream primitives are all VERIFIED (see V-list) and `vehicleXZPosHighPrecisionCompressionParams` is confirmed (`ref:Vehicle.lua:1561`). Untested: that every event's `readStream` mirrors its `writeStream` order (pitfalls #10) end-to-end under FS25, and the `guidanceSteering#version=1` written at save (`GuidanceSteering.lua:142`) is ignored on load (no migration guard). Symptom: desync/garbage AB data on client, or load error if the save schema drifts. | HIGH (MP/savegame) |
| U4 | Overlay slice id `"gui.gearBg"` | `GuidanceSteeringHUD.lua:96` | `g_overlayManager:createOverlay` is VERIFIED and `"gui.button_middle"` is a confirmed real slice (cp CourseGeneratorFrame.xml:312). `"gui.gearBg"` is unconfirmed. If absent, `createOverlay` returns nil + one-time log and the HUD skips the background box (nil-guarded, `.lua:97`). | LOW (non-crashing) |
| U5 | `g_currentMission.terrainRootNode` fallback | `ABPoint.lua:71`, `ABStrategy.lua:130,137`, `HeadlandUtil.lua:24 (comment)` | Used only as the `g_terrainNode or g_currentMission.terrainRootNode` fallback. `g_terrainNode` is VERIFIED-present (`ref:ai/AISystem.lua:600,767`), so the fallback is effectively never reached. `terrainRootNode` itself unconfirmed for FS25. | LOW (fallback only) |

---

## 5. VERIFIED-FS25 (compact)

Globals / managers: `g_currentMission.guidanceSteering` (mod's own field), `g_i18n:getText`
(`ref` ubiquitous), `g_localPlayer:getCurrentVehicle()` (`ref:VehicleDebug.lua:235,1947`;
cp CpUtil.lua:491 wraps it), `g_soundManager:playSample` (vca:5464) + `loadSampleFromXML`/`stopSample`/`deleteSamples`
(standard soundManager API), `g_inputBinding:setActionEventTextVisibility`/`setActionEventTextPriority`
(cp:147-157), `g_overlayManager:createOverlay(sliceId,x,y,w,h)` (cp CpGuiUtil.lua:320),
`g_gui:loadGui`/`showGui` (pitfalls #6), `g_gameSettings.uiScale`, `g_safeFrameOffsetX/Y`,
`getNormalizedScreenValues`, `g_terrainNode` (`ref:ai/AISystem.lua:600`).

Mission fields: `g_currentMission.vehicleXZPosHighPrecisionCompressionParams` (`ref:Vehicle.lua:1561`),
`g_currentMission.terrainDetailId` + `getDensityAtWorldPos(...)` (cp PathfinderUtil.lua:196 identical usage),
`g_currentMission.fieldGroundSystem:getGroundAngleMaxValue()` (`ref:ai/jobs/AIJobFieldWork.lua:149`
identical expression), `g_currentMission:showBlinkingWarning(text, ms)` (vca:1689, cp CpAIJob.lua:489),
`g_currentMission.time` / `missionInfo.savegameDirectory` (pitfalls #1; loader.lua:145).

Spec / vehicle: `SpecializationUtil.registerFunction/registerEventListener/registerOverwrittenFunction/hasSpecialization`,
event names `onLoad/onPostLoad/onLoadFinished/onReadStream/onWriteStream/onReadUpdateStream/onWriteUpdateStream/onRegisterActionEvents/onUpdate/onUpdateTick/onDraw/onEnterVehicle/onLeaveVehicle`
(spec-level enter/leave confirmed by cp + vca specs using them), `self:addActionEvent(table, InputAction.X, target, cb, up, down, always, active, state, conflict, report)` 11-arg form (vca:1007 same shape),
`self:getNextDirtyFlag()` / `self:raiseDirtyFlags(flag)`, stream primitives
`streamReadBool/Int8/UIntN/Float32/String/UInt16` + Write counterparts, `bitAND`.

Store/config: `ConfigurationUtil.getConfigurationsFromXML(manager, xmlFile, key, baseDir, customEnvironment, isMod, storeItem)`
(`ref:configurations/ConfigurationUtil.lua:474` — signature matches loader.lua:266 exactly),
`ConfigurationUtil.getDefaultConfigIdFromItems` (`ref:...:631`), `StoreItemUtil.getIsVehicle`
(`ref:VehicleSystem.lua:1174`), `configurationDesc.itemClass.new`, `manager:getConfigurations()`.

Dialogs: `InfoDialog.show(text, callback, target, dialogType, okText, ...)` (`luadoc InfoDialog.md:75`;
cp Courseplay.lua:88) — StrategyFrame.lua:480 uses it; `TextInputDialog.show(callback, target, default, prompt, _, maxChars, ...)`
(cp AIParameterSettingList.lua:554, CustomFieldManager.lua:126) — CardinalStrategy.lua:54 uses it.

GUI elements (tag → class all present in `ref:elements/`): `GuiElement`, `Bitmap`(BitmapElement),
`Text`(TextElement), `Button`(ButtonElement), `MultiTextOption`(MultiTextOptionElement),
`TextInput`(TextInputElement), `ScrollingLayout`(ScrollingLayoutElement), `BoxLayout`(BoxLayoutElement),
`SmoothList`(SmoothListElement), `ListItem`(ListItemElement), `Slider`(SliderElement),
`Paging`(PagingElement), `FrameReference`(FrameReferenceElement), `ThreePartBitmap`(ThreePartBitmapElement).
Methods: `MultiTextOptionElement:setTexts/setState/getState` (`ref:elements/MultiTextOptionElement.lua:391,342,356`),
`FrameElement:exposeControlsAsFields` (`ref:elements/FrameElement.lua:100`), `TabbedMenu:registerPage`
(`ref:base/TabbedMenu.lua:708`), `Element:setText/setVisible/setImageFilename/setSelectedIndex/invalidateLayout`.
Element attributes read by FS25 loaders: `toolTipElementId`, `toolTipText`, `focusFallthrough`,
`anchors`, `pivot`, `position`, `size` (`ref:GuiElement.lua:255-265,246,317-324`);
`maxCharacters`, `maxInputTextWidth`, `imeKeyboardType/imeTitle/imeDescription/imePlaceholder`,
`onTextChanged`, `onEnterPressed` (`ref:elements/TextInputElement.lua:116-152`);
`bottomClipperElementName` (`ref:elements/ScrollingLayoutElement.lua:55`);
`dataElementId`, `handleFocus` on Slider/List (`ref:elements/SliderElement.lua:140`);
`isHorizontalList`, `showHighlights`, `selectOnScroll` (`ref:elements/SmoothListElement.lua:142,169,170`).

Rendering / engine: `Overlay.new/setColor/setUVs/setPosition/setDimension/render`
(`ref:base/Overlay.lua:37,99,115,138,154,224`), `GuiUtils.getUVs`, `renderText`, `setTextBold/setTextAlignment/setTextColor/setTextVerticalAlignment`,
`RenderText.ALIGN_*`/`VERTICAL_ALIGN_*`, `getTerrainHeightAtWorldPos`, `localToWorld/worldToLocal/localDirectionToWorld/getWorldTranslation`,
`createTransformGroup/setTranslation/setRotation`, `DebugUtil.drawDebugNode/drawDebugCircle`, `drawDebugLine/drawDebugPoint`.
XML: `XMLFile.load/create`, `xmlFile:getValue/setValue/getInt/setInt/getFloat/setFloat/getBool/setBool/getString/setString/getVector/setVector/hasProperty/iterate/save/delete`,
plus legacy `loadXMLFile/getXMLString/getXMLBool/getXMLInt/delete` (loader.lua:116-135).
Utils: `Utils.getFilename/getNoNil/getUVs/appendedFunction/prependedFunction/overwrittenFunction`,
`MathUtil.getLineLineIntersection2D/getYRotationFromDirection/round/vector2Length/vector3Length`.

Loader hooks (all one-time, installed at file scope): `FSBaseMission.delete`, `Mission00.load`,
`Mission00.loadMission00Finished`, `FSCareerMissionInfo.saveToXMLFile`, `TypeManager.validateTypes`,
`ConfigurationUtil.getConfigurationsFromXML` — all targets exist and are hooked with the correct
FS25 signatures. `addModEventListener`/`removeModEventListener` VERIFIED. modDesc `<actions>`/`<inputBinding>`
schema unchanged; the 10 `GS_*` actions + bindings are well-formed.

Sounds: `resources/sounds.xml` uses `<activate>/<deactivate>/<warning>` with `file` + `linkNode="0>"`
— standard sound-XML shape consumed by `g_soundManager:loadSampleFromXML`. No dataS/ paths anywhere in the tree.

---

## 6. Rules for future work (systematic lessons)

1. **Tag-name → class resolution.** A GUI XML element tag maps to `<Tag>Element` in `ref:elements/`.
   Before using a tag, confirm the class file exists; before using an attribute, confirm the class's
   `loadFromXML` **and** `loadProfile` actually read it. Lowercase legacy tags are gone — PascalCase only.

2. **Anchors-only positioning.** FS25 `GuiElement` reads `pivot`, `position`, `size`, `anchors` and
   nothing else for placement. `screenAlign` / `positionOrigin` are inert corpses. To pin an element,
   set `anchors="{xMin xMax yMin yMax}"` (top-left = `0 0 1 1`) + `position` offset, at the element or
   in the profile.

3. **Profile extend rules.** Custom profiles must `extends="fs25_*"` or be fully self-contained
   (pitfalls #5). Base row profiles like `fs25_settingsMultiTextOption` auto-add their arrows/value/bg;
   declare only the `label` child. `TextInput` profiles MUST set `maxInputTextWidth` or `TextInputElement:draw`
   throws per-frame nil-arithmetic.

4. **List cells key off `name`, not `attribute`.** `cell:getAttribute("x")` resolves the descendant
   declared `name="x"` (CP-confirmed FS25 pattern). Do not use `attribute="x"` (see B1).

5. **Per-frame nil-tolerance.** `draw`/`onDraw`/`update` paths must nil-guard every engine value and
   bail without arithmetic (the HUD's `computeLayout` returning nil is the model). Read the base HUD's
   per-frame guards (`isVehicleDrawSafe`, `getVisible`) exactly as `vca` does; never drive removed
   layout/scale pipelines.

6. **Live-mod-first verification.** Confirm any non-obvious symbol against an extracted live FS25 mod
   (cp/vca/pf/fruit/fuel) or the curated engine index — never the banned decompiled repo for GUI/HUD.
   Prefer an identical-usage citation (`file:line`) over "it probably still exists."

7. **Hook lifecycle.** `Utils.appendedFunction`/`prependedFunction` accumulate. Hooks installed per
   `loadMission` (i.e. inside `GuidanceSteering:new`) MUST be restored in `delete()` or they stack on
   savegame reload (pitfalls #20). Hooks installed once at file scope (`loader.lua init()`) are safe.

8. **MP: server-authored saves + gated events.** Savegame load is server-only; clients depend on the
   mod's event classes for initial sync. Keep every event's `readStream` order identical to `writeStream`
   (pitfalls #10), and check `g_server`/`g_client` before sending (pitfalls #9).
