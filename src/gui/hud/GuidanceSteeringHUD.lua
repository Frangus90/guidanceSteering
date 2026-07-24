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

    -- Drag & drop state. posX/posY are the box's bottom-left corner in normalized screen
    -- coordinates (0..1), i.e. resolution independent -- the same storage model Courseplay
    -- uses for its moveable HUD (CpBaseHud.lua:82 getNormalizedScreenValues + #posX/#posY
    -- floats). nil means "never moved": computeLayout falls back to the default bottom-right
    -- anchor below.
    instance.posX = nil
    instance.posY = nil
    instance.isDragging = false
    instance.dragOffsetX = 0
    instance.dragOffsetY = 0
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
    self:loadPosition()
    self:setVehicle(nil)
end

--- Absolute path of the per-user HUD position file. The modSettings folder under the user
--- profile is the FS25 idiom for settings that are not tied to a savegame; path shape and
--- createFolder usage from Courseplay (Courseplay.lua:19-20) and the fs25-modding
--- hud-framework reference (User Settings Storage).
function GuidanceSteeringHUD:getPositionFilePath()
    if getUserProfileAppPath == nil or g_guidanceSteeringModName == nil then
        return nil
    end
    return getUserProfileAppPath() .. "modSettings/" .. g_guidanceSteeringModName .. "/hud.xml"
end

--- Read the stored HUD position. Missing file, missing attributes or out-of-range values all
--- leave posX/posY nil so computeLayout uses the default anchor.
function GuidanceSteeringHUD:loadPosition()
    local path = self:getPositionFilePath()
    if path == nil or not fileExists(path) then
        return
    end

    local xmlFile = XMLFile.load("GuidanceSteeringHudXML", path)
    if xmlFile == nil then
        return
    end

    local x = xmlFile:getFloat("guidanceSteeringHud.position#x")
    local y = xmlFile:getFloat("guidanceSteeringHud.position#y")
    xmlFile:delete()

    -- Reject values that cannot be a screen fraction (hand-edited or written by a different
    -- coordinate model); the clamp in computeLayout only fixes values that are still sane.
    if x ~= nil and y ~= nil and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
        self.posX = x
        self.posY = y
    end
end

--- Persist the current HUD position. Called once when a drag ends, not per frame.
function GuidanceSteeringHUD:savePosition()
    local path = self:getPositionFilePath()
    if path == nil or self.posX == nil or self.posY == nil then
        return
    end

    createFolder(getUserProfileAppPath() .. "modSettings/" .. g_guidanceSteeringModName)

    local xmlFile = XMLFile.create("GuidanceSteeringHudXML", path, "guidanceSteeringHud")
    if xmlFile == nil then
        -- Unwritable path (missing/locked modSettings folder, read-only profile). The HUD keeps
        -- the dragged position for this session; it just won't survive a restart.
        Logger.warning(("Could not write the HUD position file '%s'; position will not persist."):format(path))
        return
    end

    xmlFile:setFloat("guidanceSteeringHud.position#x", self.posX)
    xmlFile:setFloat("guidanceSteeringHud.position#y", self.posY)
    xmlFile:save()
    xmlFile:delete()
end

--- Drop the stored position and the file backing it, so the HUD returns to (and stays at)
--- the default bottom-right anchor.
function GuidanceSteeringHUD:resetPosition()
    self.posX = nil
    self.posY = nil
    self.isDragging = false

    local path = self:getPositionFilePath()
    if path ~= nil and fileExists(path) then
        deleteFile(path)
    end
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

--- Compute the on-screen geometry for this frame. Everything is anchored to the box's
--- bottom-left corner (dragged position, or by default the bottom-right safe-frame
--- corner) and scaled by the UI scale, converting pixel
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
    local textReserve = getNormalizedScreenValues(P.LANE_TEXT.RESERVE * uiScale, 0)

    if boxW == nil or boxH == nil or iconW == nil or iconH == nil
        or padX == nil or padY == nil or gapY == nil
        or marginR == nil or marginB == nil or laneTextSize == nil or laneGapX == nil
        or textReserve == nil then
        return nil
    end

    -- Bottom-left corner of the box: the dragged position when the user has moved the HUD,
    -- otherwise the original bottom-right safe-frame anchor.
    local boxX, boxY
    if self.posX ~= nil and self.posY ~= nil then
        boxX, boxY = self.posX, self.posY
    else
        boxX = ((1.0 - safeX) - marginR) - boxW
        boxY = safeY + marginB
    end

    -- Keep the whole widget on screen. The lane/method text is drawn to the LEFT of the box,
    -- so the left bound reserves room for it; the default anchor is well inside these bounds,
    -- so this is a no-op until the HUD is dragged. Re-clamping every frame also absorbs a
    -- resolution or UI-scale change made after the position was saved.
    boxX = math.clamp(boxX, textReserve, 1.0 - boxW)
    boxY = math.clamp(boxY, 0.0, 1.0 - boxH)

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

    -- When headland is the active guidance source, show "HL" + the active pass number instead
    -- of the AB method/lane readout (they are mutually exclusive sources).
    if spec.headland ~= nil and spec.headland:isActive() then
        self.methodText = "HL"
        self.laneText = tostring(spec.headland:getActivePassNumber())
    else
        self.laneText = self:getLaneText(spec.guidanceData.currentLane or 0)
        -- spec.lineStrategy is created in GlobalPositioningSystem:onLoad and swapped by
        -- setGuidanceStrategy; nil-guard it in case the HUD draws during a transient state.
        local strategy = spec.lineStrategy
        self.methodText = strategy ~= nil and self:getMethodText(strategy.id) or ""
    end
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

--- Drag & drop repositioning. Routed here from GuidanceSteering:mouseEvent (the mod event
--- listener), which is the FS25 way a non-GUI mod receives mouse input -- proven by
--- FS25_Courseplay (Courseplay.lua:222-231 + addModEventListener at Courseplay.lua:313) and
--- FS25_VehicleFruitHud (hlHudSystem.lua:93 + addModEventListener at hlHudSystem.lua:363).
---
--- Dragging is only possible while the mouse cursor is actually shown in-game
--- (g_inputBinding:getShowMouseCursor(), the same global cursor state Courseplay's HUD gates
--- on -- CpHud.lua:140/144/301), so normal driving is never affected. The caller already
--- rejects the event while a menu is open.
---
--- The press/hold/release shape (grab offset on mouse-down, follow while held, commit on
--- mouse-up) follows Courseplay's CpHudMoveableElement (HudElements.lua:370-419); hit testing
--- uses GuiUtils.checkOverlayOverlap, the same helper it uses (HudElements.lua:73).
function GuidanceSteeringHUD:mouseEvent(posX, posY, isDown, isUp, button)
    if g_inputBinding == nil or not g_inputBinding:getShowMouseCursor() then
        self:stopDrag()
        return
    end

    -- Same visibility precondition as onDraw: no vehicle with guidance data, nothing drawn,
    -- nothing to grab.
    local vehicle = self.vehicle
    if vehicle == nil or vehicle.spec_globalPositioningSystem == nil then
        self:stopDrag()
        return
    end

    local layout = self:computeLayout()
    if layout == nil then
        return
    end

    if button == Input.MOUSE_BUTTON_LEFT then
        if isDown then
            if not self.isDragging and GuiUtils.checkOverlayOverlap(posX, posY, layout.boxX, layout.boxY, layout.boxW, layout.boxH) then
                self.isDragging = true
                self.dragOffsetX = posX - layout.boxX
                self.dragOffsetY = posY - layout.boxY
            end
        elseif isUp then
            self:stopDrag()
            return
        end
    end

    if self.isDragging then
        -- Store the raw corner; computeLayout clamps it back on screen every frame.
        self.posX = posX - self.dragOffsetX
        self.posY = posY - self.dragOffsetY
    end
end

--- End an in-progress drag and persist where it landed. The clamped value is read back from
--- the layout so the file never stores an off-screen corner.
function GuidanceSteeringHUD:stopDrag()
    if not self.isDragging then
        return
    end

    self.isDragging = false

    local layout = self:computeLayout()
    if layout ~= nil then
        self.posX = layout.boxX
        self.posY = layout.boxY
    end

    self:savePosition()
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
    -- Width budget kept free to the left of the box when clamping a dragged HUD on screen,
    -- so the lane number / method label ("-12", "A+B") never runs off the left edge.
    RESERVE = 60,
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
