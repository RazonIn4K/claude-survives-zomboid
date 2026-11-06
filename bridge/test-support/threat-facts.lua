-- Deterministic observation fixtures, not a live-game danger assessment.
dofile(assert(arg[1]))
local passed=0
local function test(name,fn) fn();passed=passed+1;print("ok "..name) end
local function zombie(x,y)
    return {getX=function() return x end,getY=function() return y end,
        getZ=function() error("floor filtering is not part of threat awareness") end,
        isVisibleToPlayer=function() error("visibility filtering is not part of threat awareness") end}
end
local function world(entries,size)
    local list={size=function() return size or #entries end,get=function(_,index) return entries[index+1] end}
    getCell=function() return {getZombieList=function() return list end} end
    return list
end
local function unknown(result)
    assert(result.valid==false and result.status=="unknown" and result.scanned==0)
    assert(type(result.error)=="string")
end
local function sample(label,result) print("JSON "..label.." "..ClaudeThreatFacts.toJSON(result)) end

test("only an observed empty list is a known all-clear",function()
    world({});local result=ClaudeThreatFacts.read(0,0)
    assert(result.valid and result.status=="observed" and result.zTotal==0 and result.zDist==-1)
    assert(result.zNear==0 and result.zClose==0 and result.zDir=="-" and result.scanned==0)
    sample("empty",result)
end)
test("all loaded entries contribute exact distances and radius counts",function()
    world({zombie(3,4),zombie(12,0),zombie(31,0),zombie(-10,0)})
    local result=ClaudeThreatFacts.read(0,0)
    assert(result.valid and result.zTotal==4 and result.scanned==4)
    assert(result.zNear==3 and result.zClose==2 and result.zDist==5 and result.zDir=="S")
    assert(result.dx==3 and result.dy==4)
end)
test("positions are relative to the player and radius boundaries are included",function()
    world({zombie(110,100),zombie(130,100)})
    local result=ClaudeThreatFacts.read(100,100)
    assert(result.valid and result.zDist==10 and result.zNear==2 and result.zClose==1 and result.zDir=="E")
end)
test("same-position zombie is an observed immediate threat",function()
    world({zombie(4,8)});local result=ClaudeThreatFacts.read(4,8)
    assert(result.valid and result.zDist==0 and result.zDir=="HERE" and result.zClose==1)
end)
test("distant zombies are not capped at the old sentinel distance",function()
    world({zombie(12000,0)});local result=ClaudeThreatFacts.read(0,0)
    assert(result.valid and result.zTotal==1 and result.zDist==12000 and result.zNear==0)
end)
test("missing cell API is unknown",function()
    getCell=nil;local result=ClaudeThreatFacts.read(0,0);unknown(result);assert(result.zTotal==-1)
    sample("missing",result)
end)
test("missing and failing cells cannot claim no zombies",function()
    getCell=function() return nil end;unknown(ClaudeThreatFacts.read(0,0))
    getCell=function() error("fixture cell failure") end;unknown(ClaudeThreatFacts.read(0,0))
end)
test("missing and failing zombie lists are unknown",function()
    getCell=function() return {getZombieList=function() return nil end} end
    unknown(ClaudeThreatFacts.read(0,0))
    getCell=function() return {getZombieList=function() error("fixture list failure") end} end
    unknown(ClaudeThreatFacts.read(0,0))
end)
test("malformed player positions fail before reading the world",function()
    getCell=function() error("world should not be read") end
    for _,bad in ipairs({false,"0",0/0,math.huge,-math.huge}) do
        local result=ClaudeThreatFacts.read(bad,0);unknown(result)
        assert(result.error=="threat_player_position_unknown")
        unknown(ClaudeThreatFacts.read(0,bad))
    end
    unknown(ClaudeThreatFacts.read(nil,0))
end)
test("list counts require bounded-safe nonnegative integers",function()
    for _,bad in ipairs({false,"0",-1,0.5,0/0,math.huge,9007199254740992}) do
        local list=world({});list.size=function() return bad end
        local result=ClaudeThreatFacts.read(0,0);unknown(result);assert(result.zTotal==-1)
    end
end)
test("a throwing count API is unknown",function()
    local list=world({});list.size=function() error("fixture size failure") end
    unknown(ClaudeThreatFacts.read(0,0))
end)
test("missing first entry cannot claim a complete scan",function()
    world({},1);local result=ClaudeThreatFacts.read(0,0);unknown(result);assert(result.zTotal==1)
end)
test("partial scans retain known close threats without claiming validity",function()
    world({zombie(2,0)},2);local result=ClaudeThreatFacts.read(0,0)
    assert(not result.valid and result.status=="partial" and result.scanned==1)
    assert(result.zTotal==2 and result.zDist==2 and result.zClose==1)
    sample("partial",result)
end)
test("entry read exceptions remain partial after prior successful reads",function()
    local list=world({zombie(-3,-4)},2)
    list.get=function(_,index) if index==1 then error("fixture entry failure") end;return zombie(-3,-4) end
    local result=ClaudeThreatFacts.read(0,0)
    assert(not result.valid and result.status=="partial" and result.zDist==5 and result.zDir=="N")
end)
test("malformed zombie coordinates are unknown",function()
    for _,bad in ipairs({false,"0",0/0,math.huge,-math.huge}) do
        world({zombie(bad,0)});unknown(ClaudeThreatFacts.read(0,0))
        world({zombie(0,bad)});unknown(ClaudeThreatFacts.read(0,0))
    end
    world({zombie(nil,0)});unknown(ClaudeThreatFacts.read(0,0))
end)
test("coordinate API exceptions do not escape the read boundary",function()
    world({{getX=function() error("fixture position failure") end}})
    unknown(ClaudeThreatFacts.read(0,0))
end)
test("overflowing distance arithmetic cannot be a known far-away threat",function()
    world({zombie(1e308,0)});local result=ClaudeThreatFacts.read(-1e308,0)
    unknown(result);assert(result.error=="threat_distance_unknown")
    world({zombie(1e200,0)});unknown(ClaudeThreatFacts.read(0,0))
end)
test("duplicate entity references reject list completeness",function()
    local value=zombie(2,0);world({value,value})
    local result=ClaudeThreatFacts.read(0,0)
    assert(not result.valid and result.status=="partial" and result.scanned==1)
end)
test("list growth or shrinkage during observation invalidates it",function()
    for _,changed in ipairs({0,2}) do
        local list=world({zombie(2,0)});local calls=0
        list.size=function() calls=calls+1;return calls==1 and 1 or changed end
        local result=ClaudeThreatFacts.read(0,0)
        assert(not result.valid and result.error=="threat_list_changed" and result.status=="partial")
    end
end)
test("exact scan limit can be complete",function()
    local list=world({},16384);local calls=0
    list.get=function(_,index) calls=calls+1;return zombie(index+1,0) end
    local result=ClaudeThreatFacts.read(0,0)
    assert(result.valid and result.scanned==16384 and calls==16384 and result.zDist==1)
end)
test("oversized lists are bounded partial observations",function()
    local list=world({},16385);local calls=0
    list.get=function(_,index) calls=calls+1;assert(index<16384);return zombie(index+1,0) end
    local result=ClaudeThreatFacts.read(0,0)
    assert(not result.valid and result.status=="partial" and result.error=="threat_scan_bounded")
    assert(result.scanned==16384 and calls==16384 and result.zTotal==16385 and result.zDist==1)
    sample("bounded",result)
end)
test("a fresh failed scan cannot inherit an earlier all-clear",function()
    world({});assert(ClaudeThreatFacts.read(0,0).valid)
    getCell=function() return nil end;unknown(ClaudeThreatFacts.read(0,0))
end)
print("passed "..passed.." threat facts Lua tests")
