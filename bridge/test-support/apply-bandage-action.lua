-- Behavior fixtures; optional argument loads the installed native parent.
local directory,official=assert(arg[1]),arg[2]
local mode,queue,effects,count="client",{},nil,0
local clock=1000
getTimestampMs=function() return clock end
local function test(name,fn) fn();count=count+1;print("ok "..name) end
local function derive(self,name)
    local child={Type=name};child.__index=child;setmetatable(child,{__index=self});return child
end
local function vector(items) return {size=function() return #items end,get=function(_,i) return items[i+1] end} end
ISBaseTimedAction={derive=derive}
function ISBaseTimedAction:new(character) return setmetatable({character=character},{__index=self}) end
function ISBaseTimedAction.perform(self)
    effects.performed=effects.performed+1
    for i,action in ipairs(queue) do if action==self then table.remove(queue,i);break end end
end
function ISBaseTimedAction.stop() effects.stopped=effects.stopped+1;queue={} end
function ISBaseTimedAction:getJobDelta() return 0.5 end
function ISBaseTimedAction:setActionAnim() effects.animation=effects.animation+1 end
function ISBaseTimedAction:setAnimVariable() end
function ISBaseTimedAction:setOverrideHandModels() end
local base=ISBaseTimedAction
if official then
    package.path=official.."/media/lua/shared/?.lua;"..package.path
    require "TimedActions/ISApplyBandage"
    for _,name in ipairs({"perform","stop","getJobDelta","setActionAnim","setAnimVariable","setOverrideHandModels"}) do
        ISBaseTimedAction[name]=base[name]
    end
else
    ISApplyBandage=ISBaseTimedAction:derive("ISApplyBandage")
    function ISApplyBandage:new(character,otherPlayer,item,bodyPart,doIt)
        local action=ISBaseTimedAction.new(self,character)
        action.character,action.otherPlayer,action.item,action.bodyPart,action.doIt=character,otherPlayer,item,bodyPart,doIt
        action.doctorLevel=character:getPerkLevel(Perks.Doctor)
        action.maxTime=action:getDuration()
        return action
    end
    function ISApplyBandage:start()
        if isClient() then self.item=self.character:getInventory():getItemById(self.item:getID()) end
        self:setActionAnim("Bandage");self.item:setJobDelta(0);self.sound=1
    end
    function ISApplyBandage:update()
        self.item:setJobDelta(self:getJobDelta())
        ISHealthPanel.setBodyPartActionForPlayer(self.otherPlayer,self.bodyPart,self,"Bandage",{})
    end
    function ISApplyBandage:serverStart()
        if self.bodyPart:manipulatingUsername()==nil or self.bodyPart:manipulatingUsername()=="" then
            self.bodyPart:setManipulatingUsername(self.character:getUsername())
        end
    end
    function ISApplyBandage:serverStop() self.bodyPart:setManipulatingUsername(nil) end
    function ISApplyBandage:stopSound() end
    function ISApplyBandage:complete()
        if isServer() and self.bodyPart:manipulatingUsername()~="" and self.bodyPart:manipulatingUsername()~=self.character:getUsername() then return false end
        self.otherPlayer:getBodyDamage():SetBandaged(self.bodyPart:getIndex(),true,5,false,self.item:getModule().."."..self.item:getType())
        self.character:getInventory():Remove(self.item)
        self.bodyPart:setManipulatingUsername(nil)
        syncBodyPart(self.bodyPart,0)
        return true
    end
end
package.loaded["TimedActions/ISApplyBandage"]=true
package.loaded["ClaudeTreatmentFacts"]=true
isServer=function() return mode=="server" end
isClient=function() return mode=="client" end
Perks={Doctor="doctor"}
BodyPartType={MAX=17,Groin=12,ToIndex=function(value) return value end}
CharacterActionAnims={Bandage="Bandage"}
Metabolics={LightDomestic="light"}
CharacterTrait={HEMOPHOBIC="hemophobic"}
CharacterStat={PANIC="panic"}
getText=function(text) return text end
ZombRandFloat=function(a) return a end
addXp=function() effects.xp=effects.xp+1 end
syncPlayerStats=function() effects.statSync=effects.statSync+1 end
syncBodyPart=function() effects.bodySync=effects.bodySync+1 end
sendRemoveItemFromContainer=function() effects.itemSync=effects.itemSync+1 end
ISTimedActionQueue={hasAction=function(action)
    for _,a in ipairs(queue) do if a==action then return true end end;return false
end,getTimedActionQueue=function() return {queue=queue} end}
ClaudeTreatmentFacts={inspectWound=function(player,part)
    if not part or part.parent~=player or not part.eligible or part.dressed then return {allowed=false,reason="wound_unsupported"} end
    return {allowed=true,index=part.index}
end,inspectSupply=function(player,item)
    if not item or item.container~=player.inventory or not item.allowed or item.used then return {allowed=false,reason="supply_unsupported"} end
    return {allowed=true,key=item.key}
end}
dofile(directory.."/TimedActions/ClaudeApplyBandageAction.lua")

local function fixture()
    mode,queue="client",{}
    clock=1000
    effects={bandage=0,removed=0,bodySync=0,itemSync=0,statSync=0,xp=0,animation=0,performed=0,stopped=0,locks=0,ui=0,blocked={}}
    local p={dead=false,driving=false,doctor=3,username="admin",permit=true}
    function p:isDead() return self.dead end
    function p:isDriving() return self.driving end
    function p:getUsername() return self.username end
    function p:getPerkLevel() return self.doctor end
    function p:isTimedActionInstant() return false end
    function p:getX() return 100 end
    function p:getY() return 100 end
    function p:hasTrait() return false end
    function p:reportEvent() end
    function p:playSound() return 1 end
    function p:playerVoiceSound() return 2 end
    function p:getEmitter() return {isPlaying=function() return false end} end
    function p:setMetabolicTarget() end
    local part={parent=p,index=3,eligible=true,dressed=false,life=0,bandageType=nil,lock=nil}
    function part:getIndex() return self.index end
    function part:getType() return self.index end
    function part:getParentChar() return self.parent end
    function part:bandaged() return self.dressed end
    function part:HasInjury() return self.eligible end
    function part:manipulatingUsername() return self.lock end
    function part:setManipulatingUsername(value) self.lock=value;effects.locks=effects.locks+1 end
    function part:getBandageLife() return self.life end
    function part:getBandageType() return self.bandageType end
    function part:getBleedingTime() return 10 end
    function part:isGetBandageXp() return false end
    function part:SetInfected() effects.infected=true end
    local parts={};for i=1,17 do parts[i]={} end;parts[4]=part
    local body={getBodyParts=function() return vector(parts) end}
    function body:SetBandaged(index,dressed,life,alcoholic,kind)
        assert(index==part.index);effects.bandage=effects.bandage+1
        part.dressed,part.life,part.bandageType=dressed,life,kind
        if effects.throwAfterBandage then error("synthetic partial native failure") end
    end
    p.getBodyDamage=function() return body end
    local inv={items={}}
    function inv:getItems() return vector(self.items) end
    function inv:contains(item) for _,v in ipairs(self.items) do if v==item then return true end end;return false end
    function inv:getItemById(id)
        if self.alias then return self.alias end
        for _,item in ipairs(self.items) do if item.id==id then return item end end
        return nil
    end
    function inv:Remove(item)
        effects.removed=effects.removed+1
        for i,v in ipairs(self.items) do if v==item then table.remove(self.items,i);break end end
        item.container=nil;item.used=true
    end
    p.inventory=inv;p.getInventory=function() return inv end
    local item={id=9,key="item:9",allowed=true,container=inv,used=false,job=0}
    function item:getID() return self.id end
    function item:getContainer() return self.container end
    function item:getModule() return "Base" end
    function item:getType() return "Bandage" end
    function item:getBandagePower() return 4 end
    function item:isAlcoholic() return false end
    function item:isInfected() return false end
    function item:setJobDelta(value) self.job=value end
    function item:setJobType() end
    inv.items={item}
    ISHealthPanel={DidPatientMove=function() return false end,getBandageType=function() return "Arm" end,
        setBodyPartActionForPlayer=function(_,bodyPart,action) effects.ui=effects.ui+1;bodyPart.ui=action end}
    local action=ClaudeApplyBandageAction:new(p,p,item,part,true,item.key,part.index)
    action.claudeAuthorized=function() return p.permit end
    action.claudeOnBlocked=function(reason) effects.blocked[#effects.blocked+1]=reason end
    queue={action}
    return action,p,part,item,inv
end
local function beginServer(action) mode="server";action.claudeAuthorized=nil;action:serverStart() end

test("constructor stores all explicit network fields and native doctor level",function()
    local a,p,part,item=fixture()
    assert(a.Type=="ClaudeApplyBandageAction" and a.character==p and a.otherPlayer==p and a.item==item and a.bodyPart==part)
    assert(a.doIt==true and a.itemKey=="item:9" and a.partIndex==3 and a.doctorLevel==3 and a.maxTime==108)
end)
test("client requires lease before starting native animation",function()
    local a,p=fixture();p.permit=false;a:start();assert(effects.animation==0 and not a:isValid())
end)
test("missing client callback cannot authorize treatment",function()
    local a=fixture();a.claudeAuthorized=nil;a:start();assert(effects.animation==0 and not a:isValid())
end)
test("separate reconstructed server action recomputes local guard fields",function()
    local client,p,part,item=fixture()
    local fields={"character","otherPlayer","item","bodyPart","doIt","itemKey","partIndex"}
    for _,name in ipairs(fields) do assert(rawget(client,name)~=nil) end
    mode="server"
    local reconstructed=ClaudeApplyBandageAction:new(client.character,client.otherPlayer,client.item,
        client.bodyPart,client.doIt,client.itemKey,client.partIndex)
    assert(reconstructed~=client and reconstructed.claudeAuthorized==nil and reconstructed.claudeAttempted==nil)
    reconstructed:serverStart();assert(reconstructed:complete())
    assert(reconstructed.claudeSucceeded and client.claudeAttempted==nil and item:getContainer()==nil and part:bandaged())
end)
test("server freshly treats and consumes exact supply without client callback",function()
    local a,p,part,item,inv=fixture();beginServer(a)
    assert(part.lock==nil and effects.locks==0)
    assert(a:complete() and part.dressed and item:getContainer()==nil and inv:getItemById(9)==nil)
    assert(effects.bandage==1 and effects.removed==1 and effects.bodySync==1)
end)
test("server treatment does not depend on client health panel UI",function()
    local a=fixture();ISHealthPanel=nil;beginServer(a);assert(a:complete())
end)
test("server requires native action to have begun",function()
    local a=fixture();mode="server";a.claudeAuthorized=nil
    assert(not a:complete() and effects.bandage==0)
end)
test("client cannot directly perform medical effects",function()
    local a=fixture();a:start();assert(not a:complete() and effects.bandage==0 and effects.removed==0)
end)
test("singleplayer uses native completion with live authority",function()
    local a,p=fixture();mode="single";a:start();assert(a:complete() and effects.bandage==1)
    local b,p2=fixture();mode="single";b:start();p2.permit=false;assert(not b:complete() and effects.bandage==0)
end)
test("wound change before complete blocks all medical mutation",function()
    local a,_,part=fixture();beginServer(a);part.eligible=false
    assert(not a:complete() and effects.bandage==0 and effects.removed==0)
end)
test("already bandaged target cannot consume another supply",function()
    local a,_,part=fixture();beginServer(a);part.dressed=true
    assert(not a:complete() and effects.removed==0)
end)
test("foreign or nested inventory supply cannot be consumed",function()
    local a,_,_,item=fixture();beginServer(a);item.container={}
    assert(not a:complete() and effects.removed==0)
end)
test("unsafe supply change is rechecked at completion",function()
    local a,_,_,item=fixture();beginServer(a);item.allowed=false
    assert(not a:complete() and effects.bandage==0)
end)
test("supply ID change cannot inherit authorization",function()
    local a,_,_,item=fixture();beginServer(a);item.key="item:10"
    assert(not a:complete() and effects.removed==0)
end)
test("body part index change is refused",function()
    local a,_,part=fixture();beginServer(a);part.index=4
    assert(not a:complete() and effects.bandage==0)
end)
test("dead or driving survivor cannot complete",function()
    local a,p=fixture();beginServer(a);p.dead=true;assert(not a:complete() and effects.bandage==0)
    local b,q=fixture();beginServer(b);q.driving=true;assert(not b:complete() and effects.bandage==0)
end)
test("another healer may win during animation and blocks completion",function()
    local a,_,part=fixture();beginServer(a);part.lock="doctor"
    assert(not a:complete() and part.lock=="doctor" and effects.bandage==0)
end)
test("same username native work is not mistaken for our lock",function()
    local a,p,part=fixture();beginServer(a);part.lock=p.username
    assert(not a:complete() and part.lock==p.username and effects.bandage==0)
end)
test("empty native lock retains normal nonzero duration",function()
    local a,p,part,item=fixture();part.lock=""
    local b=ClaudeApplyBandageAction:new(p,p,item,part,true,item.key,3)
    assert(not b.claudeBlocked and b.maxTime==108)
end)
test("duplicate complete is idempotent after native effect",function()
    local a=fixture();beginServer(a);assert(a:complete());assert(a:complete())
    assert(effects.bandage==1 and effects.removed==1 and effects.bodySync==1)
end)
test("fractional or changed IDs cannot satisfy original consumption identity",function()
    local a,_,_,item=fixture();beginServer(a);assert(a:complete());item.id=9.2
    assert(not a:complete() and effects.bandage==1 and effects.removed==1)
    local b,_,_,supply=fixture();beginServer(b);supply.id=9.2
    assert(not b:complete() and effects.bandage==0 and effects.removed==0)
end)
test("partial native failure cannot repeat effects and releases only synchronous lock",function()
    local a,_,part=fixture();beginServer(a);effects.throwAfterBandage=true
    assert(not a:complete() and effects.bandage==1 and effects.removed==0 and part.lock==nil)
    assert(not a:complete() and effects.bandage==1)
end)
test("delayed serverStop never clears replacement healer locks",function()
    local a,p,part=fixture();beginServer(a);part.lock=p.username;a:serverStop()
    assert(part.lock==p.username);part.lock="different-doctor";a:serverStop();assert(part.lock=="different-doctor")
end)
test("retained client callbacks preserve replacement queue and UI state",function()
    local a,_,part,item=fixture();a:start();a:update()
    local replacement={bodyPart=part,item=item};queue={replacement};part.ui=replacement;item.job=0.8
    a:stop();a:perform();assert(queue[1]==replacement and part.ui==replacement and item.job==0.8)
    assert(effects.performed==0 and effects.stopped==0)
end)
test("legitimate removed client action clears its own progress",function()
    local a,_,part,item=fixture();a:start();a:update();queue={};a:stop()
    assert(item.job==0 and part.ui==nil and effects.stopped==0)
end)
test("new custom action takes progress ownership from retained old callbacks",function()
    local a,p,part,item=fixture();a:start();a:update();queue={}
    local b=ClaudeApplyBandageAction:new(p,p,item,part,true,item.key,part.index)
    b.claudeAuthorized=function() return true end;queue={b};b:start();b:update();item.job=0.6
    a:stop();a:perform();assert(part.ui==b and item.job==0.6 and queue[1]==b)
    b:stop();assert(part.ui==nil and item.job==0)
end)
test("replicated completion is recognized before client queue acknowledgement",function()
    local a,p,part,item,inv=fixture();a:start();a:update()
    part.dressed,part.life,part.bandageType=true,5,"Base.Bandage";inv.items={};item.container=nil
    assert(a:isValid() and a.claudeReplicatedComplete);a:perform()
    assert(effects.performed==1 and effects.bandage==0)
end)
test("moved nested item cannot count as replicated consumption",function()
    local a,_,part,item,inv=fixture();a:start()
    part.dressed,part.life,part.bandageType=true,5,"Base.Bandage";inv.items={};item.container={}
    assert(not a:isValid() and not a.claudeReplicatedComplete)
end)
test("matching dressing may replicate before exact supply removal",function()
    local a,_,part,item,inv=fixture();a:start()
    part.dressed,part.life,part.bandageType=true,5,"Base.Bandage"
    assert(a:isValid() and a.claudeReplicationPending and not a.claudeBlocked)
    inv.items={};item.container=nil;clock=clock+200
    assert(a:isValid() and a.claudeReplicatedComplete and not a.claudeBlocked)
    a:perform();assert(effects.performed==1)
end)
test("supply removal may replicate before matching dressing",function()
    local a,_,part,item,inv=fixture();a:start();inv.items={};item.container=nil
    assert(a:isValid() and a.claudeReplicationPending and not a.claudeBlocked)
    part.dressed,part.life,part.bandageType=true,5,"Base.Bandage";clock=clock+200
    assert(a:isValid() and a.claudeReplicatedComplete and not a.claudeBlocked)
end)
test("partial replication expires and cannot weaken server validation",function()
    local a,_,part=fixture();a:start();part.dressed,part.life,part.bandageType=true,5,"Base.Bandage"
    assert(a:isValid());clock=clock+1501;assert(not a:isValid() and a.claudeBlocked=="treatment_replication_timeout")
    local a,_,part=fixture();beginServer(a);part.dressed,part.life,part.bandageType=true,5,"Base.Bandage"
    assert(not a:complete() and effects.removed==0)
end)
test("ambiguous item ID is rejected before native start can remap",function()
    local a,_,_,_,inv=fixture();inv.alias={};a:start()
    assert(effects.animation==0 and a.claudeBlocked=="treatment_supply_id_ambiguous")
end)
test("unsupported mode or patient returns a harmless constructor",function()
    local a,p,part,item=fixture()
    local invalid=ClaudeApplyBandageAction:new(p,{},item,part,true,item.key,3)
    assert(invalid.claudeBlocked and invalid.maxTime==1)
    local removal=ClaudeApplyBandageAction:new(p,p,item,part,false,item.key,3)
    assert(removal.claudeBlocked and removal.maxTime==1)
end)
test("stopped server action cannot later complete",function()
    local a=fixture();beginServer(a);a:serverStop();assert(not a:complete() and effects.bandage==0)
end)
test("server completion after source API failure is blocked",function()
    local a,p=fixture();beginServer(a);p.getInventory=function() error("synthetic unreadable inventory") end
    assert(not a:complete() and effects.bandage==0)
end)
print("passed "..count.." apply bandage action Lua tests"..(official and " with installed native parent" or " with portable parent fixture"))
