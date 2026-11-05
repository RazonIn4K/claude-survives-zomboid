-- Pure factual-memory fixtures. No game, filesystem persistence or model calls.
local directory=assert(arg[1])
dofile(directory.."/ClaudePlaceMemory.lua")
local memory,who,now
local function reset()
    memory=ClaudePlaceMemory.new();who={world="world",actor="0",session="session"};now=1000
end
local function pos(x,y,z,room) return {x=x or 0.5,y=y or 0.5,z=z or 0,room=room} end
local function observe(p) now=now+10;return memory:observe(who,p or pos(),now) end
local function snapshot(p) return memory:snapshot(who,p or pos(),now) end
local function outcome(seq,id,status,extra)
    local value={world=who.world,actor=who.actor,session=who.session,seq=seq,targetId=id,
        action="NAVIGATE",status=status or "native_failed",detail="native_path_failed"}
    for k,v in pairs(extra or {}) do value[k]=v end
    return value
end
local count=0
local function test(name,fn) reset();fn();count=count+1;print("ok "..name) end

test("empty memory does not invent a place before observation",function()
    local state=snapshot();assert(not state.valid and #state.anchors==0)
    assert(not memory:resolve(1,who,now))
end)
test("only actual occupied positions become anchors",function()
    assert(observe(pos(12.25,8.75,0,"kitchen")))
    local state=snapshot(pos(12.25,8.75))
    assert(state.valid and state.anchorCount==1 and #state.anchors==1)
    local anchor=state.anchors[1]
    assert(anchor.id==1 and anchor.origin and anchor.x==12.25 and anchor.y==8.75)
    assert(anchor.room=="kitchen" and not anchor.canNavigate and anchor.blocker=="place_already_here")
end)
test("same tile merges without replacing first occupied coordinates",function()
    observe(pos(1.1,2.2));local first=snapshot(pos(1.1,2.2));local at=first.anchors[1].visitedAt
    observe(pos(1.9,2.9));local state=snapshot(pos(1.9,2.9))
    assert(state.anchorCount==1 and state.observationVersion==1)
    assert(state.anchors[1].x==1.1 and state.anchors[1].y==2.2 and state.anchors[1].visitedAt==at)
    assert(state.anchors[1].lastVisitedAt==now)
end)
test("floor is part of tile identity",function()
    observe(pos(1.1,2.2,0));observe(pos(1.1,2.2,1));assert(snapshot(pos(1.1,2.2,1)).anchorCount==2)
end)
test("room labels update factual labels rather than serve as unique IDs",function()
    observe(pos(1.1,2.2,0,"kitchen"));observe(pos(1.2,2.3,0,"kitchen"))
    assert(snapshot(pos(1.2,2.3)).observationVersion==1)
    observe(pos(1.2,2.3,0,"living room"));assert(snapshot(pos(1.2,2.3)).observationVersion==2)
    observe(pos(2.2,2.3,0,"living room"));assert(snapshot(pos(2.2,2.3)).anchorCount==2)
end)
test("room labels are capped safe optional ASCII",function()
    observe(pos(1,1,0,'kitchen\0<script>"\\'..string.rep("x",100)))
    local label=snapshot(pos(1,1)).anchors[1].room
    assert(#label<=64 and not label:find('[<>"\\%z]'))
end)
test("unknown or nonfinite positions never add anchors",function()
    for _,p in ipairs({{},pos(0/0,1),pos(math.huge,1),pos(1000001,1),pos(1,1,0.5),pos(1,1,101),{x="1",y=1,z=0}}) do
        assert(not observe(p))
    end
    assert(snapshot().anchorCount==0)
end)
test("negative coordinates use floor tile merging",function()
    observe(pos(-0.1,-0.1));observe(pos(-0.9,-0.9));assert(snapshot(pos(-0.9,-0.9)).anchorCount==1)
    observe(pos(-1.1,-0.9));assert(snapshot(pos(-1.1,-0.9)).anchorCount==2)
end)
test("identity requires explicit nonempty world actor and session",function()
    for _,value in ipairs({{}, {world="w",actor="0"},{world="w",actor="0",session=""},
        {world="w",actor=0,session="s"},{world="w\0",actor="0",session="s"}}) do
        assert(not memory:observe(value,pos(),now))
    end
end)
test("world actor and session changes clear namespace memory",function()
    for _,key in ipairs({"world","actor","session"}) do
        reset();observe();local old={world=who.world,actor=who.actor,session=who.session}
        who[key]="changed";observe(pos(10.5,0.5))
        assert(not memory:resolve(1,old,now));local value=assert(memory:resolve(1,who,now))
        assert(value.x==10.5 and snapshot(pos(10.5,0.5)).anchorCount==1)
    end
end)
test("caller mutation of supplied identity and position cannot rewrite memory",function()
    local identity={world="w",actor="a",session="s"};local p=pos(1.25,2.25)
    assert(memory:observe(identity,p,now));identity.session="bad";p.x=99
    local result=assert(memory:resolve(1,{world="w",actor="a",session="s"},now));assert(result.x==1.25)
end)
test("resolution returns copies and rejects malformed or unknown IDs",function()
    observe();local value=assert(memory:resolve(1,who,now));value.x=500
    assert(memory:resolve(1,who,now).x==0.5)
    for _,id in ipairs({0,-1,1.5,"1",math.huge,0/0,2147483648,2}) do assert(not memory:resolve(id,who,now)) end
end)
test("snapshot mutation cannot alter stored anchors or namespace",function()
    observe();local state=snapshot();state.anchors[1].x=100;state.world="bad";state.anchors={}
    assert(memory:resolve(1,who,now).x==0.5 and snapshot().world=="world")
end)
test("backwards observation clock resets facts without reusing old IDs",function()
    observe();observe(pos(2.5,0.5));local before=snapshot(pos(2.5,0.5)).observationVersion
    now=500;assert(memory:observe(who,pos(4.5,0.5),now))
    assert(not memory:resolve(1,who,now) and not memory:resolve(2,who,now))
    assert(memory:resolve(3,who,now).x==4.5 and snapshot(pos(4.5,0.5)).observationVersion>before)
end)
test("backwards read clock clears stale facts and fails closed",function()
    observe();local value,reason=memory:resolve(1,who,now-1)
    assert(not value and reason=="place_clock_regressed")
    now=now-1;assert(memory:observe(who,pos(5.5,0.5),now));assert(memory:resolve(2,who,now))
end)
test("unknown or fractional clocks cannot make observations fresh",function()
    observe();for _,value in ipairs({-1,0/0,math.huge,"1000",1000.5}) do
        assert(not memory:resolve(1,who,value));assert(not memory:observe(who,pos(),value))
    end
end)
test("memory is bounded and pins origin while evicting least-recent places",function()
    for i=0,119 do observe(pos(i+0.5,0.5)) end
    local state=snapshot(pos(119.5,0.5));assert(state.anchorCount==96 and #state.anchors==24)
    assert(memory:resolve(1,who,now) and not memory:resolve(2,who,now))
    assert(memory:resolve(120,who,now).id==120 and state.anchors[1].origin)
end)
test("revisiting a place protects it from least-recent eviction",function()
    for i=0,95 do observe(pos(i+0.5,0.5)) end
    observe(pos(1.5,0.5));observe(pos(96.5,0.5))
    assert(memory:resolve(2,who,now) and not memory:resolve(3,who,now))
end)
test("evicted IDs are never reused when that tile is revisited",function()
    for i=0,96 do observe(pos(i+0.5,0.5)) end
    assert(not memory:resolve(2,who,now));observe(pos(1.5,0.5));assert(memory:resolve(98,who,now).x==1.5)
end)
test("public places prefer nearest anchors while always retaining origin",function()
    for i=0,70 do observe(pos(i+0.5,0.5)) end
    local list=snapshot(pos(70.5,0.5)).anchors
    assert(#list==24 and list[1].id==1 and list[2].id==71 and list[3].id==70)
end)
test("navigation eligibility is same floor range and arrival constrained",function()
    observe();assert(memory:canAttempt(1,pos(2.5,0.5),who,now))
    local ok,reason=memory:canAttempt(1,pos(0.6,0.5),who,now);assert(not ok and reason=="place_already_here")
    ok,reason=memory:canAttempt(1,pos(33,0.5),who,now);assert(not ok and reason=="place_out_of_range")
    ok,reason=memory:canAttempt(1,pos(2.5,0.5,1),who,now);assert(not ok and reason=="place_other_floor")
end)
test("eligibility rejects unknown inputs and mismatched identity",function()
    observe();assert(not memory:canAttempt(1,{},who,now))
    assert(not memory:canAttempt(1,pos(2.5,0.5),{world="other",actor="0",session="session"},now))
    assert(not memory:canAttempt(1,pos(2.5,0.5),who,math.huge))
end)
test("failed route blocks only the same target and origin tile for 30 seconds",function()
    observe();observe(pos(5.5,0.5))
    assert(memory:recordOutcome(outcome(7,1),pos(5.5,0.5),now))
    local ok,reason=memory:canAttempt(1,pos(5.9,0.9),who,now);assert(not ok and reason=="place_route_cooldown")
    assert(memory:canAttempt(1,pos(6.5,0.5),who,now))
    now=now+30000;assert(memory:canAttempt(1,pos(5.5,0.5),who,now))
end)
test("manual interruption and arrival do not become route failure memory",function()
    observe();observe(pos(5.5,0.5))
    for _,status in ipairs({"interrupted","observed_effect","pending"}) do
        assert(not memory:recordOutcome(outcome(7,1,status),pos(5.5,0.5),now))
    end
    assert(#snapshot(pos(5.5,0.5)).failures==0 and memory:canAttempt(1,pos(5.5,0.5),who,now))
end)
test("stale outcome identity target or sequence cannot poison current routes",function()
    observe();observe(pos(5.5,0.5))
    for _,value in ipairs({outcome(1,1,nil,{session="old"}),outcome(1,99),outcome(0,1),outcome(1.5,1),outcome(1,1,nil,{action="MOVE"})}) do
        assert(not memory:recordOutcome(value,pos(5.5,0.5),now))
    end
    assert(#snapshot(pos(5.5,0.5)).failures==0)
end)
test("repeated outcome cannot extend cooldown or replay an older sequence",function()
    observe();observe(pos(5.5,0.5));local record=outcome(7,1)
    assert(memory:recordOutcome(record,pos(5.5,0.5),now));local expiry=snapshot(pos(5.5,0.5)).failures[1].retryAfter
    now=now+1000;assert(not memory:recordOutcome(record,pos(5.5,0.5),now))
    assert(not memory:recordOutcome(outcome(6,1),pos(6.5,0.5),now))
    assert(snapshot(pos(5.5,0.5)).failures[1].retryAfter==expiry)
end)
test("failure snapshots are copies and failure records remain bounded",function()
    observe()
    for i=1,80 do now=now+10;assert(memory:recordOutcome(outcome(i,1,"unverified"),pos(i+0.5,0.5),now)) end
    local state=snapshot(pos(80.5,0.5));assert(#state.failures==64)
    state.failures[1].retryAfter=0;assert(snapshot(pos(80.5,0.5)).failures[1].retryAfter>0)
end)
test("snapshot truth distinguishes stored count from bounded public list",function()
    for i=0,40 do observe(pos(i+0.5,0.5)) end
    local state=snapshot(pos(40.5,0.5));assert(state.valid and state.scope=="current_session")
    assert(state.anchorCount==41 and #state.anchors==24 and state.observationVersion==41)
end)
test("snapshot cannot disclose another namespace on mismatch",function()
    observe();local state=memory:snapshot({world="other",actor="0",session="session"},pos(),now)
    assert(not state.valid and #state.anchors==0 and state.world==nil and state.anchorCount==0)
end)
test("serialization excludes extras and converts nonfinite numbers to null",function()
    observe(pos(1.25,2.25,0,"kitchen"));observe(pos(4.5,2.5))
    local state=snapshot(pos(4.5,2.5));state.secret="never emit";state.anchors[1].engine={}
    print("JSON:"..ClaudePlaceMemory.toJSON(state))
    print("JSON:"..ClaudePlaceMemory.toJSON(nil))
    print("JSON:"..ClaudePlaceMemory.toJSON({valid="true",scope="current_session",anchorCount=math.huge,
        anchors={{id=0/0,x=math.huge,canNavigate="true",origin=1,room='a\0"\\'..string.rep("x",200)}},failures={}}))
end)
test("serialization remains bounded even for externally oversized snapshots",function()
    local values={};for i=1,1000 do values[i]={id=i,room=string.rep("x",10000),detail=string.rep("x",10000)} end
    local encoded=ClaudePlaceMemory.toJSON({valid=false,anchors=values,failures=values})
    assert(#encoded<=40000)
    print("JSON:"..encoded)
end)
print("passed "..count.." place memory Lua tests")
