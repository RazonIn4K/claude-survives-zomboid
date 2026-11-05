-- Behavioral fixtures for the shared action. An optional second argument loads
-- the locally installed official parent instead of the portable parent fixture.
local directory, official = assert(arg[1]), arg[2]
local count, nativeConstructed, nativeStarted, emulated = 0, 0, 0, 0
local mode, completed, reset = "client", 0, 0
local members = {}
local function test(name, fn)
    fn(); count=count+1; print("ok " .. name)
end
local function derive(self, kind)
    local child={Type=kind}; child.__index=child; setmetatable(child,{__index=self});return child
end
ISBaseTimedAction={derive=derive}
function ISBaseTimedAction:new(character) return setmetatable({character=character},{__index=self}) end
function ISBaseTimedAction.perform(self) completed=completed+1;members[self]=nil end
function ISBaseTimedAction.stop(self) reset=reset+1;members={} end
function ISBaseTimedAction:getJobDelta() return self.action:getJobDelta() end
function ISBaseTimedAction:setActionAnim() end
function ISBaseTimedAction:setAnimVariable() end
function ISBaseTimedAction:setOverrideHandModels() end
local portableBase=ISBaseTimedAction
if official then
    package.path=official .. "/media/lua/shared/?.lua;" .. package.path
    require "TimedActions/ISTakeWaterAction"
    -- Render/queue surfaces are injected; constructor, updateUse, mutation,
    -- complete and animEvent remain the installed native implementation.
    ISBaseTimedAction.perform=portableBase.perform
    ISBaseTimedAction.stop=portableBase.stop
    ISBaseTimedAction.setActionAnim=portableBase.setActionAnim
    ISBaseTimedAction.setAnimVariable=portableBase.setAnimVariable
    ISBaseTimedAction.setOverrideHandModels=portableBase.setOverrideHandModels
else
    ISTakeWaterAction=ISBaseTimedAction:derive("ISTakeWaterAction")
    function ISTakeWaterAction:new(character,item,waterObject,waterTaintedCL)
        local action=ISBaseTimedAction.new(self,character)
        action.item,action.waterObject=item,waterObject
        action.startUsedAmount=item and item.fc.amount or 0
        action.startThirst=character.thirst*2
        action.waterUnit=math.min(waterObject.amount,item and (item.fc.capacity-item.fc.amount) or character.thirst*2)
        action.maxTime=action.waterUnit*100+15
        return action
    end
    function ISTakeWaterAction:isValid() return self.waterObject:hasFluid() and not self.character:hasFullInventory() end
    function ISTakeWaterAction:start() nativeStarted=nativeStarted+1;if self.item then self.item:setBeingFilled(true) end end
    function ISTakeWaterAction:waitToStart() self.character:faceThisObject(self.waterObject);return self.character:shouldBeTurning() end
    function ISTakeWaterAction:updateUse(progress)
        local used=self.item and self.item.fc.amount-self.startUsedAmount or self.startThirst-self.character.thirst*2
        local amount=math.max(0,self.waterUnit*progress-used)
        self:transferFluid(amount)
    end
    function ISTakeWaterAction:update() if not isClient() then self:updateUse(self:getJobDelta()) end end
    function ISTakeWaterAction:transferFluid(amount)
        if amount<=0 or self.waterObject:getFluidAmount()<=0 then return end
        if self.item then self.waterObject:transferFluidTo(self.item.fc,amount);self.item:syncItemFields();sendItemStats(self.item)
        else self.character:DrinkFluid(self.waterObject:moveFluidToTemporaryContainer(amount),1) end
    end
    function ISTakeWaterAction:serverStart() emulateAnimEvent(self.netAction,100,"takeFluid",nil) end
    function ISTakeWaterAction:animEvent(event) if isServer() and event=="takeFluid" then self:updateUse(self.netAction:getProgress()) end end
    function ISTakeWaterAction:complete() self:updateUse(1);return true end
    function ISTakeWaterAction:stopSound() end
    function ISTakeWaterAction:perform() ISBaseTimedAction.perform(self) end
end
local originalNew=ISTakeWaterAction.new
ISTakeWaterAction.new=function(self,...)
    nativeConstructed=nativeConstructed+1
    return originalNew(self,...)
end
local originalStart=ISTakeWaterAction.start
if official then
    ISTakeWaterAction.start=function(self)
        nativeStarted=nativeStarted+1
        return originalStart(self)
    end
end
package.loaded["TimedActions/ISTakeWaterAction"]=true
package.loaded["ClaudeWaterFacts"]=true
ClaudeWaterFacts={}
function ClaudeWaterFacts.inspectSource(player,source,reach)
    assert(reach==true)
    if not source or source.allowed~=true then return {allowed=false,reason="source_unsafe"} end
    if source.reachable~=true then return {allowed=false,reason="source_unreachable"} end
    if source.amount<=0 then return {allowed=false,reason="source_empty"} end
    return {allowed=true,key=source.key}
end
function ClaudeWaterFacts.inspectVessel(player,item,allowFull)
    if not item.owned or not item.safe or (not allowFull and item.fc.amount>=item.fc.capacity) then return {allowed=false,reason="vessel_unsafe"} end
    return {allowed=true,key=item.key,amount=item.fc.amount,capacity=item.fc.capacity}
end
isServer=function() return mode=="server" end
isClient=function() return mode=="client" end
emulateAnimEvent=function() emulated=emulated+1 end
getText=function(key) return key end
sendItemStats=function() end
instanceof=function() return false end
CharacterStat={THIRST="thirst"}
IsoFlagType={water="water",solidfloor="solidfloor"}
luautils={stringStarts=function(text,prefix) return text:sub(1,#prefix)==prefix end}
ZomboidGlobals={EquippedOrWornEncumbranceMultiplier=0.3}
FluidContainer={DisposeContainer=function() end}
ItemBodyLocation={MASK="mask",MASK_EYES="eyes",MASK_FULL="full",FULL_HAT="hat",FULL_SUIT_HEAD="head",SCBA="scba",SCBANOTANK="scbanotank"}
ItemTag={CAN_EAT="eat"}
ISTimedActionQueue={hasAction=function(action) return members[action]==true end,getTimedActionQueue=function()
    local queue={};for action in pairs(members) do queue[#queue+1]=action end
    return {queue=queue,onCompleted=ISBaseTimedAction.perform,resetQueue=function() reset=reset+1;members={} end}
end}
dofile(directory .. "/TimedActions/ClaudeTakeWaterAction.lua")

local function fixture(fill)
    mode,completed,reset="client",0,0;members={}
    local effects={transfers=0,drinks=0,blocked={}}
    local player={dead=false,thirst=0.4,worn={},faced=0}
    function player:isDead() return self.dead end
    function player:hasFullInventory() return false end
    function player:getFreeInventoryCapacity() return 10 end
    function player:isEquippedClothing() return false end
    function player:isTimedActionInstant() return false end
    function player:getStats() return {get=function() return player.thirst end} end
    function player:getWornItem(slot) return self.worn[slot] end
    function player:faceThisObject() self.faced=self.faced+1 end
    function player:shouldBeTurning() return false end
    function player:playSound() return 1 end
    function player:isSecondaryHandItem() return true end
    function player:reportEvent() end
    function player:getEmitter() return {isPlaying=function() return false end} end
    function player:DrinkFluid(container) effects.drinks=effects.drinks+1;self.thirst=self.thirst-container.amount/2 end
    local source={allowed=true,reachable=true,key="source:1",amount=10,compatible=true}
    function source:getFluidAmount() return self.amount end
    function source:hasFluid() return self.amount>0 end
    function source:canTransferFluidTo() return self.compatible end
    function source:getProperties() return {has=function() return false end,get=function() return "Sink" end} end
    function source:getSprite() return {getName=function() return "sink_01" end} end
    function source:transferFluidTo(fc,amount) effects.transfers=effects.transfers+1;fc.amount=fc.amount+amount;self.amount=self.amount-amount end
    function source:moveFluidToTemporaryContainer(amount) self.amount=self.amount-amount;return {amount=amount} end
    local item={owned=true,safe=true,key="item:1",fc={amount=0,capacity=1}}
    function item.fc:getAmount() return self.amount end
    function item.fc:getCapacity() return self.capacity end
    function item:getFluidContainer() return self.fc end
    function item:getContainer() if self.owned then return {setDrawDirty=function() end} end end
    function item:isEquipped() return false end
    function item:setBeingFilled(value) self.beingFilled=value end
    function item:setJobDelta(value) self.jobDelta=value end
    function item:setJobType() end
    function item:getName() return "Bottle" end
    function item:getFillFromTapSound() return "GetWaterFromTap" end
    function item:getPourType() return "Bottle" end
    function item:getStaticModel() return "Bottle" end
    function item:syncItemFields() end
    local action=ClaudeTakeWaterAction:new(player,fill and item or nil,source,source.key,fill and item.key or nil)
    action.claudeAuthorized=function() return true end
    action.claudeOnBlocked=function(reason) effects.blocked[#effects.blocked+1]=reason end
    action.action={getJobDelta=function() return 0.5 end}
    action.netAction={getProgress=function() return 0.5 end}
    members[action]=true
    return action,player,source,item,effects
end

test("constructor stores named network fields and uses distinct type",function()
    local a,p,s,i=fixture(true)
    assert(a.Type=="ClaudeTakeWaterAction" and a.character==p and a.item==i and a.waterObject==s)
    assert(a.sourceKey==s.key and a.itemKey==i.key and a.retriggerLastAction==false)
    assert(a:isValidStart() and a:isValid())
end)
test("client authorization is required before any start or facing",function()
    local a,p=fixture();a.claudeAuthorized=nil
    local before=nativeStarted;a:start();a:waitToStart()
    assert(not a:isValid() and nativeStarted==before and p.faced==0)
end)
test("native animation start accepts both supported drink and fill",function()
    for _,fill in ipairs({false,true}) do
        local a=fixture(fill);local before=nativeStarted;a:start()
        assert(a.claudeStarted and not a.claudeBlocked and nativeStarted==before+1)
    end
end)
test("revoked client control is latched and reported",function()
    local a,_,_,_,e=fixture();a.claudeAuthorized=function() return false end
    assert(not a:isValid() and a.claudeBlocked=="water_control_revoked" and #e.blocked>0)
    a.claudeAuthorized=function() return true end;assert(not a:isValid())
end)
test("server reconstruction needs no client callback",function()
    local a=fixture(true);mode="server";a.claudeAuthorized=nil
    assert(a:isValid());local before=emulated;a:serverStart();assert(emulated==before+1)
end)
test("client cannot invoke consumption directly",function()
    local a,p,_,_,e=fixture();assert(not a:complete())
    assert(p.thirst==0.4 and e.drinks==0)
end)
test("native completion performs real server drinking through guard",function()
    local a,p,_,_,e=fixture();mode="server"
    assert(a:complete());assert(e.drinks==1 and p.thirst<0.4)
end)
test("native completion fills exact server vessel through guard",function()
    local a,_,_,i,e=fixture(true);mode="server"
    assert(a:complete());assert(e.transfers==1 and i.fc.amount==1)
end)
test("changed source purity after start blocks server effects",function()
    local a,p,s,_,e=fixture();a:start();mode="server";s.allowed=false
    a:animEvent("takeFluid");assert(not a:complete())
    assert(e.drinks==0 and p.thirst==0.4)
end)
test("changed reach after start blocks incremental native transfer",function()
    local a,_,s,i,e=fixture(true);a:start();mode="server";s.reachable=false
    a:update();a:animEvent("takeFluid");assert(not a:complete())
    assert(e.transfers==0 and i.fc.amount==0)
end)
test("changed vessel contents or ownership blocks server fill",function()
    for _,field in ipairs({"safe","owned"}) do
        local a,_,_,i,e=fixture(true);mode="server";i[field]=false
        assert(not a:complete() and e.transfers==0 and i.fc.amount==0)
    end
end)
test("changed source and vessel identities are rejected",function()
    local a,_,s,_,e=fixture();mode="server";s.key="other"
    assert(not a:complete() and e.drinks==0)
    local b,_,_,i,f=fixture(true);mode="server";i.key="other"
    assert(not b:complete() and f.transfers==0)
end)
test("source transfer compatibility is checked on server",function()
    local a,_,s,_,e=fixture(true);mode="server";s.compatible=false
    assert(not a:complete() and e.transfers==0)
end)
test("blocking mask and missing mask schema stop drinking only",function()
    local a,p,_,_,e=fixture();mode="server";p.worn.mask={hasTag=function() return false end}
    assert(not a:complete() and e.drinks==0)
    local b,p2=fixture(true);mode="server";p2.worn.mask={hasTag=function() return false end};assert(b:complete())
    local c=fixture();local saved=ItemBodyLocation.MASK;ItemBodyLocation.MASK=nil
    assert(not c:isValid());ItemBodyLocation.MASK=saved
end)
test("dead actor and throwing facts never mutate",function()
    local a,p,_,_,e=fixture();mode="server";p.dead=true
    assert(not a:complete() and e.drinks==0)
    local b,_,s,_,f=fixture();mode="server";s.hasFluid=function() error("unavailable") end
    assert(not b:complete() and f.drinks==0)
end)
test("invalid constructor avoids native constructor and yields harmless skeleton",function()
    local a,p,s=fixture();s.allowed=false
    local before=nativeConstructed
    local invalid=ClaudeTakeWaterAction:new(p,nil,s,s.key,nil)
    assert(nativeConstructed==before and invalid.waterUnit==0 and invalid.claudeBlocked)
    mode="server";assert(not invalid:complete())
end)
test("native constructor exceptions fail closed",function()
    local a,p,s=fixture();local previous=ISTakeWaterAction.new
    ISTakeWaterAction.new=function() error("unavailable") end
    local invalid=ClaudeTakeWaterAction:new(p,nil,s,s.key,nil)
    ISTakeWaterAction.new=previous
    assert(invalid.claudeBlocked=="water_native_constructor_failed_or_no_need" and invalid.waterUnit==0)
end)
test("retained perform and stop cannot complete or reset replacement queue",function()
    local a=fixture();members={};local replacement={};members[replacement]=true
    a.claudeAuthorized=function() return false end;a:perform();a:stop()
    assert(completed==0 and reset==0 and members[replacement])
end)
test("rejected perform only acknowledges its own still queued action",function()
    local a=fixture();a.claudeAuthorized=function() return false end;a:perform()
    assert(completed==1 and not members[a] and reset==0)
end)
test("queue ownership uses the official static hasAction signature",function()
    local a=fixture();local queue=ISTimedActionQueue.getTimedActionQueue(a.character)
    assert(queue.hasAction==nil and ISTimedActionQueue.hasAction(a)==true)
    a:perform();assert(completed==1 and not members[a])
end)
test("stale callbacks preserve a replacement native fill's vessel flags",function()
    local a,_,_,item=fixture(true);a:start();assert(item.beingFilled==true)
    local replacement={item=item};members={[replacement]=true};item.jobDelta=0.7
    a.claudeAuthorized=function() return false end;a:stop();a:perform()
    assert(item.beingFilled==true and item.jobDelta==0.7 and reset==0 and completed==0)
end)
test("legitimate removed action cleans its own vessel state",function()
    local a,_,_,item=fixture(true);a:start();item.jobDelta=0.4;members={};a:stop()
    assert(item.beingFilled==false and item.jobDelta==0 and reset==0)
end)
test("new custom fill owns vessel state after an older action was removed",function()
    local a,p,s,item=fixture(true);a:start();members={}
    local b=ClaudeTakeWaterAction:new(p,item,s,s.key,item.key)
    b.claudeAuthorized=function() return true end;members[b]=true;b:start();item.jobDelta=0.6
    a:stop();a:perform();assert(item.beingFilled==true and item.jobDelta==0.6)
    b:stop();assert(item.beingFilled==false and item.jobDelta==0)
end)
test("server animated updates use guarded self transfer",function()
    local a,_,s,i,e=fixture(true);mode="server";a:animEvent("takeFluid")
    assert(e.transfers==1 and i.fc.amount==0.5)
    s.allowed=false;a:animEvent("takeFluid");assert(e.transfers==1 and i.fc.amount==0.5)
end)
test("completed native fill remains a no-op after source empties",function()
    local a,_,s,i,e=fixture(true);mode="server";s.amount=1
    a.netAction.getProgress=function() return 1 end
    a:animEvent("takeFluid")
    assert(a.claudeSatisfied and i.fc.amount==1 and s.amount==0)
    a:animEvent("takeFluid");assert(a:complete() and not a.claudeBlocked and e.transfers==1)
    i.safe=false;assert(not a:complete() and e.transfers==1)
end)
test("completed native drink does not repeat after finite source drains",function()
    local a,p,s,_,e=fixture();mode="server";s.amount=a.waterUnit
    a.netAction.getProgress=function() return 1 end
    a:animEvent("takeFluid")
    assert(a.claudeSatisfied and e.drinks==1 and p.thirst==0 and s.amount==0)
    a:animEvent("takeFluid");assert(a:complete() and e.drinks==1)
end)
test("client recognizes replicated target completion without a server latch",function()
    local a,_,s,i,e=fixture(true);a:start();i.fc.amount=1;s.amount=0
    assert(a:isValid() and a.claudeSatisfied and not a.claudeBlocked)
    a:update();a:perform();assert(completed==1 and e.transfers==0 and not a.claudeBlocked)
end)
test("zero is a no-op while nonfinite and negative mutation requests are refused",function()
    local a,_,_,i,e=fixture(true);mode="server"
    assert(a:transferFluid(0) and not a.claudeBlocked and e.transfers==0 and i.fc.amount==0)
    for _,amount in ipairs({-1,math.huge,0/0}) do
        local a,_,_,i,e=fixture(true);mode="server"
        assert(not a:transferFluid(amount) and e.transfers==0 and i.fc.amount==0)
    end
end)
print("passed " .. count .. " take water action Lua tests" .. (official and " with installed native parent" or " with portable parent fixture"))
