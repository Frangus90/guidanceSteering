---
-- HeadlandPasses
--
-- Generates and draws N concentric "headland" passes inset from the current field's
-- outer boundary. Slice 1: boundary detection + loop generation + drawing only.
-- No steering integration (that is slice 2). Single-player only.
--
-- Boundary detection uses the base-engine field-boundary API (FieldCourseSettings.generate
-- + FieldCourseField.generateAtPosition), confirmed against live Courseplay v8.1.0.3 and the
-- engine source (FieldCourseField.lua:214-232). Loop geometry is our own inward polygon
-- offset — no Courseplay code is copied.
--
-- Copyright (c) Wopster

---@class HeadlandPasses
HeadlandPasses = {}

local HeadlandPasses_mt = Class(HeadlandPasses)

HeadlandPasses.STATE_IDLE = 1
HeadlandPasses.STATE_DETECTING = 2
HeadlandPasses.STATE_READY = 3

HeadlandPasses.DEFAULT_PASS_COUNT = 3
HeadlandPasses.MAX_PASS_COUNT = 10
HeadlandPasses.DETECTION_TIMEOUT = 15000 -- ms; abort a detection that never completes
HeadlandPasses.DETECTION_TOLERANCE = 0.00025 -- the value Courseplay pumps FieldCourseField:update with
HeadlandPasses.DRAW_STEP = 5 -- m; subdivide drawn loop edges so the line follows terrain

-- Boundary smoothing (slice 2): densify the raw boundary to a fixed spacing, then apply
-- Chaikin corner-cutting. Densify-first keeps the rounding LOCAL to real corners instead of
-- eating whole edges (plain Chaikin on a sparse polygon bevels long edges by 25%). With
-- SMOOTH_SPACING=3 m and 2 iterations the corner-rounding radius is ~1-2 m: mild, and 90-degree
-- field corners stay recognisably square (per the in-game feedback).
--
-- ==> TUNING KNOBS: these are the ONLY two values to touch to change corner rounding. To round
--     corners MORE, either raise SMOOTH_ITERATIONS (each extra Chaikin pass roughly doubles the
--     radius) or lower SMOOTH_SPACING (denser samples let Chaikin cut a tighter, rounder arc).
--     To keep corners sharper, do the opposite. One-line change, no other code depends on them.
HeadlandPasses.SMOOTH_SPACING = 3 -- m; max spacing after densification, before Chaikin
HeadlandPasses.SMOOTH_ITERATIONS = 2 -- Chaikin passes

-- Lane-switch hysteresis (slice-2 fix): the active loop follows whichever loop the vehicle is
-- nearest (both directions), but only switches once the candidate loop is nearer than the current
-- active loop by this fraction of a working width. Loops sit one width apart, so their midline is
-- at half a width; this dead-band around the midline stops the active loop flapping when the
-- vehicle straddles it. 0.1 => must be ~5% of a width past the midline before it flips.
HeadlandPasses.HYSTERESIS_FRACTION = 0.1

-- Look-ahead follower (slice 2): pure-pursuit target distance along the active loop. Base
-- matches the AB path's fixed 5 m look-ahead (DriveUtil.TARGET_STEP); a mild speed term
-- lengthens it a little at field speed to damp oscillation without cutting corners.
HeadlandPasses.LOOK_AHEAD_BASE = 5 -- m
HeadlandPasses.LOOK_AHEAD_SPEED = 0.25 -- m per km/h
HeadlandPasses.LOOK_AHEAD_MIN = 5 -- m
HeadlandPasses.LOOK_AHEAD_MAX = 12 -- m

-- Same RGB constants ABStrategy uses (ABStrategy.lua:23-25) so headland loops read identically to
-- AB guidance lines: green = active line, blue = next lane, white = inactive.
local RGB_WHITE = { 1, 1, 1 }
local RGB_GREEN = { 0, 0.447871, 0.003697 }
local RGB_BLUE = { 0, 0, 1 }

---2D parametric line intersection with the same contract as MathUtil.getLineLineIntersection2D:
---args (p1x,p1z, d1x,d1z, p2x,p2z, d2x,d2z); returns (hasIntersection, f1) where the point is
---p1 + f1*d1. Delegates to the engine function when present (keeping it the one used), else
---falls back to a local solve — same guard DriveUtil.lua already uses for this symbol.
local function lineIntersect(p1x, p1z, d1x, d1z, p2x, p2z, d2x, d2z)
    if MathUtil.getLineLineIntersection2D ~= nil then
        return MathUtil.getLineLineIntersection2D(p1x, p1z, d1x, d1z, p2x, p2z, d2x, d2z)
    end

    local denominator = d1x * d2z - d1z * d2x
    if math.abs(denominator) < 0.00001 then
        return false
    end

    local wx, wz = p2x - p1x, p2z - p1z
    local f1 = (wx * d2z - wz * d2x) / denominator
    return true, f1
end

---Proper segment-vs-segment intersection over the xz plane, endpoints EXCLUSIVE. Segment 1 is
---(a->b), segment 2 is (c->d). Returns the intersection x,z when the two segments cross at an
---interior point of BOTH, else nil. Used by the self-intersection cull (offset "bowtie" removal).
local function segmentIntersection(ax, az, bx, bz, cx, cz, dx, dz)
    local rx, rz = bx - ax, bz - az
    local sx, sz = dx - cx, dz - cz
    local denom = rx * sz - rz * sx
    if math.abs(denom) < 1e-9 then
        return nil -- parallel or degenerate
    end
    local qpx, qpz = cx - ax, cz - az
    local t = (qpx * sz - qpz * sx) / denom
    local u = (qpx * rz - qpz * rx) / denom
    if t > 1e-6 and t < 1 - 1e-6 and u > 1e-6 and u < 1 - 1e-6 then
        return ax + t * rx, az + t * rz
    end
    return nil
end

---Signed area of an {x,z} polygon (sign encodes winding).
local function polygonSignedArea(poly)
    local area = 0
    local n = #poly
    for i = 1, n do
        local a = poly[i]
        local b = poly[i % n + 1]
        area = area + (a.x * b.z - b.x * a.z)
    end
    return area * 0.5
end

---Ray-cast point-in-polygon test over an {x,z} polygon.
local function pointInPolygon(poly, px, pz)
    local inside = false
    local n = #poly
    local j = n
    for i = 1, n do
        local pi, pj = poly[i], poly[j]
        if (pi.z > pz) ~= (pj.z > pz) then
            local xCross = (pj.x - pi.x) * (pz - pi.z) / (pj.z - pi.z) + pi.x
            if px < xCross then
                inside = not inside
            end
        end
        j = i
    end
    return inside
end

---Densifies a closed {x,z} polygon so no edge is longer than maxSpacing. Only ever ADDS
---points (interior samples), so an already-dense boundary is left as-is. Returns {x,z} points.
local function densifyPolygon(poly, maxSpacing)
    local out = {}
    local n = #poly
    for i = 1, n do
        local a = poly[i]
        local b = poly[i % n + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local len = math.sqrt(dx * dx + dz * dz)
        local steps = math.max(1, math.ceil(len / maxSpacing))
        for s = 0, steps - 1 do
            local t = s / steps
            out[#out + 1] = { x = a.x + dx * t, z = a.z + dz * t }
        end
    end
    return out
end

---One closed-curve Chaikin corner-cutting pass. Each edge (a->b) contributes points at 1/4
---and 3/4; collinear runs stay collinear, corners get rounded. Returns {x,z} points.
local function chaikin(poly)
    local out = {}
    local n = #poly
    for i = 1, n do
        local a = poly[i]
        local b = poly[i % n + 1]
        out[#out + 1] = { x = a.x * 0.75 + b.x * 0.25, z = a.z * 0.75 + b.z * 0.25 }
        out[#out + 1] = { x = a.x * 0.25 + b.x * 0.75, z = a.z * 0.25 + b.z * 0.75 }
    end
    return out
end

---Nearest point on a closed {x,y,z} polyline to (px,pz). Returns segment index, the
---parameter t in [0,1] along that segment, and the distance. Used by the follower
---(look-ahead origin) and the lane-switch check (which loop is nearer).
local function nearestOnLoop(points, px, pz)
    local n = #points
    local bestDist2 = math.huge
    local bestI, bestT = 1, 0
    for i = 1, n do
        local a = points[i]
        local b = points[i % n + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local len2 = dx * dx + dz * dz
        local t = 0
        if len2 > 0.0001 then
            t = ((px - a.x) * dx + (pz - a.z) * dz) / len2
            t = math.clamp(t, 0, 1)
        end
        local qx, qz = a.x + dx * t, a.z + dz * t
        local ddx, ddz = px - qx, pz - qz
        local d2 = ddx * ddx + ddz * ddz
        if d2 < bestDist2 then
            bestDist2 = d2
            bestI, bestT = i, t
        end
    end
    return bestI, bestT, math.sqrt(bestDist2)
end

---Walks `distance` metres along a closed {x,y,z} polyline from (segIndex, t) in traversal
---direction dir (+1 = increasing index, -1 = decreasing). Returns the world x,z of the point
---reached. If distance exceeds the perimeter it stops at the last vertex visited.
local function walkAlongLoop(points, segIndex, t, dir, distance)
    local n = #points
    local i = segIndex
    local a = points[i]
    local b = points[i % n + 1]
    local cx = a.x + (b.x - a.x) * t
    local cz = a.z + (b.z - a.z) * t
    local remaining = distance

    for _ = 1, n + 1 do
        local nx, nz, nextI
        if dir >= 0 then
            local vb = points[i % n + 1]
            nx, nz, nextI = vb.x, vb.z, i % n + 1
        else
            local va = points[i]
            nx, nz, nextI = va.x, va.z, (i - 2) % n + 1
        end

        local ex, ez = nx - cx, nz - cz
        local el = math.sqrt(ex * ex + ez * ez)
        if el >= remaining then
            if el < 0.0001 then
                return cx, cz
            end
            local f = remaining / el
            return cx + ex * f, cz + ez * f
        end

        remaining = remaining - el
        cx, cz = nx, nz
        i = nextI
    end

    return cx, cz
end

---Removes LOCAL self-intersections ("bowtie" loop-backs) from an inset {x,y,z} polygon. When a
---boundary corner is sharper than the inset radius, the two offset edges meeting at that corner
---cross each other, enclosing a small reversed sub-loop (the notch seen in-game). We scan every
---pair of non-adjacent edges for an interior crossing; on the first one, the crossing point splits
---the ring into two runs — the enclosed artifact and the real field outline. The artifact is always
---the SHORTER run (a sharp-corner loop-back spans only a few vertices, the outline spans the rest),
---so we drop the shorter run and splice the crossing point in its place, then rescan until clean.
---O(n^2) per rescan; runs once per generation, so a few hundred points is fine.
---@param points table {x,y,z} polygon (mutated copy returned)
---@param terrainNode number for sampling the y of the spliced crossing point
---@return table
local function removeSelfIntersections(points, terrainNode)
    -- Bound the outer loop: at most one removal per original vertex guards against a pathological
    -- shape looping forever (each removal strictly shrinks the ring).
    for _ = 1, #points do
        local n = #points
        if n < 4 then
            return points
        end

        local foundI, foundJ, ix, iz
        for i = 1, n do
            local a = points[i]
            local b = points[i % n + 1]
            -- j from i+2 skips the vertex-sharing neighbour edge (i+1); the extra guard skips the
            -- ring-wrap neighbour (edge n shares vertex 1 with edge 1).
            for j = i + 2, n do
                if not (i == 1 and j == n) then
                    local c = points[j]
                    local d = points[j % n + 1]
                    local hx, hz = segmentIntersection(a.x, a.z, b.x, b.z, c.x, c.z, d.x, d.z)
                    if hx ~= nil then
                        foundI, foundJ, ix, iz = i, j, hx, hz
                        break
                    end
                end
            end
            if foundI ~= nil then
                break
            end
        end

        if foundI == nil then
            return points
        end

        -- Run A = vertices (foundI+1 .. foundJ), enclosed between the two crossing edges.
        -- Run B = the complement. Drop whichever is shorter; keep the crossing point as the join.
        local splice = { x = ix, y = getTerrainHeightAtWorldPos(terrainNode, ix, 0, iz), z = iz }
        local runA = foundJ - foundI
        local out = {}
        if runA <= n - runA then
            for k = 1, foundI do
                out[#out + 1] = points[k]
            end
            out[#out + 1] = splice
            for k = foundJ + 1, n do
                out[#out + 1] = points[k]
            end
        else
            for k = foundI + 1, foundJ do
                out[#out + 1] = points[k]
            end
            out[#out + 1] = splice
        end
        points = out
    end

    return points
end

---Creates a new HeadlandPasses producer for the given vehicle.
---@param vehicle table
---@return HeadlandPasses
function HeadlandPasses:new(vehicle)
    local instance = setmetatable({}, HeadlandPasses_mt)

    instance.vehicle = vehicle
    instance.state = HeadlandPasses.STATE_IDLE
    instance.passCount = HeadlandPasses.DEFAULT_PASS_COUNT
    instance.width = 0
    instance.loops = {}          -- ordered: [1] = outermost pass
    instance.activeLoopIndex = 1 -- updateActiveLoop tracks the nearest loop (both directions)
    instance.courseField = nil
    instance.detectionTime = 0
    instance.done = false
    instance.active = false        -- true when headland is the ACTIVE guidance source (exclusivity)
    instance.hasLoggedEngage = false -- one-shot guard for the "steering engaged" diagnostic

    return instance
end

---Starts an async field-boundary detection at the vehicle position and, on success,
---generates the inset loops. Safe to call while idle or ready; restarts detection.
---@param passCount number desired number of passes (clamped to 1..MAX_PASS_COUNT)
function HeadlandPasses:startDetection(passCount)
    if FieldCourseSettings == nil or FieldCourseSettings.generate == nil
        or FieldCourseField == nil or FieldCourseField.generateAtPosition == nil then
        Logger.warning("HeadlandPasses: base field-boundary API unavailable; cannot generate headland passes.")
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_headlandUnavailable"), 3000)
        return
    end

    local spec = self.vehicle.spec_globalPositioningSystem

    -- Match the mod's auto-width action (GlobalPositioningSystem.actionEventSetAutoWidth,
    -- GlobalPositioningSystem.lua:1101): max work-area width across the vehicle and its
    -- attached implements. This sizes loop spacing to the actual implement even when guidance
    -- was never activated and no track exists (guidanceData.width would still hold the GS
    -- default). Fall back to guidanceData.width if the computation yields nothing sensible.
    local width = GlobalPositioningSystem.getActualWorkWidth(spec.guidanceNode, self.vehicle)
    if width == nil or width <= 0 then
        width = spec.guidanceData.width
    end
    if width == nil or width <= 0 then
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_setWidth"), 2000)
        return
    end

    self.passCount = math.clamp(passCount or self.passCount, 1, HeadlandPasses.MAX_PASS_COUNT)
    self.width = width
    self.loops = {}
    self.activeLoopIndex = 1
    self.detectionTime = 0
    self.done = false
    self.state = HeadlandPasses.STATE_DETECTING

    local x, _, z = getWorldTranslation(spec.guidanceNode)

    -- Guard the engine interaction: FieldCourseSettings.generate reads the vehicle's AI markers
    -- (Courseplay ImplementUtil.lua:351), which can be absent on e.g. a tractor with no
    -- implement. Contain that so a user click degrades to a warning instead of a hard error.
    local ok, err = pcall(function()
        local settings = FieldCourseSettings.generate(self.vehicle)
        self.courseField = FieldCourseField.generateAtPosition(x, z, settings, function(courseField, success)
            self.done = true
            if success and courseField ~= nil and courseField.fieldRootBoundary ~= nil then
                self:onBoundaryDetected(courseField.fieldRootBoundary.boundaryLine)
            else
                self.state = HeadlandPasses.STATE_IDLE
                self.courseField = nil
                g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_headlandNoField"), 3000)
            end
        end)
    end)

    if not ok then
        Logger.warning("HeadlandPasses: field-boundary detection failed to start: " .. tostring(err))
        self.state = HeadlandPasses.STATE_IDLE
        self.courseField = nil
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_headlandNoField"), 3000)
        return
    end

    g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_info_headlandDetecting"), 2000)
end

---Pumps the async detection. No-op unless a detection is in progress.
---@param dt number
function HeadlandPasses:update(dt)
    if self.state ~= HeadlandPasses.STATE_DETECTING then
        return
    end

    self.detectionTime = self.detectionTime + dt
    if self.detectionTime > HeadlandPasses.DETECTION_TIMEOUT then
        Logger.warning("HeadlandPasses: field-boundary detection timed out; aborting.")
        self.state = HeadlandPasses.STATE_IDLE
        self.courseField = nil
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_headlandNoField"), 3000)
        return
    end

    -- FieldCourseField:update returns true while detecting and may never itself return false
    -- (Courseplay FieldBoundaryDetector.lua:60-64); completion is signalled by the callback
    -- setting self.done. Keep pumping until then.
    if not self.done and self.courseField ~= nil then
        self.courseField:update(dt, HeadlandPasses.DETECTION_TOLERANCE)
    end
end

---Callback body: build the boundary polygon and generate the inset loops.
---@param boundaryLine table array of {x, z} pairs from the engine (first vertex repeated last)
function HeadlandPasses:onBoundaryDetected(boundaryLine)
    local boundary = self:toPolygon(boundaryLine)
    self.courseField = nil

    if boundary == nil or #boundary < 3 then
        self.state = HeadlandPasses.STATE_IDLE
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_headlandNoField"), 3000)
        return
    end

    local rawCount = #boundary
    local smoothed = self:smoothBoundary(boundary)

    self.loops = self:generateLoops(smoothed, self.width, self.passCount)
    self.activeLoopIndex = 1
    self.state = HeadlandPasses.STATE_READY

    local n = #self.loops
    Logger.info(("HeadlandPasses: width=%.2fm passes requested=%d generated=%d dropped=%d boundary=%d->%d pts"):format(
        self.width, self.passCount, n, self.passCount - n, rawCount, #smoothed))

    if n == 0 then
        self.active = false
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_headlandTooSmall"), 3000)
    else
        -- Headland becomes the ACTIVE guidance source (exclusivity). Any AB track stays stored
        -- but inactive; the steering/draw branches prefer headland while self.active is true.
        self.active = true
        self.hasLoggedEngage = false
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_info_headlandCreated"):format(n), 3000)
    end
end

---Densify-then-Chaikin smoothing of the raw {x,y,z} boundary. Returns {x,z} points (loop
---generation samples terrain y itself, so boundary y is not needed downstream). See the
---SMOOTH_* constants for the rounding characteristics.
---@param boundary table
---@return table
function HeadlandPasses:smoothBoundary(boundary)
    if boundary == nil or #boundary < 3 then
        return boundary
    end

    local poly = densifyPolygon(boundary, HeadlandPasses.SMOOTH_SPACING)
    for _ = 1, HeadlandPasses.SMOOTH_ITERATIONS do
        poly = chaikin(poly)
    end
    return poly
end

---True when headland is the active guidance source and there is at least one loop to follow.
---@return boolean
function HeadlandPasses:isActive()
    return self.active and self.state == HeadlandPasses.STATE_READY and #self.loops > 0
end

---1-based pass number of the currently active loop (for the HUD).
---@return number
function HeadlandPasses:getActivePassNumber()
    return self.activeLoopIndex
end

---Drops headland as the guidance source and clears the loops. Called when an AB track becomes
---the active source (Set A/B or Load track funnel through onCreateGuidanceData) so the two
---sources can never be mixed.
function HeadlandPasses:deactivate()
    self.active = false
    self.hasLoggedEngage = false
    self.loops = {}
    self.activeLoopIndex = 1
    if self.state == HeadlandPasses.STATE_READY then
        self.state = HeadlandPasses.STATE_IDLE
    end
end

---Sets the active loop to whichever loop the vehicle is currently nearest, in EITHER direction
---(inner or outer). The midline between two loops (which sit one working width apart) is at half a
---width, so "nearest loop" is the AB half-width lane-switch rule (mirrors GlobalPositioningSystem
---.onUpdate's MathUtil.round(lineAlpha) nearest-lane pick), but unlike AB the vehicle can move to an
---outer pass again after passing a midline — nothing is ever locked out. A hysteresis dead-band
---(HYSTERESIS_FRACTION of a width) around the midline keeps the choice stable while straddling it.
---@param vehicle table
function HeadlandPasses:updateActiveLoop(vehicle)
    if not self:isActive() then
        return
    end

    if #self.loops < 2 then
        return
    end

    local spec = vehicle.spec_globalPositioningSystem
    local px, _, pz = getWorldTranslation(spec.guidanceNode)

    -- Nearest loop overall, plus the current active loop's distance (captured in the same scan).
    local bestIndex, bestDist = self.activeLoopIndex, math.huge
    local dActive = math.huge
    for idx, loop in ipairs(self.loops) do
        local _, _, d = nearestOnLoop(loop.points, px, pz)
        if idx == self.activeLoopIndex then
            dActive = d
        end
        if d < bestDist then
            bestDist = d
            bestIndex = idx
        end
    end

    if bestIndex == self.activeLoopIndex then
        return
    end

    -- Only switch once the candidate beats the active loop by the hysteresis margin.
    local margin = self.width * HeadlandPasses.HYSTERESIS_FRACTION
    if bestDist < dActive - margin then
        local from = self.activeLoopIndex
        self.activeLoopIndex = bestIndex
        self.hasLoggedEngage = false -- re-log the (possibly new) traversal direction on the new loop
        Logger.info(("HeadlandPasses: active loop %d -> %d (nearer: %.2fm < %.2fm, margin %.2fm)"):format(
            from, bestIndex, bestDist, dActive, margin))
    end
end

---Steers the vehicle along the active loop (server only; mirrors DriveUtil.guideSteering's
---contract). Pure-pursuit: snap to the nearest point on the active loop, pick the traversal
---direction matching the vehicle's current heading (works both ways around the loop), walk a
---look-ahead distance to a target point, then hand off to the SAME DriveUtil.driveToPoint and
---acceleration path the AB follower uses. The user still owns the throttle (spec.axisForward).
---@param vehicle table
---@param dt number
function HeadlandPasses:updateSteering(vehicle, dt)
    if not self:isActive() then
        return
    end

    local loop = self.loops[self.activeLoopIndex]
    local points = loop.points
    if #points < 2 then
        return
    end

    local spec = vehicle.spec_globalPositioningSystem
    local node = spec.guidanceNode
    local px, py, pz = getWorldTranslation(node)

    local segIndex, t = nearestOnLoop(points, px, pz)

    -- Traversal direction = whichever way around the loop aligns with where the vehicle points.
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    local a = points[segIndex]
    local b = points[segIndex % #points + 1]
    local dir = (fx * (b.x - a.x) + fz * (b.z - a.z)) >= 0 and 1 or -1

    local lastSpeed = vehicle:getLastSpeed()
    local lookAhead = math.clamp(
        HeadlandPasses.LOOK_AHEAD_BASE + lastSpeed * HeadlandPasses.LOOK_AHEAD_SPEED,
        HeadlandPasses.LOOK_AHEAD_MIN, HeadlandPasses.LOOK_AHEAD_MAX)

    local targetX, targetZ = walkAlongLoop(points, segIndex, t, dir, lookAhead)

    if not self.hasLoggedEngage then
        self.hasLoggedEngage = true
        Logger.info(("HeadlandPasses: steering engaged on loop %d, direction %s"):format(
            self.activeLoopIndex, dir >= 0 and "forward" or "reverse"))
    end

    local localX, _, localZ = worldToLocal(node, targetX, py, targetZ)
    DriveUtil.driveToPoint(vehicle, dt, localX, localZ)

    -- Lock max speed to the working tool, same as DriveUtil.guideSteering, then apply the
    -- player's throttle through the guidance path.
    local speed = vehicle:getSpeedLimit(true)
    local drivable_spec = vehicle:guidanceSteering_getSpecTable("drivable")
    if drivable_spec.cruiseControl.state == Drivable.CRUISECONTROL_STATE_ACTIVE then
        speed = math.min(speed, drivable_spec.cruiseControl.speed)
    end
    vehicle:getMotor():setSpeedLimit(speed)

    DriveUtil.accelerateInDirection(vehicle, spec.axisForward, dt, false)
end

---Converts the engine's {x,z} boundary line into an {x,y,z} polygon, dropping the repeated
---closing vertex (Courseplay does the same, FieldBoundaryDetector.lua:87).
---@param boundaryLine table
---@return table|nil
function HeadlandPasses:toPolygon(boundaryLine)
    if boundaryLine == nil or #boundaryLine < 4 then
        return nil
    end

    local terrainNode = g_terrainNode or g_currentMission.terrainRootNode
    local poly = {}
    for i = 1, #boundaryLine - 1 do
        local p = boundaryLine[i]
        local x, z = p[1], p[2]
        poly[i] = { x = x, y = getTerrainHeightAtWorldPos(terrainNode, x, 0, z), z = z }
    end
    return poly
end

---Picks the edge-normal rotation that points into the polygon (winding-agnostic). Returns
---+1 if the normal (-ez, ex) of edge 1 points inside, -1 otherwise. Consistent winding means
---the same sign is inward for every edge.
---@param poly table
---@return number
function HeadlandPasses:getInwardSign(poly)
    local a, b = poly[1], poly[2]
    local ex, ez = b.x - a.x, b.z - a.z
    local len = math.sqrt(ex * ex + ez * ez)
    if len < 0.0001 then
        return 1
    end
    ex, ez = ex / len, ez / len

    local mx, mz = (a.x + b.x) * 0.5, (a.z + b.z) * 0.5
    local eps = 0.5
    if pointInPolygon(poly, mx - ez * eps, mz + ex * eps) then
        return 1
    end
    return -1
end

---Generates up to passCount inset loops. Stops early (dropping the collapsing loop and all
---inner ones) once an inset exceeds the field.
---@param boundary table {x,y,z} polygon
---@param width number working width
---@param passCount number
---@return table array of { index, points, closed }
function HeadlandPasses:generateLoops(boundary, width, passCount)
    local loops = {}
    local baseSign = polygonSignedArea(boundary) >= 0 and 1 or -1
    local inwardSign = self:getInwardSign(boundary)
    local minArea = width * width
    local terrainNode = g_terrainNode or g_currentMission.terrainRootNode

    for i = 1, passCount do
        local inset = (i - 0.5) * width
        local points = self:offsetPolygon(boundary, inset, inwardSign)
        if points == nil then
            break
        end

        -- Cull local self-intersections (offset bowties at corners sharper than the inset) before
        -- measuring area, so the collapse guard sees the true field outline, not the notched ring.
        points = removeSelfIntersections(points, terrainNode)

        -- Collapse guard: an over-inset loop flips its winding or shrinks to nothing.
        local area = polygonSignedArea(points)
        local newSign = area >= 0 and 1 or -1
        if newSign ~= baseSign or math.abs(area) < minArea then
            break
        end

        table.insert(loops, { index = i, points = points, closed = true })
    end

    return loops
end

---Insets a polygon by offsetting each edge inward and re-intersecting adjacent offset edges.
---@param boundary table {x,y,z} polygon
---@param inset number distance to offset inward
---@param inwardSign number +1 or -1 from getInwardSign
---@return table|nil {x,y,z} inset polygon, or nil if the boundary has a degenerate edge
function HeadlandPasses:offsetPolygon(boundary, inset, inwardSign)
    local n = #boundary

    -- Each edge i runs boundary[i] -> boundary[i+1]; store a point on its inward-offset line
    -- plus the (unchanged) edge direction.
    local edges = {}
    for i = 1, n do
        local a = boundary[i]
        local b = boundary[i % n + 1]
        local ex, ez = b.x - a.x, b.z - a.z
        local len = math.sqrt(ex * ex + ez * ez)
        if len < 0.0001 then
            return nil
        end
        ex, ez = ex / len, ez / len
        local nx, nz = inwardSign * -ez, inwardSign * ex
        edges[i] = { px = a.x + nx * inset, pz = a.z + nz * inset, dx = ex, dz = ez }
    end

    -- Output vertex j (= boundary vertex j) is the intersection of offset edge (j-1) and (j).
    local terrainNode = g_terrainNode or g_currentMission.terrainRootNode
    local out = {}
    for j = 1, n do
        local prev = edges[(j - 2) % n + 1]
        local cur = edges[j]
        local vx, vz
        local hit, f1 = lineIntersect(prev.px, prev.pz, prev.dx, prev.dz, cur.px, cur.pz, cur.dx, cur.dz)
        if hit then
            vx = prev.px + f1 * prev.dx
            vz = prev.pz + f1 * prev.dz
        else
            -- Collinear/parallel consecutive edges: the offset point is already correct.
            vx, vz = cur.px, cur.pz
        end
        out[j] = { x = vx, y = getTerrainHeightAtWorldPos(terrainNode, vx, 0, vz), z = vz }
    end

    return out
end

---Draws all generated loops in the AB guidance-line visual language, with STRICT AB parity on the
---engaged/not-engaged colour swap. The active loop is the analog of AB's middle line: it renders
---green only while GS steering is engaged (guidanceSteeringIsActive) and white when not — exactly
---AB's `guidanceSteeringIsActive and rgbActive or rgb` rule (ABStrategy.lua:149, middle line
---rgbActive=green/rgb=white, ABStrategy.lua:30). The immediate next inner loop is the analog of AB's
---side/"next" line: blue in BOTH states (ABStrategy side lines rgb=rgbActive=blue, ABStrategy.lua
---:29,31). Other loops stay inactive white. Honors the same show-as-dots toggle and reuses the exact
---AB primitives — GuidanceUtil.renderText3DAtWorldPosition for dots (ABStrategy.lua:133) and
---drawDebugLine for lines (ABStrategy.lua:138), the same RGB constants (ABStrategy.lua:23-25),
---lineOffset (getLineOffset) and camera-billboarded dots (ABStrategy.lua:116-120). Called from
---onDraw, which passes spec.guidanceSteeringIsActive (GlobalPositioningSystem.lua:679).
---@param guidanceSteeringIsActive boolean true while GS steering is engaged (Alt+X active)
function HeadlandPasses:draw(guidanceSteeringIsActive)
    if self.state ~= HeadlandPasses.STATE_READY or #self.loops == 0 then
        return
    end

    local guidanceSteering = g_currentMission.guidanceSteering
    local lineOffset = guidanceSteering:getLineOffset()
    local showAsDots = guidanceSteering:isShowGuidanceLinesAsDotsEnabled()
    local terrainNode = g_terrainNode or g_currentMission.terrainRootNode

    -- Dots are billboarded to the active camera, exactly as ABStrategy:draw does.
    local camRotX, camRotY, camRotZ = 0, 0, 0
    if showAsDots then
        local activeCamera = self.vehicle:getActiveCamera()
        if activeCamera ~= nil then
            camRotX, camRotY, camRotZ = getWorldRotation(activeCamera.cameraNode)
        end
    end

    -- Dots at the AB 1 m spacing (ABStrategy.STEP_SIZE) so dot density matches AB; continuous lines
    -- subdivide at DRAW_STEP purely to follow interior terrain.
    local stepLen = showAsDots and ABStrategy.STEP_SIZE or HeadlandPasses.DRAW_STEP

    for _, loop in ipairs(self.loops) do
        local rgb
        if loop.index == self.activeLoopIndex then
            -- AB middle-line rule: green only while engaged, white otherwise.
            rgb = guidanceSteeringIsActive and RGB_GREEN or RGB_WHITE
        elseif loop.index == self.activeLoopIndex + 1 then
            rgb = RGB_BLUE
        else
            rgb = RGB_WHITE
        end

        local pts = loop.points
        local count = #pts
        for i = 1, count do
            local a = pts[i]
            local b = pts[i % count + 1]

            -- Corner heights (a.y/b.y) were terrain-sampled at generation; interior steps sample now
            -- so the line follows interior ground instead of dipping below a rising hill.
            local dx, dz = b.x - a.x, b.z - a.z
            local segLen = math.sqrt(dx * dx + dz * dz)
            local steps = math.max(1, math.ceil(segLen / stepLen))

            local px, py, pz = a.x, a.y + lineOffset, a.z
            for s = 1, steps do
                local nx, ny, nz
                if s == steps then
                    nx, ny, nz = b.x, b.y + lineOffset, b.z
                else
                    local t = s / steps
                    nx, nz = a.x + dx * t, a.z + dz * t
                    ny = getTerrainHeightAtWorldPos(terrainNode, nx, 0, nz) + lineOffset
                end

                if showAsDots then
                    GuidanceUtil.renderText3DAtWorldPosition(px, py, pz, camRotX, camRotY, camRotZ, 0.5, ".", rgb)
                else
                    drawDebugLine(px, py, pz, rgb[1], rgb[2], rgb[3], nx, ny, nz, rgb[1], rgb[2], rgb[3])
                end
                px, py, pz = nx, ny, nz
            end
        end
    end
end

---Resets state and clears loops.
function HeadlandPasses:delete()
    self.loops = {}
    self.courseField = nil
    self.state = HeadlandPasses.STATE_IDLE
    self.active = false
    self.hasLoggedEngage = false
end
