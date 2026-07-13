---
-- GuidanceSteeringHUD
--
-- HUD for GuidanceSteering
--
-- Copyright (c) Wopster, 2019
--
-- FS25 port: the rendering was rewritten to be fully self-contained. The FS22
-- HUD parented HUDElements to the SpeedMeterDisplay and relied on the base HUD's
-- layout/scale pipeline (addChild / storeScaledValues / scalePixelToScreenVector /
-- getPosition). In FS25 SpeedMeterDisplay derives from HUDDisplay, and that
-- pipeline is no longer driven for it (the appended storeScaledValues hook never
-- fired, leaving text offsets nil -> per-frame "arithmetic on nil"). This version
-- owns everything: plain Overlay objects, positioned every frame from the screen
-- edge + UI scale, drawn from an appended SpeedMeterDisplay.draw hook. The only
-- base-game field it reads is the per-frame draw guard, exactly as
-- FS25_VehicleControlAddon does.

---@class GuidanceSteeringHUD
GuidanceSteeringHUD = {}

local GuidanceSteeringHUD_mt = Class(GuidanceSteeringHUD)

---Creates a new instance of the GuidanceSteeringHUD.
---@return GuidanceSteeringHUD
function GuidanceSteeringHUD:new(mission, speedMeterDisplay, i18n, uiFilename)
    local instance = setmetatable({}, GuidanceSteeringHUD_mt)

    instance.speedMeterDisplay = speedMeterDisplay
    instance.i18n = i18n
    instance.uiFilename = uiFilename

    instance.vehicle = nil
    instance.receiverIconIsActive = false
    instance.steeringIconIsActive = false
    instance.laneText = "0"
    -- Current line method readout ("A+B" / "A+H" / "A+D"); set per frame from the
    -- vehicle's active guidance strategy (spec.lineStrategy.id) in onDraw.
    instance.methodText = ""

    -- Draw our overlays on top of the speed meter every frame. We never call
    -- layout/scale helpers on the base HUD; we only read the per-frame draw
    -- guard fields from it (see onDraw). Hook pattern proven by
    -- FS25_VehicleControlAddon (vehicleControlAddon.lua:5652).
    --
    -- Install the hook exactly once per script load. A fresh GuidanceSteeringHUD is
    -- constructed on every mission load (loader.lua:loadMission), and Utils.appendedFunction
    -- stacks a new copy each time; without this guard the HUD would redraw N times after N
    -- reloads in one session. speedMeterDisplay_draw is a static router that always dispatches
    -- to the CURRENT hud via g_currentMission.guidanceSteering.ui.hud, so one install serves
    -- every instance and needs no teardown in delete() (it no-ops when that chain is nil after
    -- unload). VCA likewise installs its SpeedMeterDisplay.draw hook once, at file scope.
    if not GuidanceSteeringHUD.hookInstalled then
        SpeedMeterDisplay.draw = Utils.appendedFunction(SpeedMeterDisplay.draw, GuidanceSteeringHUD.speedMeterDisplay_draw)
        GuidanceSteeringHUD.hookInstalled = true
    end

    return instance
end

function GuidanceSteeringHUD:delete()
    if self.stateBox ~= nil and self.stateBox.delete ~= nil then
        self.stateBox:delete()
    end
    local icons = { self.steeringIcon, self.receiverIcon, self.laneIcon }
    for _, overlay in ipairs(icons) do
        if overlay ~= nil and overlay.delete ~= nil then
            overlay:delete()
        end
    end
    self.stateBox = nil
    self.steeringIcon = nil
    self.receiverIcon = nil
    self.laneIcon = nil
end

function GuidanceSteeringHUD:load()
    self:createElements()
    self:setVehicle(nil)
end

--- Create the (unpositioned) overlays once. Positioning/scaling happens per
--- frame in onDraw so the HUD needs no base-HUD layout callbacks.
function GuidanceSteeringHUD:createElements()
    -- Icons come from our own atlas. Overlay object API (new / setUVs / setColor /
    -- setPosition / setDimension / render) proven by FS25_VehicleFruitHud
    -- (hlHudSystemOverlays.lua:92, _hlUtils.lua:641-642, VehicleFruitHud_Draw.lua:344-346).
    self.steeringIcon = self:createIcon(self.uiFilename, GuidanceSteeringHUD.UV.STEERING_WHEEL_DISABLED)
    self.receiverIcon = self:createIcon(self.uiFilename, GuidanceSteeringHUD.UV.RECEIVER)
    self.laneIcon = self:createIcon(self.uiFilename, GuidanceSteeringHUD.UV.LANE)

    if self.steeringIcon ~= nil then
        self.steeringIcon:setColor(unpack(GuidanceSteeringHUD.COLOR.INACTIVE))
    end
    if self.receiverIcon ~= nil then
        self.receiverIcon:setColor(unpack(GuidanceSteeringHUD.COLOR.INACTIVE))
    end
    if self.laneIcon ~= nil then
        self.laneIcon:setColor(unpack(GuidanceSteeringHUD.COLOR.INACTIVE))
    end

    -- Optional dark background box behind the icons. g_overlayManager:createOverlay
    -- returns an Overlay, or nil + a one-time log line on an unknown slice (never
    -- per frame). If it fails we simply render without a background; the icons
    -- remain visible.
    if g_overlayManager ~= nil then
        local boxOverlay = g_overlayManager:createOverlay("gui.gearBg", 0, 0, 0, 0)
        if boxOverlay ~= nil then
            boxOverlay:setColor(unpack(GuidanceSteeringHUD.COLOR.BOX_BG))
            self.stateBox = boxOverlay
        end
    end
end

--- Create a single icon overlay from the mod atlas.
function GuidanceSteeringHUD:createIcon(imagePath, uvs)
    local overlay = Overlay.new(imagePath, 0, 0, 0, 0)
    if overlay ~= nil then
        overlay:setUVs(GuiUtils.getUVs(uvs))
    end
    return overlay
end

--- Sets the current vehicle to display on the HUD.
function GuidanceSteeringHUD:setVehicle(vehicle)
    self.vehicle = vehicle
end

--- Short label for the active line method. Source of truth is the vehicle's current
--- guidance strategy object (spec.lineStrategy), whose .id is one of the ABStrategy
--- constants set when the strategy is created/swapped in GlobalPositioningSystem:
--- setGuidanceStrategy (AB -> StraightABStrategy, A_PLUS_HEADING -> CardinalStrategy,
--- A_PLUS_DIRECTION -> SnapDirectionStrategy). Unknown/nil ids yield an empty string so
--- the HUD simply omits the readout.
function GuidanceSteeringHUD:getMethodText(methodId)
    if ABStrategy == nil or methodId == nil then
        return ""
    end
    if methodId == ABStrategy.AB then
        return "A+B"
    elseif methodId == ABStrategy.A_PLUS_HEADING then
        return "A+H"
    elseif methodId == ABStrategy.A_PLUS_DIRECTION then
        return "A+D"
    end
    return ""
end

--- Gets the lane text depending on the direction.
function GuidanceSteeringHUD:getLaneText(laneNumber)
    local lane = math.abs(laneNumber)
    if laneNumber < 0 then
        return ("-%s"):format(lane)
    elseif laneNumber > 0 then
        return ("+%s"):format(lane)
    end
    return ("%s"):format(lane)
end

--- The current in-game UI scale (FS25_VehicleControlAddon.getUiScale pattern,
--- vehicleControlAddon.lua:88-94). Nil-tolerant, defaults to 1.0.
function GuidanceSteeringHUD:getUiScale()
    if g_gameSettings ~= nil and type(g_gameSettings.uiScale) == "number" and g_gameSettings.uiScale > 0 then
        return g_gameSettings.uiScale
    end
    return 1.0
end

--- Compute the on-screen geometry for this frame. Everything is anchored to the
--- bottom-right safe-frame corner and scaled by the UI scale, converting pixel
--- sizes to normalized screen coordinates with getNormalizedScreenValues -- the
--- same self-contained approach FS25_FuelConsumptionHUD uses
--- (FuelConsumptionHUD.lua:492-508). Returns nil if any engine value is missing
--- so onDraw can bail without arithmetic on nil.
function GuidanceSteeringHUD:computeLayout()
    if getNormalizedScreenValues == nil then
        return nil
    end

    local P = GuidanceSteeringHUD
    local uiScale = self:getUiScale()

    local safeX = g_safeFrameOffsetX
    local safeY = g_safeFrameOffsetY
    if type(safeX) ~= "number" then safeX = 0 end
    if type(safeY) ~= "number" then safeY = 0 end

    local boxW, boxH = getNormalizedScreenValues(P.SIZE.BOX[1] * uiScale, P.SIZE.BOX[2] * uiScale)
    local iconW, iconH = getNormalizedScreenValues(P.SIZE.ICON[1] * uiScale, P.SIZE.ICON[2] * uiScale)
    local padX, padY = getNormalizedScreenValues(P.SIZE.BOX_PAD * uiScale, P.SIZE.BOX_PAD * uiScale)
    local _, gapY = getNormalizedScreenValues(0, P.SIZE.ICON_GAP * uiScale)
    local marginR = getNormalizedScreenValues(P.ANCHOR.RIGHT_MARGIN * uiScale, 0)
    local _, marginB = getNormalizedScreenValues(0, P.ANCHOR.BOTTOM_MARGIN * uiScale)
    local _, laneTextSize = getNormalizedScreenValues(0, P.LANE_TEXT.SIZE * uiScale)
    local laneGapX = getNormalizedScreenValues(P.LANE_TEXT.GAP * uiScale, 0)

    if boxW == nil or boxH == nil or iconW == nil or iconH == nil
        or padX == nil or padY == nil or gapY == nil
        or marginR == nil or marginB == nil or laneTextSize == nil or laneGapX == nil then
        return nil
    end

    local boxRightX = (1.0 - safeX) - marginR
    local boxY = safeY + marginB          -- bottom edge of the box
    local boxX = boxRightX - boxW         -- left edge of the box
    local boxTopY = boxY + boxH

    local iconX = boxX + padX
    local rowY = {}
    rowY[1] = boxTopY - padY - iconH               -- steering (top)
    rowY[2] = rowY[1] - (iconH + gapY)             -- receiver (middle)
    rowY[3] = rowY[2] - (iconH + gapY)             -- lane (bottom)

    return {
        boxX = boxX,
        boxY = boxY,
        boxW = boxW,
        boxH = boxH,
        iconX = iconX,
        iconW = iconW,
        iconH = iconH,
        rowY = rowY,
        laneTextSize = laneTextSize,
        laneTextX = boxX - laneGapX,
        laneTextY = rowY[3] + iconH * 0.5,         -- vertical centre of the lane row
    }
end

--- Update the icon UVs/colours to reflect the current guidance state.
function GuidanceSteeringHUD:updateIconState(spec)
    local P = GuidanceSteeringHUD

    if self.steeringIconIsActive ~= spec.guidanceSteeringIsActive then
        self.steeringIconIsActive = spec.guidanceSteeringIsActive
        local uvs = self.steeringIconIsActive and P.UV.STEERING_WHEEL_ENABLED or P.UV.STEERING_WHEEL_DISABLED
        local color = self.steeringIconIsActive and P.COLOR.ACTIVE or P.COLOR.INACTIVE
        self.steeringIcon:setUVs(GuiUtils.getUVs(uvs))
        self.steeringIcon:setColor(unpack(color))
    end

    if self.receiverIconIsActive ~= spec.guidanceIsActive then
        self.receiverIconIsActive = spec.guidanceIsActive
        local color = self.receiverIconIsActive and P.COLOR.ACTIVE or P.COLOR.INACTIVE
        self.receiverIcon:setColor(unpack(color))
        self.laneIcon:setColor(unpack(color))
    end
end

local function renderOverlayAt(overlay, x, y, width, height)
    if overlay == nil then
        return
    end
    overlay:setPosition(x, y)
    overlay:setDimension(width, height)
    overlay:render()
end

--- Per-frame entry point, called from the appended SpeedMeterDisplay.draw hook.
--- speedMeterDisplay is the display instance (the hook's self).
function GuidanceSteeringHUD:onDraw(speedMeterDisplay)
    -- Draw guard copied from FS25_VehicleControlAddon (vehicleControlAddon.lua:5591-5592):
    -- only render while the speed meter itself is drawing for a real, visible vehicle.
    if speedMeterDisplay == nil then
        return
    end
    if speedMeterDisplay.isVehicleDrawSafe ~= true then
        return
    end
    if speedMeterDisplay.getVisible == nil or not speedMeterDisplay:getVisible() then
        return
    end

    local vehicle = self.vehicle
    if vehicle == nil then
        return
    end

    local spec = vehicle.spec_globalPositioningSystem
    if spec == nil or spec.guidanceData == nil then
        return
    end

    -- Our overlays must exist (createElements ran). All three are created together.
    if self.steeringIcon == nil or self.receiverIcon == nil or self.laneIcon == nil then
        return
    end

    self.laneText = self:getLaneText(spec.guidanceData.currentLane or 0)
    -- spec.lineStrategy is created in GlobalPositioningSystem:onLoad and swapped by
    -- setGuidanceStrategy; nil-guard it in case the HUD draws during a transient state.
    local strategy = spec.lineStrategy
    self.methodText = strategy ~= nil and self:getMethodText(strategy.id) or ""
    self:updateIconState(spec)

    local layout = self:computeLayout()
    if layout == nil then
        return
    end

    renderOverlayAt(self.stateBox, layout.boxX, layout.boxY, layout.boxW, layout.boxH)
    renderOverlayAt(self.steeringIcon, layout.iconX, layout.rowY[1], layout.iconW, layout.iconH)
    renderOverlayAt(self.receiverIcon, layout.iconX, layout.rowY[2], layout.iconW, layout.iconH)
    renderOverlayAt(self.laneIcon, layout.iconX, layout.rowY[3], layout.iconW, layout.iconH)

    self:drawLaneText(layout)
end

function GuidanceSteeringHUD:drawLaneText(layout)
    if renderText == nil then
        return
    end

    local color = self.receiverIconIsActive and GuidanceSteeringHUD.COLOR.ACTIVE or GuidanceSteeringHUD.COLOR.INACTIVE

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    setTextColor(unpack(color))

    renderText(layout.laneTextX, layout.laneTextY, layout.laneTextSize, self.laneText)

    -- Line-method readout ("A+B" / "A+H" / "A+D"), stacked just above the lane number,
    -- same style/colour, slightly smaller so it reads as a sub-label. Omitted when empty.
    if self.methodText ~= nil and self.methodText ~= "" then
        local methodSize = layout.laneTextSize * 0.9
        local methodY = layout.laneTextY + layout.laneTextSize * 1.15
        renderText(layout.laneTextX, methodY, methodSize, self.methodText)
    end

    -- Restore engine text defaults so we don't leak state into other HUD draws.
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
end

function GuidanceSteeringHUD.speedMeterDisplay_draw(speedMeterDisplay)
    local mission = g_currentMission
    if mission == nil then
        return
    end
    local guidanceSteering = mission.guidanceSteering
    if guidanceSteering == nil or guidanceSteering.ui == nil then
        return
    end
    local hud = guidanceSteering.ui.hud
    if hud ~= nil then
        hud:onDraw(speedMeterDisplay)
    end
end

-- Pixel sizes are authored against a 1080p reference and multiplied by the UI
-- scale before being converted to normalized screen coordinates.
GuidanceSteeringHUD.SIZE = {
    BOX = { 44, 120 },
    ICON = { 32, 32 },
    ICON_GAP = 6,
    BOX_PAD = 6,
}

-- Placement of the widget's box relative to the bottom-right safe-frame corner,
-- in 1080p pixels. RIGHT_MARGIN is the gap from the box's right edge to the safe
-- right edge; BOTTOM_MARGIN lifts the box's bottom edge above the safe bottom so
-- it sits above the speed gauge. Tune here if it overlaps other HUD elements.
GuidanceSteeringHUD.ANCHOR = {
    RIGHT_MARGIN = 52,
    BOTTOM_MARGIN = 250,
}

GuidanceSteeringHUD.LANE_TEXT = {
    SIZE = 20,   -- text height in pixels
    GAP = 8,     -- gap between the box's left edge and the (right-aligned) lane text
}

GuidanceSteeringHUD.UV = {
    STEERING_WHEEL_ENABLED = { 650, 0, 65, 65 },
    STEERING_WHEEL_DISABLED = { 715, 0, 65, 65 },
    RECEIVER = { 650, 65, 65, 65 },
    LANE = { 715, 65, 65, 65 },
}

GuidanceSteeringHUD.COLOR = {
    INACTIVE = { 0.7, 0.7, 0.7, 0.3 },
    ACTIVE = { 0.0003, 0.5647, 0.9822, 1 },
    -- FS25 port: box background tint (replaces the removed SpeedMeterDisplay.COLOR.GEARS_BG).
    BOX_BG = { 0.018, 0.018, 0.018, 0.6 },
}
