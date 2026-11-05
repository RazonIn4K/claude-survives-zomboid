-- Real navigation task with portable or installed vanilla path action.
local directory,official=assert(arg[1]),arg[2]
local count=0
local function derive(self,name) local child={Type=name};child.__index=child;setmetatable(child,{__index=self});return child end
local q,player,clock,permit,nativeBusy,result,safe,createMode,addMode,effects,skill,env,target,room
ISBaseTimedAction={derive=derive,new=function(self,p) return setmetatable({character=p},{__index=self}) end}
function ISBaseTimedAction:forceStop() self:stop() end
function ISBaseTimedAction:forceComplete() self:perform() end
function ISBaseTimedAction.perform(self)
    effects.perform=effects.perform+1
    for i,a in ipairs(q) do if a==self then table.remove(q,i);break end end
end
function ISBaseTimedAction.stop() effects.stop=effects.stop+1;q={} end
package.loaded["TimedActions/ISBaseTimedAction"]=true
BehaviorResult={Failed="failed",Succeeded="succeeded",Working="working"}
instanceof=function(object,name) return object==player and name=="IsoPlayer" end
if official then
    package.path=official.."/media/lua/client/?.lua;"..package.path
    require "Vehicles/TimedActions/ISPathFindAction"
else
    ISPathFindAction=ISBaseTimedAction:derive("ISPathFindAction")
    function ISPathFindAction:pathToLocationF(p,x,y,z)
        return setmetatable({character=p,goal={"LocationF",x,y,z}},{__index=self})
    end
    function ISPathFindAction:isValid() return true end
    function ISPathFindAction:start() self.character:getPathFindBehavior2():pathToLocationF(self.goal[2],self.goal[3],self.goal[4]) end
    function ISPathFindAction:update()
        local outcome=self.character:getPathFindBehavior2():update()
        if outcome==BehaviorResult.Failed then
            if self.onFailFunc then self.onFailFunc() end
            self:forceStop()
        elseif outcome==BehaviorResult.Succeeded then self:forceComplete() end
    end
    function ISPathFindAction:stop()
        ISBaseTimedAction.stop(self);self.character:getPathFindBehavior2():cancel();self.character:setPath2(nil)
    end
    function ISPathFindAction:perform()
        self.character:getPathFindBehavior2():cancel();self.character:setPath2(nil);ISBaseTimedAction.perform(self)
        if self.onCompleteFunc then self.onCompleteFunc() end
    end
    function ISPathFindAction:setOnFail(fn) self.onFailFunc=fn;self.onFailArgs={} end
    function ISPathFindAction:setOnComplete(fn) self.onCompleteFunc=fn;self.onCompleteArgs={} end
    function ISPathFindAction:setRunActionsAfterFailing(value) self.runActionsAfterFailing=value end
end
package.loaded["Vehicles/TimedActions/ISPathFindAction"]=true
dofile(directory.."/ClaudeNavigationSkill.lua")
local function reset()
    q,clock,permit,nativeBusy,result,safe={},1000,true,false,BehaviorResult.Working,true
    createMode,addMode="ok","ok";effects={cancel=0,perform=0,stop=0,start=0,update=0,clear=0,path2=0}
    room={}
    player={x=100.5,y=100.5,z=0,dead=false,pressedMovement=function() return false end,pressedCancelAction=function() return false end}
    function player:isDead() return self.dead end
    function player:getX() return self.x end
    function player:getY() return self.y end
    function player:getZ() return self.z end
    function player:setPath2() effects.path2=effects.path2+1 end
    local behavior={pathToLocationF=function() effects.start=effects.start+1 end,
        update=function() effects.update=effects.update+1;return result end,
        cancel=function() effects.cancel=effects.cancel+1 end}
    function player:getPathFindBehavior2() return behavior end
    env={now=function() return clock end,
        position=function(p) if p.dead then return nil end;return {x=p.x,y=p.y,z=p.z} end,
        state=function()
            local actions={};for i,a in ipairs(q) do actions[i]=a end
            return {actions=actions,busy=nativeBusy or #q>0}
        end,
        inspect=function() return safe,safe and nil or "unsafe_live_route",room end,
        create=function(p,t)
            if createMode=="refuse" then return {} end
            local a=ISPathFindAction:pathToLocationF(p,t.x,t.y,t.z)
            a.action={setPathfinding=function() end,setAllowedWhileDraggingCorpses=function() end}
            return a
        end,
        add=function(a)
            q[#q+1]=a;a:start()
            if addMode=="throw" then error("synthetic enqueue failure") end
            return addMode=="ok"
        end,
        cancelOwned=function(_,owned)
            for _,a in ipairs(q) do if a~=owned then return false end end
            if q[1] then q[1]:stop() end
            q={};nativeBusy=false;effects.clear=effects.clear+1;return true
        end}
    target={id=1,x=104.5,y=100.5,z=0}
    skill=ClaudeNavigationSkill.new(env)
end
local identity={world="w",actor="0",session="s"}
local function start() return skill:start(player,7,target,function() return permit end,identity) end
local function step(ms) clock=clock+(ms or 100);return skill:update() end
local function test(name,fn) reset();fn();count=count+1;print("ok "..name) end
test("native path acceptance is not arrival",function()
    assert(start() and #q==1 and effects.start==1)
    assert(skill.receipt.status=="pending" and q[1].runActionsAfterFailing==false)
end)
test("actual same-floor destination plus native idle establishes arrival",function()
    assert(start());player.x=target.x;player.y=target.y;result=BehaviorResult.Succeeded;q[1]:update();step()
    assert(skill.receipt.status=="arrived" and skill.receipt.finalX==target.x and skill.receipt.nativeResult=="completed")
end)
test("native completed callback away from target is no_effect",function()
    assert(start());result=BehaviorResult.Succeeded;q[1]:update();step()
    assert(skill.receipt.status=="no_effect" and skill.receipt.detail=="native_completion_without_arrival")
end)
test("native failure has a distinct terminal receipt",function()
    assert(start());result=BehaviorResult.Failed;q[1]:update();step()
    assert(skill.receipt.status=="no_effect" and skill.receipt.nativeResult=="failed" and effects.cancel==1)
end)
test("empty queue without arrival never succeeds",function()
    assert(start());q={};step();assert(skill.receipt.status=="no_effect")
end)
test("native busy delays arrival even with empty Lua queue",function()
    assert(start());player.x=target.x;q={};nativeBusy=true;step();assert(skill.receipt.status=="pending")
    nativeBusy=false;step();assert(skill.receipt.status=="arrived")
end)
test("manual takeover interrupts only owned navigation",function()
    assert(start());permit=false;step();assert(skill.receipt.status=="interrupted" and #q==0 and effects.cancel==1)
end)
test("retained callbacks cannot mutate successor work or receipt",function()
    assert(start());local old=q[1];skill:cancel("replacement");assert(start());local current=q[1]
    local cancel,perform,detail=effects.cancel,effects.perform,skill.receipt.detail
    assert(not old:isValid());old:start();old:update();old:stop();old:perform();old.onFailFunc();old.onCompleteFunc()
    assert(q[1]==current and effects.cancel==cancel and effects.perform==perform and skill.receipt.detail==detail)
end)
test("foreign replacement queue is never cleared",function()
    assert(start());local foreign={};q={foreign};step()
    assert(skill.receipt.status=="interrupted" and q[1]==foreign and effects.cancel==0 and effects.clear==0)
end)
test("initial and newly unsafe route facts fail closed",function()
    safe=false;assert(not start() and #q==0)
    assert(skill.receipt.startX==100.5 and skill.receipt.targetX==104.5)
    reset();assert(start());safe=false;step();assert(skill.receipt.status=="unverified" and #q==0)
end)
test("foreign work appended to the owned path cannot be cleared by retained stop",function()
    assert(start());local action=q[1];local foreign={};q[2]=foreign
    action:stop();action:update();assert(q[1]==action and q[2]==foreign and effects.cancel==0 and effects.stop==0)
    step();assert(skill.receipt.status=="interrupted" and q[2]==foreign and effects.clear==0)
end)
test("live safety checked before every native update",function()
    assert(start());local action=q[1];safe=false;action:update()
    assert(effects.update==0 and effects.cancel==1);step();assert(skill.receipt.status=="unverified")
end)
test("new floor and excessive excursion cannot finish",function()
    assert(start());player.z=1;step();assert(skill.receipt.status=="unverified")
    reset();assert(start());player.x=150;step();assert(skill.receipt.status=="unverified")
end)
test("unknown position or queue cannot establish progress",function()
    player.dead=true;assert(not start())
    reset();assert(start());env.state=function() return nil end;step();assert(skill.receipt.status=="unverified")
end)
test("no-progress deadline stops a live path",function()
    assert(start());step(10001);assert(skill.receipt.status=="unverified" and skill.receipt.detail=="navigation_no_progress")
end)
test("valid detour movement counts as progress without requiring decreasing distance",function()
    assert(start());player.x=99.5;step(9000);player.y=101.5;step(9000)
    assert(skill.receipt.status=="pending")
end)
test("task deadline remains bounded despite movement",function()
    assert(start());for i=1,6 do player.x=100.5+i*0.3;step(9000) end
    player.x=103;step(9000);assert(skill.receipt.status=="unverified" and skill.receipt.detail=="navigation_deadline")
end)
test("clock regression does not report arrival",function()
    assert(start());clock=999;skill:update();assert(skill.receipt.status=="unverified")
end)
test("potential enqueue side effects are unverified on refusal or exception",function()
    addMode="refuse";assert(not start() and skill.receipt.status=="unverified" and #q==0)
    reset();addMode="throw";assert(not start() and skill.receipt.status=="unverified" and #q==0)
end)
test("unknown native adapter or pre-existing work refuses before queue mutation",function()
    createMode="refuse";assert(not start() and #q==0)
    reset();nativeBusy=true;assert(not start() and #q==0)
end)
test("target copied at acceptance cannot change under a model or caller",function()
    assert(start());target.x=120;player.x=104.5;result=BehaviorResult.Succeeded;q[1]:update();step()
    assert(skill.receipt.status=="arrived" and skill.receipt.targetX==104.5)
end)
test("invalid distant or cross-floor targets cannot queue",function()
    target.id="1";assert(not start())
    reset();target.x=140;assert(not start())
    reset();target.z=1;assert(not start())
end)

-- Exercise the real default native-safety adapter with a bounded synthetic cell.
local function nativeFixture()
    local currentRoom={}
    local squares={};local bad={};local stepLength=0.1;local path=nil
    IsoObjectType={MAX="none"}
    IsoFlagType={HoppableW="hw",HoppableN="hn",TallHoppableW="tw",TallHoppableN="tn",WallW="ww",WallN="wn",WallWTrans="wt",WallNTrans="nt"}
    Vector2={new=function() return {length=0,getLength=function(self) return self.length end} end}
    function player:getDeferredMovement(vector) vector.length=stepLength;return vector end
    local function square(x,y,z)
        local key=x..":"..y..":"..z
        if squares[key] then return squares[key] end
        local s={x=x,y=y,z=z,room=currentRoom,flags={}}
        function s:getX() return self.x end
        function s:getY() return self.y end
        function s:getProperties() return {has=function(_,flag) return s.flags[flag] or false end} end
        function s:getZ() return self.z end
        function s:getRoom() return self.room end
        function s:canStand() return not self.standBlocked end
        function s:TreatAsSolidFloor() return not self.noFloor end
        function s:getBrokenGlass() return self.glass end
        function s:haveFire() return self.fire or false end
        function s:hasSlopedSurface() return self.slope or false end
        function s:isVehicleIntersecting() return self.vehicle or false end
        function s:getStairs() return self.stairs or IsoObjectType.MAX end
        for _,name in ipairs({"isWindowTo","isDoorTo","isWallTo","isBlockedTo","isHoppableTo"}) do
            s[name]=function(self) return self.edge or false end
        end
        for _,name in ipairs({"getWindowTo","getWindowThumpableTo","getWindowFrameTo","getDoorTo","getHoppableTo","getWallHoppableTo"}) do
            s[name]=function(self) return self.edgeObject end
        end
        squares[key]=s;return s
    end
    getCell=function() return {getGridSquare=function(_,x,y,z) if bad[x..":"..y..":"..z] then return nil end;return square(x,y,z) end} end
    function player:getCurrentSquare() return square(math.floor(self.x),math.floor(self.y),self.z) end
    function player:getPath2() return path end
    getTimestampMs=function() return clock end
    ISTimedActionQueue={getTimedActionQueue=function() return {queue=q} end,
        isPlayerDoingAction=function() return nativeBusy or #q>0 end,
        hasAction=function(a) for _,v in ipairs(q) do if v==a then return true end end;return false end,
        clear=function() if q[1] then q[1]:stop() end;q={} end,
        add=function(a)
            a.action={setPathfinding=function() end,setAllowedWhileDraggingCorpses=function() end}
            q[#q+1]=a;a:start();return {queue=q}
        end}
    local nativeSkill=ClaudeNavigationSkill.new()
    return nativeSkill,square,bad,function(n) stepLength=n end,function(p) path=p end
end
local function nativeStart(ns) return ns:start(player,8,target,function() return permit end,identity) end
test("default adapter accepts only known indoor clear floor",function()
    local ns=nativeFixture();assert(nativeStart(ns) and #q==1)
end)
test("default adapter refuses outdoor or changed-room targets",function()
    local ns,square=nativeFixture();square(100,100,0).room=nil;assert(not nativeStart(ns))
    reset();local ns,square=nativeFixture();square(104,100,0).room={};assert(not nativeStart(ns))
end)
test("first native path-ready frame cannot bypass nearby window or door edges",function()
    local ns,square=nativeFixture();assert(nativeStart(ns));square(100,100,0).edge=true
    q[1]:update();assert(effects.update==0 and effects.cancel==1)
end)
test("unknown or excessive deferred movement cannot start a native path",function()
    local ns,_,_,speed=nativeFixture();speed(0.51);assert(not nativeStart(ns))
    reset();local ns,_,_,speed=nativeFixture();speed(0/0);assert(not nativeStart(ns))
end)
test("all supported floor hazards are refused",function()
    for _,field in ipairs({"standBlocked","noFloor","glass","fire","slope","vehicle","stairs"}) do
        reset();local ns,square=nativeFixture();square(101,100,0)[field]=true
        assert(not nativeStart(ns),field)
    end
end)
test("unloaded neighbor and unreadable edge APIs fail closed",function()
    local ns,_,bad=nativeFixture();bad["101:100:0"]=true;assert(not nativeStart(ns))
    reset();local ns,square=nativeFixture();square(100,100,0).isWindowTo=nil;assert(not nativeStart(ns))
end)
test("already exposed path nodes cannot leave loaded safe room",function()
    local ns,_,_,_,setPath=nativeFixture()
    setPath({size=function() return 1 end,getNode=function() return {x=105,y=100,z=1} end})
    assert(not nativeStart(ns))
end)
test("default queue adapter refuses sparse foreign entries",function()
    local ns=nativeFixture();local foreign={};q={[2]=foreign}
    assert(not nativeStart(ns) and q[2]==foreign)
end)
test("native wall and fence flags cannot bypass otherwise clear edge helpers",function()
    for _,name in ipairs({"HoppableW","HoppableN","TallHoppableW","TallHoppableN","WallW","WallN","WallWTrans","WallNTrans"}) do
        reset();local ns,square=nativeFixture();assert(nativeStart(ns))
        square(101,100,0).flags[IsoFlagType[name]]=true
        q[1]:update();assert(effects.update==0 and effects.cancel==1,name)
    end
end)
test("position neighborhood must match Java current-square coordinates",function()
    for _,offset in ipairs({{1,0},{0,1}}) do
        reset();local ns,square=nativeFixture()
        player.getCurrentSquare=function() return square(100+offset[1],100+offset[2],0) end
        assert(not nativeStart(ns) and effects.update==0)
    end
end)
test("mixed queue cancels only current path and blocks new navigation until idle",function()
    local ns=nativeFixture();assert(nativeStart(ns));local own=q[1];local foreign={}
    q[2]=foreign;ns:cancel("foreign_work_appended")
    assert(effects.cancel==1 and q[1]==own and q[2]==foreign)
    assert(ns.receipt.status=="interrupted" and ns.receipt.detail:find("cleanup_unverified",1,true))
    own:stop();assert(effects.cancel==2 and q[2]==foreign)
    assert(not nativeStart(ns) and q[2]==foreign)
end)
test("deferred completion cannot advance foreign work appended after native success",function()
    local ns=nativeFixture();assert(nativeStart(ns));local own=q[1];local deferred=false;local began=false
    own.forceComplete=function() deferred=true end
    result=BehaviorResult.Succeeded;own:update();assert(deferred and effects.perform==0)
    local foreign={begin=function() began=true end};q[2]=foreign
    own:perform()
    assert(effects.cancel==1 and effects.perform==0 and q[1]==own and q[2]==foreign and not began)
    ns:update();assert(ns.receipt.status=="interrupted" and q[2]==foreign)
end)
print("passed "..count.." navigation skill Lua tests"..(official and " with installed native path action" or " with portable path fixture"))
