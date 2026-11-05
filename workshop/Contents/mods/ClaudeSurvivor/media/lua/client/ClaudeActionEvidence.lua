-- Bounded observation receipts; queue completion alone is never proof of an effect.
-- Inventory keys should be stable item IDs (engine objects also work in local fixtures).
ClaudeActionEvidence = {}
local supported = {LOOT=true, EAT=true, DRINK=true}
local function finite(value)
    return type(value)=="number" and value==value and math.abs(value)<math.huge
end
local function readable(snapshot, action)
    if type(snapshot)~="table" or snapshot.valid~=true then return false end
    if action=="LOOT" then return type(snapshot.items)=="table" end
    return finite(snapshot[action=="EAT" and "hunger" or "thirst"])
end

function ClaudeActionEvidence.new()
    local self = {receipt=nil, baseline=nil, started=nil, emptySince=nil}
    function self:begin(seq, action, snapshot)
        if not supported[action] then return nil end
        self.receipt = {seq=seq, action=action, status="pending", added=0,
            hungerDrop=0, thirstDrop=0, detail="waiting_for_observed_effect"}
        self.started = type(snapshot)=="table" and snapshot.now or nil
        self.emptySince = nil
        self.baseline = {valid=readable(snapshot, action), items={}}
        if type(snapshot)=="table" then
            self.receipt.world, self.receipt.actor, self.receipt.session = snapshot.world, snapshot.actor, snapshot.session
            self.baseline.hunger, self.baseline.thirst = snapshot.hunger, snapshot.thirst
            if type(snapshot.items)=="table" then
                for key, present in pairs(snapshot.items) do
                    if present then self.baseline.items[key]=true end
                end
            end
        end
        if not finite(self.started) then
            self.receipt.status, self.receipt.detail = "unverified", "invalid_start_time"
        end
        return self.receipt
    end
    function self:cancel(reason)
        if self.receipt and self.receipt.status=="pending" then
            self.receipt.status, self.receipt.detail = "interrupted", tostring(reason or "control_revoked")
        end
        return self.receipt
    end
    function self:update(snapshot, queueLength, nowMs)
        local receipt, baseline = self.receipt, self.baseline
        if not receipt or receipt.status~="pending" then return receipt end
        if not finite(nowMs) or nowMs<self.started then
            receipt.status, receipt.detail = "unverified", "invalid_observation_time"
            return receipt
        end
        if nowMs-self.started>=30000 then
            receipt.status, receipt.detail = "unverified", "observation_timeout"
            return receipt
        end
        if queueLength~=0 then self.emptySince=nil; return receipt end
        if not baseline.valid or not readable(snapshot, receipt.action) then return receipt end
        self.emptySince = self.emptySince or nowMs
        if nowMs-self.started<50 then return receipt end
        local added, hungerDrop, thirstDrop = 0, 0, 0
        if receipt.action=="LOOT" then
            for key, present in pairs(snapshot.items) do
                if present and not baseline.items[key] then added=added+1 end
            end
        elseif receipt.action=="EAT" then
            hungerDrop=math.max(0, baseline.hunger-snapshot.hunger)
        else thirstDrop=math.max(0, baseline.thirst-snapshot.thirst) end
        receipt.added, receipt.hungerDrop, receipt.thirstDrop = added, hungerDrop, thirstDrop
        if added>0 or hungerDrop>0.0001 or thirstDrop>0.0001 then
            receipt.status, receipt.detail = "observed_effect", "inventory_or_stat_delta_observed"
        elseif nowMs-self.emptySince>=1000 then
            receipt.status, receipt.detail = "no_effect", "queue_empty_without_observed_delta"
        end
        return receipt
    end
    return self
end
