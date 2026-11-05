-- Conservative, read-only local piped-water facts. No path, action, or stat mutation.
-- B42.21 anchors: shared/luautils.lua:363-381 (reach); shared/TimedActions/
-- ISTakeWaterAction.lua (fluid use); IsoObject getFluidAmount/getPrimaryFluid/
-- transferFluidTo bytecode (piped reserve/infinite versus external/mixed fluids).
ClaudeWaterFacts = {}

local MAX_OBJECTS, MAX_PER_SQUARE, MAX_ITEMS = 512, 64, 512
local MAX_SOURCES, MAX_VESSELS, MAX_TEXT = 8, 16, 128
local function finite(v)
    return type(v)=="number" and v==v and v>-math.huge and v<math.huge
end
local function integer(v,low,high)
    return finite(v) and v==math.floor(v) and v>=low and v<=high
end
local function denied(reason) return {allowed=false,reason=reason} end
local function position(square)
    if not square then return nil end
    local x,y,z=square:getX(),square:getY(),square:getZ()
    if not integer(x,-1000000,1000000) or not integer(y,-1000000,1000000)
        or not integer(z,-100,100) then return nil end
    return x,y,z
end
local function knownClean(fc)
    return fc:isPureFluid(Fluid.Water)==true and fc:isTainted()==false and fc:isPoisonous()==false
end
local function reach(player,square)
    local ok,value=pcall(function()
        local current=player:getCurrentSquare()
        if not current then return nil end
        local correct=luautils.getCorrectSquareForWall(player,square)
        if not correct then return nil end
        local x,y,z=position(correct)
        local px,py,pz=player:getX(),player:getY(),player:getZ()
        if not x or not finite(px) or not finite(py) or not finite(pz) then return nil end
        if z~=math.floor(pz) then return false end
        if math.abs(x+0.5-px)>1.6 or math.abs(y+0.5-py)>1.6 then return false end
        local canReach=current:canReachTo(correct)
        if type(canReach)=="boolean" then return canReach end
        return nil
    end)
    if ok then return value end
    return nil
end

function ClaudeWaterFacts.inspectSource(player,source,requireReach)
    local ok,result=pcall(function()
        if not player or player:isDead()~=false then return denied("water_player_unavailable") end
        if not source or instanceof(source,"IsoObject")~=true then return denied("water_source_type_unsupported") end
        for _,kind in ipairs({"IsoClothingWasher","IsoCombinationWasherDryer","IsoClothingDryer","IsoWorldInventoryObject"}) do
            if instanceof(source,kind)==true then return denied("water_source_type_unsupported") end
        end
        local props=source:getProperties()
        if not props then return denied("water_source_not_piped") end
        local piped=props:has(IsoFlagType.waterPiped)
        if type(piped)~="boolean" then return denied("water_source_flags_unknown") end
        if not piped then return denied("water_source_not_piped") end
        -- Native transfer checks natural-water and puddle branches before local
        -- fluid containers. Exclude both, even on an unusual waterPiped sprite.
        if props:has(IsoFlagType.water)~=false or props:has(IsoFlagType.solidfloor)~=false then
            return denied("water_source_natural_or_unknown")
        end
        local square=source:getSquare()
        local x,y,z=position(square)
        local current=player:getCurrentSquare()
        local px,py,pz=player:getX(),player:getY(),player:getZ()
        if not x or not current or not finite(px) or not finite(py) or not finite(pz) then
            return denied("water_source_position_unknown")
        end
        if z~=math.floor(pz) or current:getZ()~=z then return denied("water_source_wrong_floor") end
        if math.abs(x-math.floor(px))+math.abs(y-math.floor(py))>4 then return denied("water_source_out_of_range") end
        local index=source:getObjectIndex()
        local objects=square:getObjects()
        if not integer(index,0,1000000) or not objects or not integer(objects:size(),0,1000000)
            or index>=objects:size() or objects:get(index)~=source then return denied("water_source_removed_or_replaced") end
        if source:getUsesExternalWaterSource()~=false then return denied("water_external_source_or_unknown") end
        local amount=source:getFluidAmount()
        if source:hasFluid()~=true or source:hasWater()~=true or not finite(amount) or amount<=0 then
            return denied("water_source_empty_or_unknown")
        end
        if not Fluid or not Fluid.Water or source:getPrimaryFluid()~=Fluid.Water
            or source:isTaintedWater()~=false then return denied("water_source_not_clean") end
        local fc=source:getFluidContainer()
        if fc then
            local localAmount,empty=fc:getAmount(),fc:isEmpty()
            if not finite(localAmount) or localAmount<0 or type(empty)~="boolean"
                or empty~=(localAmount==0) then return denied("water_source_fluid_unknown") end
            if not empty and not knownClean(fc) then return denied("water_source_mixed_tainted_or_poisoned") end
        end
        -- With no nonempty local fluid container, the combined native facts
        -- above identify clean generated piped/reserve water. No appearance,
        -- isFilledWithCleanWater flag, or primary-water mixture is trusted.
        local reachable=reach(player,square)
        if requireReach and reachable~=true then
            return denied(reachable==false and "water_source_not_reached" or "water_source_reach_unknown")
        end
        return {allowed=true,reason="water_source_ready",key=string.format("%d:%d:%d:%d",x,y,z,index),
            x=x,y=y,z=z,index=index,amount=amount,reachable=reachable,source=source}
    end)
    return ok and result or denied("water_source_facts_unavailable")
end

local function inspectVessel(player,item,allowFull,knownInventory,knownItems)
    local ok,result=pcall(function()
        if not player or player:isDead()~=false or not item then return denied("water_vessel_unavailable") end
        local inventory=knownInventory or player:getInventory()
        if not inventory or item:getContainer()~=inventory then return denied("water_vessel_not_owned") end
        if not knownItems then
            local items=inventory:getItems()
            local size=items and items:size()
            if not integer(size,0,1000000) then return denied("water_inventory_unknown") end
            local found=false
            for i=0,math.min(size,MAX_ITEMS)-1 do if items:get(i)==item then found=true;break end end
            if not found then return denied(size>MAX_ITEMS and "water_inventory_scan_bounded" or "water_vessel_not_owned") end
        elseif knownItems[item]~=true then return denied("water_vessel_not_owned") end
        local id=item:getID()
        if not integer(id,0,9007199254740991) then return denied("water_vessel_identity_unknown") end
        local fc=item:getFluidContainer()
        if not fc then return denied("water_vessel_no_fluid_container") end
        local amount,capacity,empty=fc:getAmount(),fc:getCapacity(),fc:isEmpty()
        if not finite(amount) or not finite(capacity) or amount<0 or capacity<=0 or amount>capacity
            or type(empty)~="boolean" or empty~=(amount==0) then return denied("water_vessel_fluid_unknown") end
        local full=capacity-amount<=0.000001
        if full and allowFull~=true then return denied("water_vessel_full") end
        if fc:isInputLocked()~=false or fc:canAddFluid(Fluid.Water)~=true then return denied("water_vessel_cannot_fill") end
        if not empty and not knownClean(fc) then return denied("water_vessel_mixed_tainted_or_poisoned") end
        return {allowed=true,reason="water_vessel_ready",key="item:"..string.format("%.0f",id),
            amount=amount,capacity=capacity,full=full,item=item,container=fc}
    end)
    return ok and result or denied("water_vessel_facts_unavailable")
end

-- allowFull is only for validating settled completion without adding more
-- fluid. Default eligibility never selects a vessel with no free capacity.
function ClaudeWaterFacts.inspectVessel(player,item,allowFull)
    return inspectVessel(player,item,allowFull)
end

local function publicSource(fact)
    return {key=fact.key,x=fact.x,y=fact.y,z=fact.z,index=fact.index,amount=fact.amount,reachable=fact.reachable}
end
local function mark(snapshot,reason)
    snapshot.valid=false
    snapshot.error=snapshot.error or reason
end
local function unknownReason(reason)
    return type(reason)=="string" and (reason:find("unknown",1,true) or reason:find("unavailable",1,true)
        or reason:find("bounded",1,true))
end
local function sourceBefore(a,b,px,py)
    local ar=a.reachable==true and 0 or (a.reachable==false and 1 or 2)
    local br=b.reachable==true and 0 or (b.reachable==false and 1 or 2)
    if ar~=br then return ar<br end
    local ad,bd=math.abs(a.x-px)+math.abs(a.y-py),math.abs(b.x-px)+math.abs(b.y-py)
    if ad~=bd then return ad<bd end
    return a.key<b.key
end

-- Bounded loaded proximity facts, not visibility or a promise that a route exists.
function ClaudeWaterFacts.read(player)
    local snapshot={valid=true,status="observed",sources={},fillableVessels={},scannedSquares=0,
        scannedObjects=0,scannedItems=0}
    local ok=pcall(function()
        if not player or player:isDead()~=false then error("player unavailable") end
        local px,py,pz=player:getX(),player:getY(),player:getZ()
        if not finite(px) or not finite(py) or not finite(pz) then error("position unknown") end
        px,py,pz=math.floor(px),math.floor(py),math.floor(pz)
        local cell=getCell()
        for dx=-4,4 do for dy=-4,4 do if math.abs(dx)+math.abs(dy)<=4 then
            local square=cell:getGridSquare(px+dx,py+dy,pz)
            snapshot.scannedSquares=snapshot.scannedSquares+1
            if not square then mark(snapshot,"water_square_unloaded")
            else
                local objects=square:getObjects()
                local size=objects and objects:size()
                if not integer(size,0,1000000) then mark(snapshot,"water_objects_unknown")
                else
                    if size>MAX_PER_SQUARE then mark(snapshot,"water_object_scan_bounded") end
                    for i=0,math.min(size,MAX_PER_SQUARE)-1 do
                        if snapshot.scannedObjects>=MAX_OBJECTS then mark(snapshot,"water_object_scan_bounded");break end
                        snapshot.scannedObjects=snapshot.scannedObjects+1
                        local object=objects:get(i)
                        local fact=object and ClaudeWaterFacts.inspectSource(player,object,false) or denied("water_object_unknown")
                        if fact.allowed then
                            snapshot.sources[#snapshot.sources+1]=publicSource(fact)
                            table.sort(snapshot.sources,function(a,b) return sourceBefore(a,b,px,py) end)
                            if #snapshot.sources>MAX_SOURCES then
                                table.remove(snapshot.sources)
                                mark(snapshot,"water_source_list_bounded")
                            end
                            if fact.reachable==nil then mark(snapshot,"water_source_reach_unknown") end
                        elseif unknownReason(fact.reason) then mark(snapshot,fact.reason) end
                    end
                end
            end
        end end end
        local inventory=player:getInventory()
        local items=inventory and inventory:getItems()
        local size=items and items:size()
        if not integer(size,0,1000000) then mark(snapshot,"water_inventory_unknown");return end
        if size>MAX_ITEMS then mark(snapshot,"water_inventory_scan_bounded") end
        local observedItems,owned={},{}
        for i=0,math.min(size,MAX_ITEMS)-1 do
            snapshot.scannedItems=snapshot.scannedItems+1
            local item=items:get(i)
            if item then observedItems[#observedItems+1]=item;owned[item]=true
            else mark(snapshot,"water_inventory_item_unknown") end
        end
        for _,item in ipairs(observedItems) do
            local fact=inspectVessel(player,item,false,inventory,owned)
            if fact.allowed then
                if #snapshot.fillableVessels<MAX_VESSELS then
                    snapshot.fillableVessels[#snapshot.fillableVessels+1]={key=fact.key,amount=fact.amount,capacity=fact.capacity}
                else mark(snapshot,"water_vessel_list_bounded") end
            elseif unknownReason(fact.reason) then mark(snapshot,fact.reason) end
        end
    end)
    if not ok then mark(snapshot,"water_scan_unavailable") end
    if not snapshot.valid then snapshot.status=(#snapshot.sources>0 or #snapshot.fillableVessels>0) and "partial" or "unknown" end
    return snapshot
end

local function quoted(value)
    if type(value)~="string" then return "null" end
    local out,i,count={'"'},1,0
    while i<=#value and count<MAX_TEXT do
        local byte=value:byte(i)
        if byte<128 then
            if byte==34 then out[#out+1]='\\"'
            elseif byte==92 then out[#out+1]='\\\\'
            elseif byte<32 then out[#out+1]=string.format("\\u%04x",byte)
            else out[#out+1]=string.char(byte) end
            i=i+1
        else
            local length=byte>=194 and byte<=223 and 2 or (byte>=224 and byte<=239 and 3 or (byte>=240 and byte<=244 and 4 or 0))
            local valid=length>0 and i+length-1<=#value
            local second=value:byte(i+1)
            if valid then
                for offset=1,length-1 do local nextByte=value:byte(i+offset);if nextByte<128 or nextByte>191 then valid=false end end
                if (byte==224 and second<160) or (byte==237 and second>159)
                    or (byte==240 and second<144) or (byte==244 and second>143) then valid=false end
            end
            if valid then out[#out+1]=value:sub(i,i+length-1);i=i+length
            else out[#out+1]="\\ufffd";i=i+1 end
        end
        count=count+1
    end
    out[#out+1]='"';return table.concat(out)
end
local function number(v) return finite(v) and tostring(v) or "null" end
local function boolean(v) return type(v)=="boolean" and tostring(v) or "null" end
local function listJSON(values,fields,maximum)
    local out={}
    values=type(values)=="table" and values or {}
    for i=1,math.min(#values,maximum) do
        local item=type(values[i])=="table" and values[i] or {}
        local encoded={}
        for _,field in ipairs(fields) do
            local v=item[field]
            encoded[#encoded+1]=quoted(field)..":"..(field=="key" and quoted(v) or (field=="reachable" and boolean(v) or number(v)))
        end
        out[#out+1]="{"..table.concat(encoded,",").."}"
    end
    return "["..table.concat(out,",").."]"
end
function ClaudeWaterFacts.toJSON(snapshot)
    local ok,result=pcall(function()
        snapshot=type(snapshot)=="table" and snapshot or {valid=false,status="unknown",error="water_snapshot_unavailable"}
        return '{"valid":'..boolean(snapshot.valid)..',"status":'..quoted(snapshot.status)..',"error":'..quoted(snapshot.error)
            ..',"scannedSquares":'..number(snapshot.scannedSquares)..',"scannedObjects":'..number(snapshot.scannedObjects)
            ..',"scannedItems":'..number(snapshot.scannedItems)..',"sources":'
            ..listJSON(snapshot.sources,{"key","x","y","z","index","amount","reachable"},MAX_SOURCES)
            ..',"fillableVessels":'..listJSON(snapshot.fillableVessels,{"key","amount","capacity"},MAX_VESSELS)..'}'
    end)
    if ok and #result<=16384 then return result end
    return '{"valid":false,"status":"unknown","error":"water_serialization_failed","sources":[],"fillableVessels":[]}'
end

return ClaudeWaterFacts
