---
-- StoppedState
--
-- Main state for stopping on the headland.
--
-- Copyright (c) Wopster, 2019

---@class StoppedState
StoppedState = {}

local StoppedState_mt = Class(StoppedState, AbstractState)

---Creates a new stopped state.
---@param id number
---@param object table
---@param custom_mt table
---@return StoppedState
function StoppedState:new(id, object, custom_mt)
    local self = AbstractState:new(id, object, custom_mt or StoppedState_mt)

    return self
end

---@see AbstractState#onEntry
function StoppedState:onEntry()
    StoppedState:superClass().onEntry(self)

    -- We turn off the cruiseControl
    local spec = self.object:guidanceSteering_getSpecTable("drivable")
    if spec.cruiseControl.state ~= Drivable.CRUISECONTROL_STATE_OFF then
        self.object:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF)
    end

    spec = self.object.spec_globalPositioningSystem
    spec.lastInputValues.guidanceSteeringIsActive = not spec.lastInputValues.guidanceSteeringIsActive
end

---@see AbstractState#onExit
function StoppedState:onExit()
    StoppedState:superClass().onExit(self)
end

---@see AbstractState#update
function StoppedState:update(dt)
    StoppedState:superClass().update(self, dt)

    -- Headland STOP mode. onEntry already turned off cruise control and toggled Guidance Steering
    -- off, so the vehicle coasts to a stop under the player's control. We no longer force-brake via
    -- WheelsUtil: the vehicle now stays player-controlled and the base game owns the wheels, so a
    -- manual brake here would fight base physics.
    return FSM.ANY_STATE
end
