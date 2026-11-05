-- Conservative window traversal for the player-client controller. This module
-- never smashes, removes glass, walks, or clears a timed-action queue.
ClaudeWindowPolicy = {}

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function denied(reason)
    return {allowed=false, reason=reason}
end

-- Source APIs: B42.21 ISObjectClickHandler.doClickWindow, the installed
-- ISClimbThroughWindow action, and IsoGridSquare.canStand/TreatAsSolidFloor.
-- Stay beside a known window; approaching an unseen target is another skill.
function ClaudeWindowPolicy.inspect(player, window)
    if not player or not window then return denied("window_target_missing") end
    local ok, result = pcall(function()
        if type(instanceof) ~= "function" or instanceof(window, "IsoWindow") ~= true then
            return denied("window_type_unsupported")
        end
        if player:isDead() ~= false then return denied("window_player_not_alive") end
        local index = window:getObjectIndex()
        if not finite(index) or index < 0 or index ~= math.floor(index) then
            return denied("window_target_removed")
        end
        local current, first, second = player:getCurrentSquare(), window:getSquare(), window:getOppositeSquare()
        if not current or not first or not second then return denied("window_square_unknown") end
        local z, firstZ, secondZ = current:getZ(), first:getZ(), second:getZ()
        if not finite(z) or not finite(firstZ) or not finite(secondZ) then
            return denied("window_floor_unknown")
        end
        if z ~= firstZ or z ~= secondZ then return denied("window_wrong_floor") end
        if current ~= first and current ~= second then return denied("window_not_adjacent") end
        local destination = current == first and second or first
        if current:TreatAsSolidFloor() ~= true or destination:TreatAsSolidFloor() ~= true
            or destination:canStand() ~= true then
            return denied("window_landing_unsafe")
        end
        -- Existing floor glass is hazardous too. Do not assume shoes/gloves are
        -- adequate protection; equipment-aware hazardous entry is a later skill.
        if current:getBrokenGlass() ~= nil or destination:getBrokenGlass() ~= nil then
            return denied("window_floor_glass")
        end
        local open, destroyed, smashed = window:IsOpen(), window:isDestroyed(), window:isSmashed()
        if type(open) ~= "boolean" or type(destroyed) ~= "boolean" or type(smashed) ~= "boolean" then
            return denied("window_state_unknown")
        end
        if destroyed or smashed then
            if window:isGlassRemoved() ~= true then return denied("window_glass_present_or_unknown") end
        elseif not open then
            return denied("window_closed_no_smashing")
        end
        if window:isBarricaded() ~= false then return denied("window_barricaded_or_unknown") end
        if window:canClimbThrough(player) ~= true then return denied("window_climb_unavailable") end
        return {allowed=true, reason="window_ready", destination=destination}
    end)
    return ok and result or denied("window_facts_unavailable")
end

local function defaults()
    return {
        busy=function(player)
            local queue = ISTimedActionQueue.getTimedActionQueue(player)
            if not queue or type(queue.queue) ~= "table" then return nil end
            local doing = ISTimedActionQueue.isPlayerDoingAction(player)
            if type(doing) ~= "boolean" then return nil end
            return #queue.queue ~= 0 or doing
        end,
        createAction=function(player, window) return ISClimbThroughWindow:new(player, window, 0) end,
        add=function(action)
            local queue = ISTimedActionQueue.add(action)
            return queue ~= nil and queue ~= false and ISTimedActionQueue.hasAction(action) == true
        end,
        finishRejected=function(action)
            -- A successful manual clear may already have removed this action.
            -- Do not run queue completion against unrelated replacement work.
            if ISTimedActionQueue.hasAction(action) == true then return ISBaseTimedAction.perform(action) end
        end,
    }
end

-- Optional env provides the four game adapters above, an authorized() callback
-- bound to the original player's session/token/lease, and onBlocked(reason).
-- The fifth argument supplies authorization with the default game adapters.
-- There are no fallback moves and authorization is checked again at execution.
function ClaudeWindowPolicy.queue(player, window, env, onBlocked, authorized)
    local initial = ClaudeWindowPolicy.inspect(player, window)
    if not initial.allowed then return false, initial.reason end
    env = env or defaults()
    if type(onBlocked) == "function" then env.onBlocked = onBlocked end
    if type(authorized) == "function" then env.authorized = authorized end
    if type(env.authorized) ~= "function" then return false, "window_authorization_unavailable" end
    local function hasAuthority()
        local ok, permitted = pcall(env.authorized)
        return ok and permitted == true
    end
    if not hasAuthority() then return false, "window_control_revoked" end
    if type(env.busy) ~= "function" or type(env.createAction) ~= "function"
        or type(env.add) ~= "function" or type(env.finishRejected) ~= "function" then
        return false, "window_queue_adapter_unavailable"
    end
    local okBusy, busy = pcall(env.busy, player)
    if not okBusy or type(busy) ~= "boolean" then return false, "window_queue_unknown" end
    if busy then return false, "window_body_busy" end
    local made, action = pcall(env.createAction, player, window)
    if not made or type(action) ~= "table" or type(action.isValid) ~= "function"
        or type(action.perform) ~= "function" then
        return false, "window_action_unavailable"
    end
    local originalValid, originalPerform = action.isValid, action.perform
    local function blocked(self, reason)
        self.claudeWindowBlocked = reason
        if type(env.onBlocked) == "function" then pcall(env.onBlocked, reason) end
        return false
    end
    local function validate(self)
        if not hasAuthority() then return blocked(self, "window_control_revoked") end
        local current = ClaudeWindowPolicy.inspect(player, window)
        if not current.allowed then return blocked(self, current.reason) end
        local valid, accepted = pcall(originalValid, self)
        if not valid or accepted ~= true then return blocked(self, "window_action_invalid") end
        return true
    end
    action.isValid = validate
    action.perform = function(self)
        -- Vanilla isValid checks climbability but not all the glass/landing
        -- preconditions. Recheck immediately before its climb call as well.
        if not validate(self) then
            local finished = pcall(env.finishRejected, self)
            if not finished then blocked(self, "window_rejection_cleanup_failed") end
            return false
        end
        return originalPerform(self)
    end
    -- Do not retrigger a previous food or other action after climbing. The
    -- bridge owns explicit subsequent work instead of vanilla UI conveniences.
    action.retriggerLastAction = false
    if not validate(action) then return false, action.claudeWindowBlocked end
    local final = ClaudeWindowPolicy.inspect(player, window)
    if not final.allowed then return false, final.reason end
    local added, confirmed = pcall(env.add, action)
    if not added then return false, "window_enqueue_failed" end
    if confirmed ~= true then return false, "window_enqueue_refused" end
    return true, "window_queued"
end

return ClaudeWindowPolicy
