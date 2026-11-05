local directory=assert(arg[1])
require=function() end
dofile(directory.."/ClaudeTreatmentSkill.lua")
local skill,env,clock,permit,queue,nativeBusy,part,item,woundOK,supplyOK,bandaged,consumed,matching,valid,clears
local function reset()
    clock,permit,queue,nativeBusy=1000,true,{},false
    part,item={},{getID=function() return 5 end};woundOK,supplyOK=true,true
    bandaged,consumed,matching,valid=false,false,false,true;clears=0
    ClaudeTreatmentFacts={inspectWound=function() return {allowed=woundOK,index=0,reason="unsupported_wound"} end,
        inspectSupply=function() return {allowed=supplyOK,key="item:5",fullType="Base.Bandage",reason="unsafe_supply"} end}
    env={now=function() return clock end,
        state=function() return {busy=nativeBusy or #queue>0,actions=queue} end,
        choose=function() return part,item end,
        capture=function() return {valid=valid,bandaged=bandaged,consumed=consumed,matchingDressing=matching,bleeding=not bandaged} end,
        create=function(_,i,p,key,index)
            assert(i==item and p==part and key=="item:5" and index==0)
            return {isValid=function(a) return a.claudeAuthorized() and woundOK and supplyOK end}
        end,
        add=function(a) queue[#queue+1]=a;return true end,
        cancelOwned=function(_,owned)
            for _,a in ipairs(queue) do if a~=owned then return false end end
            queue={};nativeBusy=false;clears=clears+1;return true
        end}
    skill=ClaudeTreatmentSkill.new(env)
end
local function start() return skill:start({},7,function() return permit end,{world="w",actor="0",session="s"}) end
local function step(ms) clock=clock+(ms or 100);return skill:update() end
local function settle() queue={};nativeBusy=false;return step() end
local count=0
local function test(name,fn) reset();fn();count=count+1;print("ok "..name) end
test("success requires matching dressing and exact supply consumption",function()
    assert(start());bandaged,consumed,matching=true,true,true;step();assert(skill.receipt.status=="pending")
    settle();assert(skill.receipt.status=="observed_effect" and skill.receipt.consumed and skill.receipt.bandaged)
    assert(skill.receipt.partIndex==0 and skill.receipt.supplyKey=="item:5" and skill.receipt.session=="s")
end)
test("queue empty alone cannot prove treatment",function()
    assert(start());settle();assert(skill.receipt.status=="pending");step(1501)
    assert(skill.receipt.status=="no_effect")
end)
test("dressing without consumed supply is partial unverified",function()
    assert(start());bandaged,matching=true,true;settle();step(1501)
    assert(skill.receipt.status=="unverified" and skill.receipt.consumed==false)
end)
test("consumption without matching dressing is partial unverified",function()
    assert(start());consumed=true;settle();step(1501)
    assert(skill.receipt.status=="unverified" and skill.receipt.bandaged==false)
end)
test("wrong dressing never counts as matching success",function()
    assert(start());bandaged,consumed=true,true;settle();step(1501);assert(skill.receipt.status=="unverified")
end)
test("unknown result cannot count as an effect",function()
    assert(start());valid=false;settle();assert(skill.receipt.status=="unverified")
end)
test("native busy with empty Lua queue delays verification",function()
    assert(start());queue={};nativeBusy=true;bandaged,consumed,matching=true,true,true
    step(2000);assert(skill.receipt.status=="pending");nativeBusy=false;step();assert(skill.receipt.status=="observed_effect")
end)
test("unsupported wound and unsafe supply refuse mutation",function()
    woundOK=false;assert(not start() and #queue==0)
    reset();supplyOK=false;assert(not start() and #queue==0)
end)
test("unknown baseline refuses queueing",function()
    valid=false;assert(not start() and #queue==0)
end)
test("existing work and unknown queue refuse new treatment",function()
    nativeBusy=true;assert(not start() and #queue==0)
    reset();env.state=function() return nil end;assert(not start() and #queue==0)
end)
test("queued action cannot execute after takeover",function()
    assert(start());local old=queue[1];permit=false;assert(not old:isValid());step()
    assert(skill.receipt.status=="interrupted" and #queue==0)
end)
test("retained old callbacks cannot change successor receipt",function()
    assert(start());local old=queue[1];skill:cancel("replacement");assert(start())
    assert(not old:isValid());old.claudeOnBlocked("old_failure");assert(skill.receipt.status=="pending")
end)
test("replacement human work is preserved",function()
    assert(start());local human={};queue={human};step()
    assert(skill.receipt.status=="interrupted" and queue[1]==human and clears==0)
end)
test("partial mutation on a blocked action stays visible and unverified",function()
    assert(start());bandaged=true;queue[1].claudeOnBlocked("native_complete_failed")
    assert(skill.receipt.status=="pending" and skill.receipt.bandaged==nil)
    consumed,matching=true,true;settle()
    assert(skill.receipt.status=="unverified" and skill.receipt.bandaged==true and skill.receipt.consumed==true)
end)
test("enqueue refusal or error cleans only owned work",function()
    env.add=function(a) queue={a};bandaged=true;return nil end;assert(not start() and #queue==0 and skill.receipt.status=="unverified")
    reset();env.add=function(a) queue={a};error("synthetic") end;assert(not start() and #queue==0 and skill.receipt.status=="unverified")
end)
test("deadline and backwards clock cannot claim success",function()
    assert(start());step(30001);assert(skill.receipt.status=="unverified" and #queue==0)
    reset();assert(start());clock=999;skill:update();assert(skill.receipt.status=="unverified")
end)
test("replication grace admits delayed measured results",function()
    assert(start());settle();step(1000);bandaged,consumed,matching=true,true,true;step(100)
    assert(skill.receipt.status=="observed_effect")
end)
test("default queue adapter refuses sparse or malformed arrays",function()
    local foreign={};local nativeQueue={[2]=foreign}
    getTimestampMs=function() return clock end
    ISTimedActionQueue={getTimedActionQueue=function() return {queue=nativeQueue} end,isPlayerDoingAction=function() return false end}
    local nativeSkill=ClaudeTreatmentSkill.new()
    assert(not nativeSkill:start({},1,function() return true end,{world="w",actor="0",session="s"}))
    assert(nativeQueue[2]==foreign and nativeSkill.receipt.status=="no_effect")
    nativeQueue={unexpected=foreign}
    assert(not nativeSkill:start({},2,function() return true end,{world="w",actor="0",session="s"}))
end)
test("default capture refuses fractional or changed original IDs",function()
    local id,container,present=5,nil,nil
    local target={getID=function() return id end,getContainer=function() return container end}
    local anatomy={};local p={getBodyDamage=function() return {getBodyParts=function() return {get=function() return anatomy end} end} end}
    function anatomy:getParentChar() return p end
    function anatomy:getIndex() return 0 end
    function anatomy:bandaged() return bandaged end
    function anatomy:bleeding() return not bandaged end
    function anatomy:getBandageLife() return 2 end
    function anatomy:getBandageType() return "Base.Bandage" end
    local inventory={getItems=function() return {size=function() return 1 end,get=function() return target end} end,
        getItemById=function() return present end}
    p.getInventory=function() return inventory end
    ClaudeTreatmentFacts.read=function() return {eligibleWounds={{index=0}},supplies={{key="item:5"}}} end
    local q={queue={}};container,present=inventory,target
    getTimestampMs=function() return clock end
    ISTimedActionQueue={getTimedActionQueue=function() return q end,isPlayerDoingAction=function() return false end,
        add=function(a) q.queue={a};return q end,hasAction=function(a) return q.queue[1]==a end,
        clear=function() q.queue={} end}
    ClaudeApplyBandageAction={new=function() return {isValid=function(a) return a.claudeAuthorized() end} end}
    local nativeSkill=ClaudeTreatmentSkill.new()
    assert(nativeSkill:start(p,1,function() return true end,{world="w",actor="0",session="s"}))
    q.queue={};container,present=nil,nil;bandaged=true;id=5.25;clock=clock+100
    nativeSkill:update();assert(nativeSkill.receipt.status=="unverified" and nativeSkill.receipt.detail=="treatment_result_unknown")
end)
print("passed "..count.." treatment skill Lua tests")
