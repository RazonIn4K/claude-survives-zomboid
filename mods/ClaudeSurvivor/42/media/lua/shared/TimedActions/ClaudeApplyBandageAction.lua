require "TimedActions/ISApplyBandage"
require "ClaudeTreatmentFacts"

-- A distinct self-bandaging action. All wound/supply mutation remains in the
-- native complete(); shared checks run again immediately before that mutation.
ClaudeApplyBandageAction = ISApplyBandage:derive("ClaudeApplyBandageAction")
local partOwners=setmetatable({}, {__mode="k"})
local itemOwners=setmetatable({}, {__mode="k"})

local function finite(n) return type(n)=="number" and n==n and n>-math.huge and n<math.huge end
local function validId(n) return finite(n) and n==math.floor(n) and n>=0 and n<=9007199254740991 end
local function server()
    local ok,value=pcall(isServer)
    return ok and value==true
end
local function block(self,reason)
    self.claudeBlocked=self.claudeBlocked or tostring(reason or "treatment_facts_unavailable")
    if type(self.claudeOnBlocked)=="function" then pcall(self.claudeOnBlocked,self.claudeBlocked) end
    return false,self.claudeBlocked
end
local function ownsPart(self)
    local expected=BodyPartType.ToIndex(BodyPartType.MAX)
    local index=self.partIndex
    if not finite(expected) or not finite(index) or index~=math.floor(index) or index<0 or index>=expected then return false end
    local parts=self.character:getBodyDamage():getBodyParts()
    return parts:size()==expected and parts:get(index)==self.bodyPart
        and self.bodyPart:getIndex()==index and self.bodyPart:getParentChar()==self.character
        and BodyPartType.ToIndex(self.bodyPart:getType())==index
end

local function completionObserved(self)
    if not ownsPart(self) or self.bodyPart:bandaged()~=true then return false end
    local life=self.bodyPart:getBandageLife()
    if not finite(life) or life<=0 or self.bodyPart:getBandageType()~=self.claudeBandageType then return false end
    local inventory=self.character:getInventory()
    local id=self.item:getID()
    return validId(id) and id==self.claudeOriginalItemId and "item:"..string.format("%.0f",id)==self.itemKey
        and self.item:getContainer()==nil and inventory:getItemById(id)==nil
end

-- Body-part and inventory packets need not become visible on the same tick.
-- Only the already-started client may wait for this narrow partial transition;
-- it never authorizes medical mutation on the server or in single-player.
local function partialReplication(self)
    if not ownsPart(self) then return false end
    local part,item,inventory=self.bodyPart,self.item,self.character:getInventory()
    local lock=part:manipulatingUsername()
    if lock~=nil and lock~="" then return false end
    local dressed=part:bandaged()==true and part:getBandageType()==self.claudeBandageType
        and finite(part:getBandageLife()) and part:getBandageLife()>0
    local absent=item:getContainer()==nil and inventory:getItemById(self.claudeOriginalItemId)==nil
    if dressed and not absent then
        local supply=ClaudeTreatmentFacts.inspectSupply(self.character,item)
        return supply.allowed==true and supply.key==self.itemKey and inventory:getItemById(self.claudeOriginalItemId)==item
    elseif absent and part:bandaged()==false then
        local wound=ClaudeTreatmentFacts.inspectWound(self.character,part)
        return wound.allowed==true and wound.index==self.partIndex
    end
    return false
end

local function inspect(self,authorization)
    if self.claudeBlocked then return false,self.claudeBlocked end
    local ok,allowed,reason=pcall(function()
        if not self.character or self.character~=self.otherPlayer or self.character:isDead()~=false
            or self.character:isDriving()~=false then return false,"treatment_actor_unavailable" end
        if self.doIt~=true or not self.item then return false,"treatment_mode_unsupported" end
        local currentId=self.item:getID()
        if not validId(currentId) or currentId~=self.claudeOriginalItemId
            or "item:"..string.format("%.0f",currentId)~=self.itemKey then
            return false,"treatment_supply_identity_unknown_or_changed"
        end
        if self.claudeStopped then return false,"treatment_action_stopped" end
        if authorization and not server() then
            if type(self.claudeAuthorized)~="function" or self.claudeAuthorized()~=true then
                return false,"treatment_control_revoked"
            end
        end
        if self.claudeStarted and not self.claudeAttempted and completionObserved(self) then
            -- A client can observe the completed server effect without receiving
            -- the server's local one-shot completion latch.
            self.claudeReplicatedComplete=true
            self.claudeReplicationPending=false
        end
        if self.claudeSucceeded or self.claudeReplicatedComplete then
            return completionObserved(self),"treatment_completed_target_changed"
        end
        local remoteClient=isClient()
        if type(remoteClient)~="boolean" then return false,"treatment_runtime_unknown" end
        if remoteClient==true and self.claudeStarted and not self.claudeAttempted and partialReplication(self) then
            local now=tonumber(getTimestampMs())
            if not finite(now) then return false,"treatment_replication_clock_unknown" end
            self.claudeReplicationSince=self.claudeReplicationSince or now
            if now<self.claudeReplicationSince or now-self.claudeReplicationSince>1500 then
                return false,"treatment_replication_timeout"
            end
            self.claudeReplicationPending=true
            return true
        end
        self.claudeReplicationPending=false
        if self.claudeAttempted then return false,"treatment_completion_already_attempted" end
        local wound=ClaudeTreatmentFacts.inspectWound(self.character,self.bodyPart)
        if type(wound)~="table" or wound.allowed~=true then
            return false,type(wound)=="table" and wound.reason or "treatment_wound_unavailable"
        end
        if wound.index~=self.partIndex then return false,"treatment_body_part_changed" end
        local supply=ClaudeTreatmentFacts.inspectSupply(self.character,self.item)
        if type(supply)~="table" or supply.allowed~=true then
            return false,type(supply)=="table" and supply.reason or "treatment_supply_unavailable"
        end
        if type(self.itemKey)~="string" or supply.key~=self.itemKey then return false,"treatment_supply_changed" end
        if self.claudeOriginalItem and self.item~=self.claudeOriginalItem then return false,"treatment_supply_object_changed" end
        if self.character:getInventory():getItemById(self.item:getID())~=self.item then
            return false,"treatment_supply_id_ambiguous"
        end
        local lock=self.bodyPart:manipulatingUsername()
        local username=self.character:getUsername()
        if type(username)~="string" or username=="" then return false,"treatment_username_unknown" end
        -- We reserve no long-lived native lock. Even our username may belong
        -- to ordinary/replacement medical work, so it cannot be borrowed.
        if lock~=nil and lock~="" then return false,"treatment_other_healer_busy" end
        return true
    end)
    if not ok then return false,"treatment_facts_unavailable" end
    return allowed==true,reason
end

function ClaudeApplyBandageAction:claudeValidate()
    local allowed,reason=inspect(self,true)
    if not allowed then return block(self,reason) end
    return true
end
function ClaudeApplyBandageAction:isValidStart() return self:claudeValidate() end
function ClaudeApplyBandageAction:isValid() return self:claudeValidate() end
function ClaudeApplyBandageAction:waitToStart()
    -- Only self treatment is supported, so no facing or patient approach.
    self:claudeValidate()
    return false
end
function ClaudeApplyBandageAction:getDuration()
    local ok,duration=pcall(function()
        if self.character:isTimedActionInstant() then return 1 end
        local lock=self.bodyPart:manipulatingUsername()
        if lock~=nil and lock~="" and lock~=self.character:getUsername() then return 0 end
        if not finite(self.doctorLevel) or self.doctorLevel<0 or self.doctorLevel>10 then return 0 end
        -- Native duration, with empty usernames treated like an unlocked part.
        return 120-self.doctorLevel*4
    end)
    return ok and duration or 0
end
function ClaudeApplyBandageAction:start()
    if not self:claudeValidate() or self.claudeReplicatedComplete or self.claudeStarted then return end
    partOwners[self.bodyPart],itemOwners[self.item]=self,self
    local ok=pcall(ISApplyBandage.start,self)
    if not ok then block(self,"treatment_native_start_failed");return end
    self.claudeStarted=true
    -- Native client start resolves the item by ID. A different object must not
    -- inherit authorization from a recycled/ambiguous identifier.
    self:claudeValidate()
end
function ClaudeApplyBandageAction:update()
    if not self:claudeValidate() or self.claudeReplicatedComplete then return end
    if self.claudeReplicationPending then return end
    local ok=pcall(ISApplyBandage.update,self)
    if not ok then block(self,"treatment_native_update_failed") end
end
function ClaudeApplyBandageAction:serverStart()
    if not server() or not self:claudeValidate() or self.claudeServerStarted then return end
    partOwners[self.bodyPart]=self
    -- Do not hold a username-only native lock across asynchronous cancellation.
    -- Fresh completion may lose to another healer; that safely blocks our work.
    self.claudeServerStarted=true
end
function ClaudeApplyBandageAction:complete()
    local okClient,client=pcall(isClient)
    if not okClient or type(client)~="boolean" or client==true then return block(self,"treatment_client_effect_forbidden") end
    if self.claudeAttempted then
        local ok,observed=pcall(completionObserved,self)
        return self.claudeSucceeded==true and ok and observed==true
    end
    if not self:claudeValidate() then return false end
    if self.claudeReplicatedComplete then return true end
    if not (self.claudeStarted or self.claudeServerStarted) then return block(self,"treatment_action_not_started") end
    if server() and (not self.claudeServerStarted or partOwners[self.bodyPart]~=self) then
        return block(self,"treatment_server_lock_not_owned")
    end
    -- Latch before mutation: an exception after partial native effects must not
    -- cause another supply removal or another XP/panic/medical application.
    self.claudeAttempted=true
    local acquired=false
    if server() then
        -- Acquire and consume synchronously. A deferred serverStop never needs
        -- to clear this lock and cannot erase a newer native healer's lock.
        local locked,owned=pcall(function()
            ISApplyBandage.serverStart(self)
            return self.bodyPart:manipulatingUsername()==self.character:getUsername()
        end)
        acquired=locked and owned==true
        if not acquired then
            pcall(function()
                if self.bodyPart:manipulatingUsername()==self.character:getUsername() then ISApplyBandage.serverStop(self) end
            end)
            return block(self,"treatment_native_lock_failed")
        end
    end
    local ok,completed=pcall(ISApplyBandage.complete,self)
    if acquired then
        pcall(function()
            if self.bodyPart:manipulatingUsername()==self.character:getUsername() then ISApplyBandage.serverStop(self) end
        end)
    end
    if not ok then return block(self,"treatment_native_complete_failed") end
    local readable,observed=pcall(completionObserved,self)
    if completed~=true or not readable or observed~=true then
        return block(self,"treatment_native_effect_unverified")
    end
    self.claudeSucceeded=true
    return true
end

local function ownsQueue(self)
    local ok,owned=pcall(function()
        local queue=ISTimedActionQueue.getTimedActionQueue(self.character)
        return ISTimedActionQueue.hasAction(self)==true and queue and type(queue.queue)=="table"
            and queue.queue[1]==self
    end)
    return ok and owned==true
end
local function competing(self,field,target)
    local queue=ISTimedActionQueue.getTimedActionQueue(self.character)
    if not queue or type(queue.queue)~="table" then return nil end
    for _,action in ipairs(queue.queue) do
        if action~=self and action[field]==target then return true end
    end
    return false
end
local function cleanupClient(self)
    pcall(ISApplyBandage.stopSound,self)
    if self.item and itemOwners[self.item]==self then
        local ok,busy=pcall(competing,self,"item",self.item)
        if ok and type(busy)=="boolean" then
            itemOwners[self.item]=nil
            if not busy then pcall(function() self.item:setJobDelta(0) end) end
        end
    end
    if self.bodyPart and partOwners[self.bodyPart]==self then
        local ok,busy=pcall(competing,self,"bodyPart",self.bodyPart)
        if ok and type(busy)=="boolean" then
            partOwners[self.bodyPart]=nil
            if not busy then pcall(function()
                ISHealthPanel.setBodyPartActionForPlayer(self.otherPlayer,self.bodyPart,nil,nil,nil)
            end) end
        end
    end
end
function ClaudeApplyBandageAction:stop()
    self.claudeStopped=true
    cleanupClient(self)
    if ownsQueue(self) then pcall(ISBaseTimedAction.stop,self) end
end
function ClaudeApplyBandageAction:serverStop()
    -- No native lock is held during the action; there is nothing to release.
    -- In particular, a delayed callback must never erase replacement work.
    if self.claudeServerStopped then return end
    self.claudeServerStopped=true
    self.claudeStopped=true
    if partOwners[self.bodyPart]~=self then return end
    partOwners[self.bodyPart]=nil
end
function ClaudeApplyBandageAction:perform()
    self:claudeValidate()
    cleanupClient(self)
    -- Native perform only cleans UI and advances the queue; native complete
    -- on server/SP owns actual treatment. Do not touch replacement work.
    if ownsQueue(self) then pcall(ISBaseTimedAction.perform,self) end
end
function ClaudeApplyBandageAction:new(character,otherPlayer,item,bodyPart,doIt,itemKey,partIndex)
    local idOk,originalId=pcall(function() return item:getID() end)
    local probe={character=character,otherPlayer=otherPlayer,item=item,bodyPart=bodyPart,
        doIt=doIt,itemKey=itemKey,partIndex=partIndex,claudeOriginalItem=item,
        claudeOriginalItemId=idOk and originalId or nil}
    local allowed,reason=inspect(probe,false)
    local action
    if allowed then
        local ok,native=pcall(ISApplyBandage.new,self,character,otherPlayer,item,bodyPart,doIt)
        if ok and type(native)=="table" and finite(native.maxTime) and native.maxTime>0 then action=native
        else reason="treatment_native_constructor_failed" end
    end
    if not action then
        action=ISBaseTimedAction.new(self,character)
        action.maxTime=1
        action.claudeBlocked=reason or "treatment_action_unavailable"
    end
    action.character,action.otherPlayer,action.item,action.bodyPart=character,otherPlayer,item,bodyPart
    action.doIt,action.itemKey,action.partIndex=doIt,itemKey,partIndex
    action.claudeOriginalItem=item
    action.claudeOriginalItemId=idOk and originalId or nil
    local ok,fullType=pcall(function() return item:getModule().."."..item:getType() end)
    action.claudeBandageType=ok and fullType or nil
    action.retriggerLastAction=false
    return action
end

return ClaudeApplyBandageAction
