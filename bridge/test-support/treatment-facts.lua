-- Read-only treatment prerequisites; no mutation-capable action is loaded.
local directory=assert(arg[1])
dofile(directory.."/ClaudeTreatmentFacts.lua")
BodyPartType={MAX=17,ToIndex=function(v) return v end,ToString=function(v) return "Part_"..v end}
instanceof=function(item,kind)
    if kind=="InventoryItem" then return item.inventoryItem==true end
    if kind=="DrainableComboItem" then return item.drainable==true end
    return false
end
local function vector(list) return {size=function() return #list end,get=function(_,i) return list[i+1] end} end
local player,parts,items,inventory,item
local function supply(kind,id)
    local value={kind=kind or "Bandage",id=id or 1,inventoryItem=true,infected=false,power=4,uses=1,canBandage=true}
    function value:getContainer() return self.container end
    function value:getID() return self.id end
    function value:getType() return self.kind end
    function value:getModule() return self.module or "Base" end
    function value:getFullType() return self.fullType or self:getModule().."."..self.kind end
    function value:getUses() return self.uses end
    function value:getBandagePower() return self.power end
    function value:isCanBandage() return self.canBandage end
    function value:isInfected() return self.infected end
    value.container=inventory
    return value
end
local bools={"bandaged","bleeding","scratched","isCut","deepWounded","bitten","haveGlass","haveBullet","stitched","isBurnt","isSplint"}
local function reset()
    parts,items={},{}
    inventory={getItems=function() return vector(items) end}
    player={dead=false,isDead=function(self) return self.dead end,getUsername=function() return "survivor" end,
        getInventory=function() return inventory end,getBodyDamage=function() return {getBodyParts=function() return vector(parts) end} end}
    for index=0,16 do
        local part={index=index,kind=index,parent=player,burn=0,fracture=0}
        function part:getParentChar() return self.parent end
        function part:getIndex() return self.index end
        function part:getType() return self.kind end
        function part:getBurnTime() return self.burn end
        function part:getFractureTime() return self.fracture end
        function part:manipulatingUsername() return self.manipulator end
        for _,method in ipairs(bools) do
            part[method.."Value"]=false
            part[method]=function(self) return self[method.."Value"] end
        end
        parts[#parts+1]=part
    end
    parts[1].bleedingValue,parts[1].scratchedValue=true,true
    item=supply();items[1]=item
end
local count=0
local function test(name,fn) reset();fn();count=count+1;print("ok "..name) end
local function wound() return ClaudeTreatmentFacts.inspectWound(player,parts[1]) end
local function bandage() return ClaudeTreatmentFacts.inspectSupply(player,item) end

test("ordinary bleeding scratch and cut are supported",function()
    local fact=wound();assert(fact.allowed and fact.index==0 and fact.bodyPart==parts[1] and fact.name=="Part_0")
    parts[1].scratchedValue=false;parts[1].isCutValue=true;assert(wound().allowed)
end)
test("healthy and unrecognized bleeding wounds are refused",function()
    parts[1].bleedingValue=false;assert(not wound().allowed)
    parts[1].bleedingValue=true;parts[1].scratchedValue=false;assert(not wound().allowed)
end)
test("already bandaged wound is refused",function() parts[1].bandagedValue=true;assert(not wound().allowed) end)
test("all complex injury flags are refused",function()
    for _,method in ipairs({"deepWounded","bitten","haveGlass","haveBullet","stitched","isBurnt","isSplint"}) do
        parts[1][method.."Value"]=true;assert(not wound().allowed,method);parts[1][method.."Value"]=false
    end
end)
test("burn and fracture duration require known zero",function()
    for _,field in ipairs({"burn","fracture"}) do
        for _,value in ipairs({1,-1,math.huge,0/0}) do parts[1][field]=value;assert(not wound().allowed) end
        parts[1][field]=0
    end
end)
test("unknown boolean and missing critical method fail closed",function()
    for _,method in ipairs(bools) do
        local original=parts[1][method];parts[1][method]=function() return nil end
        assert(not wound().allowed,method);parts[1][method]=original
    end
    parts[1].haveGlass=nil;assert(wound().reason=="treatment_wound_facts_unavailable")
end)
test("body part owned by another character is refused",function()
    parts[1].parent={};assert(not wound().allowed)
end)
test("foreign reference outside own body list is refused",function()
    local foreign={getIndex=function() return 0 end};assert(not ClaudeTreatmentFacts.inspectWound(player,foreign).allowed)
end)
test("removed and replaced body part is refused",function()
    local old=parts[1];parts[1]=parts[2];assert(not ClaudeTreatmentFacts.inspectWound(player,old).allowed)
end)
test("index and enum type must match exact current slot",function()
    parts[1].index=1;assert(not wound().allowed)
    parts[1].index=0;parts[1].kind=1;assert(not wound().allowed)
end)
test("duplicate body reference and identity are refused",function()
    parts[2]=parts[1];assert(not wound().allowed)
    reset();parts[2].index=0;parts[2].kind=0;assert(not wound().allowed)
end)
test("incomplete and missing schema are unknown",function()
    table.remove(parts);assert(not wound().allowed)
    local max=BodyPartType.MAX;BodyPartType.MAX=nil;assert(not wound().allowed);BodyPartType.MAX=max
end)
test("dead or missing player cannot be treated",function()
    player.dead=true;assert(not wound().allowed and not bandage().allowed)
    assert(not ClaudeTreatmentFacts.inspectWound(nil,parts[1]).allowed)
end)
test("any existing doctor lock is unavailable for a new treatment",function()
    parts[1].manipulator="other";assert(not wound().allowed)
    parts[1].manipulator="survivor";assert(not wound().allowed)
    parts[1].manipulator={};assert(not wound().allowed)
end)
test("all five official clean supplies return canonical identity",function()
    for _,kind in ipairs({"Bandage","AlcoholBandage","Bandaid","RippedSheets","AlcoholRippedSheets"}) do
        item.kind=kind;local fact=bandage()
        assert(fact.allowed and fact.key=="item:1" and fact.name==kind and fact.fullType=="Base."..kind and fact.item==item)
    end
end)
test("dirty and unsupported supplies are refused despite positive power",function()
    for _,kind in ipairs({"BandageDirty","RippedSheetsDirty","DenimStrips","DirtyBandage","Unknown"}) do
        item.kind=kind;assert(not bandage().allowed)
    end
end)
test("infected or unknown supply cleanliness is refused",function()
    item.infected=true;assert(not bandage().allowed)
    item.infected=nil;assert(not bandage().allowed)
end)
test("foreign or nested supplies are refused",function()
    item.container={};assert(not bandage().allowed)
    item.container=inventory;items={};assert(not bandage().allowed)
end)
test("item ID must be a finite supported integer",function()
    for _,id in ipairs({-1,9007199254740992,1.5,math.huge,0/0,"1"}) do item.id=id;assert(not bandage().allowed) end
    item.id=2147483648;assert(bandage().allowed and bandage().key=="item:2147483648")
end)
test("module and full type must match supported canonical item",function()
    item.module="Mod";assert(not bandage().allowed)
    item.module=nil;item.fullType="Base.RippedSheets";assert(not bandage().allowed)
end)
test("drainable and multiuse supplies are refused",function()
    item.drainable=true;assert(not bandage().allowed)
    item.drainable=false;item.uses=2;assert(not bandage().allowed)
    item.uses=0;assert(not bandage().allowed)
end)
test("positive bandage power and CanBandage property are both required",function()
    for _,power in ipairs({0,-1,math.huge,0/0,"4"}) do item.power=power;assert(not bandage().allowed) end
    item.power=4;item.canBandage=false;assert(not bandage().allowed)
    item.canBandage=nil;assert(not bandage().allowed)
end)
test("missing supply API fails closed",function()
    item.isInfected=nil;assert(bandage().reason=="treatment_supply_facts_unavailable")
end)
test("noninventory objects cannot masquerade as normal bandages",function()
    item.inventoryItem=false;assert(not bandage().allowed)
end)
test("complete read returns only public wound and supply facts",function()
    local facts=ClaudeTreatmentFacts.read(player)
    assert(facts.valid and facts.status=="observed" and #facts.eligibleWounds==1 and #facts.supplies==1)
    assert(facts.scannedParts==17 and facts.scannedItems==1)
    assert(facts.eligibleWounds[1].bodyPart==nil and facts.supplies[1].item==nil)
end)
test("incomplete body can retain supply observation without eligible treatment",function()
    table.remove(parts);local facts=ClaudeTreatmentFacts.read(player)
    assert(not facts.valid and facts.status=="partial" and #facts.eligibleWounds==0 and #facts.supplies==1)
end)
test("no supported wounds or supplies is known empty when all facts readable",function()
    parts[1].bleedingValue=false;items={};local facts=ClaudeTreatmentFacts.read(player)
    assert(facts.valid and facts.status=="observed" and #facts.eligibleWounds==0 and #facts.supplies==0)
end)
test("unknown wound facts preserve other readable supply facts",function()
    parts[1].bleeding=function() return nil end;local facts=ClaudeTreatmentFacts.read(player)
    assert(not facts.valid and facts.status=="partial" and #facts.supplies==1)
end)
test("inventory scan and public supply list are bounded",function()
    for i=2,513 do items[i]=supply("Bandage",i) end
    local facts=ClaudeTreatmentFacts.read(player)
    assert(not facts.valid and facts.scannedItems==512 and #facts.supplies==16)
end)
test("unknown inventory size fails closed",function()
    inventory.getItems=function() return {size=function() return math.huge end} end
    local facts=ClaudeTreatmentFacts.read(player);assert(not facts.valid and #facts.supplies==0)
end)
test("JSON serialization is bounded and strips engine/extraneous fields",function()
    local facts=ClaudeTreatmentFacts.read(player);facts.secret="MUST_NOT_SERIALIZE";facts.supplies[1].item=item
    local json=ClaudeTreatmentFacts.toJSON(facts)
    assert(not json:find("MUST_NOT_SERIALIZE",1,true) and not json:find("function",1,true))
    print("JSON:"..json)
end)
test("JSON handles missing, malformed and nonfinite facts",function()
    print("JSON:"..ClaudeTreatmentFacts.toJSON(nil))
    print("JSON:"..ClaudeTreatmentFacts.toJSON({valid=false,status='bad\0\n"\\',scannedParts=math.huge,
        eligibleWounds={{index=0/0,name="x\001y"}},supplies={{key="item:1",name=string.rep("x",10000),fullType="Base.Bandage"}}}))
end)
print("passed "..count.." treatment facts Lua tests")
