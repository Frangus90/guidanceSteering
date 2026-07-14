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

local RGB_WHITE = { 1, 1, 1 }
local RGB_GREEN = { 0, 0.447871, 0.003697 }

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
    instance.activeLoopIndex = 1 -- slice 2 advances this AB-style; slice 1 highlights loop 1
    instance.courseField = nil
    instance.detectionTime = 0
    instance.done = false

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

    self.loops = self:generateLoops(boundary, self.width, self.passCount)
    self.activeLoopIndex = 1
    self.state = HeadlandPasses.STATE_READY

    local n = #self.loops
    Logger.info(("HeadlandPasses: width=%.2fm passes requested=%d generated=%d dropped=%d"):format(
        self.width, self.passCount, n, self.passCount - n))

    if n == 0 then
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_headlandTooSmall"), 3000)
    else
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_info_headlandCreated"):format(n), 3000)
    end
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

    for i = 1, passCount do
        local inset = (i - 0.5) * width
        local points = self:offsetPolygon(boundary, inset, inwardSign)
        if points == nil then
            break
        end

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

---Draws all generated loops. Active loop = green, others = white. Called from onDraw under
---the existing show-lines gate.
function HeadlandPasses:draw()
    if self.state ~= HeadlandPasses.STATE_READY or #self.loops == 0 then
        return
    end

    local lineOffset = g_currentMission.guidanceSteering:getLineOffset()
    local terrainNode = g_terrainNode or g_currentMission.terrainRootNode

    for _, loop in ipairs(self.loops) do
        local rgb = (loop.index == self.activeLoopIndex) and RGB_GREEN or RGB_WHITE
        local pts = loop.points
        local count = #pts
        for i = 1, count do
            local a = pts[i]
            local b = pts[i % count + 1]

            -- Subdivide each edge into ~DRAW_STEP steps and re-sample terrain at every step so
            -- the line follows interior ground instead of dipping below a rising hill between
            -- two distant corners (the same terrain-follow the AB line does, ABStrategy.lua:128).
            -- Corner heights (a.y/b.y) were terrain-sampled at generation; interior steps sample now.
            local dx, dz = b.x - a.x, b.z - a.z
            local segLen = math.sqrt(dx * dx + dz * dz)
            local steps = math.max(1, math.ceil(segLen / HeadlandPasses.DRAW_STEP))

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
                drawDebugLine(px, py, pz, rgb[1], rgb[2], rgb[3], nx, ny, nz, rgb[1], rgb[2], rgb[3])
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
end
