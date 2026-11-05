-- Factual positions actually occupied by this survivor, scoped to one lab
-- identity. No map discovery, room IDs, object discovery or automatic control.
ClaudePlaceMemory = {}

local MAX_ANCHORS,MAX_PUBLIC,MAX_FAILURES=96,24,64
local MAX_ID,MAX_TIME=2147483647,9007199254710991
local COOLDOWN,RANGE,ARRIVAL=30000,32,0.35
local function finite(n) return type(n)=="number" and n==n and n>-math.huge and n<math.huge end
local function integer(n,low,high) return finite(n) and n==math.floor(n) and n>=low and n<=high end
local function clock(n) return integer(n,0,MAX_TIME) end
local function identity(value)
    if type(value)~="table" then return nil end
    local out={}
    for _,key in ipairs({"world","actor","session"}) do
        local v=value[key]
        if type(v)~="string" or #v<1 or #v>128 or v:find("[%z\1-\31\127]") then return nil end
        out[key]=v
    end
    return out
end
local function same(a,b)
    return a and b and a.world==b.world and a.actor==b.actor and a.session==b.session
end
local function roomLabel(value)
    if type(value)~="string" then return nil end
    local result=value:sub(1,64):gsub("[^%w _%.%-]","")
    return #result>0 and result or nil
end
local function position(value)
    if type(value)~="table" or not finite(value.x) or not finite(value.y)
        or math.abs(value.x)>1000000 or math.abs(value.y)>1000000
        or not integer(value.z,-100,100) then return nil end
    return {x=value.x,y=value.y,z=value.z,room=roomLabel(value.room)}
end
local function tile(p) return string.format("%d:%d:%d",math.floor(p.x),math.floor(p.y),p.z) end
local function failureKey(id,p) return tostring(id).."@"..tile(p) end
local function copy(value)
    local out={};for key,v in pairs(value) do out[key]=v end;return out
end
local function distance(a,b)
    local dx,dy=a.x-b.x,a.y-b.y
    return math.sqrt(dx*dx+dy*dy)
end

function ClaudePlaceMemory.new()
    local self={}
    local namespace,anchors,tiles,failures={}, {}, {}, {}
    local nextID,version,lastNow,origin,count,lastOutcomeSeq=1,0,nil,nil,0,0
    local function reset(newNamespace,now,preserveIDs)
        namespace=newNamespace
        anchors,tiles,failures={},{},{}
        count,origin,lastOutcomeSeq=0,nil,0
        if preserveIDs then version=version+1 else nextID,version=1,0 end
        lastNow=now
    end
    local function ready(expected,now)
        local requested=identity(expected)
        if not requested then return false,"place_identity_unknown" end
        if not same(namespace,requested) then return false,"place_identity_changed" end
        if not clock(now) then return false,"place_clock_unknown" end
        if lastNow and now<lastNow then
            reset(namespace,now,true)
            return false,"place_clock_regressed"
        end
        lastNow=now
        return true
    end
    local function pruneFailures()
        local list={};for key,record in pairs(failures) do list[#list+1]={key=key,record=record} end
        table.sort(list,function(a,b)
            if a.record.observedAt~=b.record.observedAt then return a.record.observedAt>b.record.observedAt end
            return a.record.seq>b.record.seq
        end)
        for i=MAX_FAILURES+1,#list do failures[list[i].key]=nil end
    end
    local function attempt(id,from,now)
        if not integer(id,1,MAX_ID) then return false,"place_id_invalid" end
        local anchor=anchors[id]
        if not anchor then return false,"place_not_remembered" end
        if from.z~=anchor.z then return false,"place_other_floor" end
        local d=distance(from,anchor)
        if d<=ARRIVAL then return false,"place_already_here" end
        if d>RANGE then return false,"place_out_of_range" end
        local failed=failures[failureKey(id,from)]
        if failed and now<failed.retryAfter then return false,"place_route_cooldown" end
        return true
    end
    function self:observe(expected,raw,now)
        local requested=identity(expected)
        if not requested then return false,"place_identity_unknown" end
        if not clock(now) then return false,"place_clock_unknown" end
        if not same(namespace,requested) then reset(requested,now,false)
        elseif lastNow and now<lastNow then reset(namespace,now,true) end
        lastNow=now
        local p=position(raw)
        if not p then return false,"place_position_unknown" end
        local key=tile(p)
        local known=tiles[key] and anchors[tiles[key]]
        if known then
            known.lastVisitedAt=now
            if p.room and p.room~=known.room then known.room=p.room;version=version+1 end
            return true
        end
        if nextID>MAX_ID then return false,"place_id_exhausted" end
        if count>=MAX_ANCHORS then
            local victim
            for id,anchor in pairs(anchors) do if id~=origin and (not victim
                or anchor.lastVisitedAt<anchors[victim].lastVisitedAt
                or (anchor.lastVisitedAt==anchors[victim].lastVisitedAt and id<victim)) then victim=id end end
            if not victim then return false,"place_memory_full" end
            tiles[tile(anchors[victim])]=nil
            anchors[victim]=nil;count=count-1
        end
        local id=nextID;nextID=nextID+1
        origin=origin or id
        anchors[id]={id=id,x=p.x,y=p.y,z=p.z,room=p.room,visitedAt=now,lastVisitedAt=now,origin=id==origin}
        tiles[key]=id;count=count+1;version=version+1
        return true
    end
    function self:resolve(id,expected,now)
        local ok,reason=ready(expected,now)
        if not ok then return nil,reason end
        if not integer(id,1,MAX_ID) then return nil,"place_id_invalid" end
        local anchor=anchors[id]
        if not anchor then return nil,"place_not_remembered" end
        return copy(anchor)
    end
    function self:canAttempt(id,raw,expected,now)
        local ok,reason=ready(expected,now)
        if not ok then return false,reason end
        local p=position(raw)
        if not p then return false,"place_position_unknown" end
        return attempt(id,p,now)
    end
    function self:recordOutcome(receipt,raw,now)
        if type(receipt)~="table" or receipt.action~="NAVIGATE"
            or not ({native_failed=true,no_effect=true,unverified=true})[receipt.status] then
            return false,"place_outcome_not_failure"
        end
        local ok,reason=ready(receipt,now)
        if not ok then return false,reason end
        if not integer(receipt.seq,1,MAX_ID) then return false,"place_outcome_sequence_invalid" end
        if receipt.seq<=lastOutcomeSeq then return false,"place_outcome_already_recorded" end
        local p=position(raw)
        local id=receipt.targetId
        if not p or not integer(id,1,MAX_ID) or not anchors[id] then return false,"place_outcome_target_unknown" end
        lastOutcomeSeq=receipt.seq
        local detail=type(receipt.detail)=="string" and receipt.detail:sub(1,128):gsub("[^%w _%.:%-]","") or "route_unverified"
        failures[failureKey(id,p)]={targetId=id,fromX=math.floor(p.x),fromY=math.floor(p.y),fromZ=p.z,
            status=receipt.status,detail=detail,observedAt=now,retryAfter=now+COOLDOWN,seq=receipt.seq}
        pruneFailures()
        return true
    end
    function self:snapshot(expected,raw,now)
        local result={valid=false,scope="current_session",anchors={},failures={},anchorCount=0,observationVersion=version}
        local ok,reason=ready(expected,now)
        if not ok then result.error=reason;result.observationVersion=version;return result end
        local p=position(raw)
        if not p then result.error="place_position_unknown";return result end
        result.valid=true
        result.world,result.actor,result.session=namespace.world,namespace.actor,namespace.session
        result.anchorCount,result.observationVersion=count,version
        local list={}
        for id,anchor in pairs(anchors) do
            local value=copy(anchor)
            value.distance=distance(p,anchor)
            value.canNavigate,value.blocker=attempt(id,p,now)
            list[#list+1]=value
        end
        table.sort(list,function(a,b)
            if a.origin~=b.origin then return a.origin end
            if a.distance~=b.distance then return a.distance<b.distance end
            if a.lastVisitedAt~=b.lastVisitedAt then return a.lastVisitedAt>b.lastVisitedAt end
            return a.id<b.id
        end)
        for i=1,math.min(#list,MAX_PUBLIC) do result.anchors[i]=list[i] end
        local failed={};for _,record in pairs(failures) do failed[#failed+1]=copy(record) end
        table.sort(failed,function(a,b)
            if a.observedAt~=b.observedAt then return a.observedAt>b.observedAt end
            return a.seq>b.seq
        end)
        for i=1,math.min(#failed,MAX_FAILURES) do result.failures[i]=failed[i] end
        return result
    end
    return self
end

local function quote(value)
    if type(value)~="string" then return "null" end
    value=value:sub(1,128):gsub("[\128-\255]","?")
    return '"'..value:gsub('[%z\1-\31\\"]',function(c)
        if c=='"' then return '\\"' end
        if c=='\\' then return '\\\\' end
        return string.format("\\u%04x",c:byte())
    end)..'"'
end
local booleanFields={valid=true,origin=true,canNavigate=true}
local numberFields={observationVersion=true,anchorCount=true,id=true,x=true,y=true,z=true,
    visitedAt=true,lastVisitedAt=true,distance=true,targetId=true,fromX=true,fromY=true,fromZ=true,
    observedAt=true,retryAfter=true,seq=true}
local function scalar(field,value)
    if numberFields[field] then return finite(value) and tostring(value) or "null" end
    if booleanFields[field] then return type(value)=="boolean" and tostring(value) or "null" end
    return quote(value)
end
local function records(values,fields,maximum)
    local list={};values=type(values)=="table" and values or {}
    for i=1,math.min(#values,maximum) do
        local value=type(values[i])=="table" and values[i] or {}
        local parts={}
        for _,field in ipairs(fields) do parts[#parts+1]=quote(field)..":"..scalar(field,value[field]) end
        list[#list+1]="{"..table.concat(parts,",").."}"
    end
    return "["..table.concat(list,",").."]"
end
function ClaudePlaceMemory.toJSON(snapshot)
    local ok,result=pcall(function()
        snapshot=type(snapshot)=="table" and snapshot or {valid=false,error="place_snapshot_unknown"}
        local fields={"valid","scope","world","actor","session","observationVersion","anchorCount","error"}
        local out={}
        for _,field in ipairs(fields) do out[#out+1]=quote(field)..":"..scalar(field,snapshot[field]) end
        out[#out+1]='"anchors":'..records(snapshot.anchors,{"id","x","y","z","room","visitedAt","lastVisitedAt","origin","distance","canNavigate","blocker"},MAX_PUBLIC)
        out[#out+1]='"failures":'..records(snapshot.failures,{"targetId","fromX","fromY","fromZ","status","detail","observedAt","retryAfter","seq"},MAX_FAILURES)
        return "{"..table.concat(out,",").."}"
    end)
    if ok and #result<=40000 then return result end
    return '{"valid":false,"scope":"current_session","error":"place_serialization_failed","anchors":[],"failures":[]}'
end

return ClaudePlaceMemory
