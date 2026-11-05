require "ClaudeTreatmentFacts"
require "TimedActions/ClaudeApplyBandageAction"
-- One self-bandaging attempt; dressings and consumption must both be observed.
ClaudeTreatmentSkill = {}
local function finite(n) return type(n)=="number" and n==n and n>-math.huge and n<math.huge end
local function itemID(n) return finite(n) and n==math.floor(n) and n>=0 and n<=9007199254740991 end
local function state(player)
    local q=ISTimedActionQueue.getTimedActionQueue(player)
    local native=ISTimedActionQueue.isPlayerDoingAction(player)
    if not q or type(q.queue)~="table" or type(native)~="boolean" then return nil end
    local actions,count={},0
    for index,action in pairs(q.queue) do
        if not finite(index) or index~=math.floor(index) or index<1 or index>512 or type(action)~="table" then return nil end
        count=count+1
    end
    for i=1,count do if q.queue[i]==nil then return nil end;actions[i]=q.queue[i] end
    return {busy=native or #actions>0,actions=actions}
end
local function defaults()
    return {
        now=function() return tonumber(getTimestampMs()) end,
        state=state,
        choose=function(player)
            local facts=ClaudeTreatmentFacts.read(player)
            local wound,supply=facts.eligibleWounds[1],facts.supplies[1]
            if not wound then return nil,nil,"no_supported_bleeding_wound" end
            if not supply then return nil,nil,"no_supported_clean_bandage" end
            local part=player:getBodyDamage():getBodyParts():get(wound.index)
            local items=player:getInventory():getItems()
            for i=0,math.min(items:size(),512)-1 do
                local item=items:get(i)
                local current=ClaudeTreatmentFacts.inspectSupply(player,item)
                if current.allowed and current.key==supply.key then return part,item end
            end
            return nil,nil,"bandage_supply_changed"
        end,
        capture=function(player,part,item,index,key,fullType,originalID)
            local parts=player:getBodyDamage():getBodyParts()
            if parts:get(index)~=part or part:getParentChar()~=player or part:getIndex()~=index then return {valid=false} end
            local id=item:getID()
            if not itemID(id) or id~=originalID or "item:"..string.format("%.0f",id)~=key then return {valid=false} end
            local bandaged,bleeding,life=part:bandaged(),part:bleeding(),part:getBandageLife()
            if type(bandaged)~="boolean" or type(bleeding)~="boolean" or not finite(life) then return {valid=false} end
            local inventory=player:getInventory()
            local present=inventory:getItemById(id)
            local consumed=present==nil and item:getContainer()==nil
            return {valid=true,bandaged=bandaged,bleeding=bleeding,consumed=consumed,
                matchingDressing=bandaged and part:getBandageType()==fullType and life>0}
        end,
        create=function(player,item,part,key,index)
            return ClaudeApplyBandageAction:new(player,player,item,part,true,key,index)
        end,
        add=function(action)
            local q=ISTimedActionQueue.add(action)
            return q~=nil and q~=false and ISTimedActionQueue.hasAction(action)==true
        end,
        cancelOwned=function(player,owned)
            local q=state(player)
            if not q then return false end
            if #q.actions==0 then return not q.busy end
            for _,action in ipairs(q.actions) do if action~=owned then return false end end
            ISTimedActionQueue.clear(player)
            local after=state(player)
            return after~=nil and not after.busy
        end,
    }
end

function ClaudeTreatmentSkill.new(env)
    env=env or defaults()
    local self={task=nil,receipt=nil}
    local function authorized(task)
        local ok,value=pcall(task.authority)
        return ok and value==true and self.task==task and self.receipt.status=="pending"
    end
    local function finish(task,status,reason,cleanup)
        if self.task~=task or not self.receipt or self.receipt.status~="pending" then return end
        self.receipt.status,self.receipt.detail=status,tostring(reason)
        if cleanup then
            local ok,stopped=pcall(env.cancelOwned,task.player,task.action)
            if not ok or stopped~=true then self.receipt.detail=self.receipt.detail..";owned_cleanup_unverified" end
        end
    end
    function self:cancel(reason)
        if self.task then finish(self.task,"interrupted",reason or "treatment_interrupted",true) end
    end
    function self:start(player,sequence,authority,identity)
        self:cancel("treatment_superseded")
        local task={player=player,authority=authority}
        self.task=task
        self.receipt={seq=sequence,action="BANDAGE",world=identity.world,actor=identity.actor,session=identity.session,
            status="pending",phase="validate",partIndex=-1,supplyKey="",
            added=0,hungerDrop=0,thirstDrop=0,detail="checking_wound_and_supply"}
        local ok,reason=pcall(function()
            task.started=env.now()
            if not finite(task.started) then return "treatment_clock_unknown" end
            if type(authority)~="function" or not authorized(task) then return "treatment_control_revoked" end
            local q=env.state(player)
            if not q or q.busy then return "treatment_body_busy_or_unknown" end
            local part,item,blocker=env.choose(player)
            if not part or not item then return blocker or "treatment_target_unavailable" end
            local wound=ClaudeTreatmentFacts.inspectWound(player,part)
            local supply=ClaudeTreatmentFacts.inspectSupply(player,item)
            if not wound.allowed then return wound.reason end
            if not supply.allowed then return supply.reason end
            task.part,task.item,task.index,task.key,task.fullType=part,item,wound.index,supply.key,supply.fullType
            task.originalID=item:getID()
            if not itemID(task.originalID) or "item:"..string.format("%.0f",task.originalID)~=supply.key then return "treatment_supply_identity_unknown" end
            self.receipt.partIndex,self.receipt.supplyKey=wound.index,supply.key
            local before=env.capture(player,part,item,wound.index,supply.key,supply.fullType,task.originalID)
            if not before or before.valid~=true or before.bandaged~=false or before.consumed~=false then return "treatment_baseline_unknown" end
            local action=env.create(player,item,part,supply.key,wound.index)
            if type(action)~="table" or type(action.isValid)~="function" then return "treatment_action_unavailable" end
            task.action=action
            action.claudeAuthorized=function() return authorized(task) end
            action.claudeOnBlocked=function(blocked)
                if self.task==task and self.receipt.status=="pending" then
                    task.blockedReason=tostring(blocked)
                    self.receipt.detail="blocked_waiting_for_settled_observation"
                end
            end
            if action:isValid()~=true then return "treatment_action_refused" end
            self.receipt.phase,self.receipt.detail="bandage","applying_supported_dressing"
            if not authorized(task) then return "treatment_control_revoked" end
            task.enqueueAttempted=true
            if env.add(action)~=true then return "treatment_enqueue_refused" end
        end)
        if not ok or reason then
            finish(task,task.enqueueAttempted and "unverified" or "no_effect",ok and reason or "treatment_start_facts_unavailable",true)
            return false,self.receipt.detail
        end
        return true,"treatment_queued"
    end
    function self:update()
        local task,receipt=self.task,self.receipt
        if not task or not receipt or receipt.status~="pending" then return receipt end
        local ok,reason=pcall(function()
            local now=env.now()
            if not finite(now) or now<task.started then return "treatment_clock_invalid" end
            if not authorized(task) then self:cancel("treatment_control_revoked");return end
            if now-task.started>30000 then return "treatment_timeout" end
            local q=env.state(task.player)
            if not q then return "treatment_queue_unknown" end
            for _,a in ipairs(q.actions) do if a~=task.action then self:cancel("treatment_queue_replaced");return end end
            if q.busy then task.emptySince=nil;return end
            receipt.phase="verify"
            local after=env.capture(task.player,task.part,task.item,task.index,task.key,task.fullType,task.originalID)
            if not after or after.valid~=true then return "treatment_result_unknown" end
            receipt.bandaged,receipt.consumed,receipt.bleedingAfter=after.bandaged,after.consumed,after.bleeding
            task.emptySince=task.emptySince or now
            if now-task.started<50 then return end
            if task.blockedReason then
                finish(task,"unverified",task.blockedReason,false)
            elseif after.matchingDressing==true and after.consumed==true then
                finish(task,"observed_effect","matching_dressing_and_supply_consumption_observed",false)
            elseif now-task.emptySince>=1500 then
                local partial=after.bandaged==true or after.consumed==true
                finish(task,partial and "unverified" or "no_effect",
                    partial and "partial_treatment_effect_observed" or "treatment_queue_empty_without_both_effects",false)
            end
        end)
        if not ok or reason then finish(task,"unverified",ok and reason or "treatment_runtime_facts_unavailable",true) end
        return receipt
    end
    return self
end
return ClaudeTreatmentSkill
