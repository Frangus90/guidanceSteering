---
-- GuidanceSteeringStrategyFrame
--
-- Frame to handle the tracks and guidance strategy.
--
-- Copyright (c) Wopster, 2019

---@class GuidanceSteeringStrategyFrame
GuidanceSteeringStrategyFrame = {}

local GuidanceSteeringStrategyFrame_mt = Class(GuidanceSteeringStrategyFrame, TabbedMenuFrameElement)

---FS25 belt-and-braces: run a per-element GUI setup step under pcall so an unexpected
---element type or API shape degrades that single step (logged) instead of aborting the
---whole menu build.
local function protectedSetup(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        Logger.warning(("GuidanceSteeringStrategyFrame: %s setup failed: %s"):format(label, tostring(err)))
    end
end

GuidanceSteeringStrategyFrame.CONTROLS = {
    CONTAINER = "container",
    STRATEGY_METHOD = "guidanceSteeringStrategyMethodElement",
    -- Text box
    TRACK_TEXT_INPUT = "guidanceSteeringTrackNameElement",
    -- Check box
    SCOPE_FARM_ID = "guidanceSteeringScopeFarmIdElement",
    -- Buttons
    POINT_A_BUTTON = "guidanceSteeringPointAButton",
    POINT_B_BUTTON = "guidanceSteeringPointBButton",
    CREATE_TRACK = "guidanceSteeringCreateTrackButton",
    SAVE_TRACK = "guidanceSteeringSaveTrackButton",
    LOAD_TRACK = "guidanceSteeringLoadTrackButton",
    REMOVE_TRACK = "guidanceSteeringRemoveTrackButton",
    ROTATE_TRACK = "guidanceSteeringRotateTrackButton",
    -- Warning box
    HELP_BOX = "settingsHelpBoxText",

    LIST = "list",
}

---Creates a new instance of the GuidanceSteeringStrategyFrame.
---@return GuidanceSteeringStrategyFrame
function GuidanceSteeringStrategyFrame.new(ui, i18n)
    local self = TabbedMenuFrameElement.new(nil, GuidanceSteeringStrategyFrame_mt)

    self.guidanceSteering = g_currentMission.guidanceSteering

    self.ui = ui
    self.i18n = i18n
    self.allowSave = false
    -- FS25: flat data-source array for the SmoothList track list, entries { trackId, name }.
    self.tracks = {}

    self.lastLoadedTrackId = -1

    -- FS25: GuiElement.registerControls was replaced by exposeControlsAsFields, which
    -- takes the same CONTROLS table and binds each element id onto self under that name.
    self:exposeControlsAsFields(GuidanceSteeringStrategyFrame.CONTROLS)

    return self
end

function GuidanceSteeringStrategyFrame:copyAttributes(src)
    GuidanceSteeringStrategyFrame:superClass().copyAttributes(self, src)

    self.ui = src.ui
    self.i18n = src.i18n
end

function GuidanceSteeringStrategyFrame:initialize()
    protectedSetup("initialize", function()
        -- The "Line strategy" selector was removed from the XML (single option, curves never
        -- shipped); the strategy value is hardcoded to the default in getVehicleTrackData.
        -- The track-name field is labelled "Track name" by its row, so leave the input empty
        -- (it is filled from the selected track in displayTrackElements).
        self.guidanceSteeringTrackNameElement:setText("")

        -- FS25: scope toggle is a MultiTextOptionElement (state 1 = off, state 2 = on),
        -- see the settings frame note. Set its two texts here so the toggle displays and
        -- its buttons cycle state.
        self.guidanceSteeringScopeFarmIdElement:setTexts({
            self.i18n:getText("ui_off"),
            self.i18n:getText("ui_on"),
        })
    end)

    -- FS25: the SmoothList is data-source driven (setDataSource + reloadData + the
    -- getNumberOfItemsInSection/populateCellForItemInSection callbacks below), replacing
    -- the FS22 manual clone/deleteListItems API which was removed from SmoothListElement.
    if self.list ~= nil and self.list.setDataSource ~= nil then
        self.list:setDataSource(self)
    end

    self:setupHeader()
end

---Populate the standard FS25 menu header (icon + title) from the mod's own atlas. Guarded
---so a missing element/atlas degrades to a bare header instead of aborting the build. The
---track create/save/remove/rotate controls are plain text buttons now (their FS22 atlas
---glyphs were dropped), so no per-button image setup is needed.
function GuidanceSteeringStrategyFrame:setupHeader()
    protectedSetup("header", function()
        if self.strategyHeaderText ~= nil then
            -- Mod proper name (not localized); the tab strip already indicates the page.
            self.strategyHeaderText:setText("Guidance Steering")
        end
        if self.strategyHeaderIcon ~= nil and self.ui ~= nil and self.ui.uiFilename ~= nil then
            self.strategyHeaderIcon:setImageFilename(self.ui.uiFilename)
            self.strategyHeaderIcon:setImageUVs(nil, unpack(GuiUtils.getUVs(GuidanceSteeringStrategyFrame.HEADER_ICON_UV)))
        end
    end)
end

function GuidanceSteeringStrategyFrame:onFrameOpen()
    GuidanceSteeringStrategyFrame:superClass().onFrameOpen(self)

    self.guidanceSteering:subscribe(self)
    self:buildList()

    -- Re-arrange the left control column after the paging clone/open (the base BoxLayout
    -- auto-invalidates only on its initial onGuiSetupFinished).
    if self.strategyBoxLayout ~= nil and self.strategyBoxLayout.invalidateLayout ~= nil then
        self.strategyBoxLayout:invalidateLayout()
    end

    local vehicle = self.ui:getVehicle()
    if vehicle ~= nil then
        protectedSetup("onFrameOpen strategy", function()
            local strategy = vehicle:getGuidanceStrategy()

            self.guidanceSteeringStrategyMethodElement:setTexts(strategy:getTexts(self.i18n))
            self.guidanceSteeringStrategyMethodElement:setState(strategy.id + 1)
            self:displayMethodElements()

            self.allowSave = true
        end)
    end
end

function GuidanceSteeringStrategyFrame:onFrameClose()
    GuidanceSteeringStrategyFrame:superClass().onFrameClose(self)

    if self.allowSave then
        local trackId = self:getSelectedTrackId()
        if trackId ~= nil then
            if self.lastLoadedTrackId ~= trackId then
                self:loadTrack(trackId)
                self.lastLoadedTrackId = trackId
            end
        end

        self.allowSave = false
    end

    self.guidanceSteering:unsubscribe(self)
end

---FS25: reads the track id stored on the currently selected SmoothList cell (set in
---populateCellForItemInSection). Returns nil when nothing is selected.
function GuidanceSteeringStrategyFrame:getSelectedTrackId()
    if self.list == nil or self.list.getSelectedElement == nil then
        return nil
    end

    local element = self.list:getSelectedElement()
    return element ~= nil and element.trackId or nil
end

function GuidanceSteeringStrategyFrame:buildList()
    if self.list == nil then
        return
    end

    -- Remember the current selection so we can restore it after the reload.
    local selectedTrackId = self:getSelectedTrackId()

    local farmId = AccessHandler.EVERYONE
    local vehicle = self.ui:getVehicle()
    if vehicle ~= nil then
        farmId = vehicle:getOwnerFarmId()
    end

    self.tracks = {}
    for id, track in pairs(self.guidanceSteering:getTracksForFarmId(farmId)) do
        table.insert(self.tracks, { trackId = id, name = ("%s - %s"):format(id, track.name) })
    end

    -- getTracksForFarmId returns a hash; give the list a stable order by track id.
    table.sort(self.tracks, function(lhs, rhs)
        return lhs.trackId < rhs.trackId
    end)

    self.list:reloadData()

    -- Empty-state: an empty SmoothList draws zero cells and both the list and its column are
    -- transparent (emptyPanel), so with no tracks the whole right side is invisible. Show a
    -- helper text in that case so an empty list is never a silent mystery. The element is
    -- auto-bound by exposeControlsAsFields (id in the frame XML).
    if self.guidanceSteeringTrackListEmptyText ~= nil then
        self.guidanceSteeringTrackListEmptyText:setVisible(#self.tracks == 0)
    end

    -- Restore the previous selection, defaulting to the first row.
    local selectedIndex = 1
    for index, entry in ipairs(self.tracks) do
        if entry.trackId == selectedTrackId then
            selectedIndex = index
            break
        end
    end

    -- FS25 SmoothList selects by (section, index) via setSelectedItem; there is no
    -- setSelectedIndex on SmoothListElement (that lives on the paging tab list), so the old
    -- call was a silent no-op and the prior selection was lost on every reload. Section is 1
    -- (single flat section, see getNumberOfSections).
    if #self.tracks > 0 and self.list.setSelectedItem ~= nil then
        self.list:setSelectedItem(1, selectedIndex)
    end

    self:onListSelectionChanged()
end

---FS25 SmoothList data source: a single flat section of tracks.
function GuidanceSteeringStrategyFrame:getNumberOfSections(list)
    return 1
end

function GuidanceSteeringStrategyFrame:getNumberOfItemsInSection(list, section)
    return #self.tracks
end

---FS25 SmoothList data source: fill a (reused) cell for the given row. The cell's title
---text child is named "title" in the frame XML; the track id is stashed on the cell so
---getSelectedTrackId can read it back from the selected element.
function GuidanceSteeringStrategyFrame:populateCellForItemInSection(list, section, index, cell)
    local entry = self.tracks[index]
    cell.trackId = entry ~= nil and entry.trackId or nil

    local title = cell:getAttribute("title")
    if title ~= nil then
        title:setText(entry ~= nil and entry.name or "")
    end
end

--- Get the frame's main content element's screen size.
function GuidanceSteeringStrategyFrame:getMainElementSize()
    return self.container.size
end

--- Get the frame's main content element's screen position.
function GuidanceSteeringStrategyFrame:getMainElementPosition()
    return self.container.absPosition
end

function GuidanceSteeringStrategyFrame:onClickSelect(_, element)

end

function GuidanceSteeringStrategyFrame:onListSelectionChanged()
    local trackId = self:getSelectedTrackId()
    if trackId ~= nil then
        self:onDisplayElementsChanged({ trackId = trackId })
    end
end

function GuidanceSteeringStrategyFrame:onClickCreateTrack()
    -- Get a new Id
    local trackId = self.guidanceSteering:getNewTrackId()
    local trackData = self:getVehicleTrackData()

    if trackData ~= nil then
        -- might check if the name already exists
        if self.guidanceSteering:isExistingTrack(trackId, trackData) then
            self:setWarningMessage(self.i18n:getText("guidanceSteering_tooltip_trackAlreadyExists"):format(trackData.name))
            return
        end

        self:saveTrack(trackId, trackData)
    end
end

function GuidanceSteeringStrategyFrame:onClickSaveTrack()
    local trackId = self:getSelectedTrackId()
    if trackId ~= nil then
        local track = self.guidanceSteering:getTrack(trackId)

        if track ~= nil then
            local trackData = self:getVehicleTrackData()
            if trackData ~= nil then
                self:saveTrack(trackId, trackData)
            end
        end
    end
end

---Explicit "Load track" button: previously the selected track only loaded when the menu
---closed (see onFrameClose above). Loads immediately and records lastLoadedTrackId so
---onFrameClose doesn't reload it again on close.
function GuidanceSteeringStrategyFrame:onClickLoadTrack()
    local trackId = self:getSelectedTrackId()

    if trackId == nil then
        g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_noTrackSelected"), 2000)
        return
    end

    local track = self.guidanceSteering:getTrack(trackId)

    self:loadTrack(trackId)
    self.lastLoadedTrackId = trackId

    g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_trackLoaded"):format(track ~= nil and track.name or tostring(trackId)), 2000)
end

function GuidanceSteeringStrategyFrame:onClickRemoveTrack()
    local trackId = self:getSelectedTrackId()

    if trackId ~= nil then
        if trackId ~= 0 then
            self:deleteTrack(trackId)

            local vehicle = self.ui:getVehicle()
            if vehicle ~= nil then
                -- Reset loaded track when we are deleting it.
                if trackId ~= self.lastLoadedTrackId then
                    self:loadTrack(trackId)
                    self.lastLoadedTrackId = trackId
                end
            end
        end
    end
end

function GuidanceSteeringStrategyFrame:onClickRotateTrack()
    local vehicle = self.ui:getVehicle()
    if vehicle ~= nil then
        local data = vehicle:getGuidanceData()

        if not data.isCreated then
            self:setWarningMessage(self.i18n:getText("guidanceSteering_tooltip_trackIsNotCreated"))
            return
        end

        GlobalPositioningSystem.rotateTrack(vehicle, data)
    end
end

function GuidanceSteeringStrategyFrame:getFarmId()
    -- FS25: scope toggle is a MultiTextOptionElement (see settings frame note); state 2 = on.
    local isScoped = self.guidanceSteeringScopeFarmIdElement:getState() == 2

    if isScoped then
        local vehicle = self.ui:getVehicle()
        if vehicle ~= nil then
            return vehicle:getOwnerFarmId()
        end
    end

    return AccessHandler.EVERYONE
end

function GuidanceSteeringStrategyFrame:getVehicleTrackData()
    local track = {}

    track.name = self.guidanceSteeringTrackNameElement:getText()
    -- Strategy selector removed (only ever had one option, "AB straight" = state 1). Keep the
    -- serialized default so save/load and the network TrackSaveEvent stay unchanged.
    track.strategy = 1
    track.method = self.guidanceSteeringStrategyMethodElement:getState()

    local vehicle = self.ui:getVehicle()
    if vehicle ~= nil then
        local data = vehicle:getGuidanceData()

        if not data.isCreated then
            self:setWarningMessage(self.i18n:getText("guidanceSteering_tooltip_trackIsNotCreated"))
            return nil
        end

        track.farmId = self:getFarmId()
        track.guidanceData = {}
        track.guidanceData.width = data.width
        track.guidanceData.offsetWidth = data.offsetWidth
        track.guidanceData.snapDirection = data.snapDirection
        track.guidanceData.driveTarget = data.driveTarget
    end

    return track
end

--- Track creation

function GuidanceSteeringStrategyFrame:onClickSetPointA()
    local vehicle = self.ui:getVehicle()

    if vehicle == nil then
        return
    end

    local spec = vehicle.spec_globalPositioningSystem
    if not spec.lineStrategy:getIsABDirectionPossible() then
        -- First request reset to make sure the current track is clear
        spec.multiActionEvent:reset()

        -- Simulate event invoked:
        -- 1 Reset
        -- 2 Point A
        for i = 1, 2 do
            spec.multiActionEvent:invoked()
        end

        vehicle:updateGuidanceData(nil, false, true)
        vehicle:interactWithGuidanceStrategy(true)
    end
end

function GuidanceSteeringStrategyFrame:onClickSetPointB()
    local vehicle = self.ui:getVehicle()

    if vehicle == nil then
        return
    end

    local spec = vehicle.spec_globalPositioningSystem

    if spec.lineStrategy:getIsABDirectionPossible() then
        if spec.abDistanceCounter < GlobalPositioningSystem.AB_DROP_DISTANCE then
            g_currentMission:showBlinkingWarning(g_i18n:getText("guidanceSteering_warning_dropDistance"):format(spec.abDistanceCounter), 4000)
            return
        end

        -- Make sure the multi action event isn't doing anything in the meantime.
        spec.multiActionEvent:reset()

        -- Simulate event invoked:
        -- 1 Reset
        -- 2 Point A
        -- 3 Point B
        for i = 1, 3 do
            spec.multiActionEvent:invoked()
        end

        vehicle:interactWithGuidanceStrategy(true)
        GlobalPositioningSystem.computeGuidanceDirection(vehicle)
    end
end

function GuidanceSteeringStrategyFrame:onStrategyChanged(method)
    self:loadStrategy(method - 1)
    self:displayMethodElements()
end

--- Functions

---Called by the GuidanceSteering class
function GuidanceSteeringStrategyFrame:onTrackChanged(trackId)
    self:buildList()
end

function GuidanceSteeringStrategyFrame:loadTrack(trackId)
    local track = self.guidanceSteering:getTrack(trackId)

    local vehicle = self.ui:getVehicle()

    if vehicle ~= nil then
        local data = vehicle:getGuidanceData()

        -- First request reset to make sure the current track is clear
        vehicle:updateGuidanceData(nil, false, true)

        if self.guidanceSteering:isTrackValid(trackId) then
            data.width = track.guidanceData.width
            data.offsetWidth = track.guidanceData.offsetWidth
            data.snapDirection = track.guidanceData.snapDirection
            data.driveTarget = track.guidanceData.driveTarget

            -- Now we send a creation event
            vehicle:updateGuidanceData(data, true, false)

            vehicle:setGuidanceStrategy(track.strategy - 1)
        end
    end
end

function GuidanceSteeringStrategyFrame:saveTrack(trackId, track)
    g_client:getServerConnection():sendEvent(TrackSaveEvent:new(trackId, track))
end

function GuidanceSteeringStrategyFrame:deleteTrack(trackId)
    g_client:getServerConnection():sendEvent(TrackDeleteEvent:new(trackId))
end

function GuidanceSteeringStrategyFrame:loadStrategy(method)
    local vehicle = self.ui:getVehicle()
    if vehicle ~= nil then
        if method ~= nil then
            vehicle:setGuidanceStrategy(method)
        end
    end
end

function GuidanceSteeringStrategyFrame:setWarningMessage(message)
    -- FS25: g_gui:showInfoDialog(args-table) was replaced by the static InfoDialog.show
    -- (text, callback, target, dialogType). Guarded so an unexpected API shape can't crash
    -- the frame.
    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        InfoDialog.show(message)
    else
        Logger.warning("GuidanceSteeringStrategyFrame: InfoDialog.show unavailable; message: " .. tostring(message))
    end
end

function GuidanceSteeringStrategyFrame:onDisplayElementsChanged(element)
    self:displayTrackElements(element)
    self:displayMethodElements()
end

function GuidanceSteeringStrategyFrame:displayTrackElements(element)
    local track = self.guidanceSteering:getTrack(element.trackId)

    if track ~= nil then
        self.guidanceSteeringTrackNameElement:setText(track.name)
        -- Strategy selector removed; track.strategy stays at its default and needs no UI element.
        self.guidanceSteeringStrategyMethodElement:setState(track.method)
    end
end

function GuidanceSteeringStrategyFrame:displayMethodElements()
    local method = self.guidanceSteeringStrategyMethodElement:getState() - 1

    if method == ABStrategy.AB then
        self.guidanceSteeringPointAButton:setVisible(true)
        self.guidanceSteeringPointBButton:setVisible(true)
    elseif method == ABStrategy.A_AUTO_B
        or method == ABStrategy.A_PLUS_HEADING
        or method == ABStrategy.A_PLUS_DIRECTION then
        self.guidanceSteeringPointAButton:setVisible(true)
        self.guidanceSteeringPointBButton:setVisible(false)
    end
end

-- Header icon UV in the mod atlas (resources/guidanceSteering_1080p.png): the tile the
-- strategy tab uses (GuidanceSteeringMenu.TAB_UV.STRATEGY).
GuidanceSteeringStrategyFrame.HEADER_ICON_UV = { 845, 0, 65, 65 }

GuidanceSteeringStrategyFrame.L10N_SYMBOL = {}
