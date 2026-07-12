---
-- GuidanceSteeringHUD
--
-- HUD for GuidanceSteering
--
-- Copyright (c) Wopster, 2019

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

    SpeedMeterDisplay.storeScaledValues = Utils.appendedFunction(SpeedMeterDisplay.storeScaledValues, GuidanceSteeringHUD.speedMeterDisplay_storeScaledValues)
    SpeedMeterDisplay.draw = Utils.appendedFunction(SpeedMeterDisplay.draw, GuidanceSteeringHUD.speedMeterDisplay_draw)

    return instance
end

function GuidanceSteeringHUD:delete()
    if self.stateBox ~= nil then
        self.stateBox:delete()
    end
end

function GuidanceSteeringHUD:load()
    self:createElements()
    self:setVehicle(nil)
end

--- Gets the anchor position (top-right of our widget) relative to the speed meter.
-- FS25 port: the FS22 HUD anchored to SpeedMeterDisplay.gearIcon, but in FS25 the
-- gear icon is a plain overlay that is only positioned mid-draw and only when the
-- vehicle actually has a gear display, so it is not a reliable anchor. The speed
-- meter itself is an HUDElement anchored at the screen's bottom-right, so we offset
-- from its position instead.
function GuidanceSteeringHUD:getAnchorPosition()
    local baseX, baseY = self.speedMeterDisplay:getPosition()
    local offsetX, offsetY = self.speedMeterDisplay:scalePixelToScreenVector(GuidanceSteeringHUD.POSITION.ANCHOR)
    return baseX + offsetX, baseY + offsetY
end

--- Create the elements for the HUD.
function GuidanceSteeringHUD:createElements()
    local topRightX, topRightY = self:getAnchorPosition()
    local marginWidth, marginHeight = self.speedMeterDisplay:scalePixelToScreenVector(GuidanceSteeringHUD.SIZE.BOX_MARGIN)
    self:createBox(self.uiFilename, topRightX + marginWidth, topRightY + marginHeight)
end

--- Create the box with the HUD icons.
function GuidanceSteeringHUD:createBox(hudAtlasPath, x, y)
    local boxWidth, boxHeight = self.speedMeterDisplay:scalePixelToScreenVector(GuidanceSteeringHUD.SIZE.BOX)
    local posX = x - boxWidth * 0.5

    local iconWidth, iconHeight = self.speedMeterDisplay:scalePixelToScreenVector(GuidanceSteeringHUD.SIZE.ICON)
    local iconPosX, iconPosY = self.speedMeterDisplay:scalePixelToScreenVector(GuidanceSteeringHUD.POSITION.ICON)

    -- FS25 port: the FS22 HUD drew the box using the base game's gears-bar atlas
    -- region (SpeedMeterDisplay.UV.GEARS_BAR) tinted with SpeedMeterDisplay.COLOR.GEARS_BG.
    -- Both constant tables were removed in FS25's gauge redesign. Build the background
    -- from the base "gui.gearBg" slice via g_overlayManager and tint it with our own
    -- colour instead. (g_overlayManager:createOverlay returns nil + logs on an unknown
    -- slice; "gui.gearBg" is a base-game slice used by SpeedMeterDisplay itself.)
    local boxOverlay = g_overlayManager:createOverlay("gui.gearBg", posX, y, boxWidth, boxHeight)
    local boxElement = HUDElement.new(boxOverlay)
    self.stateBox = boxElement

    self.stateBox:setColor(unpack(GuidanceSteeringHUD.COLOR.BOX_BG))

    self.stateBox:setVisible(true)
    self.speedMeterDisplay:addChild(boxElement)

    self.steeringIcon = self:createIcon(hudAtlasPath, posX + iconPosX, y + iconPosY, iconWidth, iconHeight, GuidanceSteeringHUD.UV.STEERING_WHEEL_DISABLED)

    self.stateBox:addChild(self.steeringIcon)
    self.steeringIcon:setColor(unpack(GuidanceSteeringHUD.COLOR.INACTIVE))
    self.steeringIcon:setVisible(true)

    y = y + iconHeight

    self.receiverIcon = self:createIcon(hudAtlasPath, posX + iconPosX, y + iconPosY, iconWidth, iconHeight, GuidanceSteeringHUD.UV.RECEIVER)

    self.stateBox:addChild(self.receiverIcon)
    self.receiverIcon:setColor(unpack(GuidanceSteeringHUD.COLOR.INACTIVE))
    self.receiverIcon:setVisible(true)

    y = y + iconHeight

    self.laneIcon = self:createIcon(hudAtlasPath, posX + iconPosX, y + iconPosY, iconWidth, iconHeight, GuidanceSteeringHUD.UV.LANE)

    self.stateBox:addChild(self.laneIcon)
    self.laneIcon:setColor(unpack(GuidanceSteeringHUD.COLOR.INACTIVE))
    self.laneIcon:setVisible(true)

    return x - boxWidth
end

--- Create icon for the HUD.
function GuidanceSteeringHUD:createIcon(imagePath, baseX, baseY, width, height, uvs)
    local iconOverlay = Overlay.new(imagePath, baseX, baseY, width, height)
    iconOverlay:setUVs(GuiUtils.getUVs(uvs))
    local element = HUDElement.new(iconOverlay)

    element:setVisible(false)

    return element
end

function GuidanceSteeringHUD:storeScaledValues()
    if self.stateBox == nil then
        return
    end

    self.textOffX, self.textOffY = self.speedMeterDisplay:scalePixelToScreenVector(GuidanceSteeringHUD.POSITION.LANE_TEXT)
    self.laneTextSize = self.speedMeterDisplay:scalePixelToScreenHeight(GuidanceSteeringHUD.TEXT_SIZE.LANE)
end

--- Sets the current vehicle to display on the HUD.
function GuidanceSteeringHUD:setVehicle(vehicle)
    self.vehicle = vehicle
    if self.stateBox ~= nil then
        self.stateBox:setVisible(vehicle ~= nil)
    end
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

function GuidanceSteeringHUD:drawText()
    if self.speedMeterDisplay.isVehicleDrawSafe and self.stateBox ~= nil and self.stateBox:getVisible() then
        local spec = self.vehicle.spec_globalPositioningSystem
        local data = spec.guidanceData

        self.laneText = self:getLaneText(data.currentLane)
        if self.steeringIconIsActive ~= spec.guidanceSteeringIsActive then
            self.steeringIconIsActive = spec.guidanceSteeringIsActive
            local uvs = self.steeringIconIsActive and GuidanceSteeringHUD.UV.STEERING_WHEEL_ENABLED or GuidanceSteeringHUD.UV.STEERING_WHEEL_DISABLED
            local color = self.steeringIconIsActive and GuidanceSteeringHUD.COLOR.ACTIVE or GuidanceSteeringHUD.COLOR.INACTIVE

            self.steeringIcon:setUVs(GuiUtils.getUVs(uvs))
            self.steeringIcon:setColor(unpack(color))
        end

        if self.receiverIconIsActive ~= spec.guidanceIsActive then
            self.receiverIconIsActive = spec.guidanceIsActive
            local color = self.receiverIconIsActive and GuidanceSteeringHUD.COLOR.ACTIVE or GuidanceSteeringHUD.COLOR.INACTIVE

            self.receiverIcon:setColor(unpack(color))
            self.laneIcon:setColor(unpack(color))
        end

        self:drawLaneText()

        local topRightX, topRightY = self:getAnchorPosition()
        local marginWidth, marginHeight = self.speedMeterDisplay:scalePixelToScreenVector(GuidanceSteeringHUD.SIZE.BOX_MARGIN)
        self.stateBox:setPosition(topRightX + marginWidth, topRightY + marginHeight)

        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end
end

function GuidanceSteeringHUD:drawLaneText()
    local color = self.receiverIconIsActive and GuidanceSteeringHUD.COLOR.ACTIVE or GuidanceSteeringHUD.COLOR.INACTIVE

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(unpack(color))

    local boxPosX, boxPosY = self.stateBox:getPosition()
    local boxWidth, boxHeight = self.stateBox:getWidth(), self.stateBox:getHeight()

    self.laneTextPositionX = boxPosX + boxWidth + self.textOffX
    self.laneTextPositionY = boxPosY + boxHeight + self.textOffY
    renderText(self.laneTextPositionX, self.laneTextPositionY, self.laneTextSize, self.laneText)
end

function GuidanceSteeringHUD.speedMeterDisplay_storeScaledValues(speedMeterDisplay)
    g_currentMission.guidanceSteering.ui.hud:storeScaledValues()
end

function GuidanceSteeringHUD.speedMeterDisplay_draw(speedMeterDisplay)
    g_currentMission.guidanceSteering.ui.hud:drawText()
end

GuidanceSteeringHUD.SIZE = {
    BOX = { 44, 110 },
    BOX_MARGIN = { -5, 50 },
    ICON = { 32, 32 },
}
GuidanceSteeringHUD.UV = {
    STEERING_WHEEL_ENABLED = { 650, 0, 65, 65 },
    STEERING_WHEEL_DISABLED = { 715, 0, 65, 65 },
    RECEIVER = { 650, 65, 65, 65 },
    LANE = { 715, 65, 65, 65 },
}

GuidanceSteeringHUD.POSITION = {
    LANE_TEXT = { -22, -20 },
    ICON = { 5, 5 },
    -- FS25 port: pixel offset from the speed meter's bottom-right anchor to the
    -- top-right of our widget. Places the box above the speed gauge. Tune here if
    -- it overlaps other HUD elements at a given resolution/UI scale.
    ANCHOR = { -40, 245 },
}

GuidanceSteeringHUD.TEXT_COLOR = {
    LANE = { 0.7, 0.7, 0.7, 0.3 }
}

GuidanceSteeringHUD.COLOR = {
    INACTIVE = { 0.7, 0.7, 0.7, 0.3 },
    ACTIVE = { 0.0003, 0.5647, 0.9822, 1 },
    -- FS25 port: box background tint (replaces the removed SpeedMeterDisplay.COLOR.GEARS_BG).
    BOX_BG = { 0.018, 0.018, 0.018, 0.6 }
}

GuidanceSteeringHUD.TEXT_SIZE = {
    LANE = 14
}
