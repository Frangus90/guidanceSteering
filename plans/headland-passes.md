# Headland Passes — Research & Design Plan

Status: research/design only. No code written. Target branch `fs25-port`.
Author: architecture research pass, 2026-07-13.

## 1. Goal (one sentence)

Add a feature that detects the current field's boundary shape and generates
**N concentric passes hugging that boundary** (N = user-chosen headland count),
which Guidance Steering (GS) then draws and/or steers the vehicle along — the
mod-side equivalent of FS25's built-in Steering-Assist headland support, but
free and consistent with GS's "you drive, GS steers" model.

Single-player only. English-only UI. Explicitly **not** curved-AB (that upstream
`CurveABStrategy` is abandoned and rejected).

## 2. Why this is fundamentally new work

GS today follows an **infinite straight line** defined by a point + direction and
steers by cross-track error. Headland passes are **closed, curved polylines**
offset inward from the field boundary. The geometry producer and the follower are
both different from what exists. Details below.

---

## 3. Current-state summary (GS internals)

### 3.1 The steering model is a line-follower, not a path-follower

`guidanceData` (the shared steering state) is built in
`src/vehicles/GlobalPositioningSystem.lua:262-276`. The load-bearing fields:

- `snapDirection = { dirX, dirZ, lineX, lineZ }` — an **infinite line**: a
  direction unit-vector plus one point on it. Computed in
  `GlobalPositioningSystem.computeGuidanceDirection` (`:827-867`).
- `driveTarget = { x, y, z, dirX, dirZ }` — the vehicle guide node's world pose,
  from `computeGuidanceTarget` (`:789-825`).
- `width`, `offsetWidth`, `alphaRad` (fractional lane offset), `currentLane`,
  `snapDirectionMultiplier`.

`DriveUtil.guideSteering` (`src/utils/DriveUtil.lua:53-88`) is the actual steering
loop. It projects the vehicle onto the infinite line, computes a target point
`TARGET_STEP = 5 m` ahead **along the line direction**, converts it to guide-node
local space, and calls `DriveUtil.driveToPoint`. There is no notion of a waypoint
list or of "the line curving."

- **Reusable primitive:** `DriveUtil.driveToPoint(vehicle, dt, tX, tZ)`
  (`DriveUtil.lua:95-126`) takes an arbitrary **local-space** target point and
  computes the steer angle (turning radius from the local target, ramped by
  `rotatedTime`). It is not line-specific. A waypoint follower can feed it the
  next look-ahead point on a polyline and get identical low-level steering. This
  is the single most reusable piece for this feature.

### 3.2 Strategies are swappable, but all are AB-line producers

`spec.lineStrategy` is swapped in `GlobalPositioningSystem:setGuidanceStrategy`
(`:737-751`) between `StraightABStrategy` / `CardinalStrategy` /
`SnapDirectionStrategy`, all subclasses of `ABStrategy` (`src/strategies/ABStrategy.lua`).
The `ABStrategy` contract (`getGuidanceData` → a line, `getHasABDependentDirection`,
`draw` an infinite line) is **line-shaped**; a polygon-pass producer does not fit
it cleanly. A headland feature is better modeled as a *parallel* geometry producer
than as another `ABStrategy` subclass.

### 3.3 Existing "headland" code is a safety STOP, not pass generation

The word "headland" already exists in GS but means something narrow:

- `OnHeadlandState.MODES = { OFF = 1, STOP = 2 }`, `DEFAULT_ACT_DISTANCE = 9 m`,
  `MAX_ACT_DISTANCE = 100 m` (`src/misc/states/OnHeadlandState.lua:12-17`).
- The FSM (`src/misc/FSMContext.lua:11-36`) runs `FollowLineState` →
  `OnHeadlandState`. `FollowLineState:detectedHeadland`
  (`src/misc/states/FollowLineState.lua:86-101`) looks a speed-scaled distance
  ahead and asks `HeadlandUtil.getDistanceToHeadLand`
  (`src/utils/HeadlandUtil.lua:7-41`) whether the look-ahead point is still on the
  field, using `getDensityAtWorldPos(g_currentMission.terrainDetailId, ...)`.
- `OnHeadlandState:update` (`:48-62`): in `STOP` mode it transitions to
  `StoppedState` (halts the vehicle at the edge); in `OFF` it just keeps steering.

So today's "headland management" = *"when the AB line runs into the field edge,
optionally stop."* It is a per-edge density probe along one line — **there is no
field-boundary polygon and no concept of driving around the perimeter.**

- `TurningState` and `END_TURNING_STATE` exist in the FSM but are **stubs / never
  wired** (`src/misc/states/TurningState.lua:41-45` returns `ANY_STATE`;
  `END_TURNING_STATE` is listed in `FSMContext.STATES` but never `add`ed). Evidence
  the original author scaffolded headland turning and never finished it. We can
  reuse this scaffolding.

### 3.4 Where the feature would surface in the UI

- Headland mode/act-distance controls already live in the Settings frame
  (`src/gui/frames/GuidanceSteeringSettingsFrame.lua:58-59, 106-111, 184-186,
  236-241`). A "headland passes" count + "Generate" action fits naturally either
  here or in the Strategy frame, which already hosts the strategy-method selector
  and Create/Save/Remove-track buttons
  (`src/gui/frames/GuidanceSteeringStrategyFrame.lua:23-41`).
- Coexistence guard already exists: GS refuses to engage while the base
  Steering-Assist is `ACTIVE` (`GlobalPositioningSystem.lua:1145-1150`, referencing
  `AIAutomaticSteering.STATE.ACTIVE` and `getAIAutomaticSteeringState()`). This
  confirms the base spec's name/enum and matters for Option 1.

---

## 4. Research findings

Confidence key: **[live]** = read from a working mod running in the user's game
(highest trust); **[decompile]** = MyGameSteamOfficial decompiled dataS (lower
confidence, but here corroborated by [live] usage of the same globals).

### A. FS25 base game

**A1/A4 — Field boundary detection IS callable standalone by a mod. [live]**
This is the biggest enabler. Courseplay (FS25 v8.1.0.3, running in the user's
game) obtains the boundary purely through base-engine globals:

- `FieldCourseSettings.generate(vehicle)` → `(fieldCourseSettings, implementData)`
  (`<scratchpad>/cp/scripts/field/FieldBoundaryDetector.lua:31`).
- `FieldCourseField.generateAtPosition(x, z, fieldCourseSettings, cb)` starts an
  **async** detection; the returned object must be pumped every frame via
  `courseField:update(dt, 0.00025)` until the callback fires `success`
  (`FieldBoundaryDetector.lua:32-70`).
- Result: `courseField.fieldRootBoundary.boundaryLine` = array of `{x, z}`
  boundary points (first vertex repeated as last — drop the last), and
  `courseField.islands[i].rootBoundary.boundaryLine` = island polygons
  (`FieldBoundaryDetector.lua:37-42, 84-93`).
- CP drives this from a spec `onUpdate` and hands the finished polygon to a
  callback (`CpCourseGenerator.lua:51-97`). Nothing about it requires the vehicle
  to own a base GPS/Steering-Assist config — it is a plain terrain/field query.
- Corroborated by [decompile]: `FieldCourseField` uses a `FieldCourseDetectionState.FINISHED`
  state machine (`field/course/FieldCourseField.lua:235`).

**A2 — Base game can also generate a full course and drive it. [decompile]**

- `g_fieldCourseManager:generateFieldCourseAtWorldPos(wx, wz, settings, cb, target)`
  → a `FieldCourse` (`field/course/FieldCourseManager.lua:121`).
- `AIAutomaticSteering` (the Steering-Assist spec) generates via
  `generateSteeringFieldCourse(x, z, settings)` and activates via
  `setAIAutomaticSteeringCourse(course)` → `g_fieldCourseManager:setActiveSteeringFieldCourse(course, vehicle)`
  (`FieldCourseManager.lua:133`; `vehicles/specializations/AIAutomaticSteering.lua`).
- STATE enum: `DISABLED / AVAILABLE / ACTIVE`. Preconditions to activate include
  farm land access (`g_currentMission.accessHandler:canFarmAccessLand`), on-field
  density check, and `getIsAIAutomaticSteeringAllowed()` (tool must permit it).

**A3 — The base *driver* follows rows + turns, not perimeter loops. [decompile,
medium confidence]** `AIDriveStrategyFieldCourse` drives the course
**segment-by-segment**, where each segment is a straight working row and
transitions are `segmentIsTurn` headland *turns* (`aiFieldWorkerStartTurn` /
`EndTurn`), steering to a target point from `aiFieldCourse:getDriveData(...)`.
There is "no headland-specific [perimeter] logic" — the model is *straight line,
auto-turn onto the next parallel line*, i.e. it drives the field's **rows**, not
concentric boundary loops. **This is the key limiter on Option 1** and should be
confirmed in-game before relying on it.

### B. Courseplay (pattern only — do NOT copy code; see §7 license)

- **Boundary:** as in A1 (CP's `FieldBoundaryDetector` is a thin wrapper over the
  base `FieldCourseField`).
- **Headland generation is repeated inward polygon offset.** Each pass is a new
  polygon offset inward from the previous by the work width:
  `CourseGenerator.Offset.generate(basePolygon, offsetVector, width)`, with
  corner handling, self-intersection/loop removal, and a min-vertex validity check
  (`<scratchpad>/cp/scripts/courseGenerator/Headland.lua:20-57`). The outermost
  pass is #1; inner passes are discarded when "no room left"
  (`Headland.lua:49-52`). The generator library is explicitly written to **not**
  depend on CP/Giants code (`CourseGeneratorInterface.lua:1-3`) — pure geometry
  over `Polygon`/`Polyline`/`Vector`/`Offset`/`Intersection`.
- **Following** is a `PurePursuitController` (`cp/scripts/ai/PurePursuitController.lua`):
  a look-ahead point on the waypoint path drives the steering — conceptually the
  same as feeding `DriveUtil.driveToPoint` a look-ahead point.
- Reusable **as a pattern**: (1) offset the boundary inward per pass; (2)
  clip/validate degenerate passes; (3) round corners at the turning radius;
  (4) follow with pure-pursuit look-ahead. The *code* is GPL-3.0 and cannot be
  ported into GS.

### C. GS internals — what following a path instead of a line requires

To follow a generated polygon pass, a new follower must, per frame:
1. Find the nearest segment / advance a waypoint index on the current pass.
2. Pick a look-ahead point ~`TARGET_STEP` ahead along the polyline.
3. `worldToLocal` it into the guide node and call `DriveUtil.driveToPoint`
   (reused unchanged), then accelerate as `guideSteering` does
   (`DriveUtil.lua:79-87`).
4. Detect "loop complete" and either stop, or hand off to the next inner pass.

The FSM (`FSMContext`) is the right host: add a `HEADLAND_FOLLOW` state parallel
to `FOLLOW_LINE_STATE`, reusing the existing `StateEngine`. The stubbed
`TurningState` slot can host corner behavior later.

---

## 5. Design options

| # | Approach | Boundary source | Geometry (passes) | Follower / driver | Effort | Risk | GS-fit |
|---|----------|-----------------|-------------------|-------------------|--------|------|--------|
| 1 | **Base does everything.** GS = UI that generates a base `FieldCourse` and hands it to `AIAutomaticSteering`. | base | base | **base** `AIDriveStrategyFieldCourse` | Low *if it works* | **High** | **Poor** |
| 2 | **Base boundary + own gen + own follower.** (recommended) | base `FieldCourseField` [live-proven] | own inward polygon-offset | **new GS** waypoint follower reusing `driveToPoint` | Medium | Medium | **Good** |
| 3 | **Full custom (CP pattern).** Own boundary scan + own gen + own follower. | own terrain/field scan | own offset | new GS follower | High | Medium-High | Good |
| 4 | **Phased hybrid:** Option 2's geometry, ship *draw-only* first (manual steer), add auto-steer after. | base | own offset | Phase 1: none (visual); Phase 2: new follower | Low→Medium | Low→Medium | **Best** |

### Option 1 — hand off to base Steering-Assist. Not recommended.
Least code, but: (a) the base driver follows **rows + turns, not perimeter loops**
(§A3) — it likely can't drive N concentric headland loops at all; (b) it requires
the vehicle to have Steering-Assist available and turns the feature into full AI
autodrive, breaking GS's manual-assist UX; (c) GS already refuses to run alongside
active base steering (`GlobalPositioningSystem.lua:1145-1150`), so this is
essentially "tell the user to use the base game" — it defeats GS's free-alternative
value proposition. Only revisit if in-game testing shows the base course generator
emits drivable headland-only loops.

### Option 2 — base boundary detection + own generation + own follower. **Recommended.**
Use the **[live]-proven** base `FieldCourseField.generateAtPosition` for the
boundary polygon (robust, matches what the base game/CP see, handles islands),
then generate the N passes ourselves with a small inward-offset routine, and
follow them with a new GS waypoint state that reuses `DriveUtil.driveToPoint`.
Clean license story (base engine calls + our own geometry), keeps GS's
"you throttle, GS steers" model, and avoids owning the fragile part (boundary
scanning) while owning the parts that define the feature.

### Option 3 — full custom incl. our own boundary scanner.
Only worth it if the base detection proves unusable (e.g. unavailable in some SP
context). More code and the boundary scanner is exactly the part most likely to
be buggy across odd field shapes. Keep as fallback, not first choice.

### Option 4 — phased hybrid. **This is how to ship Option 2.**
Ship the geometry + on-field drawing first (high value, low risk: the player
steers manually along visible loops, exactly like following drawn AB lines), then
add auto-steer. Recommended sequencing, folded into §6.

**Recommendation: Option 2, delivered via Option 4's phasing.**

Reasoning: the boundary detector is the one piece that is both hard and already
solved by a first-party engine API proven in a live mod, so we lean on it. The
passes are simple, self-contained geometry we can own cleanly under GS's
proprietary license. The follower reuses GS's existing `driveToPoint` and FSM
scaffolding, preserving the manual-assist UX that is GS's whole point. Drawing
first de-risks the generator before any steering code exists.

---

## 6. Phased implementation plan (each phase testable in-game)

**Phase 0 — Spike the base boundary API in SP.** Add a hidden debug console
command that calls `FieldCourseSettings.generate(vehicle)` +
`FieldCourseField.generateAtPosition(x,z,settings,cb)`, pumps `:update(dt, tol)`
from the spec `onUpdate`, and logs the returned `fieldRootBoundary.boundaryLine`
vertex count.
→ *Verify:* on 3+ differently-shaped owned fields, a non-empty polygon comes back
within a second or two; confirm island polygons appear on a field with an island.
This validates the entire premise before building on it. **If this fails, stop and
reconsider Option 3.**

**Phase 1 — Generate + draw N passes (no steering).** Add an inward polygon-offset
routine (offset each boundary edge inward by `width`, re-intersect adjacent edges
for corners, drop self-intersections/degenerate passes). Store passes as
polylines. Add a UI control for pass count (reuse the Settings-frame integer
control pattern at `GuidanceSteeringSettingsFrame.lua:184-186`) and a "Generate"
action. Draw the passes with the existing debug-line drawing style used by
`ABStrategy:draw` (`ABStrategy.lua:123-161`).
→ *Verify:* on a rectangular field, N passes render as clean concentric rectangles
at correct spacing; on a convex irregular field they stay inside the boundary; a
too-small field yields fewer/zero inner passes without error. Player can steer
manually along them. Ships as a usable feature on its own.

**Phase 2 — Waypoint follower (auto-steer one pass).** Add a `HEADLAND_FOLLOW`
state to `FSMContext` parallel to `FOLLOW_LINE_STATE`, plus a
`DriveUtil.followWaypoints`-style loop: nearest-point + look-ahead on the current
pass → `worldToLocal` → `driveToPoint` (reused) → accelerate. Engage it from the
existing steering toggle when a headland course is active instead of the AB path.
→ *Verify:* on a rectangular field, the vehicle auto-steers around one selected
loop (player controls throttle), stays within a lane-width tolerance of the drawn
pass, and rounds corners without oscillation. Test forward only first.

**Phase 3 — Pass sequencing, corners, and integration.** Decide loop-to-loop
transition (stop at loop end, or advance to the next inner pass); use the stubbed
`TurningState` slot for corner/transition behavior; reconcile with the existing
headland `STOP` mode (the passes are the region STOP currently just halts at) and
with AB lane work (a run usually = headland passes first, then AB rows in the
center). Persist generated passes across save/load if desired (mirror the existing
`saveToXMLFile` pattern, `GlobalPositioningSystem.lua:316-326`).
→ *Verify:* full workflow on an owned field — generate, drive all N passes, then
switch to AB rows for the interior; save/reload preserves state; STOP-mode
interaction is coherent.

---

## 7. Risks, unknowns, and constraints

- **LICENSE (hard constraint).** GS is **"Copyright (c) 2022 Wopster. All rights
  reserved."** (`README.md:146-148`) — proprietary. Courseplay is **GPL-3.0**.
  Copying or close-porting CP's Lua would make GS a GPL derivative, incompatible
  with its license. **Read CP for algorithm/approach only; write our own code.**
  General techniques (inward offset, pure-pursuit look-ahead) are not
  copyrightable; specific CP code expression is. Base-engine globals
  (`FieldCourseField`, `g_fieldCourseManager`) are free to call from any mod.
- **Base API is [decompile] for the manager path, [live] for the boundary path.**
  The boundary path (Option 2's dependency) is proven by a running mod — safe. The
  `AIAutomaticSteering` / driver claims (Option 1) are decompile-only and the
  "rows not loops" conclusion is an inference — must be confirmed in-game if
  Option 1 is ever pursued. Do not build on the manager path without Phase 0-style
  verification.
- **Async detection must be pumped.** `FieldCourseField:update(dt, tol)` returns
  true until finished and may "never go to FINISHED" (CP's own comment,
  `FieldBoundaryDetector.lua:60-64`) — rely on the callback `success`, not the
  update return, and guard against a detection that never completes.
- **Polygon offset is the fiddly part.** Inward offset on concave/irregular fields
  produces self-intersections and corner artifacts; this is why Phase 1 draws
  before steering. Start with convex/rectangular fields; treat complex-polygon
  robustness as iterative.
- **Follower stability.** `driveToPoint` was tuned for gentle line correction, not
  continuous curvature. Corner behavior and look-ahead distance will need tuning
  (Phase 2/3); risk of oscillation at tight corners.
- **Field ownership / position.** Detection needs an on-field start position;
  behavior off-field or on unowned land is undefined — validate and warn (reuse
  the field-detection fallback pattern from the skill's `field-detection.md`).
- **Timing.** `g_fieldManager.fields` is empty at load; only run detection from
  update/user-action, never `loadMap` (skill `field-detection.md:152-176`).
- **Scope creep vs. curved-AB.** A polygon follower is close to what a curve
  follower needs; keep the feature scoped to *generated-from-boundary* passes, not
  a general recorded-curve system (which was rejected).

---

## 8. Open questions for the user

1. **Steering model:** should headland passes be **manual-guided** (player
   throttles, GS steers — consistent with AB lines and GS's identity), or
   **fully auto-driven** (vehicle drives itself around, like the base
   Steering-Assist)? The recommendation assumes manual-guided.
2. **Pass sequencing at loop end:** when one loop finishes, should GS **stop** and
   let the player re-engage on the next inner pass, or **auto-advance** inward to
   the next pass continuously?
3. **Relationship to AB work:** typical pattern is *headland passes first, then AB
   rows in the field center.* Should generating headland passes also set up / hint
   the interior AB direction, or are the two features fully independent for v1?
4. **Existing STOP mode:** keep the current headland `STOP` behavior as-is and add
   passes as a separate mode, or fold STOP into the new headland system?
5. **Boundary source preference:** rely solely on the base
   `FieldCourseField` detection (Option 2), or also support user-drawn/custom
   field boundaries later (CP supports custom fields)? Base-only is simplest for v1.
6. **Islands:** should generated passes route **around in-field islands**
   (the base detector returns island polygons), or ignore islands for v1?
