-- Deterministic checks of the actual policy, not multiplayer engine proof.
local directory = assert(arg[1])
dofile(directory .. "/ClaudeWindowPolicy.lua")
local count = 0
local function test(name, fn)
    fn()
    count = count + 1
    print("ok " .. name)
end
local function fixture()
    local a = {z=0, floor=true, stand=true}
    local b = {z=0, floor=true, stand=true}
    for _,square in ipairs({a,b}) do
        square.getZ=function(self) return self.z end
        square.TreatAsSolidFloor=function(self) return self.floor end
        square.canStand=function(self) return self.stand end
        square.getBrokenGlass=function(self) return self.glass end
    end
    local player = {square=a, dead=false}
    player.getCurrentSquare=function(self) return self.square end
    player.isDead=function(self) return self.dead end
    local window = {class="IsoWindow", index=1, open=true, smashed=false,
        destroyed=false, removed=false, barricaded=false, climbable=true}
    window.getObjectIndex=function(self) return self.index end
    window.getSquare=function() return a end
    window.getOppositeSquare=function() return b end
    window.IsOpen=function(self) return self.open end
    window.isDestroyed=function(self) return self.destroyed end
    window.isSmashed=function(self) return self.smashed end
    window.isGlassRemoved=function(self) return self.removed end
    window.isBarricaded=function(self) return self.barricaded end
    window.canClimbThrough=function(self,p) assert(p==player); return self.climbable end
    local effects={queued={}, climbs=0, finished=0, blocked={}}
    local env={busy=function() return false end, authorized=function() return true end,
        createAction=function(p,w)
            assert(p==player and w==window)
            return {isValid=function() return true end,
                perform=function() effects.climbs=effects.climbs+1; return "performed" end}
        end,
        add=function(action) effects.queued[#effects.queued+1]=action;return true end,
        finishRejected=function() effects.finished=effects.finished+1 end,
        onBlocked=function(reason) effects.blocked[#effects.blocked+1]=reason end}
    return player,window,a,b,env,effects
end
instanceof=function(object,class) return object.class==class end

test("only an already open or explicitly cleared destroyed window is eligible",function()
    local p,w=fixture()
    assert(ClaudeWindowPolicy.inspect(p,w).allowed)
    w.open=false
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_closed_no_smashing")
    w.destroyed=true
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_glass_present_or_unknown")
    w.removed=true
    assert(ClaudeWindowPolicy.inspect(p,w).allowed)
end)

test("an open flag cannot bypass glass on a smashed window",function()
    local p,w=fixture();w.smashed=true
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_glass_present_or_unknown")
    w.removed=true;assert(ClaudeWindowPolicy.inspect(p,w).allowed)
    w.removed=nil;assert(not ClaudeWindowPolicy.inspect(p,w).allowed)
end)

test("adjacency must be an actual side of the window on the same floor",function()
    local p,w,a,b=fixture()
    p.square=b;assert(ClaudeWindowPolicy.inspect(p,w).destination==a)
    p.square={getZ=function() return 0 end}
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_not_adjacent")
    p.square=a;b.z=1
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_wrong_floor")
end)

test("removed targets and unreadable squares are rejected",function()
    local p,w=fixture();w.index=-1
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_target_removed")
    w.index=1;w.getOppositeSquare=function() return nil end
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_square_unknown")
end)

test("floor support and standable landing are required",function()
    local p,w,a,b=fixture();b.floor=false
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_landing_unsafe")
    b.floor=true;b.stand=false
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_landing_unsafe")
    b.stand=true;a.floor=false
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_landing_unsafe")
end)

test("glass under either side forbids traversal",function()
    local p,w,a,b=fixture();a.glass={}
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_floor_glass")
    a.glass=nil;b.glass={}
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_floor_glass")
end)

test("barricades, unavailable climb and unknown facts fail closed",function()
    local p,w=fixture();w.barricaded=true
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_barricaded_or_unknown")
    w.barricaded=false;w.climbable=false
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_climb_unavailable")
    w.climbable=true;w.open=nil
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_state_unknown")
    w.IsOpen=function() error("unavailable API") end
    assert(ClaudeWindowPolicy.inspect(p,w).reason=="window_facts_unavailable")
end)

test("unsupported types, absent targets and dead players cannot queue",function()
    local p,w,_,_,env,effects=fixture()
    assert(not ClaudeWindowPolicy.queue(nil,w,env))
    assert(not ClaudeWindowPolicy.queue(p,nil,env))
    w.class="IsoThumpable";assert(not ClaudeWindowPolicy.queue(p,w,env))
    w.class="IsoWindow";p.dead=true;assert(not ClaudeWindowPolicy.queue(p,w,env))
    assert(#effects.queued==0 and effects.climbs==0)
end)

test("rejection cannot create an action, walk, smash or clear a queue",function()
    local p,w,_,_,env,effects=fixture();w.open=false
    env.createAction=function() error("must not construct rejected work") end
    local ok,reason=ClaudeWindowPolicy.queue(p,w,env)
    assert(not ok and reason=="window_closed_no_smashing" and #effects.queued==0)
end)

test("busy and unknown queues remain untouched",function()
    local p,w,_,_,env,effects=fixture();env.busy=function() return true end
    local ok,reason=ClaudeWindowPolicy.queue(p,w,env)
    assert(not ok and reason=="window_body_busy" and #effects.queued==0)
    env.busy=function() return nil end
    ok,reason=ClaudeWindowPolicy.queue(p,w,env)
    assert(not ok and reason=="window_queue_unknown" and #effects.queued==0)
end)

test("missing, revoked or unreadable control authorization cannot queue",function()
    local p,w,_,_,env,effects=fixture();env.authorized=nil
    local ok,reason=ClaudeWindowPolicy.queue(p,w,env)
    assert(not ok and reason=="window_authorization_unavailable")
    env.authorized=function() return false end
    ok,reason=ClaudeWindowPolicy.queue(p,w,env)
    assert(not ok and reason=="window_control_revoked")
    env.authorized=function() error("lease could not be read") end
    ok,reason=ClaudeWindowPolicy.queue(p,w,env)
    assert(not ok and reason=="window_control_revoked" and #effects.queued==0)
end)

test("a retained queued action cannot climb after authority is revoked",function()
    local p,w,_,_,env,effects=fixture();local authorized=true
    env.authorized=function() return authorized end
    assert(ClaudeWindowPolicy.queue(p,w,env));local retained=effects.queued[1]
    assert(retained:isValid());authorized=false
    -- Simulate an unsuccessful queue clear: the original action still exists.
    assert(not retained:isValid() and retained.claudeWindowBlocked=="window_control_revoked")
    assert(retained:perform()==false and effects.climbs==0 and effects.finished==1)
end)

test("valid traversal queues one climb with no previous action retrigger",function()
    local p,w,_,_,env,effects=fixture()
    assert(ClaudeWindowPolicy.queue(p,w,env))
    assert(#effects.queued==1 and effects.climbs==0)
    local action=effects.queued[1]
    assert(action.retriggerLastAction==false and action:isValid())
    assert(action:perform()=="performed" and effects.climbs==1 and effects.finished==0)
end)

test("a changed window is refused by isValid and again immediately before perform",function()
    local p,w,_,_,env,effects=fixture()
    assert(ClaudeWindowPolicy.queue(p,w,env));local action=effects.queued[1]
    assert(action:isValid());w.open=false
    assert(not action:isValid())
    assert(action:perform()==false)
    assert(effects.climbs==0 and effects.finished==1 and action.claudeWindowBlocked=="window_closed_no_smashing")
end)

test("glass or an unsafe landing appearing after queueing cannot trigger a climb",function()
    for _,change in ipairs({function(_,b) b.glass={} end,function(_,b) b.floor=false end,
        function(w) w.smashed=true end,function(w) w.barricaded=true end}) do
        local p,w,_,b,env,effects=fixture()
        assert(ClaudeWindowPolicy.queue(p,w,env));change(w,b)
        assert(effects.queued[1]:perform()==false and effects.climbs==0 and effects.finished==1)
    end
end)

test("construction, vanilla validation and publication errors are reported",function()
    local p,w,_,_,env,effects=fixture();env.createAction=function() error("bad constructor") end
    local ok,reason=ClaudeWindowPolicy.queue(p,w,env)
    assert(not ok and reason=="window_action_unavailable" and #effects.queued==0)
    env.createAction=function() return {isValid=function() return false end,perform=function() error("unsafe") end} end
    ok,reason=ClaudeWindowPolicy.queue(p,w,env)
    assert(not ok and reason=="window_action_invalid" and #effects.queued==0)
    env.createAction=function() return {isValid=function() return true end,perform=function() error("unused") end} end
    env.add=function() error("publication failed") end
    ok,reason=ClaudeWindowPolicy.queue(p,w,env);assert(not ok and reason=="window_enqueue_failed")
end)

test("a silent enqueue refusal cannot report queued work",function()
    for _,add in ipairs({function() return nil end,function() return false end}) do
        local p,w,_,_,env,effects=fixture();env.add=add
        local ok,reason=ClaudeWindowPolicy.queue(p,w,env)
        assert(not ok and reason=="window_enqueue_refused" and #effects.queued==0 and effects.climbs==0)
    end
end)

test("default adapters use vanilla game actions without queue clearing",function()
    local p,w=fixture();local queue={queue={}};local climbs,completed,blocker=0,0,nil
    ISTimedActionQueue={getTimedActionQueue=function(player) assert(player==p);return queue end,
        isPlayerDoingAction=function(player) assert(player==p);return false end,
        add=function(action) queue.queue[#queue.queue+1]=action;return queue end,
        hasAction=function(action) return queue.queue[1]==action end,
        clear=function() error("policy must never clear") end}
    ISClimbThroughWindow={new=function(_,player,window,time)
        assert(player==p and window==w and time==0)
        return {isValid=function() return w.climbable end,perform=function() climbs=climbs+1 end}
    end}
    ISBaseTimedAction={perform=function() completed=completed+1 end}
    assert(ClaudeWindowPolicy.queue(p,w,nil,function(reason) blocker=reason end,function() return true end));w.open=false
    queue.queue[1]:perform();assert(climbs==0 and completed==1)
    assert(blocker=="window_closed_no_smashing","a late rejection was hidden from the body")
    w.open=true;queue.queue={}
    assert(ClaudeWindowPolicy.queue(p,w,nil,nil,function() return true end))
    local removed=queue.queue[1];local humanWork={human=true};queue.queue={humanWork};w.open=false
    removed:perform()
    assert(completed==1 and queue.queue[1]==humanWork,"a removed action completed unrelated replacement work")
end)

test("default startup busy check includes engine actions but is not repeated for the owned climb",function()
    local p,w=fixture();local queue={queue={}};local doing=true;local climbed=false
    ISTimedActionQueue={getTimedActionQueue=function() return queue end,
        isPlayerDoingAction=function() return doing end,
        add=function(action) queue.queue[#queue.queue+1]=action;return queue end,
        hasAction=function(action) return queue.queue[1]==action end}
    ISClimbThroughWindow={new=function() return {isValid=function() return true end,
        perform=function() climbed=true end} end}
    ISBaseTimedAction={perform=function() error("valid climb must not be rejected") end}
    local auth=function() return true end
    local ok,reason=ClaudeWindowPolicy.queue(p,w,nil,nil,auth)
    assert(not ok and reason=="window_body_busy" and #queue.queue==0)
    doing=nil;ok,reason=ClaudeWindowPolicy.queue(p,w,nil,nil,auth)
    assert(not ok and reason=="window_queue_unknown" and #queue.queue==0)
    doing=false;assert(ClaudeWindowPolicy.queue(p,w,nil,nil,auth))
    doing=true;assert(queue.queue[1]:isValid());queue.queue[1]:perform();assert(climbed)
end)

test("default enqueue requires both a returned queue and confirmed membership",function()
    local p,w=fixture();local queue={queue={}};local has=false;local returned=nil
    ISTimedActionQueue={getTimedActionQueue=function() return queue end,
        isPlayerDoingAction=function() return false end,
        add=function() return returned end,hasAction=function() return has end}
    ISClimbThroughWindow={new=function() return {isValid=function() return true end,perform=function() end} end}
    ISBaseTimedAction={perform=function() end}
    local auth=function() return true end
    local ok,reason=ClaudeWindowPolicy.queue(p,w,nil,nil,auth)
    assert(not ok and reason=="window_enqueue_refused")
    returned=queue;ok,reason=ClaudeWindowPolicy.queue(p,w,nil,nil,auth)
    assert(not ok and reason=="window_enqueue_refused")
    has=true;assert(ClaudeWindowPolicy.queue(p,w,nil,nil,auth))
end)

print("passed " .. count .. " window policy Lua tests")
