require "Vehicles/TimedActions/ISPathFindAction"
-- Return to an observed location, with measured arrival and one queue owner.
-- Native pathfinding can interact with doors/windows/fences. This first slice
-- refuses such nearby edges; it is not a general traversal/navigation system.
ClaudeNavigationSkill = {}
local function finite(n) return type(n)=="number" and n==n and n>-math.huge and n<math.huge end
local function integer(n,low,high) return finite(n) and n==math.floor(n) and n>=low and n<=high end
local function position(p)
    if not p or p:isDead()~=false then return nil end
    local x,y,z=p:getX(),p:getY(),p:getZ()
    if not finite(x) or not finite(y) or math.abs(x)>1000000 or math.abs(y)>1000000
        or not integer(z,-100,100) then return nil end
    return {x=x,y=y,z=z}
end
local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local function queueState(p)
    local q=ISTimedActionQueue.getTimedActionQueue(p)
    local native=ISTimedActionQueue.isPlayerDoingAction(p)
    if not q or type(q.queue)~="table" or type(native)~="boolean" then return nil end
    local actions,count={},0
    for index,action in pairs(q.queue) do
        if not integer(index,1,512) or type(action)~="table" then return nil end
        count=count+1
    end
    for i=1,count do if not q.queue[i] then return nil end;actions[i]=q.queue[i] end
    return {actions=actions,busy=native or count>0}
end

local function squareSafe(square,z,room)
    if not square then return false end
    local properties=square:getProperties()
    if not properties or not IsoFlagType then return false end
    -- Native tall-wall climbing reads these flags directly. Do not depend on
    -- edge helper equivalence to exclude that separate interaction branch.
    for _,name in ipairs({"HoppableW","HoppableN","TallHoppableW","TallHoppableN","WallW","WallN","WallWTrans","WallNTrans"}) do
        local flag=IsoFlagType[name]
        if flag==nil or properties:has(flag)~=false then return false end
    end
    return square:getZ()==z and square:getRoom()==room
        and square:canStand()==true and square:TreatAsSolidFloor()==true
        and square:getBrokenGlass()==nil and square:haveFire()==false
        and square:hasSlopedSurface()==false and square:isVehicleIntersecting()==false
        and IsoObjectType and IsoObjectType.MAX and square:getStairs()==IsoObjectType.MAX
end
local function edgeSafe(a,b)
    return a:isWindowTo(b)==false and a:isDoorTo(b)==false and a:isWallTo(b)==false
        and a:isBlockedTo(b)==false and a:isHoppableTo(b)==false
        and a:getWindowTo(b)==nil and a:getWindowThumpableTo(b)==nil
        and a:getWindowFrameTo(b)==nil and a:getDoorTo(b)==nil
        and a:getHoppableTo(b)==nil and a:getWallHoppableTo(b)==nil
end
local function nativeInspect(p,target,start,room)
    local current=position(p)
    if not current then return false,"navigation_position_unknown" end
    if current.z~=target.z or current.z~=start.z then return false,"navigation_floor_changed" end
    if distance(current,start)>48 then return false,"navigation_excursion_limit" end
    local square=p:getCurrentSquare()
    if not square or square:getZ()~=current.z or square:getX()~=math.floor(current.x)
        or square:getY()~=math.floor(current.y) then return false,"navigation_square_unknown" end
    if room==nil then room=square:getRoom() end
    if not room then return false,"navigation_indoor_room_required" end
    if square:getRoom()~=room then return false,"navigation_room_changed" end
    local cell=getCell()
    if not squareSafe(cell:getGridSquare(math.floor(target.x),math.floor(target.y),target.z),target.z,room) then
        return false,"navigation_target_unsafe_or_different_room"
    end
    -- B42.21 native update() uses deferred animation movement length with a
    -- factor of one; its obstacle probe is max(0.5,length). Refuse larger or
    -- unreadable values before every native update, including its first path-
    -- ready frame. No possible probe/step can leave the freshly checked 3x3.
    local vector=Vector2.new()
    p:getDeferredMovement(vector)
    local movement=vector:getLength()
    if not finite(movement) or movement<0 or movement>0.5 then return false,"navigation_movement_bound_unknown" end
    local squares={}
    local px,py=math.floor(current.x),math.floor(current.y)
    for dx=-1,1 do for dy=-1,1 do
        local candidate=cell:getGridSquare(px+dx,py+dy,current.z)
        if not squareSafe(candidate,current.z,room) then return false,"navigation_local_floor_or_room_unsafe" end
        squares[(dx+1)*3+dy+2]=candidate
    end end
    for dx=-1,1 do for dy=-1,1 do
        local a=squares[(dx+1)*3+dy+2]
        if dx<1 then
            local b=squares[(dx+2)*3+dy+2]
            if not edgeSafe(a,b) or not edgeSafe(b,a) then return false,"navigation_local_edge_requires_traversal" end
        end
        if dy<1 then
            local b=squares[(dx+1)*3+dy+3]
            if not edgeSafe(a,b) or not edgeSafe(b,a) then return false,"navigation_local_edge_requires_traversal" end
        end
    end end
    -- getPath2 is not available before the first path-ready native update.
    -- The local movement/edge guard above covers that frame. When exposed,
    -- reject path nodes outside this same safe floor/room and bounded region.
    local path=p:getPath2()
    if path then
        local size=path:size()
        if not integer(size,0,128) then return false,"navigation_path_unknown" end
        for i=0,size-1 do
            local node=path:getNode(i)
            if not node or not finite(node.x) or not finite(node.y) or node.z~=target.z
                or distance(node,start)>48
                or not squareSafe(cell:getGridSquare(math.floor(node.x),math.floor(node.y),node.z),node.z,room) then
                return false,"navigation_path_leaves_supported_area"
            end
        end
    end
    return true,nil,room
end
local function defaults()
    local function cancelPath(p)
        p:getPathFindBehavior2():cancel()
        p:setPath2(nil)
        return true
    end
    return {
        now=function() return tonumber(getTimestampMs()) end,position=position,state=queueState,inspect=nativeInspect,
        create=function(p,t) return ISPathFindAction:pathToLocationF(p,t.x,t.y,t.z) end,
        cancelPath=cancelPath,
        add=function(action)
            local q=ISTimedActionQueue.add(action)
            return q~=nil and q~=false and ISTimedActionQueue.hasAction(action)==true
        end,
        cancelOwned=function(p,action)
            local q=queueState(p)
            if not q then return false end
            if #q.actions==0 then return not q.busy end
            for _,a in ipairs(q.actions) do if a~=action then
                -- Preserve mixed queue entries, cancel only the still-current
                -- native path, and leave full cleanup explicitly unverified.
                if q.actions[1]==action then cancelPath(p) end
                return false
            end end
            ISTimedActionQueue.clear(p)
            local after=queueState(p)
            return after~=nil and not after.busy
        end,
    }
end

function ClaudeNavigationSkill.new(env)
    env=env or defaults()
    local self={task=nil,receipt=nil}
    local function owns(task)
        local ok,q=pcall(env.state,task.player)
        return ok and q and q.actions[1]==task.action
    end
    local function ownsAlone(task)
        local ok,q=pcall(env.state,task.player)
        return ok and q and #q.actions==1 and q.actions[1]==task.action
    end
    local function authority(task)
        local ok,value=pcall(task.authority)
        return ok and value==true and self.task==task and self.receipt and self.receipt.status=="pending"
    end
    local function finish(task,status,reason,cleanup)
        if self.task~=task or not self.receipt or self.receipt.status~="pending" then return end
        self.receipt.status,self.receipt.detail=status,tostring(reason)
        if cleanup then
            local ok,stopped=pcall(env.cancelOwned,task.player,task.action)
            if not ok or stopped~=true then self.receipt.detail=self.receipt.detail..";owned_cleanup_unverified" end
        end
    end
    local function validate(task)
        if not authority(task) then return false,"navigation_control_revoked" end
        local ok,allowed,reason,room=pcall(env.inspect,task.player,task.target,task.start,task.room)
        if not ok or allowed~=true then return false,ok and reason or "navigation_facts_unavailable" end
        task.room=room
        return true
    end
    function self:cancel(reason)
        if self.task then finish(self.task,"interrupted",reason or "navigation_interrupted",true) end
    end
    function self:start(player,sequence,target,authorized,identity)
        self:cancel("navigation_superseded")
        local task={player=player,authority=authorized,target={}}
        self.task=task
        self.receipt={seq=sequence,action="NAVIGATE",targetId=type(target)=="table" and integer(target.id,1,2147483647) and target.id or -1,
            world=identity.world,actor=identity.actor,session=identity.session,status="pending",phase="validate",
            detail="checking_visited_destination",nativeResult="none",added=0,hungerDrop=0,thirstDrop=0}
        local ok,reason=pcall(function()
            task.started=env.now()
            if not finite(task.started) then return "navigation_clock_unknown" end
            if type(authorized)~="function" or not authority(task) then return "navigation_control_revoked" end
            if type(target)~="table" or not integer(target.id,1,2147483647) or not finite(target.x)
                or not finite(target.y) or math.abs(target.x)>1000000 or math.abs(target.y)>1000000
                or not integer(target.z,-100,100) then return "navigation_target_unknown" end
            task.target={id=target.id,x=target.x,y=target.y,z=target.z}
            task.start=env.position(player)
            if not task.start then return "navigation_position_unknown" end
            if task.start.z~=target.z or distance(task.start,target)>32 then return "navigation_target_out_of_range" end
            local q=env.state(player)
            if not q or q.busy then return "navigation_body_busy_or_unknown" end
            local receipt=self.receipt
            receipt.startX,receipt.startY,receipt.startZ=task.start.x,task.start.y,task.start.z
            receipt.targetX,receipt.targetY,receipt.targetZ=target.x,target.y,target.z
            receipt.distanceRemaining=distance(task.start,target)
            local valid,blocker=validate(task)
            if not valid then return blocker end
            task.lastProgress,task.progressPosition=task.started,task.start
            if receipt.distanceRemaining<=0.35 then
                receipt.finalX,receipt.finalY,receipt.finalZ=task.start.x,task.start.y,task.start.z
                finish(task,"arrived","already_at_observed_destination",false);return
            end
            local action=env.create(player,task.target)
            if type(action)~="table" then return "navigation_action_unavailable" end
            for _,name in ipairs({"isValid","start","update","stop","perform","setOnFail","setOnComplete","setRunActionsAfterFailing"}) do
                if type(action[name])~="function" then return "navigation_action_unavailable" end
            end
            task.action=action
            local original={isValid=action.isValid,start=action.start,update=action.update,stop=action.stop,perform=action.perform}
            local function blocked(reason)
                if self.task==task and self.receipt.status=="pending" then
                    task.blocked=reason;self.receipt.detail=tostring(reason)
                end
            end
            action.isValid=function(a)
                local allowed,why=validate(task)
                if not allowed then blocked(why);return false end
                local readable,value=pcall(original.isValid,a)
                if not readable or value~=true then blocked("navigation_native_invalid");return false end
                return true
            end
            action.start=function(a)
                if not owns(task) or not a:isValid() then return end
                task.nativeStarted=true
                local started=pcall(original.start,a)
                if not started then blocked("navigation_native_start_failed") end
            end
            action.update=function(a)
                if not owns(task) then return end
                if not ownsAlone(task) then
                    blocked("navigation_foreign_work_queued")
                    pcall(env.cancelPath,task.player)
                    return
                end
                if not a:isValid() then
                    if ownsAlone(task) then pcall(original.stop,a) end
                    return
                end
                local updated=pcall(original.update,a)
                if not updated then blocked("navigation_native_update_failed") end
            end
            action.stop=function(a)
                if not ownsAlone(task) then
                    if owns(task) then pcall(env.cancelPath,task.player) end
                    return
                end
                task.nativeStopped=true
                return original.stop(a)
            end
            action.perform=function(a)
                if not owns(task) then return end
                if not ownsAlone(task) then
                    blocked("navigation_foreign_work_queued")
                    pcall(env.cancelPath,task.player)
                    return
                end
                if not a:isValid() then return end
                return original.perform(a)
            end
            action:setRunActionsAfterFailing(false)
            action:setOnFail(function()
                if authority(task) then self.receipt.nativeResult="failed";task.failed=true end
            end)
            action:setOnComplete(function()
                if authority(task) then self.receipt.nativeResult="completed";task.completed=true end
            end)
            receipt.phase,receipt.detail="path","following_supported_native_path"
            task.enqueueAttempted=true
            if env.add(action)~=true then return "navigation_enqueue_refused" end
        end)
        if not ok or reason then
            finish(task,task.enqueueAttempted and "unverified" or "no_effect",ok and reason or "navigation_start_facts_unavailable",true)
            return false,self.receipt.detail
        end
        return true,self.receipt.detail
    end
    function self:update()
        local task,receipt=self.task,self.receipt
        if not task or not receipt or receipt.status~="pending" then return receipt end
        local ok,reason=pcall(function()
            local now=env.now()
            if not finite(now) or now<task.started then return "navigation_clock_invalid" end
            if not authority(task) then self:cancel("navigation_control_revoked");return end
            if now-task.started>60000 then return "navigation_deadline" end
            local current=env.position(task.player)
            if not current then return "navigation_position_unknown" end
            receipt.finalX,receipt.finalY,receipt.finalZ=current.x,current.y,current.z
            receipt.distanceRemaining=distance(current,task.target)
            if current.z~=task.start.z or distance(current,task.start)>48 then return "navigation_floor_or_excursion_changed" end
            if distance(current,task.progressPosition)>=0.25 then task.progressPosition=current;task.lastProgress=now end
            local q=env.state(task.player)
            if not q then return "navigation_queue_unknown" end
            for _,a in ipairs(q.actions) do if a~=task.action then self:cancel("navigation_queue_replaced");return end end
            if task.blocked then return task.blocked end
            if q.busy then
                local valid,blocker=validate(task)
                if not valid then return blocker end
                if now-task.lastProgress>10000 then return "navigation_no_progress" end
                return
            end
            receipt.phase="verify"
            local valid,blocker=validate(task)
            if not valid then return blocker end
            if receipt.distanceRemaining<=0.35 and current.z==task.target.z then
                finish(task,"arrived","raw_position_and_idle_arrival_observed",false)
            elseif task.failed then finish(task,"no_effect","navigation_native_failed",false)
            elseif task.completed then finish(task,"no_effect","native_completion_without_arrival",false)
            else finish(task,"no_effect","queue_empty_without_arrival",false) end
        end)
        if not ok or reason then finish(task,"unverified",ok and reason or "navigation_runtime_facts_unavailable",true) end
        return receipt
    end
    return self
end

return ClaudeNavigationSkill
