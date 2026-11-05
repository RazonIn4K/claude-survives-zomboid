-- Read-only local-player body observations. No treatment or stat mutation.
-- API anchors: official B42.21 client/XpSystem/ISUI/ISHealthPanel.lua
-- getDamagedParts (514-525), wound flags (631-683), bleeding (732),
-- bandage cleanliness (772-776), and lodged glass (844). Full enumeration:
-- ISClothingInsPanel.lua:636 uses 0..BodyPartType.ToIndex(BodyPartType.MAX)-1.
ClaudeHealthFacts = {}

local MAX_PARTS, MAX_TEXT = 32, 128
local stateMethods = {
    injured="HasInjury", bleeding="bleeding", scratch="scratched", cut="isCut",
    deepWound="deepWounded", bite="bitten", glass="haveGlass", bandaged="bandaged",
}
local stateOrder = {"injured", "bleeding", "scratch", "cut", "deepWound", "bite", "glass", "bandaged"}

local function finite(value)
    return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
end
local function integer(value, minimum, maximum)
    return finite(value) and value==math.floor(value) and value>=minimum and value<=maximum
end
local function call(object, method)
    local ok, value = pcall(function() return object[method](object) end)
    if not ok then return nil end
    return value
end
local function unknown(reason, expected)
    return {valid=false, status="unknown", error=reason, partCount=0, expectedParts=expected,
        observedParts=0, injuries={},
        summary={injuredParts=0, bleedingParts=0, glassParts=0, bandagedParts=0,
            untreatedBleedingParts=0, unknownParts=expected or 0, urgency="unknown"}}
end

local function expectedCount()
    local ok, expected=pcall(function()
        if not BodyPartType.MAX then return nil end
        return BodyPartType.ToIndex(BodyPartType.MAX)
    end)
    if ok and integer(expected,1,MAX_PARTS) then return expected end
    return nil
end

local function observePart(part, expected)
    if not part then return nil, "body_part_unavailable" end
    local kind=call(part,"getType")
    if not kind then return nil,"body_part_identity_unavailable" end
    local ok, index, name=pcall(function()
        return BodyPartType.ToIndex(kind), BodyPartType.ToString(kind)
    end)
    if not ok or not integer(index,0,expected-1) or type(name)~="string"
        or #name==0 or #name>48 or not name:match("^[%w_]+$") then
        return nil, "body_part_identity_unavailable"
    end
    local fact={valid=true,index=index,name=name}
    for _,field in ipairs(stateOrder) do
        local value=call(part,stateMethods[field])
        if type(value)~="boolean" then return nil,"body_part_state_unavailable" end
        fact[field]=value
    end
    if fact.bandaged then
        local life=call(part,"getBandageLife")
        if not finite(life) then return nil,"bandage_state_unavailable" end
        fact.bandageDirty=life<=0
    end
    return fact
end

function ClaudeHealthFacts.read(player)
    local expected=expectedCount()
    if not expected then return unknown("body_part_schema_unavailable") end
    local body=call(player,"getBodyDamage")
    if not body then return unknown("body_damage_unavailable",expected) end
    local parts=call(body,"getBodyParts")
    if not parts then return unknown("body_parts_unavailable",expected) end
    local size=call(parts,"size")
    if not integer(size,0,MAX_PARTS) then return unknown("body_part_count_invalid",expected) end
    local snapshot=unknown(nil,expected)
    snapshot.valid, snapshot.status, snapshot.partCount=true,"observed",size
    local summary, seen=snapshot.summary,{}
    for i=0,size-1 do
        local ok, part=pcall(function() return parts:get(i) end)
        local fact, reason
        if ok then fact,reason=observePart(part,expected) else reason="body_part_unavailable" end
        if fact and seen[fact.index] then fact,reason=nil,"duplicate_body_part_identity" end
        if not fact then
            snapshot.valid=false
            snapshot.error=snapshot.error or reason
            snapshot.injuries[#snapshot.injuries+1]={valid=false,listIndex=i,error=reason}
        else
            seen[fact.index]=true
            snapshot.observedParts=snapshot.observedParts+1
            -- HasInjury covers additional game injury types beyond the named flags.
            local injured=fact.injured or fact.bleeding or fact.scratch or fact.cut
                or fact.deepWound or fact.bite or fact.glass
            if injured then summary.injuredParts=summary.injuredParts+1 end
            if fact.bleeding then summary.bleedingParts=summary.bleedingParts+1 end
            if fact.glass then summary.glassParts=summary.glassParts+1 end
            if fact.bandaged then summary.bandagedParts=summary.bandagedParts+1 end
            if fact.bleeding and not fact.bandaged then
                summary.untreatedBleedingParts=summary.untreatedBleedingParts+1
            end
            if injured or fact.bandaged then snapshot.injuries[#snapshot.injuries+1]=fact end
        end
    end
    -- A readable truncated list is still incomplete: only unique, fully read
    -- IDs in the current schema count toward a complete body observation.
    summary.unknownParts=expected-snapshot.observedParts
    if size~=expected or summary.unknownParts>0 then
        snapshot.valid=false
        snapshot.error=snapshot.error or "body_parts_incomplete"
    end
    if not snapshot.valid then snapshot.status="partial" end
    if summary.bleedingParts>0 then summary.urgency="bleeding"
    elseif summary.glassParts>0 then summary.urgency="embedded_glass"
    elseif summary.injuredParts>0 then summary.urgency="injured"
    elseif not snapshot.valid then summary.urgency="unknown"
    else summary.urgency="none" end
    return snapshot
end

-- Schema-specific JSON keeps output bounded and ignores arbitrary extra fields.
-- Strings are limited by Unicode characters; malformed UTF-8 becomes U+FFFD.
local function quoted(value)
    if type(value)~="string" then return "null" end
    local out, i, count={'"'},1,0
    while i<=#value and count<MAX_TEXT do
        local byte=value:byte(i)
        if byte<128 then
            if byte==34 then out[#out+1]='\\"'
            elseif byte==92 then out[#out+1]='\\\\'
            elseif byte<32 then out[#out+1]=string.format("\\u%04x",byte)
            else out[#out+1]=string.char(byte) end
            i=i+1
        else
            local length=byte>=194 and byte<=223 and 2 or (byte>=224 and byte<=239 and 3
                or (byte>=240 and byte<=244 and 4 or 0))
            local valid=length>0 and i+length-1<=#value
            local second=value:byte(i+1)
            if valid then
                for offset=1,length-1 do
                    local continuation=value:byte(i+offset)
                    if continuation<128 or continuation>191 then valid=false end
                end
                if (byte==224 and second<160) or (byte==237 and second>159)
                    or (byte==240 and second<144) or (byte==244 and second>143) then valid=false end
            end
            if valid then out[#out+1]=value:sub(i,i+length-1);i=i+length
            else out[#out+1]="\\ufffd";i=i+1 end
        end
        count=count+1
    end
    out[#out+1]='"'
    return table.concat(out)
end
local function number(value)
    return finite(value) and tostring(value) or "null"
end
local function boolean(value)
    return type(value)=="boolean" and tostring(value) or "null"
end
local partFields={"valid","index","name","listIndex","error","injured","bleeding","scratch",
    "cut","deepWound","bite","glass","bandaged","bandageDirty"}
local summaryFields={"injuredParts","bleedingParts","glassParts","bandagedParts",
    "untreatedBleedingParts","unknownParts"}
local function scalar(value)
    if type(value)=="boolean" then return boolean(value) end
    if type(value)=="number" then return number(value) end
    return quoted(value)
end
function ClaudeHealthFacts.toJSON(snapshot)
    local ok, result=pcall(function()
        if type(snapshot)~="table" then snapshot=unknown("snapshot_unavailable") end
        local out={"{\"valid\":"..boolean(snapshot.valid),',"status":'..quoted(snapshot.status),
            ',"partCount":'..number(snapshot.partCount),',"expectedParts":'..number(snapshot.expectedParts),
            ',"observedParts":'..number(snapshot.observedParts)}
        if snapshot.error~=nil then out[#out+1]=',"error":'..quoted(snapshot.error) end
        out[#out+1]=',"injuries":['
        local injuries=type(snapshot.injuries)=="table" and snapshot.injuries or {}
        for i=1,math.min(#injuries,MAX_PARTS) do
            if i>1 then out[#out+1]="," end
            local item=type(injuries[i])=="table" and injuries[i] or {}
            local fields={}
            for _,field in ipairs(partFields) do
                if item[field]~=nil then fields[#fields+1]=quoted(field)..":"..scalar(item[field]) end
            end
            out[#out+1]="{"..table.concat(fields,",").."}"
        end
        out[#out+1]='],"summary":{'
        local summary=type(snapshot.summary)=="table" and snapshot.summary or {}
        for i,field in ipairs(summaryFields) do
            if i>1 then out[#out+1]="," end
            out[#out+1]=quoted(field)..":"..number(summary[field])
        end
        out[#out+1]=',"urgency":'..quoted(summary.urgency).."}}"
        return table.concat(out)
    end)
    if ok and #result<=32768 then return result end
    return '{"valid":false,"status":"unknown","error":"serialization_failed","injuries":[],"summary":{"urgency":"unknown"}}'
end
