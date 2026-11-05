-- Deterministic API fixtures; these are not a real-game medical playtest.
dofile(assert(arg[1]))
local count=0
local function test(name, fn) fn();count=count+1;print("ok "..name) end
BodyPartType={MAX={index=17,name="MAX"},ToIndex=function(kind) return kind and kind.index or 0 end,
    ToString=function(kind) return kind and kind.name or "Unknown" end}
local function part(index,extra)
    local values={injured=false,bleeding=false,scratch=false,cut=false,deepWound=false,
        bite=false,glass=false,bandaged=false,life=1}
    for k,v in pairs(extra or {}) do values[k]=v end
    local value={getType=function()return {index=index or 0,name="Hand_"..tostring(index or 0)}end}
    for field,method in pairs({injured="HasInjury",bleeding="bleeding",scratch="scratched",cut="isCut",
        deepWound="deepWounded",bite="bitten",glass="haveGlass",bandaged="bandaged",life="getBandageLife"}) do
        local key=field
        value[method]=function() return values[key] end
    end
    return value
end
local function player(parts,size)
    if size==nil then
        local full={}
        for index=0,16 do full[index+1]=part(index) end
        for slot,value in ipairs(parts) do
            local ok,kind=pcall(function()return value:getType()end)
            local index=ok and kind and kind.index or slot-1
            full[index+1]=value
        end
        parts=full
    end
    return {getBodyDamage=function()return {getBodyParts=function()return {
        size=function()return size==nil and #parts or size end,
        get=function(_,i)return parts[i+1]end,
    }end}end}
end
test("healthy body has an observed empty injury array",function()
    local result=ClaudeHealthFacts.read(player({part(0),part(1)}))
    assert(result.valid and result.status=="observed" and #result.injuries==0)
    assert(result.partCount==17 and result.expectedParts==17 and result.observedParts==17
        and result.summary.unknownParts==0 and result.summary.urgency=="none")
    print("JSON healthy "..ClaudeHealthFacts.toJSON(result))
end)
test("bleeding and glass identify stable parts and urgency",function()
    local result=ClaudeHealthFacts.read(player({part(0,{bleeding=true,cut=true}),part(1,{glass=true,deepWound=true})}))
    assert(result.valid and #result.injuries==2 and result.injuries[2].index==1)
    assert(result.injuries[2].name=="Hand_1" and result.summary.injuredParts==2)
    assert(result.summary.bleedingParts==1 and result.summary.glassParts==1)
    assert(result.summary.untreatedBleedingParts==1 and result.summary.urgency=="bleeding")
    print("JSON injured "..ClaudeHealthFacts.toJSON(result))
end)
test("bandage cleanliness is observed without inferring a healed injury",function()
    local result=ClaudeHealthFacts.read(player({part(0,{injured=true,bandaged=true,life=0}),part(1,{bandaged=true})}))
    assert(result.valid and result.summary.bandagedParts==2 and result.summary.injuredParts==1)
    assert(result.injuries[1].bandageDirty and result.injuries[2].bandageDirty==false)
end)
test("all named wound flags remain distinguishable",function()
    local result=ClaudeHealthFacts.read(player({part(3,{scratch=true,cut=true,deepWound=true,bite=true})}))
    local fact=result.injuries[1]
    assert(result.valid and fact.scratch and fact.cut and fact.deepWound and fact.bite)
end)
test("missing player and body APIs never imply healthy",function()
    for _,p in ipairs({false,{}, {getBodyDamage=function()error("fixture read failure")end}}) do
        local result=ClaudeHealthFacts.read(p)
        assert(not result.valid and result.status=="unknown" and result.summary.urgency=="unknown")
        assert(result.error=="body_damage_unavailable")
    end
end)
test("missing body-parts API is explicit unknown",function()
    local result=ClaudeHealthFacts.read({getBodyDamage=function()return {}end})
    assert(not result.valid and result.error=="body_parts_unavailable")
end)
test("oversized fractional and nonfinite part counts are rejected",function()
    for _,size in ipairs({33,1.5,math.huge,0/0}) do
        local result=ClaudeHealthFacts.read(player({},size))
        assert(not result.valid and result.error=="body_part_count_invalid")
    end
end)
test("part read failure preserves known injuries and records partial unknown",function()
    local result=ClaudeHealthFacts.read(player({part(0,{glass=true}),false},2))
    assert(not result.valid and result.status=="partial" and result.observedParts==1)
    assert(result.summary.glassParts==1 and result.summary.unknownParts==16 and result.expectedParts==17)
    assert(result.summary.urgency=="embedded_glass" and result.injuries[2].valid==false)
    print("JSON partial "..ClaudeHealthFacts.toJSON(result))
end)
test("a missing wound method cannot silently turn into false",function()
    local value=part(0);value.haveGlass=nil
    local result=ClaudeHealthFacts.read(player({value}))
    assert(not result.valid and result.summary.unknownParts==1 and result.summary.urgency=="unknown")
    assert(result.error=="body_part_state_unavailable")
end)
test("nonboolean wound results are unknown",function()
    local value=part(0);value.bleeding=function()return 0 end
    assert(not ClaudeHealthFacts.read(player({value})).valid)
end)
test("failed enum identity and duplicate IDs are unknown",function()
    local values=BodyPartType;BodyPartType=nil
    assert(not ClaudeHealthFacts.read(player({part(0)})).valid)
    BodyPartType=values
    local result=ClaudeHealthFacts.read(player({part(0),part(0)},2))
    assert(not result.valid and result.error=="duplicate_body_part_identity")
end)
test("unreadable bandage state is not a clean bandage",function()
    local value=part(0,{bandaged=true});value.getBandageLife=function()return 0/0 end
    assert(ClaudeHealthFacts.read(player({value})).error=="bandage_state_unavailable")
end)
test("body parts whose collection throws are explicit unknown",function()
    local p=player({part(0)})
    p.getBodyDamage=function()return {getBodyParts=function()return {size=function()return 1 end,get=function()error("broken collection")end}end}end
    assert(not ClaudeHealthFacts.read(p).valid)
end)
test("read does not call treatment or mutation methods",function()
    local value=part(0,{bleeding=true,glass=true})
    value.setBleeding=function()error("mutation forbidden")end
    value.setHaveGlass=function()error("mutation forbidden")end
    assert(ClaudeHealthFacts.read(player({value})).valid)
end)
test("JSON escapes quotes backslashes and control characters",function()
    local result=ClaudeHealthFacts.read(player({part(0,{glass=true})}))
    result.injuries[1].name='q"\\\n\r\t'..string.char(0,1,31)
    print("JSON escaped "..ClaudeHealthFacts.toJSON(result))
end)
test("JSON converts nonfinite numbers to null and ignores extra fields",function()
    local result=ClaudeHealthFacts.read(player({part(0,{glass=true})}))
    result.partCount=math.huge;result.injuries[1].index=0/0;result.summary.glassParts=-math.huge
    result.extra={secret="must not serialize"};result.self=result
    print("JSON nonfinite "..ClaudeHealthFacts.toJSON(result))
end)
test("JSON is bounded and preserves valid unicode at the truncation boundary",function()
    local result=ClaudeHealthFacts.read(player({part(0,{glass=true})}))
    result.injuries[1].name=string.rep("é",1000)
    for i=2,100 do result.injuries[i]=result.injuries[1] end
    local text=ClaudeHealthFacts.toJSON(result)
    assert(#text<=32768)
    print("JSON bounded "..text)
end)
test("JSON replaces invalid UTF8 and handles malformed snapshots",function()
    local result=ClaudeHealthFacts.read(player({part(0,{glass=true})}))
    result.injuries[1].name=string.char(255,192,175)
    print("JSON malformed_text "..ClaudeHealthFacts.toJSON(result))
    print("JSON missing "..ClaudeHealthFacts.toJSON(nil))
end)
test("truncated observations retain injuries and count all missing body parts",function()
    local result=ClaudeHealthFacts.read(player({part(0,{bleeding=true,cut=true})},1))
    assert(not result.valid and result.status=="partial" and result.error=="body_parts_incomplete")
    assert(result.expectedParts==17 and result.observedParts==1 and result.summary.unknownParts==16)
    assert(result.summary.bleedingParts==1 and result.summary.urgency=="bleeding")
    print("JSON truncated "..ClaudeHealthFacts.toJSON(result))
end)
test("healthy entries in an incomplete list never claim the whole body is healthy",function()
    for _,size in ipairs({0,1,2,16}) do
        local parts={};for index=0,size-1 do parts[#parts+1]=part(index) end
        local result=ClaudeHealthFacts.read(player(parts,size))
        assert(not result.valid and result.status=="partial" and result.summary.urgency=="unknown")
        assert(result.summary.unknownParts==17-size and result.expectedParts==17)
    end
end)
test("IDs outside the enum schema and nil types are rejected",function()
    for _,index in ipairs({-1,17,31}) do
        local result=ClaudeHealthFacts.read(player({part(index)},1))
        assert(not result.valid and result.observedParts==0 and result.summary.unknownParts==17)
        assert(result.error=="body_part_identity_unavailable")
    end
    local value=part(0);value.getType=function()return nil end
    assert(ClaudeHealthFacts.read(player({value},1)).error=="body_part_identity_unavailable")
end)
test("missing or invalid MAX cannot define a complete body schema",function()
    local maximum=BodyPartType.MAX
    for _,value in ipairs({false,{index=0},{index=33},{index=1.5},{index=math.huge}}) do
        BodyPartType.MAX=value
        local result=ClaudeHealthFacts.read(player({part(0)},1))
        assert(not result.valid and result.status=="unknown" and result.error=="body_part_schema_unavailable")
        assert(result.summary.urgency=="unknown")
    end
    BodyPartType.MAX=nil
    assert(ClaudeHealthFacts.read(player({part(0)},1)).error=="body_part_schema_unavailable")
    BodyPartType.MAX=maximum
end)
test("complete unique IDs can be observed in any collection order",function()
    local parts={};for index=16,0,-1 do parts[#parts+1]=part(index) end
    local result=ClaudeHealthFacts.read(player(parts,17))
    assert(result.valid and result.observedParts==17 and result.summary.unknownParts==0)
end)
test("a duplicate in a full-length list cannot replace a missing identity",function()
    local parts={};for index=0,16 do parts[#parts+1]=part(index) end
    parts[17]=part(0)
    local result=ClaudeHealthFacts.read(player(parts,17))
    assert(not result.valid and result.error=="duplicate_body_part_identity")
    assert(result.observedParts==16 and result.summary.unknownParts==1 and result.summary.urgency=="unknown")
end)
print("passed "..count.." health facts Lua tests")
