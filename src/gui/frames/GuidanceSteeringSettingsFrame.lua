---
-- GuidanceSteeringStrategyFrame
--
-- Frame to handle the settings and to modify the current guidance data.
--
-- Copyright (c) Wopster, 2019

---@class GuidanceSteeringSettingsFrame
GuidanceSteeringSettingsFrame = {}

local GuidanceSteeringSettingsFrame_mt = Class(GuidanceSteeringSettingsFrame, TabbedMenuFrameElement)

-- FS25: boolean toggles are MultiTextOptionElements with two entries (ui_off = state 1,
-- ui_on = state 2). BinaryOptionElement was tried but requires a child slider element our
-- XML lacks and crashes in the engine construction phase, before our Lua pcall guards can
-- catch it (BinaryOptionElement.lua:93 "attempt to index nil with 'setSelected'"; see the
-- fs25-modding pitfalls file). MultiTextOption is the validated toggle and constructs
-- cleanly. State is 1-indexed; the two texts are set once in :initialize.
local STATE_OFF, STATE_ON = 1, 2

local function setChecked(element, checked)
    element:setState(checked and STATE_ON or STATE_OFF)
end

local function getChecked(element)
    return element:getState() == STATE_ON
end

---FS25 belt-and-braces: run a per-element GUI setup step under pcall so an unexpected
---element type or API shape degrades that single step (logged) instead of aborting the
---whole menu build. Matches the defensive style used in CardinalStrategy/setWarningMessage.
local function protectedSetup(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        Logger.warning(("GuidanceSteeringSettingsFrame: %s setup failed: %s"):format(label, tostring(err)))
    end
end

-- FS25: exposeControlsAsFields auto-binds EVERY xml element that has an id onto self
-- under that id (FrameElement.lua:100 iterates all descendants; the argument is only used
-- in a debug log). This table is therefore descriptive only. It lists the elements the Lua
-- drives; the width/offset value texts + increment selectors + the +/- adjust buttons and
-- the headland/toggle rows. The FS22 decorative displays (widthDisplay/offsetDisplay/
-- headlandDisplay tractor bitmaps) were dropped in the FS25 rebuild.
GuidanceSteeringSettingsFrame.CONTROLS = {
    WIDTH_PLUS = "guidanceSteeringMinusButton",
    WIDTH_MINUS = "guidanceSteeringPlusButton",
    WIDTH_RESET = "guidanceSteeringResetWidthButton",
    WIDTH_INCREMENT = "guidanceSteeringWidthIncrementElement",
    WIDTH_TEXT = "guidanceSteeringWidthText",

    OFFSET_PLUS = "guidanceSteeringMinusOffsetButton",
    OFFSET_MINUS = "guidanceSteeringPlusOffsetButton",
    OFFSET_RESET = "guidanceSteeringResetOffsetButton",
    OFFSET_INCREMENT = "guidanceSteeringOffsetIncrementElement",
    OFFSET_TEXT = "guidanceSteeringOffsetWidthText",

    HEADLAND_MODE = "guidanceSteeringHeadlandModeElement",
    HEADLAND_DISTANCE = "guidanceSteeringHeadlandDistanceElement",

    TOGGLE_SHOW_LINES = "guidanceSteeringShowLinesElement",
    OFFSET_LINES = "guidanceSteeringLinesOffsetElement",
    TOGGLE_SNAP_TERRAIN_ANGLE = "guidanceSteeringSnapAngleElement",
    TOGGLE_ENABLE_STEERING = "guidanceSteeringEnableSteeringElement",
    TOGGLE_AUTO_INVERT_OFFSET = "guidanceSteeringAutoInvertOffsetElement",

    TOGGLE_DOT_LINES = "guidanceSteeringShowLinesAsDotsElement",

    BOX_LAYOUT_SETTINGS = "boxLayoutSettings",
}

GuidanceSteeringSettingsFrame.INCREMENTS = { 0.01, 0.05, 0.1, 0.5, 1 }

---Creates a new instance of the GuidanceSteeringSettingsFrame.
---@return GuidanceSteeringSettingsFrame
function GuidanceSteeringSettingsFrame.new(ui, i18n)
    local self = TabbedMenuFrameElement.new(nil, GuidanceSteeringSettingsFrame_mt)

    self.ui = ui
    self.i18n = i18n

    self.currentGuidanceWidth = 0
    self.currentWidthIncrement = 0

    self.currentGuidanceOffset = 0
    self.currentOffsetIncrement = 0

    self.allowSave = false

    -- FS25: GuiElement.registerControls was replaced by exposeControlsAsFields, which
    -- takes the same CONTROLS table and binds each element id onto self under that name.
    self:exposeControlsAsFields(GuidanceSteeringSettingsFrame.CONTROLS)

    return self
end

function GuidanceSteeringSettingsFrame:copyAttributes(src)
    GuidanceSteeringSettingsFrame:superClass().copyAttributes(self, src)

    self.ui = src.ui
    self.i18n = src.i18n
end

function GuidanceSteeringSettingsFrame:initialize()
    protectedSetup("initialize", function()
        local headlandModes = {}
        for _, mode in pairs(OnHeadlandState.MODES) do
            table.insert(headlandModes, self.i18n:getText(("guidanceSteering_headland_mode_%d"):format(mode - 1)))
        end

        self.guidanceSteeringHeadlandModeElement:setTexts(headlandModes)

        -- Two-entry texts for the boolean toggles (state 1 = off, state 2 = on). Must be set
        -- before onFrameOpen's setChecked, otherwise setState(STATE_ON) clamps to 1 (no texts).
        local booleanTexts = { self.i18n:getText("ui_off"), self.i18n:getText("ui_on") }
        self.guidanceSteeringEnableSteeringElement:setTexts(booleanTexts)
        self.guidanceSteeringSnapAngleElement:setTexts(booleanTexts)
        self.guidanceSteeringAutoInvertOffsetElement:setTexts(booleanTexts)
        self.guidanceSteeringShowLinesElement:setTexts(booleanTexts)
        self.guidanceSteeringShowLinesAsDotsElement:setTexts(booleanTexts)

        local initialUnit = self:getFormattedUnitLength(0)
        self.guidanceSteeringHeadlandDistanceElement:setText(tostring(0))
        self.guidanceSteeringWidthText:setText(initialUnit)
        self.guidanceSteeringOffsetWidthText:setText(initialUnit)
    end)

    self:setupHeader()
end

---Populate the standard FS25 menu header (icon + title) from the mod's own atlas. Guarded
---so a missing element/atlas degrades to a bare header instead of aborting the build.
function GuidanceSteeringSettingsFrame:setupHeader()
    protectedSetup("header", function()
        if self.settingsHeaderText ~= nil then
            -- Mod proper name (not localized); the tab strip already indicates the page.
            self.settingsHeaderText:setText("Guidance Steering")
        end
        if self.settingsHeaderIcon ~= nil and self.ui ~= nil and self.ui.uiFilename ~= nil then
            self.settingsHeaderIcon:setImageFilename(self.ui.uiFilename)
            self.settingsHeaderIcon:setImageUVs(nil, unpack(GuiUtils.getUVs(GuidanceSteeringSettingsFrame.HEADER_ICON_UV)))
        end
    end)
end

function GuidanceSteeringSettingsFrame:onFrameOpen()
    GuidanceSteeringSettingsFrame:superClass().onFrameOpen(self)

    local increments = {}
    for _, increment in pairs(GuidanceSteeringSettingsFrame.INCREMENTS) do
        table.insert(increments, tostring(self:getUnitLength(increment)))
    end

    protectedSetup("onFrameOpen increments", function()
        self.guidanceSteeringWidthIncrementElement:setTexts(increments)
        self.guidanceSteeringOffsetIncrementElement:setTexts(increments)
    end)

    local offsets = stream({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }):map(function(offset)
        return tostring(offset * GuidanceSteering.GROUND_CLEARANCE_OFFSET)
    end)
    self.offsets = offsets:toList()
    protectedSetup("onFrameOpen lineOffset", function()
        self.guidanceSteeringLinesOffsetElement:setTexts(self.offsets)
    end)

    local vehicle = self.ui:getVehicle()
    if vehicle ~= nil then
        protectedSetup("onFrameOpen vehicle", function()
            local spec = vehicle.spec_globalPositioningSystem
            local data = spec.guidanceData

            setChecked(self.guidanceSteeringShowLinesElement, g_currentMission.guidanceSteering:isShowGuidanceLinesEnabled())
            setChecked(self.guidanceSteeringShowLinesAsDotsElement, g_currentMission.guidanceSteering:isShowGuidanceLinesAsDotsEnabled())
            setChecked(self.guidanceSteeringSnapAngleElement, g_currentMission.guidanceSteering:isTerrainAngleSnapEnabled())
            setChecked(self.guidanceSteeringEnableSteeringElement, spec.guidanceSteeringIsActive)
            setChecked(self.guidanceSteeringAutoInvertOffsetElement, spec.autoInvertOffset)

            self.currentGuidanceWidth = data.width
            self.currentGuidanceOffset = data.offsetWidth
            self.guidanceSteeringWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceWidth))
            self.guidanceSteeringOffsetWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceOffset))

            local currentHeadlandActDistance = spec.headlandActDistance
            self.guidanceSteeringHeadlandModeElement:setState(spec.headlandMode)
            self.guidanceSteeringHeadlandDistanceElement:setText(tostring(currentHeadlandActDistance))

            self.allowSave = true
        end)
    end

    self.boxLayoutSettings:invalidateLayout()

    if FocusManager:getFocusedElement() == nil then
        self:setSoundSuppressed(true)
        FocusManager:setFocus(self.boxLayoutSettings)
        self:setSoundSuppressed(false)
    end

    GuidanceSteering.dumpGuiTree("SettingsFrame", self)
end

function GuidanceSteeringSettingsFrame:onFrameClose()
    GuidanceSteeringSettingsFrame:superClass().onFrameClose(self)

    if self.allowSave then
        -- Client only
        g_currentMission.guidanceSteering:setIsShowGuidanceLinesEnabled(getChecked(self.guidanceSteeringShowLinesElement))
        g_currentMission.guidanceSteering:setIsShowGuidanceLinesAsDotsEnabled(getChecked(self.guidanceSteeringShowLinesAsDotsElement))
        g_currentMission.guidanceSteering:setIsTerrainAngleSnapEnabled(getChecked(self.guidanceSteeringSnapAngleElement))
        g_currentMission.guidanceSteering:setIsGuidanceEnabled(getChecked(self.guidanceSteeringEnableSteeringElement))
        g_currentMission.guidanceSteering:setIsAutoInvertOffsetEnabled(getChecked(self.guidanceSteeringAutoInvertOffsetElement))
        g_currentMission.guidanceSteering:setLineOffset(tonumber(self.offsets[self.guidanceSteeringLinesOffsetElement:getState()]))

        local vehicle = self.ui:getVehicle()
        if vehicle ~= nil then
            local spec = vehicle.spec_globalPositioningSystem
            local data = spec.guidanceData

            local state = self.guidanceSteeringWidthIncrementElement:getState()
            local headlandMode = self.guidanceSteeringHeadlandModeElement:getState()
            local headlandActDistance = tonumber(self.guidanceSteeringHeadlandDistanceElement:getText()) or 0
            local increment = GuidanceSteeringSettingsFrame.INCREMENTS[state]

            -- Todo: cleanup later
            local guidanceSteeringIsActive = g_currentMission.guidanceSteering:isGuidanceEnabled()
            if guidanceSteeringIsActive and not data.isCreated then
                g_currentMission:showBlinkingWarning(self.i18n:getText("guidanceSteering_warning_createTrackFirst"), 4000)
            else
                spec.lastInputValues.guidanceSteeringIsActive = guidanceSteeringIsActive
            end

            spec.lastInputValues.autoInvertOffset = g_currentMission.guidanceSteering:isAutoInvertOffsetEnabled()
            spec.lastInputValues.widthIncrement = math.abs(increment)

            if spec.headlandMode ~= headlandMode or spec.headlandActDistance ~= headlandActDistance then
                spec.headlandMode = headlandMode
                spec.headlandActDistance = headlandActDistance
                -- Update other clients
                g_client:getServerConnection():sendEvent(HeadlandModeChangedEvent:new(vehicle, headlandMode, headlandActDistance))
            end

            if data.width ~= nil and data.width ~= self.currentGuidanceWidth
                or data.offsetWidth ~= nil and data.offsetWidth ~= self.currentGuidanceOffset then
                data.width = self.currentGuidanceWidth
                data.offsetWidth = self.currentGuidanceOffset

                vehicle:updateGuidanceData(data, false, false)
            end
        end

        self.allowSave = false
    end
end

function GuidanceSteeringSettingsFrame:updateToolTipBoxVisibility(box)
    local hasText = box.text ~= nil and box.text ~= ""
    box:setVisible(hasText)
end

---Callbacks

function GuidanceSteeringSettingsFrame:onClickIncrementWidth()
    self:changeWidth(1)
end

function GuidanceSteeringSettingsFrame:onClickDecrementWidth()
    self:changeWidth(-1)
end

function GuidanceSteeringSettingsFrame:onClickResetWidth()
    self.currentGuidanceWidth = 0
    self.guidanceSteeringWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceWidth))
end

function GuidanceSteeringSettingsFrame:onClickAutoWidth()
    local vehicle = self.ui:getVehicle()

    if vehicle ~= nil then
        local spec = vehicle.spec_globalPositioningSystem
        local width, offset = GlobalPositioningSystem.getActualWorkWidth(spec.guidanceNode, vehicle)
        self.currentGuidanceWidth = width
        self.currentGuidanceOffset = offset
        self.guidanceSteeringWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceWidth))
        self.guidanceSteeringOffsetWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceOffset))
    end
end

function GuidanceSteeringSettingsFrame:changeWidth(direction)
    local state = self.guidanceSteeringWidthIncrementElement:getState()
    local increment = GuidanceSteeringSettingsFrame.INCREMENTS[state] * direction

    self.currentGuidanceWidth = math.max(self.currentGuidanceWidth + increment, 0)
    if 2 * math.abs(self.currentGuidanceOffset) >= self.currentGuidanceWidth then
        self.currentGuidanceOffset = self.currentGuidanceWidth / 2 * (self.currentGuidanceOffset / math.abs(self.currentGuidanceOffset))
    end
    self.guidanceSteeringOffsetWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceOffset))
    self.guidanceSteeringWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceWidth))
end

function GuidanceSteeringSettingsFrame:onClickIncrementOffsetWidth()
    self:changeOffsetWidth(1)
end

function GuidanceSteeringSettingsFrame:onClickDecrementOffsetWidth()
    self:changeOffsetWidth(-1)
end

function GuidanceSteeringSettingsFrame:onClickInvertOffset()
    self.currentGuidanceOffset = -self.currentGuidanceOffset
    self.guidanceSteeringOffsetWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceOffset))
end

function GuidanceSteeringSettingsFrame:onClickResetOffsetWidth()
    self.currentGuidanceOffset = 0
    self.guidanceSteeringOffsetWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceOffset))
end

function GuidanceSteeringSettingsFrame:changeOffsetWidth(direction)
    local state = self.guidanceSteeringOffsetIncrementElement:getState()
    local increment = GuidanceSteeringSettingsFrame.INCREMENTS[state] * direction

    local threshold = self.currentGuidanceWidth * 0.5
    self.currentGuidanceOffset = math.clamp(self.currentGuidanceOffset + increment, -threshold, threshold)
    self.guidanceSteeringOffsetWidthText:setText(self:getFormattedUnitLength(self.currentGuidanceOffset))
end

function GuidanceSteeringSettingsFrame:onHeadlandDistanceChanged(_, text)
    local lastDistance = tonumber(text)
    local textLength = utf8Strlen(text)

    if lastDistance == nil and textLength > 0 then
        lastDistance = 0
        self.guidanceSteeringHeadlandDistanceElement:setText(tostring(lastDistance))
    end

    if lastDistance ~= nil then
        if lastDistance > OnHeadlandState.MAX_ACT_DISTANCE then
            lastDistance = OnHeadlandState.MAX_ACT_DISTANCE
            self.guidanceSteeringHeadlandDistanceElement:setText(tostring(lastDistance))
        end
    end
end

function GuidanceSteeringSettingsFrame:getUnitLength(meters)
    if self.i18n.useMiles then
        return meters * 3.2808
    end

    return meters
end

function GuidanceSteeringSettingsFrame:getFormattedUnitLength(meters)
    local unitLength = self:getUnitLength(meters)
    if self.i18n.useMiles then
        return string.format("%.2f %s", unitLength, "ft")
    end

    return string.format("%.2f %s", unitLength, "m")
end

GuidanceSteeringSettingsFrame.L10N_SYMBOL = {}

-- Header icon UV in the mod atlas (resources/guidanceSteering_1080p.png): the steering-wheel
-- icon, same tile the settings tab uses (GuidanceSteeringMenu.TAB_UV.SETTINGS).
GuidanceSteeringSettingsFrame.HEADER_ICON_UV = { 715, 0, 65, 65 }
