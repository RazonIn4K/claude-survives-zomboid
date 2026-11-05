-- Behavioral scheduler fixtures; native water effects are tested separately.
local directory=assert(arg[1])
require=function() end
dofile(directory.."/ClaudeWaterSkill.lua")
local clock,permit,queue,busy,source,vessel,sourceKey,itemKey,reachable,sourceSafe,vesselSafe
local thirst,amount,snapshotValid,approachMode,enqueueMode,clears,created,mode,skill,env
local p={}
local function copy(list) local out={};for i,a in ipairs(list) do out[i]=a end;return out end
local function reset()
    clock,permit,queue,busy=1000,true,{},false
    source,vessel,sourceKey,itemKey={},{},"100:100:0:0","item:5"
    reachable,sourceSafe,vesselSafe=true,true,true
    thirst,amount,snapshotValid=0.7,0,true
    approachMode,enqueueMode,clears,created="near","accept",0,0
    ClaudeWaterFacts={
        inspectSource=function(_,s,requireReach)
            return {allowed=s==source and sourceSafe and (not requireReach or reachable),
                reason=sourceSafe and "not_reached" or "unsafe_source",key=sourceKey,x=100,y=100,z=0}
        end,
        inspectVessel=function(_,v) return {allowed=v==vessel and vesselSafe,reason="unsafe_vessel",key=itemKey} end,
    }
    env={now=function() return clock end,
        state=function() return {busy=busy or #queue>0,actions=copy(queue)} end,
        choose=function(_,m) return source,m=="FILLBOTTLE" and vessel or nil end,
        approach=function()
            if approachMode=="near" then return true end
            if approachMode=="refuse" then return false end
            queue[#queue+1]={kind="path",isValid=function() return true end}
            if approachMode=="throw" then error("synthetic approach failure") end
            return true
        end,
        create=function(_,v,s,sk,ik)
            created=created+1
            assert(s==source and sk==sourceKey)
            if v then assert(v==vessel and ik==itemKey) end
            return {kind="water",isValid=function(a) return a.claudeAuthorized() and sourceSafe end}
        end,
        add=function(a)
            queue[#queue+1]=a
            if enqueueMode=="throw" then error("synthetic enqueue failure") end
            return enqueueMode=="accept"
        end,
        capture=function() return {valid=snapshotValid,thirst=thirst,amount=amount,capacity=2} end,
        cancelOwned=function(_,owned)
            for _,a in ipairs(queue) do if not owned[a] then return false end end
            queue={};busy=false;clears=clears+1;return true
        end,
    }
    skill=ClaudeWaterSkill.new(env)
end
local identity={world="world",actor="0",session="session"}
local function start(action)
    mode=action or "DRINKTAP"
    return skill:start(p,7,mode,function() return permit end,identity)
end
local function step(ms) clock=clock+(ms or 100);return skill:update() end
local function settle() queue={};busy=false;return step() end
local count=0
local function test(name,fn) reset();fn();count=count+1;print("ok "..name) end

test("drinking waits for a measured thirst reduction",function()
    assert(start());assert(created==0);step();assert(created==1 and #queue==1)
    assert(skill.receipt.status=="pending" and skill.receipt.phase=="consume")
    thirst=0.1;step();assert(skill.receipt.status=="pending")
    settle();assert(skill.receipt.status=="observed_effect" and skill.receipt.thirstDrop>0.59)
    assert(skill.receipt.sourceKey==sourceKey and skill.receipt.world=="world")
end)
test("approach completion is followed by fresh reach validation",function()
    approachMode="walk";reachable=false;assert(start());step();assert(created==0)
    settle();assert(created==0 and skill.receipt.status=="no_effect")
end)
test("path finishes before actual water action is constructed",function()
    approachMode="walk";reachable=false;assert(start());step();assert(created==0)
    reachable=true;settle();assert(created==1 and #queue==1)
end)
test("source changed or disappeared during approach is refused",function()
    approachMode="walk";assert(start());sourceSafe=false;settle()
    assert(created==0 and skill.receipt.status=="no_effect")
end)
test("source identity change is refused despite new safe facts",function()
    approachMode="walk";assert(start());sourceKey="101:100:0:0";settle()
    assert(created==0 and skill.receipt.status=="no_effect")
end)
test("manual takeover cancels owned approach work",function()
    approachMode="walk";assert(start());permit=false;step()
    assert(skill.receipt.status=="interrupted" and #queue==0 and clears==1)
end)
test("retained path and water actions cannot use revoked authorization",function()
    approachMode="walk";assert(start());local path=queue[1];permit=false
    assert(path:isValid()==false);step();assert(skill.receipt.status=="interrupted")
    reset();assert(start());step();local action=queue[1];permit=false
    assert(action:isValid()==false);step();assert(skill.receipt.status=="interrupted")
end)
test("foreign replacement queue is preserved on cancellation",function()
    approachMode="walk";assert(start());local foreign={kind="human"};queue={foreign};step()
    assert(skill.receipt.status=="interrupted" and queue[1]==foreign and clears==0)
end)
test("pre-existing native activity or unknown queue prevents starting",function()
    busy=true;assert(not start());assert(created==0)
    reset();env.state=function() return nil end;assert(not start());assert(created==0)
end)
test("approach refusal cannot produce a drink action",function()
    approachMode="refuse";assert(not start());assert(skill.receipt.status=="no_effect" and created==0)
end)
test("approach exception still captures and clears owned path",function()
    approachMode="throw";assert(not start());assert(#queue==0 and clears==1 and created==0)
end)
test("native queue acceptance must be explicit",function()
    enqueueMode="refuse";assert(start());step()
    assert(skill.receipt.status=="unverified" and #queue==0 and clears==1)
end)
test("native enqueue exception cleans only owned action",function()
    enqueueMode="throw";assert(start());step()
    assert(skill.receipt.status=="unverified" and #queue==0 and clears==1)
end)
test("native activity with an empty Lua queue prevents false completion",function()
    assert(start());step();queue={};busy=true;thirst=0;step(2000)
    assert(skill.receipt.status=="pending");busy=false;step();assert(skill.receipt.status=="observed_effect")
end)
test("empty queue without effect becomes no_effect after replication grace",function()
    assert(start());step();settle();assert(skill.receipt.status=="pending")
    step(1600);assert(skill.receipt.status=="no_effect")
end)
test("filling requires same-vessel water gain rather than a thirst drop",function()
    assert(start("FILLBOTTLE"));step();thirst=0;settle();step(1600)
    assert(skill.receipt.status=="no_effect" and skill.receipt.amountGain==0)
end)
test("full bottle after action is a valid observed fill result",function()
    assert(start("FILLBOTTLE"));step();amount=2;settle()
    assert(skill.receipt.status=="observed_effect" and skill.receipt.amountGain==2)
    assert(skill.receipt.beforeAmount==0 and skill.receipt.afterAmount==2 and skill.receipt.vesselKey==itemKey)
end)
test("vessel changed before consumption prevents construction",function()
    approachMode="walk";assert(start("FILLBOTTLE"));vesselSafe=false;settle()
    assert(created==0 and skill.receipt.status=="no_effect")
end)
test("contaminated or foreign vessel observation cannot count as a fill",function()
    assert(start("FILLBOTTLE"));step();amount=2;snapshotValid=false;settle()
    assert(skill.receipt.status=="unverified")
end)
test("effects before consumption baseline do not count as drinking",function()
    approachMode="walk";assert(start());thirst=0.3;settle();settle();step(1600)
    assert(skill.receipt.status=="no_effect" and skill.receipt.thirstDrop==0)
end)
test("late replication effect inside grace is observed",function()
    assert(start());step();settle();step(1000);thirst=0.2;step(100)
    assert(skill.receipt.status=="observed_effect")
end)
test("blocked action reports failure rather than accepting a stat delta",function()
    assert(start());step();queue[1].claudeOnBlocked("source_now_poisoned");thirst=0;settle()
    assert(skill.receipt.status=="unverified" and skill.receipt.detail=="source_now_poisoned")
end)
test("clock regression and task deadline stop owned work",function()
    assert(start());clock=999;skill:update();assert(skill.receipt.status=="unverified")
    reset();approachMode="walk";assert(start());step(60001)
    assert(skill.receipt.status=="unverified" and #queue==0)
end)
test("old retained action stays unauthorized after a new task starts",function()
    assert(start());step();local old=queue[1];skill:cancel("replace");assert(start())
    assert(old:isValid()==false)
    old.claudeOnBlocked("late_old_failure");assert(skill.receipt.status=="pending")
end)
test("no need to drink is reported without queuing consumption",function()
    thirst=0;assert(start());step();assert(created==0 and skill.receipt.status=="no_effect")
end)
print("passed "..count.." water skill Lua tests")
