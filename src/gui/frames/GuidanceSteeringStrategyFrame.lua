---
-- GuidanceSteeringStrategyFrame
--
-- Frame to handle the tracks and guidance strategy.
--
-- Copyright (c) Wopster, 2019

---@class GuidanceSteeringStrategyFrame
GuidanceSteeringStrategyFrame = {}

local GuidanceSteeringStrategyFrame_mt = Class(GuidanceSteeringStrategyFrame, TabbedMenuFrameElement)

GuidanceSteeringStrategyFrame.CONTROLS = {
    CONTAINER = "container",
    STRATEGY = "guidanceSteeringStrategyElement",
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

    self:registerControls(GuidanceSteeringStrategyFrame.CONTROLS)

    return self
end

function GuidanceSteeringStrategyFrame:copyAttributes(src)
    GuidanceSteeringStrategyFrame:superClass().copyAttributes(self, src)

    self.ui = src.ui
    self.i18n = src.i18n
end

function GuidanceSteeringStrategyFrame:initialize()
    self.guidanceSteeringStrategyElement:setTexts({
        self.i18n:getText("guidanceSteering_strategy_abStraight"),
    })

    self.guidanceSteeringTrackNameElement:setText("Track name")

    -- FS25: the SmoothList is data-source driven (setDataSource + reloadData + the
    -- getNumberOfItemsInSection/populateCellForItemInSection callbacks below), replacing
    -- the FS22 manual clone/deleteListItems API which was removed from SmoothListElement.
    if self.list ~= nil and self.list.setDataSource ~= nil then
        self.list:setDataSource(self)
    end

    self:build()
end

function GuidanceSteeringStrategyFrame:build()
    local uiFilename = self.ui.uiFilename

    -- Buttons
    self.guidanceSteeringCreateTrackButton:setImageFilename(nil, uiFilename)
    self.guidanceSteeringSaveTrackButton:setImageFilename(nil, uiFilename)
    self.guidanceSteeringRemoveTrackButton:setImageFilename(nil, uiFilename)
    self.guidanceSteeringRotateTrackButton:setImageFilename(nil, uiFilename)

    self.guidanceSteeringCreateTrackButton:setImageUVs(nil, GuiUtils.getUVs(GuidanceSteeringStrategyFrame.UVS.CREATE_TRACK))
    self.guidanceSteeringSaveTrackButton:setImageUVs(nil, GuiUtils.getUVs(GuidanceSteeringStrategyFrame.UVS.SAVE_TRACK))
    self.guidanceSteeringRemoveTrackButton:setImageUVs(nil, GuiUtils.getUVs(GuidanceSteeringStrategyFrame.UVS.REMOVE_TRACK))
    self.guidanceSteeringRotateTrackButton:setImageUVs(nil, GuiUtils.getUVs(GuidanceSteeringStrategyFrame.UVS.ROTATE_TRACK))
end

function GuidanceSteeringStrategyFrame:onFrameOpen()
    GuidanceSteeringStrategyFrame:superClass().onFrameOpen(self)

    self.guidanceSteering:subscribe(self)
    self:buildList()

    local vehicle = self.ui:getVehicle()
    if vehicle ~= nil then
        local strategy = vehicle:getGuidanceStrategy()

        self.guidanceSteeringStrategyMethodElement:setTexts(strategy:getTexts(self.i18n))
        self.guidanceSteeringStrategyMethodElement:setState(strategy.id + 1)
        self:displayMethodElements()

        self.allowSave = true
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

    -- Restore the previous selection, defaulting to the first row.
    local selectedIndex = 1
    for index, entry in ipairs(self.tracks) do
        if entry.trackId == selectedTrackId then
            selectedIndex = index
            break
        end
    end

    if #self.tracks > 0 and self.list.setSelectedIndex ~= nil then
        self.list:setSelectedIndex(selectedIndex)
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
    local isScoped = self.guidanceSteeringScopeFarmIdElement:getIsChecked()

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
    track.strategy = self.guidanceSteeringStrategyElement:getState()
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
        self.guidanceSteeringStrategyElement:setState(track.strategy)
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

GuidanceSteeringStrategyFrame.UVS = {
    REMOVE_TRACK = { 780, 0, 65, 65 },
    CREATE_TRACK = { 780, 65, 65, 65 },
    SAVE_TRACK = { 845, 65, 65, 65 },
    ROTATE_TRACK = { 325, 65, 65, 65 },
}

GuidanceSteeringStrategyFrame.L10N_SYMBOL = {}
