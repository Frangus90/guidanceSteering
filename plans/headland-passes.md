# Headland Passes — Build Plan

Status: decision-locked. Slice 1 implemented on branch `fs25-port`.
Single-player only. English-only UI. Not curved-AB (that is abandoned/rejected).

## 1. Goal

Detect the current field's outer boundary and generate **N concentric passes**
hugging that boundary (N = user-chosen). GS draws them and (slice 2+) steers the
vehicle along the active pass — the free, mod-side equivalent of FS25's built-in
Steering-Assist headland support, consistent with GS's "you drive, GS steers"
model.

## 2. Locked design decisions (final — do not reopen)

1. **GS steers only.** The user controls speed manually or with base-game cruise
   control — the same contract as existing AB lines.
2. **Pass advance = AB lane switch.** When the vehicle crosses the
   implement-width threshold into the next inner loop, that loop becomes active.
   No loop-complete detection, no confirmation dialogs. (Slice 2 work; slice 1's
   data model already supports it — loops carry an ordered `index` and their
   `points` are queryable for nearest-point / offset like current guidance data.)
3. **Islands ignored in v1** — outer boundary only.
4. **No corner special-casing.** Generate the inset loop around the whole field
   as-is; steering follows at its limit; the user takes over manually at
   too-sharp corners. No smoothing/pivot logic.

## 3. Architecture

Headland passes are a **parallel geometry producer**, not another `ABStrategy`
subclass. `ABStrategy`'s contract is line-shaped (infinite line from point +
direction); a closed inset polygon does not fit it. So the feature lives in its
own object hung off the GPS spec, next to `spec.lineStrategy`:

```
spec.headland = HeadlandPasses:new(vehicle)     -- src/misc/HeadlandPasses.lua
```

Data model (slice-2-ready):

```
HeadlandPasses = {
  state,           -- IDLE | DETECTING | READY
  passCount,       -- user-chosen N
  width,           -- work width captured at generation time
  loops = {        -- ORDERED, [1] = outermost pass
    { index = 1, points = { {x,y,z}, ... }, closed = true },
    ...
  },
  activeLoopIndex, -- slice 1 highlights loop 1; slice 2 advances it AB-style
  courseField,     -- async boundary-detection handle being pumped
}
```

`points` are `{x=,y=,z=}` tables — the same shape `GuidanceUtil:getClosestPointIndex`
already consumes, so slice 2's nearest-point / cross-track queries reuse the
existing helpers unchanged.

Three engine touch-points in `GlobalPositioningSystem.lua`:

- `onLoad`  → `spec.headland = HeadlandPasses:new(self)`
- `onUpdate`→ `spec.headland:update(dt)` (pumps async detection; no-op when idle)
- `onDraw`  → `spec.headland:draw()` (after the AB-line draw, same show-lines gate)
- `onDelete`→ `spec.headland:delete()`
- registered vehicle function `generateHeadlandPasses(passCount)` — the UI entry point.

### Boundary detection (base engine, `[live]`-proven)

Confirmed against **Courseplay v8.1.0.3** (`FieldBoundaryDetector.lua:31-42`,
running in the user's game) **and** the engine source
(`FieldCourseField.lua:214-232` in the fs25-modding skill index). Both are
base-engine globals callable from any mod:

- `FieldCourseSettings.generate(vehicle)` → `(settings, implementData)`
  (uses the vehicle's AI markers / work width to size the scan).
- `FieldCourseField.generateAtPosition(x, z, settings, cb)` — starts an **async**
  detection and returns a `courseField` handle. `cb(courseField, success)` fires
  on completion.
- Pump every frame: `courseField:update(dt, 0.00025)`. It returns `true` while
  detecting and **may never itself return false**, so completion is taken from
  the callback's `success`, not the update return (Courseplay's own caveat,
  `FieldBoundaryDetector.lua:60-64`). We add a 15 s watchdog to abort a
  detection that never completes.
- Result: `courseField.fieldRootBoundary.boundaryLine` = array of `{x, z}`
  (index `[1]`=x, `[2]`=z); the first vertex is repeated as the last, so drop the
  last. Islands live at `courseField.islands[i].rootBoundary.boundaryLine`
  (ignored in v1 per decision #3).

**Constraint:** the start position must be on a field. Off-field / no boundary →
`success=false` → we warn ("stand on a field") and stay idle. The API is guarded
for existence at call time; a version/spelling mismatch degrades to a logged
warning, never a crash.

License note: Courseplay is GPL-3.0 — read for API usage only; all geometry code
here is our own. Base-engine calls are free to use.

### Loop generation (our own inward polygon offset)

For pass `i` in `1..N`, inset the boundary inward by `(i - 0.5) * workingWidth`:

1. Winding-agnostic inward direction: pick the rotation of the first edge's
   normal that lands inside the polygon (ray-cast point-in-polygon test). One
   test fixes the sign for all edges (consistent winding).
2. Offset each edge line inward by the inset distance (edge point + inward
   normal · inset; direction unchanged).
3. New vertex = intersection of consecutive offset edge-lines
   (`MathUtil.getLineLineIntersection2D(x1,z1,d1x,d1z, x2,z2,d2x,d2z)` → `hit,f1`;
   point = `p1 + f1·d1`). Parallel/collinear edges fall back to the offset point.
4. **Self-intersection cull (slice-2 fix):** after offsetting, a boundary corner
   sharper than the inset radius makes the two offset edges meeting there cross,
   enclosing a small reversed "bowtie" sub-loop (the notch seen in-game).
   `removeSelfIntersections` scans every pair of non-adjacent edges for an interior
   crossing; on the first, the crossing point splits the ring into two runs — it
   drops the SHORTER run (the artifact; the field outline is always the longer run)
   and splices the crossing point in, then rescans until clean. O(n²) per rescan,
   once per generation. Runs before the collapse guard so area is measured on the
   cleaned ring.
5. **Collapse guard (decision #4-compatible):** after building a loop, if its
   signed-area sign flipped vs. the boundary or its area is below `width²`, the
   inset exceeded the field — **drop that loop and stop** (inner loops are
   worse).

No island routing. Corners are lightly rounded by the densify+Chaikin smoothing
pass (SMOOTH_* constants) and de-notched by the self-intersection cull above.

### Drawing

Reuse the AB draw path's primitives: `drawDebugLine` between consecutive loop
points (wrapping last→first), terrain height + `getLineOffset()` for the y, gated
by the existing `isShowGuidanceLinesEnabled()` toggle. Active loop = green,
others = white (mirrors `ABStrategy.ABLines` colours).

### UI / trigger

Placed on the **Settings frame's existing Headland section** (not the Strategy
tab). Rationale: that frame is a `ScrollingLayout` (overflow-safe), the Headland
section already exists, and it already uses the integer-selector + button-row
patterns this needs — the lowest-risk new GUI surface. Two new elements, both
proven types:

- `guidanceSteeringHeadlandPassCountElement` — a `MultiTextOption` (texts 1..10).
- `guidanceSteeringGenerateHeadlandButton` — a pill Button → `onClickGenerateHeadland`
  → `vehicle:generateHeadlandPasses(count)`.

Kept inside the frame's `protectedSetup`/pcall quarantine so a GUI failure can't
break base-game menu init.

**In-game trigger:** open the GS menu (default hotkey), Settings tab → Headland
section → set "Headland passes" to N → click "Generate headland". Close the menu;
detection completes and N green/white loops draw around the field boundary.

## 4. Slice-by-slice build sequence

- **Slice 1 — generate + draw (this run, no steering).** Boundary detection +
  own inward-offset loop generation + drawing + minimal Settings-frame UI.
  *Verify:* on a rectangular field N loops render as clean concentric rectangles
  at (i-0.5)·width spacing; on an irregular convex field they stay inside the
  boundary; a too-small field yields fewer/zero inner loops without error;
  off-field trigger warns and draws nothing. Player can steer manually along
  them. Ships as a usable feature on its own.
- **Slice 2 — steer along active loop + AB-style inward lane switch. IMPLEMENTED.**
  As built (may deviate slightly from the sketch above):
  - **Boundary smoothing (before insetting).** `smoothBoundary` densifies the raw
    boundary to `SMOOTH_SPACING` (3 m) then runs `SMOOTH_ITERATIONS` (2) Chaikin
    corner-cutting passes. Densify-first keeps rounding LOCAL to real corners
    (~1-2 m radius) instead of bevelling whole edges; 90° field corners stay
    recognisably square. All inset loops are generated from the smoothed boundary,
    so corners are consistent across passes. Point count grows ~4× (e.g. a sparse
    boundary → hundreds of points/loop); logged as `boundary=<raw>-><smoothed> pts`.
  - **Follower (pure pursuit).** `HeadlandPasses:updateSteering` (server only):
    `nearestOnLoop` (snap to nearest point on the active loop) → pick traversal
    direction from the sign of `vehicleForward · segmentDir` (works both ways round
    the loop, engages from wherever the vehicle points) → `walkAlongLoop` a
    look-ahead distance → `worldToLocal(guidanceNode)` → **reused**
    `DriveUtil.driveToPoint` → speed-limit + `DriveUtil.accelerateInDirection`
    exactly as `guideSteering` (user owns throttle). Look-ahead =
    `clamp(5 + 0.25·speed_kmh, 5, 12)` m (base matches AB `TARGET_STEP`).
  - **Branch point (clean if/else, no interleave).** `GlobalPositioningSystem:onUpdate`:
    `if spec.headland:isActive() then headland:updateSteering() else stateMachine:update() end`.
    `onDraw` mirrors it (draw headland XOR AB line).
  - **Bidirectional lane switch.** `updateActiveLoop` (runs while moving, client+server
    in SP): set `activeLoopIndex` to whichever loop the vehicle is currently nearest,
    in EITHER direction (inner or outer). Because adjacent loops sit exactly one width
    apart, their midline is at half a width — "nearest loop" is the same half-width
    threshold AB uses via `MathUtil.round(lineAlpha)`. **Not advance-only** (revised
    after in-game feedback): crossing a midline never locks the vehicle out of an outer
    pass — it can move back outward freely. A hysteresis dead-band of
    `HYSTERESIS_FRACTION` (0.1) of a width around the midline keeps the choice stable
    while the vehicle straddles it, so the active loop does not flap on the boundary.
  - **Exclusivity.** `self.active` is the single source-of-truth flag. Generating a
    headland (loops>0) sets it true (any AB track stays stored but inactive).
    Creating/loading an AB track funnels through `onCreateGuidanceData`, which calls
    `headland:deactivate()` (active=false, loops cleared, state→IDLE). The
    steering-enable gate accepts headland OR AB as a valid source and keeps the
    "create or load a track first" warning only when NEITHER exists.
  - **HUD.** Shows `HL` + active pass number in place of the AB method/lane readout
    while headland is the active source.
  - **Diagnostics.** `Logger.info` on steering-engage (loop index + direction) and
    on active-loop advance (from→to + the two nearest-distances).
  - **Corner release (locked design).** Smoothed field corners survive at ~1-3 m
    radius, far below any tractor's 5-7 m minimum, so pure pursuit there only
    saturates the wheel and overshoots. At such corners GS **releases the wheel
    entirely** instead of attempting them.
    - *Generation time.* `computeLoopRadii` stores a `radius` on every point of each
      FINAL loop (post-offset, post-`removeSelfIntersections`, since insetting
      tightens corners further): `radius = arcLength / totalHeadingChange` over a
      `CURVATURE_WINDOW` (4 m) arc centred on the point, summing ABSOLUTE per-vertex
      turn angles so an S-bend cannot cancel to "straight". No bend ⇒ `math.huge`.
      A radius is stored rather than a baked is-a-corner flag so the threshold can
      use the CURRENT vehicle's capability.
    - *Follow time.* `checkCornerRelease` (called from `updateSteering` before any
      steering is issued) scans `minRadiusAhead` over look-ahead plus the configured
      **headland act distance** and fires when any point in that horizon has
      `radius < vehicle.maxTurningRadius * CORNER_RADIUS_MARGIN` (1.2). The act
      distance is additional to the pure-pursuit look-ahead so the follower never
      aims through an unchecked corner; changing it directly shifts how early GPS
      releases. Vehicles without a `maxTurningRadius` never release.
    - *Actions.* Cruise control off (guarded `setCruiseControlState(OFF)`, the same
      call `StoppedState:onEntry` uses), then full disengage via the SAME flag the
      Alt+X toggle writes — `spec.lastInputValues.guidanceSteeringIsActive = false`
      (`GlobalPositioningSystem.actionEventEnableSteering:1239`). The next
      `updateNetworkInputs` clears `spec.guidanceSteeringIsActive` and fires
      `onSteeringStateChanged(false)` (deactivate sample, state-machine reset, MP
      dirty flag), so the state is exactly a user toggle-off. Cue is the mod's usual
      `showBlinkingWarning` (`guidanceSteering_warning_headlandCornerRelease`); the
      disengage sample fires naturally from the toggle path, no new audio.
    - *No auto-reacquire, by design.* The player drives the corner and presses Alt+X
      again, which re-acquires the nearest loop unchanged. Re-trigger spam is
      impossible: the release frame issues no steering, and from the next frame
      `onUpdate` no longer reaches `updateSteering`.
    - *Headland only.* The trigger lives in the headland follower, which AB/straight
      strategies never enter.
  *Verify:* vehicle auto-steers around the active loop (player throttles), stays
  within a lane-width tolerance, rounds gentle corners without oscillation, and
  switches to the next inner loop on the width-threshold crossing.
- **Slice 3 — polish / persistence (if needed).** Persist generated loops across
  save/load (mirror `saveToXMLFile`), reconcile with the existing headland `STOP`
  mode, tune look-ahead/corner behaviour. Single-player only; no MP event work.

## 5. References

- Boundary API: Courseplay `scripts/field/FieldBoundaryDetector.lua:31-42,60-64`
  (`[live]`); engine `FieldCourseField.lua:214-232` (skill index, `[engine]`).
- `FieldCourseSettings.generate` usage: Courseplay `WorkWidthUtil.lua:36`,
  `DevHelper.lua:61`.
- Line intersection contract: `MathUtil.getLineLineIntersection2D` — engine refs
  `AIVehicleUtil.md:207,852`, `ArticulatedAxis.md:311` (returns `hit,f1,f2`;
  point = `p1 + f1·d1`). Local fallback already present in `DriveUtil.lua:33-48`.
- Reused GS primitives: `DriveUtil.driveToPoint` (`DriveUtil.lua:95`) for slice 2;
  AB draw style `ABStrategy:draw` (`ABStrategy.lua:81-162`).
- API pitfalls / dead-symbol list: `plans/fs25-api-audit.md`.
