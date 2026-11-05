-- Read-only conservative self-bandaging prerequisites. Native B42.21 anchors:
-- client/XpSystem/ISUI/ISHealthPanel.lua:1153-1192 selects positive bandagePower;
-- shared/TimedActions/ISApplyBandage.lua:112-139 consumes one whole item;
-- scripts/generated/items/normal.txt:8037-8131,10656-10670 defines these supplies.
-- This does not diagnose infection or implement glass removal/advanced care.
ClaudeTreatmentFacts = {}

local MAX_PARTS,MAX_ITEMS,MAX_SUPPLIES=32,512,16
local supported={Bandage=true,AlcoholBandage=true,Bandaid=true,RippedSheets=true,AlcoholRippedSheets=true}
local function finite(v) return type(v)=="number" and v==v and v>-math.huge and v<math.huge end
local function integer(v,low,high) return finite(v) and v==math.floor(v) and v>=low and v<=high end
local function denied(reason) return {allowed=false,reason=reason} end
local function expectedParts()
    if not BodyPartType or not BodyPartType.MAX then return nil end
    local count=BodyPartType.ToIndex(BodyPartType.MAX)
    return integer(count,1,MAX_PARTS) and count or nil
end

-- Enumerate the current schema to reject borrowed, stale, duplicate or
-- misindexed body-part references before either selecting or treating one.
local function ownedParts(player)
    if not player or player:isDead()~=false then return nil,"treatment_player_unavailable" end
    local expected=expectedParts()
    if not expected then return nil,"treatment_schema_unknown" end
    local damage=player:getBodyDamage()
    local parts=damage and damage:getBodyParts()
    local size=parts and parts:size()
    if not integer(size,1,MAX_PARTS) or size~=expected then return nil,"treatment_body_parts_incomplete" end
    local result,seen={},{}
    for i=0,size-1 do
        local part=parts:get(i)
        if not part or part:getParentChar()~=player or part:getIndex()~=i
            or BodyPartType.ToIndex(part:getType())~=i or seen[part] then
            return nil,"treatment_body_part_identity_unknown"
        end
        seen[part]=true
        result[i+1]=part
    end
    return result
end

local function inspectWound(player,part,knownParts)
    local parts,reason=knownParts
    if not parts then parts,reason=ownedParts(player) end
    if not parts then return denied(reason) end
    if not part then return denied("treatment_body_part_missing") end
    local index=part:getIndex()
    if not integer(index,0,#parts-1) or parts[index+1]~=part then
        return denied("treatment_body_part_not_owned")
    end
    local name=BodyPartType.ToString(part:getType())
    if type(name)~="string" or #name<1 or #name>48 or not name:match("^[%w_]+$") then
        return denied("treatment_body_part_name_unknown")
    end
    local bandaged,bleeding,scratch,cut=part:bandaged(),part:bleeding(),part:scratched(),part:isCut()
    if type(bandaged)~="boolean" or type(bleeding)~="boolean" or type(scratch)~="boolean" or type(cut)~="boolean" then
        return denied("treatment_wound_state_unknown")
    end
    if bandaged then return denied("treatment_already_bandaged") end
    if not bleeding or not (scratch or cut) then return denied("treatment_no_supported_bleeding_wound") end
    for _,method in ipairs({"deepWounded","bitten","haveGlass","haveBullet","stitched","isBurnt","isSplint"}) do
        local value=part[method](part)
        if type(value)~="boolean" then return denied("treatment_complex_wound_state_unknown") end
        if value then return denied("treatment_complex_wound_unsupported") end
    end
    local burn,fracture=part:getBurnTime(),part:getFractureTime()
    if not finite(burn) or not finite(fracture) or burn<0 or fracture<0 then
        return denied("treatment_complex_wound_state_unknown")
    end
    if burn>0 or fracture>0 then return denied("treatment_complex_wound_unsupported") end
    local owner=part:manipulatingUsername()
    if owner~=nil and type(owner)~="string" then return denied("treatment_wound_lock_unknown") end
    if owner~=nil and owner~="" then return denied("treatment_wound_busy") end
    return {allowed=true,reason="treatment_wound_ready",index=index,name=name,bodyPart=part}
end

function ClaudeTreatmentFacts.inspectWound(player,part)
    local ok,result=pcall(inspectWound,player,part)
    return ok and result or denied("treatment_wound_facts_unavailable")
end

local function inspectSupply(player,item,knownInventory,knownItems)
    if not player or player:isDead()~=false or not item then return denied("treatment_supply_unavailable") end
    local inventory=knownInventory or player:getInventory()
    if not inventory or item:getContainer()~=inventory then return denied("treatment_supply_not_owned") end
    if knownItems then
        if not knownItems[item] then return denied("treatment_supply_not_owned") end
    else
        local items=inventory:getItems()
        local size=items and items:size()
        if not integer(size,0,1000000) then return denied("treatment_inventory_unknown") end
        local found=false
        for i=0,math.min(size,MAX_ITEMS)-1 do if items:get(i)==item then found=true;break end end
        if not found then return denied(size>MAX_ITEMS and "treatment_inventory_scan_bounded" or "treatment_supply_not_owned") end
    end
    local id=item:getID()
    if not integer(id,0,9007199254740991) then return denied("treatment_supply_identity_unknown") end
    local kind,fullType,module=item:getType(),item:getFullType(),item:getModule()
    if type(kind)~="string" or not supported[kind] or module~="Base" or fullType~="Base."..kind then
        return denied("treatment_supply_type_unsupported")
    end
    if type(instanceof)~="function" or instanceof(item,"InventoryItem")~=true
        or instanceof(item,"DrainableComboItem")~=false then return denied("treatment_supply_type_unsupported") end
    if item:getUses()~=1 then return denied("treatment_supply_multiple_uses_unsupported") end
    local power=item:getBandagePower()
    if not finite(power) or power<=0 or item:isCanBandage()~=true then return denied("treatment_supply_not_bandage") end
    if kind:find("Dirty",1,true) or item:isInfected()~=false then return denied("treatment_supply_unclean_or_unknown") end
    return {allowed=true,reason="treatment_supply_ready",key="item:"..string.format("%.0f",id),
        name=kind,fullType=fullType,item=item}
end

function ClaudeTreatmentFacts.inspectSupply(player,item)
    local ok,result=pcall(inspectSupply,player,item)
    return ok and result or denied("treatment_supply_facts_unavailable")
end

local function mark(snapshot,reason)
    snapshot.valid=false;snapshot.error=snapshot.error or reason
end
local function unknown(reason)
    return type(reason)=="string" and (reason:find("unknown",1,true) or reason:find("unavailable",1,true)
        or reason:find("incomplete",1,true) or reason:find("bounded",1,true))
end

function ClaudeTreatmentFacts.read(player)
    local snapshot={valid=true,status="observed",eligibleWounds={},supplies={},scannedParts=0,scannedItems=0}
    local ok=pcall(function()
        local parts,reason=ownedParts(player)
        if not parts then mark(snapshot,reason)
        else for _,part in ipairs(parts) do
            snapshot.scannedParts=snapshot.scannedParts+1
            local fact=inspectWound(player,part,parts)
            if fact.allowed then snapshot.eligibleWounds[#snapshot.eligibleWounds+1]={index=fact.index,name=fact.name}
            elseif unknown(fact.reason) then mark(snapshot,fact.reason) end
        end end
        local inventory=player:getInventory()
        local items=inventory and inventory:getItems()
        local size=items and items:size()
        if not integer(size,0,1000000) then mark(snapshot,"treatment_inventory_unknown");return end
        if size>MAX_ITEMS then mark(snapshot,"treatment_inventory_scan_bounded") end
        local list,owned={},{}
        for i=0,math.min(size,MAX_ITEMS)-1 do
            snapshot.scannedItems=snapshot.scannedItems+1
            local item=items:get(i)
            if item then list[#list+1]=item;owned[item]=true else mark(snapshot,"treatment_inventory_item_unknown") end
        end
        for _,item in ipairs(list) do
            local fact=inspectSupply(player,item,inventory,owned)
            if fact.allowed then
                if #snapshot.supplies<MAX_SUPPLIES then
                    snapshot.supplies[#snapshot.supplies+1]={key=fact.key,name=fact.name,fullType=fact.fullType}
                else mark(snapshot,"treatment_supply_list_bounded") end
            elseif unknown(fact.reason) then mark(snapshot,fact.reason) end
        end
    end)
    if not ok then mark(snapshot,"treatment_scan_unavailable") end
    if not snapshot.valid then
        snapshot.status=(#snapshot.eligibleWounds>0 or #snapshot.supplies>0) and "partial" or "unknown"
    end
    return snapshot
end

-- Only bounded canonical labels and keys are exposed; engine objects/extra
-- fields are never serialized. Escape every control byte including NUL.
local function quote(value)
    if type(value)~="string" then return "null" end
    value=value:sub(1,128):gsub("[\128-\255]","?")
    return '"'..value:gsub('[%z\1-\31\\"]',function(c)
        if c=='"' then return '\\"' end
        if c=='\\' then return '\\\\' end
        return string.format("\\u%04x",c:byte())
    end)..'"'
end
local function number(value) return finite(value) and tostring(value) or "null" end
function ClaudeTreatmentFacts.toJSON(snapshot)
    local ok,result=pcall(function()
        snapshot=type(snapshot)=="table" and snapshot or {valid=false,status="unknown",error="treatment_snapshot_unavailable"}
        local wounds,supplies={},{}
        local source=type(snapshot.eligibleWounds)=="table" and snapshot.eligibleWounds or {}
        for i=1,math.min(#source,MAX_PARTS) do
            local v=type(source[i])=="table" and source[i] or {}
            wounds[#wounds+1]='{"index":'..number(v.index)..',"name":'..quote(v.name)..'}'
        end
        source=type(snapshot.supplies)=="table" and snapshot.supplies or {}
        for i=1,math.min(#source,MAX_SUPPLIES) do
            local v=type(source[i])=="table" and source[i] or {}
            supplies[#supplies+1]='{"key":'..quote(v.key)..',"name":'..quote(v.name)..',"fullType":'..quote(v.fullType)..'}'
        end
        local valid=type(snapshot.valid)=="boolean" and tostring(snapshot.valid) or "null"
        return '{"valid":'..valid..',"status":'..quote(snapshot.status)..',"error":'..quote(snapshot.error)
            ..',"scannedParts":'..number(snapshot.scannedParts)..',"scannedItems":'..number(snapshot.scannedItems)
            ..',"eligibleWounds":['..table.concat(wounds,",")..'],"supplies":['..table.concat(supplies,",")..']}'
    end)
    if ok and #result<12000 then return result end
    return '{"valid":false,"status":"unknown","error":"treatment_serialization_failed","eligibleWounds":[],"supplies":[]}'
end

return ClaudeTreatmentFacts
