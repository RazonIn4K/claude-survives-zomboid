-- Engine API fixtures only; no game/server/provider is started.
dofile(assert(arg[1]))
local player,source,vessel,inventory,current,squares,items
local function vector(values) return {size=function() return #values end,get=function(_,i) return values[i+1] end} end
local function fluid(amount,capacity)
    local fc={amount=amount or 0,capacity=capacity or 1,pure=true,tainted=false,poisoned=false,locked=false,accept=true}
    function fc:getAmount() return self.amount end
    function fc:getCapacity() return self.capacity end
    function fc:isEmpty() return self.amount==0 end
    function fc:isPureFluid(kind) assert(kind==Fluid.Water);return self.pure end
    function fc:isTainted() return self.tainted end
    function fc:isPoisonous() return self.poisoned end
    function fc:isInputLocked() return self.locked end
    function fc:canAddFluid(kind) assert(kind==Fluid.Water);return self.accept end
    return fc
end
local function square(x,y,z)
    local sq={x=x,y=y,z=z,objects={},canReach=true}
    function sq:getX() return self.x end
    function sq:getY() return self.y end
    function sq:getZ() return self.z end
    function sq:getObjects() return vector(self.objects) end
    function sq:canReachTo() return self.canReach end
    return sq
end
local function addSource(x,y,z)
    local sq=squares[x..":"..y..":"..z] or square(x,y,z)
    squares[x..":"..y..":"..z]=sq
    local s={square=sq,index=#sq.objects,amount=10,primary="water",tainted=false,external=false,flags={piped=true}}
    sq.objects[#sq.objects+1]=s
    function s:getProperties() return {has=function(_,flag) return self.flags[flag] or false end} end
    function s:getSquare() return self.square end
    function s:getObjectIndex() return self.index end
    function s:getUsesExternalWaterSource() return self.external end
    function s:getFluidAmount() return self.amount end
    function s:hasFluid() return self.amount>0 end
    function s:hasWater() return true end
    function s:getPrimaryFluid() return self.primary end
    function s:isTaintedWater() return self.tainted end
    function s:getFluidContainer() return self.fc end
    return s
end
local function addVessel(id)
    local it={id=id or #items+1,fc=fluid(0,1)}
    items[#items+1]=it
    function it:getContainer() return inventory end
    function it:getID() return self.id end
    function it:getFluidContainer() return self.fc end
    return it
end
local function reset()
    Fluid={Water="water"};IsoFlagType={waterPiped="piped",water="natural",solidfloor="floor"}
    instanceof=function(object,kind) return object and (kind=="IsoObject" or object.kind==kind) or false end
    squares,items={},{}
    current=square(100,100,0)
    squares["100:100:0"]=current
    inventory={getItems=function() return vector(items) end}
    player={x=100.5,y=100.5,z=0}
    function player:getX() return self.x end
    function player:getY() return self.y end
    function player:getZ() return self.z end
    function player:isDead() return false end
    function player:getCurrentSquare() return current end
    function player:getInventory() return inventory end
    luautils={getCorrectSquareForWall=function(_,sq) return sq end}
    getCell=function() return {getGridSquare=function(_,x,y,z)
        return squares[x..":"..y..":"..z] or square(x,y,z)
    end} end
    source=addSource(100,100,0)
    vessel=addVessel(42)
end
local count=0
local function test(name,fn) reset();fn();count=count+1;print("ok "..name) end
local function rejectsSource(reason,required)
    local fact=ClaudeWaterFacts.inspectSource(player,source,required)
    assert(not fact.allowed,reason.." incorrectly allowed")
    if reason then assert(fact.reason==reason,fact.reason.." ~= "..reason) end
end
local function rejectsVessel(reason)
    local fact=ClaudeWaterFacts.inspectVessel(player,vessel)
    assert(not fact.allowed,reason.." incorrectly allowed")
    if reason then assert(fact.reason==reason,fact.reason.." ~= "..reason) end
end

test("native local piped water without a fluid container is eligible",function()
    local fact=ClaudeWaterFacts.inspectSource(player,source,true)
    assert(fact.allowed and fact.key=="100:100:0:0" and fact.reachable==true and fact.source==source)
end)
test("nonempty source requires pure untainted nonpoisonous water",function()
    source.fc=fluid(5,10);assert(ClaudeWaterFacts.inspectSource(player,source,true).allowed)
end)
test("empty local fluid container may use native piped reserve facts",function()
    source.fc=fluid(0,10);assert(ClaudeWaterFacts.inspectSource(player,source,true).allowed)
end)
test("primary water alone does not accept a mixture",function()
    source.fc=fluid(5,10);source.fc.pure=false;rejectsSource("water_source_mixed_tainted_or_poisoned")
end)
test("taint false does not accept poisoned water",function()
    source.fc=fluid(5,10);source.fc.poisoned=true;rejectsSource("water_source_mixed_tainted_or_poisoned")
end)
test("tainted source or fluid is refused",function()
    source.tainted=true;rejectsSource("water_source_not_clean")
    source.tainted=false;source.fc=fluid(5,10);source.fc.tainted=true;rejectsSource("water_source_mixed_tainted_or_poisoned")
end)
test("external rain reservoir composition is never inferred",function()
    source.external=true;rejectsSource("water_external_source_or_unknown")
end)
test("empty nonfinite and nonwater sources are refused",function()
    source.amount=0;rejectsSource("water_source_empty_or_unknown")
    source.amount=math.huge;rejectsSource("water_source_empty_or_unknown")
    source.amount=10;source.primary="bleach";rejectsSource("water_source_not_clean")
end)
test("washers dryers and world inventory sources are unsupported",function()
    for _,kind in ipairs({"IsoClothingWasher","IsoCombinationWasherDryer","IsoClothingDryer","IsoWorldInventoryObject"}) do
        source.kind=kind;rejectsSource("water_source_type_unsupported")
    end
end)
test("natural and floor flags are refused despite piped flag",function()
    source.flags.natural=true;rejectsSource("water_source_natural_or_unknown")
    source.flags.natural=nil;source.flags.floor=true;rejectsSource("water_source_natural_or_unknown")
end)
test("removed or replacement object cannot retain source identity",function()
    source.index=-1;rejectsSource("water_source_removed_or_replaced")
    source.index=0;source.square.objects[1]={};rejectsSource("water_source_removed_or_replaced")
end)
test("sources on another floor or beyond four tiles are refused",function()
    source.square.z=1;rejectsSource("water_source_wrong_floor")
    source.square.z=0;source.square.x=105;rejectsSource("water_source_out_of_range")
end)
test("out of reach source remains observation but cannot execute",function()
    source=addSource(104,100,0)
    local fact=ClaudeWaterFacts.inspectSource(player,source,false)
    assert(fact.allowed and fact.reachable==false)
    rejectsSource("water_source_not_reached",true)
end)
test("wall obstruction is real unreachable rather than unknown",function()
    current.canReach=false
    assert(ClaudeWaterFacts.inspectSource(player,source,false).reachable==false)
    rejectsSource("water_source_not_reached",true)
end)
test("correct wall square is used for reach",function()
    local corrected=square(104,100,0)
    luautils.getCorrectSquareForWall=function(_,sq) assert(sq==source.square);return corrected end
    rejectsSource("water_source_not_reached",true)
end)
test("missing reach API cannot authorize consumption",function()
    luautils=nil
    local fact=ClaudeWaterFacts.inspectSource(player,source,false)
    assert(fact.allowed and fact.reachable==nil)
    rejectsSource("water_source_reach_unknown",true)
end)
test("missing source API fails closed",function()
    source.getUsesExternalWaterSource=nil;rejectsSource("water_source_facts_unavailable")
end)
test("inconsistent local fluid facts fail closed",function()
    source.fc=fluid(1,5);source.fc.isEmpty=function() return true end
    rejectsSource("water_source_fluid_unknown")
end)
test("empty top level inventory vessel is fillable",function()
    local fact=ClaudeWaterFacts.inspectVessel(player,vessel)
    assert(fact.allowed and fact.key=="item:42" and fact.item==vessel and fact.container==vessel.fc)
end)
test("partly filled clean water vessel is fillable",function()
    vessel.fc.amount=0.25;assert(ClaudeWaterFacts.inspectVessel(player,vessel).allowed)
end)
test("full and overcapacity vessels are refused",function()
    vessel.fc.amount=1;rejectsVessel("water_vessel_full")
    vessel.fc.amount=2;rejectsVessel("water_vessel_fluid_unknown")
end)
test("settled full vessel is allowed only through explicit safe completion mode",function()
    vessel.fc.amount=1
    assert(ClaudeWaterFacts.inspectVessel(player,vessel,true).allowed)
    assert(ClaudeWaterFacts.inspectVessel(player,vessel,true).full==true)
    assert(not ClaudeWaterFacts.inspectVessel(player,vessel,"true").allowed)
    vessel.fc.poisoned=true
    assert(not ClaudeWaterFacts.inspectVessel(player,vessel,true).allowed)
end)
test("foreign or absent inventory item is refused",function()
    vessel.getContainer=function() return {} end;rejectsVessel("water_vessel_not_owned")
    vessel.getContainer=function() return inventory end;items={};rejectsVessel("water_vessel_not_owned")
end)
test("mixture tainted and poison vessel contents are refused",function()
    vessel.fc.amount=0.25
    vessel.fc.pure=false;rejectsVessel("water_vessel_mixed_tainted_or_poisoned")
    vessel.fc.pure=true;vessel.fc.tainted=true;rejectsVessel("water_vessel_mixed_tainted_or_poisoned")
    vessel.fc.tainted=false;vessel.fc.poisoned=true;rejectsVessel("water_vessel_mixed_tainted_or_poisoned")
end)
test("locked or incompatible vessels are refused",function()
    vessel.fc.locked=true;rejectsVessel("water_vessel_cannot_fill")
    vessel.fc.locked=false;vessel.fc.accept=false;rejectsVessel("water_vessel_cannot_fill")
end)
test("nonfluid and identity unknown vessels are refused",function()
    vessel.fc=nil;rejectsVessel("water_vessel_no_fluid_container")
    vessel.fc=fluid(0,1);vessel.id=math.huge;rejectsVessel("water_vessel_identity_unknown")
end)
test("missing vessel API and inconsistent empty state fail closed",function()
    vessel.fc.isInputLocked=nil;rejectsVessel("water_vessel_facts_unavailable")
    vessel.fc=fluid(0,1);vessel.fc.isEmpty=function() return false end;rejectsVessel("water_vessel_fluid_unknown")
end)
test("complete read emits bounded public facts without engine references",function()
    local snap=ClaudeWaterFacts.read(player)
    assert(snap.valid and snap.status=="observed" and snap.scannedSquares==41 and snap.scannedObjects==1)
    assert(#snap.sources==1 and #snap.fillableVessels==1)
    assert(snap.sources[1].source==nil and snap.fillableVessels[1].item==nil and snap.fillableVessels[1].container==nil)
    print("JSON complete "..ClaudeWaterFacts.toJSON(snap))
end)
test("unreadable scan preserves known facts as partial",function()
    getCell=function() return {getGridSquare=function(_,x,y,z) return squares[x..":"..y..":"..z] end} end
    local snap=ClaudeWaterFacts.read(player)
    assert(not snap.valid and snap.status=="partial" and #snap.sources==1)
    print("JSON partial "..ClaudeWaterFacts.toJSON(snap))
end)
test("unknown reach remains null in a partial observation",function()
    luautils=nil
    local snap=ClaudeWaterFacts.read(player)
    assert(not snap.valid and snap.sources[1].reachable==nil)
    print("JSON unknown_reach "..ClaudeWaterFacts.toJSON(snap))
end)
test("source ordering prefers reached then nearest then stable identity",function()
    source=addSource(101,100,0);addSource(104,100,0)
    local snap=ClaudeWaterFacts.read(player)
    assert(snap.sources[1].key=="100:100:0:0" and snap.sources[2].key=="101:100:0:0"
        and snap.sources[3].key=="104:100:0:0")
end)
test("source and vessel lists are bounded with incomplete marker",function()
    for i=1,20 do addSource(100,100,0);addVessel(i+100) end
    local snap=ClaudeWaterFacts.read(player)
    assert(not snap.valid and #snap.sources==8 and #snap.fillableVessels==16)
end)
test("bounded source list retains a late reached source ahead of distant sources",function()
    source.square.objects={}
    for i=1,8 do addSource(96,100,0) end
    addSource(100,100,0)
    local snap=ClaudeWaterFacts.read(player)
    assert(not snap.valid and #snap.sources==8 and snap.sources[1].key=="100:100:0:0")
end)
test("object enumeration is bounded",function()
    for _=1,100 do source.square.objects[#source.square.objects+1]={kind="furniture",getProperties=function() return nil end} end
    local snap=ClaudeWaterFacts.read(player)
    assert(not snap.valid and snap.scannedObjects==64)
end)
test("inventory enumeration is bounded",function()
    for i=1,520 do addVessel(i+100) end
    local snap=ClaudeWaterFacts.read(player)
    assert(not snap.valid and snap.scannedItems==512 and #snap.fillableVessels==16)
end)
test("nil inventory entry is incomplete rather than a successful empty scan",function()
    inventory.getItems=function() return {size=function() return 2 end,get=function(_,index) return index==0 and vessel or nil end} end
    local snap=ClaudeWaterFacts.read(player)
    assert(not snap.valid and snap.scannedItems==2 and #snap.fillableVessels==1)
end)
test("unknown piped flag cannot establish source safety",function()
    source.getProperties=function() return {has=function() return nil end} end
    rejectsSource("water_source_flags_unknown")
end)
test("unknown entire scan returns explicit unknown",function()
    player.getX=nil
    local snap=ClaudeWaterFacts.read(player)
    assert(not snap.valid and snap.status=="unknown")
end)
test("serializer bounds fields and lists and omits references",function()
    local snap={valid=true,status="q\"\\\n\r\t\0\1",extra="secret",sources={},fillableVessels={},scannedItems=math.huge}
    for i=1,100 do snap.sources[i]={key=string.rep("é",200),x=0/0,source={secret=true}};snap.fillableVessels[i]={key="item:1",capacity=1} end
    print("JSON bounded "..ClaudeWaterFacts.toJSON(snap))
    print("JSON missing "..ClaudeWaterFacts.toJSON(nil))
end)
print("passed "..count.." water facts Lua tests")
