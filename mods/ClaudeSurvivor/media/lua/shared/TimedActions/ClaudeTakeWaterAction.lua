require "TimedActions/ISTakeWaterAction"
require "ClaudeWaterFacts"

-- A separate native timed-action type, loaded by both client and server. B42's
-- NetTimedAction reconstructs Type.new from the named constructor parameters;
-- every such parameter is therefore stored under exactly the same field name.
-- Client lease callbacks are attached locally and are intentionally not sent.
ClaudeTakeWaterAction = ISTakeWaterAction:derive("ClaudeTakeWaterAction")
local vesselOwners = setmetatable({}, {__mode="k"})

local function block(self, reason)
    self.claudeBlocked = self.claudeBlocked or tostring(reason or "water_facts_unavailable")
    if type(self.claudeOnBlocked) == "function" then
        pcall(self.claudeOnBlocked, self.claudeBlocked)
    end
    return false, self.claudeBlocked
end

local function server()
    local ok, value = pcall(isServer)
    return ok and value == true
end

local function mouthAvailable(character)
    -- Match the official inventory context menu's blocking-mask locations,
    -- without depending on that client-only UI or silently removing clothing.
    if not ItemBodyLocation or not ItemTag or not ItemTag.CAN_EAT then return false end
    local names = {"MASK", "MASK_EYES", "MASK_FULL", "FULL_HAT", "FULL_SUIT_HEAD", "SCBA", "SCBANOTANK"}
    for _, name in ipairs(names) do
        local location = ItemBodyLocation[name]
        if location == nil then return false end
        local item = character:getWornItem(location)
        if item and item:hasTag(ItemTag.CAN_EAT) ~= true then return false end
    end
    return true
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function targetSatisfied(self)
    if not finite(self.waterUnit) or self.waterUnit <= 0 then return false end
    if self.item then
        local vessel = ClaudeWaterFacts.inspectVessel(self.character, self.item, true)
        return type(vessel) == "table" and vessel.allowed == true and vessel.key == self.itemKey
            and finite(vessel.amount) and finite(self.startUsedAmount)
            and vessel.amount >= self.startUsedAmount + self.waterUnit - 0.000001
    end
    local thirst = self.character:getStats():get(CharacterStat.THIRST)
    return finite(thirst) and finite(self.startThirst)
        and thirst * 2 <= self.startThirst - self.waterUnit + 0.000001
end

local function inspect(self, requireAuthorization)
    if self.claudeBlocked then return false, self.claudeBlocked end
    local ok, allowed, reason = pcall(function()
        if not self.character or self.character:isDead() ~= false then return false, "water_actor_unavailable" end
        if requireAuthorization and not server() then
            if type(self.claudeAuthorized) ~= "function" or self.claudeAuthorized() ~= true then
                return false, "water_control_revoked"
            end
        end
        if self.claudeStarted and not self.claudeSatisfied and targetSatisfied(self) then
            -- The client sees replicated native effects, not the server's local
            -- latch. Recognize a fulfilled target only after this action began.
            self.claudeSatisfied = true
        end
        if self.claudeSatisfied then
            -- An earlier guarded native animation event already delivered the
            -- entire requested amount. This branch authorizes no mutation.
            return targetSatisfied(self), "water_completed_target_changed"
        end
        local source = ClaudeWaterFacts.inspectSource(self.character, self.waterObject, true)
        if type(source) ~= "table" or source.allowed ~= true then
            return false, type(source) == "table" and source.reason or "water_source_unavailable"
        end
        if type(self.sourceKey) ~= "string" or source.key ~= self.sourceKey then
            return false, "water_source_changed"
        end
        if self.item then
            local vessel = ClaudeWaterFacts.inspectVessel(self.character, self.item)
            if type(vessel) ~= "table" or vessel.allowed ~= true then
                return false, type(vessel) == "table" and vessel.reason or "water_vessel_unavailable"
            end
            if type(self.itemKey) ~= "string" or vessel.key ~= self.itemKey then return false, "water_vessel_changed" end
            if self.waterObject:canTransferFluidTo(self.item:getFluidContainer()) ~= true then
                return false, "water_transfer_incompatible"
            end
        else
            if self.itemKey ~= nil then return false, "water_unexpected_vessel" end
            if not mouthAvailable(self.character) then return false, "water_drinking_mask_blocked_or_unknown" end
        end
        if ISTakeWaterAction.isValid(self) ~= true then return false, "water_native_action_invalid" end
        return true
    end)
    if not ok then return false, "water_facts_unavailable" end
    return allowed == true, reason
end

function ClaudeTakeWaterAction:claudeValidate()
    local allowed, reason = inspect(self, true)
    if not allowed then return block(self, reason) end
    return true
end

function ClaudeTakeWaterAction:isValidStart()
    return self:claudeValidate()
end

function ClaudeTakeWaterAction:isValid()
    return self:claudeValidate()
end

function ClaudeTakeWaterAction:waitToStart()
    if not self:claudeValidate() then return false end
    if self.claudeSatisfied then return false end
    local ok, turning = pcall(ISTakeWaterAction.waitToStart, self)
    if not ok then block(self, "water_native_wait_failed"); return false end
    return turning == true
end

function ClaudeTakeWaterAction:start()
    if not self:claudeValidate() then return end
    if self.claudeSatisfied then return end
    if self.item then vesselOwners[self.item]=self end
    local ok = pcall(ISTakeWaterAction.start, self)
    if not ok then block(self, "water_native_start_failed") else self.claudeStarted = true end
end

function ClaudeTakeWaterAction:update()
    if not self:claudeValidate() then return end
    if self.claudeSatisfied then return end
    -- The native update -> updateUse -> self:transferFluid dispatch keeps the
    -- final mutation behind the fresh shared guard below, including in SP.
    local ok = pcall(ISTakeWaterAction.update, self)
    if not ok then block(self, "water_native_update_failed") end
end

function ClaudeTakeWaterAction:serverStart()
    if not server() or not self:claudeValidate() then return end
    if self.claudeSatisfied then return end
    local ok = pcall(ISTakeWaterAction.serverStart, self)
    if not ok then block(self, "water_native_server_start_failed") else self.claudeStarted = true end
end

function ClaudeTakeWaterAction:animEvent(event, parameter)
    if not server() or not self:claudeValidate() then return end
    if self.claudeSatisfied then return end
    local ok = pcall(ISTakeWaterAction.animEvent, self, event, parameter)
    if not ok then block(self, "water_native_event_failed") end
end

function ClaudeTakeWaterAction:transferFluid(amount)
    local okClient, client = pcall(isClient)
    if not okClient or client == true then return block(self, "water_client_effect_forbidden") end
    -- Native updateUse legitimately produces zero at repeated progress values.
    -- It must stay a no-op rather than poisoning an otherwise valid action.
    if amount == 0 then return true end
    if not self:claudeValidate() then return false end
    if self.claudeSatisfied then return true end
    if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount == math.huge then
        return block(self, "water_invalid_transfer_amount")
    end
    local ok = pcall(ISTakeWaterAction.transferFluid, self, amount)
    if not ok then return block(self, "water_native_transfer_failed") end
    local observed, satisfied = pcall(targetSatisfied, self)
    if observed and satisfied then self.claudeSatisfied = true end
    return true
end

function ClaudeTakeWaterAction:complete()
    local okClient, client = pcall(isClient)
    if not okClient or client == true then return block(self, "water_client_effect_forbidden") end
    if not self:claudeValidate() then return false end
    if self.claudeSatisfied then return true end
    local ok, completed = pcall(ISTakeWaterAction.complete, self)
    if not ok then return block(self, "water_native_complete_failed") end
    return completed == true and self.claudeBlocked == nil
end

local function ownsQueue(self)
    local ok, owned = pcall(function()
        local queue=ISTimedActionQueue.getTimedActionQueue(self.character)
        return ISTimedActionQueue.hasAction(self)==true and queue and type(queue.queue)=="table"
            and queue.queue[1]==self
    end)
    return ok and owned == true
end

local function cleanup(self)
    pcall(ISTakeWaterAction.stopSound, self)
    if not self.item then return true end
    if vesselOwners[self.item]~=self then return false end
    local ok, free=pcall(function()
        local queue=ISTimedActionQueue.getTimedActionQueue(self.character)
        if not queue or type(queue.queue)~="table" then return false end
        for _,action in ipairs(queue.queue) do
            if action~=self and action.item==self.item then return false end
        end
        return true
    end)
    if not ok then return false end
    if not free then vesselOwners[self.item]=nil;return false end
    -- Ownership persists long enough to clean up a legitimate queue removal,
    -- but a replacement custom or native action using this vessel wins.
    vesselOwners[self.item]=nil
    pcall(function() self.item:setBeingFilled(false); self.item:setJobDelta(0) end)
    return true
end

function ClaudeTakeWaterAction:stop()
    cleanup(self)
    -- A retained callback after takeover must not reset a replacement queue.
    if ownsQueue(self) then pcall(ISBaseTimedAction.stop, self) end
end

function ClaudeTakeWaterAction:perform()
    local allowed = self:claudeValidate()
    local itemOwned=cleanup(self)
    if not ownsQueue(self) then return end
    -- perform only acknowledges this queued animation; it does not prove an
    -- effect. Native complete/animEvent on the server own actual consumption.
    if allowed and itemOwned then
        local ok = pcall(ISTakeWaterAction.perform, self)
        if ok then return end
        block(self, "water_native_perform_failed")
    end
    if ownsQueue(self) then pcall(ISBaseTimedAction.perform, self) end
end

function ClaudeTakeWaterAction:new(character, item, waterObject, sourceKey, itemKey)
    local probe = {character=character, item=item, waterObject=waterObject, sourceKey=sourceKey, itemKey=itemKey}
    local allowed, reason = inspect(probe, false)
    local action
    if allowed then
        local ok, native = pcall(ISTakeWaterAction.new, self, character, item, waterObject, false)
        if ok and type(native) == "table" and finite(native.waterUnit) and native.waterUnit > 0 then
            action = native
        else reason = "water_native_constructor_failed_or_no_need" end
    end
    if not action then
        action = ISBaseTimedAction.new(self, character)
        action.maxTime, action.waterUnit = 1, 0
        action.claudeBlocked = reason or "water_action_unavailable"
    end
    action.character, action.item, action.waterObject = character, item, waterObject
    action.sourceKey, action.itemKey = sourceKey, itemKey
    action.retriggerLastAction = false
    return action
end
