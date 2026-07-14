---
-- loader
--
-- loader script for the mod
--
-- Copyright (c) Wopster, 2018

local directory = g_currentModDirectory
local modName = g_currentModName

g_guidanceSteeringModName = modName

-- FS25 port: the SavegameSettingsEvent read/writeStream hooks are unverified against
-- FS25 (its multiplayer settings-sync compatibility is unknown). Gate them behind this
-- flag so a signature change can't break loading. Default off; the fallback is the
-- mod's own event classes. Flip to true only once the event is confirmed FS25-safe.
GS_ENABLE_SETTINGS_SYNC_HOOK = false

source(Utils.getFilename("src/events/TrackSaveEvent.lua", directory))
source(Utils.getFilename("src/events/TrackDeleteEvent.lua", directory))
source(Utils.getFilename("src/events/StrategyInteractEvent.lua", directory))
source(Utils.getFilename("src/events/GuidanceDataChangedEvent.lua", directory))
source(Utils.getFilename("src/events/HeadlandModeChangedEvent.lua", directory))
source(Utils.getFilename("src/events/GuidanceStrategyChangedEvent.lua", directory))

source(Utils.getFilename("src/utils/Logger.lua", directory))
source(Utils.getFilename("src/utils/DriveUtil.lua", directory))
source(Utils.getFilename("src/utils/GuidanceUtil.lua", directory))
source(Utils.getFilename("src/utils/HeadlandUtil.lua", directory))
source(Utils.getFilename("src/utils/stream.lua", directory))

source(Utils.getFilename("src/gui/GuidanceSteeringUI.lua", directory))
source(Utils.getFilename("src/gui/GuidanceSteeringMenu.lua", directory))
source(Utils.getFilename("src/gui/frames/GuidanceSteeringSettingsFrame.lua", directory))
source(Utils.getFilename("src/gui/frames/GuidanceSteeringStrategyFrame.lua", directory))
source(Utils.getFilename("src/gui/hud/GuidanceSteeringHUD.lua", directory))

source(Utils.getFilename("src/GuidanceSteering.lua", directory))

source(Utils.getFilename("src/misc/FSM.lua", directory))
source(Utils.getFilename("src/misc/FSMContext.lua", directory))
source(Utils.getFilename("src/misc/StateEngine.lua", directory))
source(Utils.getFilename("src/misc/states/AbstractState.lua", directory))
source(Utils.getFilename("src/misc/states/FollowLineState.lua", directory))
source(Utils.getFilename("src/misc/states/OnHeadlandState.lua", directory))
source(Utils.getFilename("src/misc/states/StoppedState.lua", directory))
source(Utils.getFilename("src/misc/states/TurningState.lua", directory))

source(Utils.getFilename("src/misc/MultiPurposeActionEvent.lua", directory))
source(Utils.getFilename("src/misc/ABPoint.lua", directory))
source(Utils.getFilename("src/misc/HeadlandPasses.lua", directory))
--source(Utils.getFilename("src/misc/LinkedList.lua", directory))

source(Utils.getFilename("src/strategies/ABStrategy.lua", directory))
source(Utils.getFilename("src/strategies/StraightABStrategy.lua", directory))
source(Utils.getFilename("src/strategies/CardinalStrategy.lua", directory))
source(Utils.getFilename("src/strategies/SnapDirectionStrategy.lua", directory))

local guidanceSteering
local guidanceConfigurations = {}
local gsInjectionLogged = false

local function isEnabled()
    return guidanceSteering ~= nil
end

function init()
    -- FS25: build the GPS shop configuration list before any store items load. Doing this
    -- lazily in loadMission was too late (store items load first), so an empty list got
    -- injected into every vehicle. See loadGuidanceConfigurations.
    loadGuidanceConfigurations()

    FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, unload)

    Mission00.load = Utils.prependedFunction(Mission00.load, loadMission)
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)

    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, saveToXMLFile)

    -- Networking (FS25: gated, see GS_ENABLE_SETTINGS_SYNC_HOOK above)
    if GS_ENABLE_SETTINGS_SYNC_HOOK then
        SavegameSettingsEvent.readStream = Utils.appendedFunction(SavegameSettingsEvent.readStream, readStream)
        SavegameSettingsEvent.writeStream = Utils.appendedFunction(SavegameSettingsEvent.writeStream, writeStream)
    end

    TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, validateVehicleTypes)
    -- FS25: StoreItemUtil.getConfigurationsFromXML no longer exists; shop configs are
    -- built by ConfigurationUtil.getConfigurationsFromXML (new manager-first signature).
    ConfigurationUtil.getConfigurationsFromXML = Utils.overwrittenFunction(ConfigurationUtil.getConfigurationsFromXML, addGPSConfigurationUtil)
end

function loadMission(mission)
    if isEnabled() or mission.guidanceSteering ~= nil then
        log("Error: Guidance Steering is already loaded, please remove duplicate version!")
        return
    end

    guidanceSteering = GuidanceSteering:new(mission, directory, modName, g_i18n, g_gui, g_gui.inputManager, g_messageCenter)

    mission.guidanceSteering = guidanceSteering

    addModEventListener(guidanceSteering)
end

-- FS25: the GPS shop configuration list must exist before store items are loaded.
-- ConfigurationUtil.getConfigurationsFromXML runs during store loading, and
-- addGPSConfigurationUtil reads guidanceConfigurations there. Building it lazily in
-- loadMission ran too late: the injection produced an empty list, so every vehicle got a
-- globalPositioningSystem config with no item at the resolved index -> base game logged
-- "Configuration with index '1' is not present anymore" and then crashed in Vehicle:getName
-- (indexing a nil config item with 'vehicleName'). Populate once at mod-load time instead.
function loadGuidanceConfigurations()
    if #guidanceConfigurations > 0 then
        return
    end

    local xmlFile = loadXMLFile("ConfigurationXML", directory .. "resources/globalPositioningSystemConfiguration.xml")
    if xmlFile ~= nil then
        for i = 1, 2 do
            local key = ("globalPositioningSystemConfigurations.globalPositioningSystemConfiguration(%d)"):format(i - 1)

            local config = {}
            config.desc = ""
            config.isDefault = getXMLBool(xmlFile, key .. "#isDefault")
            config.dailyUpkeep = 0
            config.index = i
            config.price = getXMLInt(xmlFile, key .. "#price")
            config.name = g_i18n:getText(getXMLString(xmlFile, key .. "#name"))
            config.enabled = getXMLBool(xmlFile, key .. "#enabled")
            config.isSelectable = true
            config.saveId = tostring(config.index)

            table.insert(guidanceConfigurations, config)
        end

        delete(xmlFile)
    end
end

function loadedMission(mission, node)
    if not isEnabled() then
        return
    end

    if mission:getIsServer() then
        if mission.missionInfo.savegameDirectory ~= nil and fileExists(mission.missionInfo.savegameDirectory .. "/guidanceSteering.xml") then
            local xmlFile = XMLFile.load("GuidanceXML", mission.missionInfo.savegameDirectory .. "/guidanceSteering.xml")
            if xmlFile ~= nil then
                guidanceSteering:onMissionLoadFromSavegame(xmlFile)
                xmlFile:delete()
            end
        end
    end

    if mission.cancelLoading then
        return
    end

    guidanceSteering:onMissionLoaded(mission)
end

function unload()
    if not isEnabled() then
        return
    end

    removeModEventListener(guidanceSteering)

    guidanceSteering:delete()
    guidanceSteering = nil -- Allows garbage collecting

    if g_currentMission ~= nil then
        g_currentMission.guidanceSteering = nil
    end
end

function saveToXMLFile(missionInfo)
    if not isEnabled() then
        return
    end

    if missionInfo.isValid then
        local xmlFile = XMLFile.create("GuidanceXML", missionInfo.savegameDirectory .. "/guidanceSteering.xml", "guidanceSteering")
        if xmlFile ~= nil then
            guidanceSteering:onMissionSaveToSavegame(xmlFile)
            xmlFile:save()
            xmlFile:delete()
        end
    end
end

function readStream(e, streamId, connection)
    if not isEnabled() then
        return
    end

    guidanceSteering:onReadStream(streamId, connection)
end

function writeStream(e, streamId, connection)
    if not isEnabled() then
        return
    end

    guidanceSteering:onWriteStream(streamId, connection)
end

function validateVehicleTypes(typeManager)
    if typeManager.typeName == "vehicle" then
        GuidanceSteering.installSpecializations(g_vehicleTypeManager, g_specializationManager, directory, modName)
    end
end

-- StoreItem insertion

local disallowedCategories = {
    ["TELELOADERS"] = false,
    ["TELELOADERVEHICLES"] = false,
    ["FRONTLOADERVEHICLES"] = false,
    ["FRONTLOADERS"] = false,
    ["WHEELLOADERS"] = false,
    ["WHEELLOADERVEHICLES"] = false,
    ["SKIDSTEERS"] = false,
    ["SKIDSTEERVEHICLES"] = false,
    ["ANIMALSVEHICLES"] = false,
    ["CUTTERS"] = false,
    ["FORAGEHARVESTERCUTTERS"] = false,
    ["CORNHEADERS"] = false,
    ["WOODHARVESTING"] = false,
    ["ANIMALS"] = false,
    ["CUTTERTRAILERS"] = false,
    ["TRAILERS"] = false,
    ["SLURRYTANKS"] = false,
    ["MANURESPREADERS"] = false,
    ["LOADERWAGONS"] = false,
    ["AUGERWAGONS"] = false,
    ["WINDROWERS"] = false,
    ["WEIGHTS"] = false,
    ["LOWLOADERS"] = false,
    ["WOOD"] = false,
    ["BELTS"] = false,
    ["LEVELER"] = false,
    ["CARS"] = false,
    ["DECORATION"] = false,
    ["PLACEABLEMISC"] = false,
    ["PLACEABLEMISC"] = false,
    ["CHAINSAWS"] = false,
    ["SHEDS"] = false,
    ["BIGBAGS"] = false,
    ["BALES"] = false,
    ["ANIMALPENS"] = false,
    ["FARMHOUSES"] = false,
    ["SILOS"] = false,
}

local function canAddGuidanceSteeringConfiguration(storeItem, xmlFile)
    local isDrivable = xmlFile:hasProperty("vehicle.drivable")
    local isMotorized = xmlFile:hasProperty("vehicle.motorized")

    return disallowedCategories[storeItem.categoryName] == nil and isDrivable and isMotorized
end

-- FS25: ConfigurationUtil.getConfigurationsFromXML(manager, xmlFile, key, baseDir, customEnvironment, isMod, storeItem)
-- Base vehicle XMLs don't contain a globalPositioningSystem config section, so the base
-- function never builds one. We inject the GPS config as VehicleConfigurationItem instances
-- after calling superFunc (pattern from FS25_RealisticHarvesting's RHM_Configuration.lua).
function addGPSConfigurationUtil(manager, superFunc, xmlFile, key, baseDir, customEnvironment, isMod, storeItem)
    local configurations, defaultConfigurationIds = superFunc(manager, xmlFile, key, baseDir, customEnvironment, isMod, storeItem)

    if StoreItemUtil.getIsVehicle(storeItem) and canAddGuidanceSteeringConfiguration(storeItem, xmlFile) then
        local gpsKey = GlobalPositioningSystem.CONFIG_NAME
        local configurationDesc = manager:getConfigurations()[gpsKey]

        if configurationDesc ~= nil then
            if configurations == nil then
                configurations = {}
            end
            if defaultConfigurationIds == nil then
                defaultConfigurationIds = {}
            end

            if configurations[gpsKey] == nil then
                local items = {}

                for i, data in ipairs(guidanceConfigurations) do
                    local configItem = configurationDesc.itemClass.new(gpsKey)
                    configItem:setIndex(i)
                    configItem.name = data.name
                    configItem.price = data.price
                    configItem.isDefault = data.isDefault
                    configItem.isSelectable = true
                    configItem.saveId = tostring(i)
                    -- Custom flag read by GlobalPositioningSystem:onLoad to decide if the
                    -- vehicle actually has a working GPS (index > 1 = "with GPS").
                    configItem.enabled = data.enabled

                    items[i] = configItem
                end

                if not gsInjectionLogged then
                    gsInjectionLogged = true
                    Logging.info("[GuidanceSteering] GPS config injection: %d source configs -> %d items for '%s'", #guidanceConfigurations, #items, tostring(storeItem.xmlFilename))
                end

                -- Never register an empty list: a present-but-empty config would leave the
                -- vehicle with a globalPositioningSystem index that resolves to a nil item,
                -- crashing base Vehicle code (index nil with 'vehicleName'). Only inject when
                -- items were actually built.
                if #items > 0 then
                    configurations[gpsKey] = items
                    defaultConfigurationIds[gpsKey] = ConfigurationUtil.getDefaultConfigIdFromItems(items)
                end
            end
        end
    end

    return configurations, defaultConfigurationIds
end

init()

-- Fixes

function Vehicle:guidanceSteering_getModName()
    return modName
end

function Vehicle:guidanceSteering_getSpecTable(name)
    local spec = self["spec_" .. modName .. "." .. name]
    if spec ~= nil then
        return spec
    end

    return self["spec_" .. name]
end
