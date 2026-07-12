---
-- GuidanceSteeringUI
--
-- The handler class for the GuidanceSteering UI.
--
-- Copyright (c) Wopster, 2019

---@class GuidanceSteeringUI
GuidanceSteeringUI = {}

local GuidanceSteeringUI_mt = Class(GuidanceSteeringUI)

---Creates a new instance of the GuidanceSteeringUI.
---@return GuidanceSteeringUI
function GuidanceSteeringUI:new(mission, i18n, modDirectory, gui, inputManager, messageCenter)
    local self = setmetatable({}, GuidanceSteeringUI_mt)

    self.mission = mission
    self.i18n = i18n
    self.modDirectory = modDirectory
    self.gui = gui
    self.inputManager = inputManager
    self.messageCenter = messageCenter
    self.isClient = mission:getIsClient()

    self.uiFilename = Utils.getFilename("resources/guidanceSteering_1080p.png", modDirectory)

    -- FS25 port (Phase 3): the HUD is ported. Create it unconditionally; its
    -- SpeedMeterDisplay.storeScaledValues/draw hooks are FS25-compatible.
    self.hud = GuidanceSteeringHUD:new(mission, mission.hud.speedMeter, i18n, self.uiFilename)

    self.vehicle = nil

    return self
end

function GuidanceSteeringUI:delete()
    if self.isClient then
        if self.hud ~= nil then
            self.hud:delete()
        end

        self:unloadMenu()
    end
end

function GuidanceSteeringUI:load()
    if self.isClient then
        -- FS25 port (Phase 3): the HUD is ported; load it. The settings menu is
        -- still Phase 4 -- skip guiProfiles + menu loading while PHASE1_NO_UI is set
        -- (the FS22 guiProfiles.xml extends base profiles that were renamed in FS25).
        self.hud:load()

        if GuidanceSteering.PHASE1_NO_UI then
            return
        end

        self.gui:loadProfiles(Utils.getFilename("resources/gui/guiProfiles.xml", self.modDirectory))

        self:loadMenu()
    end
end

---Loads the menus.
function GuidanceSteeringUI:loadMenu()
    local settingsFrame = GuidanceSteeringSettingsFrame.new(self, self.i18n)
    local strategyFrame = GuidanceSteeringStrategyFrame.new(self, self.i18n)

    self.menu = GuidanceSteeringMenu.new(self.messageCenter, self.i18n, self.inputManager)

    local root = Utils.getFilename("resources/gui/", self.modDirectory)
    self.gui:loadGui(root .. "GuidanceSteeringSettingsFrame.xml", "GuidanceSteeringSettingsFrame", settingsFrame, true)
    self.gui:loadGui(root .. "GuidanceSteeringStrategyFrame.xml", "GuidanceSteeringStrategyFrame", strategyFrame, true)
    self.gui:loadGui(root .. "GuidanceSteeringMenu.xml", "GuidanceSteeringMenu", self.menu)
end

---Unloads and removes the menus.
function GuidanceSteeringUI:unloadMenu()
    --self.menu:delete()
end

---Action event to toggle the menu.
function GuidanceSteeringUI:onToggleUI()
    -- FS25 port: the menu isn't ported yet (Phase 4). Inform the user instead of opening it.
    if GuidanceSteering.PHASE1_NO_UI then
        Logger.info("GS_SHOW_UI: menu UI is not yet available in the FS25 port.")
        if g_currentMission ~= nil then
            g_currentMission:showBlinkingWarning("Guidance Steering: menu not yet available in FS25 port", 2000)
        end
        return
    end

    if not self.mission.isSynchronizingWithPlayers then
        self.gui:showGui("GuidanceSteeringMenu")
    end
end

---Set the current vehicle on the UI.
function GuidanceSteeringUI:setVehicle(vehicle)
    self.vehicle = vehicle

    if self.hud ~= nil then
        self.hud:setVehicle(vehicle)
    end
end

---Get the current vehicle.
function GuidanceSteeringUI:getVehicle()
    return self.vehicle
end

function GuidanceSteeringUI:draw()
end
