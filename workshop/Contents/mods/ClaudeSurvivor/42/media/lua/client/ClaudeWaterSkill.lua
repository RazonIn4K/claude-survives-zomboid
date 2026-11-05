-- One bounded water task: approach, freshly validate, use a native timed action,
-- then wait for measured effects. Queue completion is not success evidence.
require "ClaudeWaterFacts"
require "TimedActions/ClaudeTakeWaterAction"
ClaudeWaterSkill = {}

local function finite(n)
    return type(n)=="number" and n==n and n>-math.huge and n<math.huge
end

local function queueState(player)
    local q = ISTimedActionQueue.getTimedActionQueue(player)
    local busy = ISTimedActionQueue.isPlayerDoingAction(player)
    if not q or type(q.queue)~="table" or type(busy)~="boolean" then return nil end
    local list = {}
    for i,action in ipairs(q.queue) do list[i]=action end
    return {busy=busy or #list>0, actions=list}
end

local function sourceIdentity(source, key)
    local sq, index = source:getSquare(), source:getObjectIndex()
    if not sq or not finite(index) or index<0 or index~=math.floor(index) then return false end
    return sq:getObjects():get(index)==source
        and string.format("%d:%d:%d:%d",sq:getX(),sq:getY(),sq:getZ(),index)==key
end

local function defaults()
    return {
        now=function() return tonumber(getTimestampMs()) end,
        state=queueState,
        choose=function(player, mode)
            local facts = ClaudeWaterFacts.read(player)
            local target = facts.sources and facts.sources[1]
            if not target then return nil,nil,"no_supported_clean_water_source" end
            local sq = getCell():getGridSquare(target.x,target.y,target.z)
            local source = sq and sq:getObjects():get(target.index)
            if not source then return nil,nil,"water_source_disappeared" end
            if mode=="DRINKTAP" then return source end
            local eligible = {}
            for _,v in ipairs(facts.fillableVessels or {}) do eligible[v.key]=true end
            local items = player:getInventory():getItems()
            for i=0,math.min(items:size(),256)-1 do
                local item = items:get(i)
                local v = ClaudeWaterFacts.inspectVessel(player,item)
                if v.allowed and eligible[v.key] then return source,item end
            end
            return nil,nil,"no_supported_fillable_vessel"
        end,
        approach=function(player, source) return luautils.walkAdjObject(player,source,true,true) end,
        create=function(player, item, source, sourceKey, itemKey)
            return ClaudeTakeWaterAction:new(player,item,source,sourceKey,itemKey)
        end,
        add=function(action)
            local q = ISTimedActionQueue.add(action)
            return q~=nil and q~=false and ISTimedActionQueue.hasAction(action)==true
        end,
        capture=function(player, source, item, sourceKey, itemKey)
            if not sourceIdentity(source,sourceKey) then return {valid=false} end
            local thirst = player:getStats():get(CharacterStat.THIRST)
            if not finite(thirst) or thirst<0 or thirst>1 then return {valid=false} end
            if not item then return {valid=true,thirst=thirst} end
            local inv, found = player:getInventory(), false
            local items = inv:getItems()
            for i=0,math.min(items:size(),256)-1 do if items:get(i)==item then found=true;break end end
            if not found or item:getContainer()~=inv then return {valid=false} end
            local id, fc = item:getID(),item:getFluidContainer()
            if not finite(id) or "item:"..string.format("%.0f",id)~=itemKey or not fc then return {valid=false} end
            local amount,capacity = fc:getAmount(),fc:getCapacity()
            if not finite(amount) or not finite(capacity) or amount<0 or capacity<=0 or amount>capacity
                or fc:isTainted()~=false or fc:isPoisonous()~=false then return {valid=false} end
            if amount>0 and fc:isPureFluid(Fluid.Water)~=true then return {valid=false} end
            return {valid=true,thirst=thirst,amount=amount,capacity=capacity}
        end,
        cancelOwned=function(player, owned)
            local state = queueState(player)
            if not state then return false end
            if #state.actions==0 then return not state.busy end
            for _,a in ipairs(state.actions) do if not owned[a] then return false end end
            ISTimedActionQueue.clear(player)
            local after = queueState(player)
            return after~=nil and not after.busy
        end,
    }
end

function ClaudeWaterSkill.new(env)
    env = env or defaults()
    local self = {receipt=nil, task=nil}
    local function authorized(task)
        local ok, value = pcall(task.authorized)
        return ok and value==true and self.task==task and self.receipt and self.receipt.status=="pending"
    end
    local function finish(status, reason, cleanup)
        local receipt,task = self.receipt,self.task
        if not receipt or receipt.status~="pending" then return end
        receipt.status,receipt.detail = status,tostring(reason)
        if cleanup and task then
            local ok, stopped = pcall(env.cancelOwned,task.player,task.owned)
            if not ok or stopped~=true then receipt.detail=receipt.detail..";owned_cleanup_unverified" end
        end
    end
    function self:cancel(reason) finish("interrupted",reason or "water_task_interrupted",true) end
    function self:start(player, sequence, mode, authority, identity)
        self:cancel("superseded_water_task")
        self.receipt = {seq=sequence,action=mode,world=identity.world,actor=identity.actor,session=identity.session,
            status="pending",phase="approach",detail="finding_supported_water_source",added=0,
            hungerDrop=0,thirstDrop=0,amountGain=0,sourceKey="",vesselKey=""}
        self.task = {player=player,authorized=authority,owned={}}
        local task = self.task
        local ok, result = pcall(function()
            task.started=env.now()
            if not finite(task.started) then return "water_clock_unknown" end
            if type(authority)~="function" or not authorized(task) then return "water_control_revoked" end
            if mode~="DRINKTAP" and mode~="FILLBOTTLE" then return "water_mode_unsupported" end
            local state = env.state(player)
            if not state or state.busy then return "water_body_busy_or_unknown" end
            local source,item,reason = env.choose(player,mode)
            if not source then return reason or "water_source_unknown" end
            local facts = ClaudeWaterFacts.inspectSource(player,source,false)
            if not facts.allowed then return facts.reason end
            task.source,task.sourceKey=source,facts.key
            self.receipt.sourceKey=facts.key
            self.receipt.x,self.receipt.y,self.receipt.z=facts.x,facts.y,facts.z
            if mode=="FILLBOTTLE" then
                local v=ClaudeWaterFacts.inspectVessel(player,item)
                if not v.allowed then return v.reason end
                task.item,task.itemKey=item,v.key
                self.receipt.vesselKey=v.key
            end
            if not authorized(task) then return "water_control_revoked" end
            local approached,walked=pcall(env.approach,player,source)
            local queued=env.state(player)
            if not queued then return "water_queue_unknown" end
            for _,a in ipairs(queued.actions) do
                task.owned[a]=true
                if type(a.isValid)=="function" then
                    local original=a.isValid
                    a.isValid=function(action)
                        if not authorized(task) then return false end
                        local fresh=ClaudeWaterFacts.inspectSource(player,source,false)
                        local readable,valid=pcall(original,action)
                        return fresh.allowed and fresh.key==task.sourceKey and readable and valid==true
                    end
                end
            end
            if not approached or walked~=true then return "water_approach_refused" end
            self.receipt.detail="approaching_water_source"
        end)
        if not ok or result then
            finish("no_effect",ok and result or "water_start_facts_unavailable",true)
            return false,self.receipt.detail
        end
        return true,"water_task_started"
    end

    function self:update()
        local task,receipt=self.task,self.receipt
        if not task or not receipt or receipt.status~="pending" then return receipt end
        local ok,reason=pcall(function()
            local now=env.now()
            if not finite(now) or now<task.started then return "water_clock_invalid" end
            if not authorized(task) then self:cancel("water_control_revoked");return end
            if now-task.started>60000 then return "water_task_timeout" end
            local state=env.state(task.player)
            if not state then return "water_queue_unknown" end
            -- Never take ownership of work inserted by another controller/human.
            for _,a in ipairs(state.actions) do if not task.owned[a] then
                self:cancel("water_queue_replaced");return
            end end
            if state.busy then task.emptySince=nil;return end
            if receipt.phase=="approach" then
                local source=ClaudeWaterFacts.inspectSource(task.player,task.source,true)
                if not source.allowed or source.key~=task.sourceKey then
                    finish("no_effect",source.reason or "water_source_changed",false);return
                end
                if task.item then
                    local vessel=ClaudeWaterFacts.inspectVessel(task.player,task.item)
                    if not vessel.allowed or vessel.key~=task.itemKey then
                        finish("no_effect",vessel.reason or "water_vessel_changed",false);return
                    end
                end
                task.baseline=env.capture(task.player,task.source,task.item,task.sourceKey,task.itemKey)
                if not task.baseline or task.baseline.valid~=true then return "water_baseline_unknown" end
                if receipt.action=="DRINKTAP" and task.baseline.thirst<=0.0001 then
                    finish("no_effect","water_not_thirsty",false);return
                end
                local action=env.create(task.player,task.item,task.source,task.sourceKey,task.itemKey)
                if type(action)~="table" or type(action.isValid)~="function" then return "water_action_unavailable" end
                action.claudeAuthorized=function() return authorized(task) end
                action.claudeOnBlocked=function(blocker)
                    if self.task==task and self.receipt==receipt then finish("unverified",blocker,false) end
                end
                if action:isValid()~=true then
                    finish("no_effect","water_action_refused",false);return
                end
                task.owned[action]=true
                receipt.phase="consume"
                receipt.detail=receipt.action=="DRINKTAP" and "drinking_at_source" or "filling_vessel"
                if env.add(action)~=true then return "water_enqueue_refused" end
                task.queuedAt=now
                return
            end
            receipt.phase="verify"
            local observed=env.capture(task.player,task.source,task.item,task.sourceKey,task.itemKey)
            if not observed or observed.valid~=true then return "water_effect_facts_unknown" end
            task.emptySince=task.emptySince or now
            receipt.thirstDrop=math.max(0,task.baseline.thirst-observed.thirst)
            if task.item then
                receipt.amountGain=math.max(0,observed.amount-task.baseline.amount)
                receipt.beforeAmount,receipt.afterAmount=task.baseline.amount,observed.amount
            end
            if now-task.queuedAt<50 then return end
            if (task.item and receipt.amountGain>0.0001) or (not task.item and receipt.thirstDrop>0.0001) then
                finish("observed_effect",task.item and "same_vessel_clean_water_gain_observed" or "thirst_drop_observed",false)
            elseif now-task.emptySince>=1500 then
                finish("no_effect","water_queue_empty_without_measured_effect",false)
            end
        end)
        if not ok or reason then finish("unverified",ok and reason or "water_runtime_facts_unavailable",true) end
        return receipt
    end
    return self
end

return ClaudeWaterSkill
