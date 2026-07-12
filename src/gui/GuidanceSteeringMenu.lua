---
-- GuidanceSteeringMenu
--
-- The main menu for GuidanceSteering.
--
-- Copyright (c) Wopster, 2019

---@class GuidanceSteeringMenu
GuidanceSteeringMenu = {}

local GuidanceSteeringMenu_mt = Class(GuidanceSteeringMenu, TabbedMenu)

GuidanceSteeringMenu.CONTROLS = {
    PAGE_SETTINGS = "pageSettings",
    PAGE_STRATEGY = "pageStrategy",
    DIALOG_BACKGROUND = "dialogBackground",
}

---Creates a new instance of the GuidanceSteeringMenu.
---@return GuidanceSteeringMenu
function GuidanceSteeringMenu.new(messageCenter, i18n, inputManager)
    -- FS25: TabbedMenu.new(target, custom_mt) dropped its FS22 service arguments
    -- (messageCenter/i18n/inputManager). The base no longer stores them, so we assign
    -- them ourselves here (same pattern as Courseplay's CpInGameMenu). self.l10n is
    -- required by the inherited setupMenuButtonInfo/menu-button plumbing.
    local self = TabbedMenu.new(nil, GuidanceSteeringMenu_mt)

    self:registerControls(GuidanceSteeringMenu.CONTROLS)

    self.messageCenter = messageCenter
    self.i18n = i18n
    self.l10n = i18n
    self.inputManager = inputManager
    self.performBackgroundBlur = false

    return self
end

function GuidanceSteeringMenu:onGuiSetupFinished()
    GuidanceSteeringMenu:superClass().onGuiSetupFinished(self)

    self.clickBackCallback = self:makeSelfCallback(self.onButtonBack) -- store to be able to apply it always when assigning menu button info

    self.pageSettings:initialize()
    self.pageStrategy:initialize()

    self:setupPages()
    self:setupMenuButtonInfo()
end

function GuidanceSteeringMenu:setupPages()
    local alwaysVisiblePredicate = self:makeIsAlwaysVisiblePredicate()

    -- FS25: g_iconsUIFilename (the base-game icon atlas the settings tab borrowed) may be
    -- unavailable; fall back to our own atlas so the tab always has a valid texture.
    local gsFilename = g_currentMission.guidanceSteering.ui.uiFilename
    local settingsIconFilename = g_iconsUIFilename or gsFilename

    local orderedPages = {
        { self.pageSettings, alwaysVisiblePredicate, settingsIconFilename, GuidanceSteeringMenu.TAB_UV.SETTINGS },
        { self.pageStrategy, alwaysVisiblePredicate, gsFilename, GuidanceSteeringMenu.TAB_UV.STRATEGY },
    }

    for i, pageDef in ipairs(orderedPages) do
        local page, predicate, uiFilename, iconUVs = unpack(pageDef)
        self:registerPage(page, i, predicate)

        -- FS25 addPageTab(frameController, iconFilename, iconUVs, iconSliceId, soundId):
        -- passing filename + UVs (sliceId nil) is still supported by the base game.
        local normalizedUVs = GuiUtils.getUVs(iconUVs)
        self:addPageTab(page, uiFilename, normalizedUVs)
    end
end

function GuidanceSteeringMenu:onOpen()
    GuidanceSteeringMenu:superClass().onOpen(self)

    self.inputDisableTime = 200
end

--- Define default properties and retrieval collections for menu buttons.
function GuidanceSteeringMenu:setupMenuButtonInfo()
    local onButtonBackFunction = self.clickBackCallback

    self.defaultMenuButtonInfo = {
        { inputAction = InputAction.MENU_BACK, text = self.l10n:getText(GuidanceSteeringMenu.L10N_SYMBOL.BUTTON_BACK), callback = onButtonBackFunction },
    }

    self.defaultMenuButtonInfoByActions[InputAction.MENU_BACK] = self.defaultMenuButtonInfo[1]

    self.defaultButtonActionCallbacks = {
        [InputAction.MENU_BACK] = onButtonBackFunction,
    }
end

function GuidanceSteeringMenu:makeIsAlwaysVisiblePredicate()
    return function()
        return true
    end
end

--- Page tab UV coordinates for display elements.
GuidanceSteeringMenu.TAB_UV = {
    SETTINGS = { 715, 0, 65, 65 },
    STRATEGY = { 845, 0, 65, 65 },
}

GuidanceSteeringMenu.L10N_SYMBOL = {
    BUTTON_BACK = "button_back",
}
