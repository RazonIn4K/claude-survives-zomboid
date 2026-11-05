-- Deterministic gate and whole-body entry-point tests. These do not prove engine compatibility.
local directory = assert(arg[1])
dofile(directory .. "/ClaudeLabControl.lua")
local clock, control, stops, player, world, actor, gate, busy, stopThrows
local function reset()
    clock, control, stops, world, actor = 1700000000000, nil, 0, "fixture-world", "0"
    busy, stopThrows = false, false
    player = {isDead=function() return false end, pressedMovement=function() return false end,
        pressedCancelAction=function() return false end}
    gate = ClaudeLabControl.new({now=function() return clock end, random=function() return 1 end,
        identity=function() return world, actor end, readControl=function() return control end,
        busy=function() return busy end,
        stop=function() stops=stops+1; if stopThrows then error("synthetic stop failure") end; return true end})
    gate:update(player)
end
local function arm(token)
    control = table.concat({1,gate.session,world,actor,token or "bridge-token","ARM",clock,clock+2000},"|")
    return gate:update(player)
end
local function intent(sequence, action, dx, dy, issued, expires, session)
    return table.concat({sequence,action,dx or 0,dy or 0,"","","","LAB1",session or gate.session,
        world,actor,gate.token,issued or clock,expires or clock+2000},"|")
end
local count=0
local function test(name, fn) reset(); fn(); count=count+1; print("ok "..name) end
test("starts disarmed and ignores legacy commands",function()
    assert(not gate.armed); assert(not gate:accept("1|MOVE|1|0|||"))
end)
test("explicit heartbeat arms a fresh identity",function()
    assert(arm()); assert(gate:accept(intent(1,"MOVE",1,0)))
    assert(not gate:accept(intent(1,"MOVE",1,0)))
end)
test("expired and future intents are refused without consuming sequence",function()
    arm(); local _,reason=gate:accept(intent(1,"MOVE",1,0,clock-3000,clock-1))
    assert(reason=="expired_intent" and gate.lastSeq==0)
    assert(not gate:accept(intent(1,"MOVE",1,0,clock+1000,clock+2000)))
end)
test("movement bounds are checked without coercion",function()
    arm(); assert(not gate:accept(intent(1,"MOVE",4,4)))
    assert(not gate:accept(intent(1,"MOVE","1e0",0)))
    assert(not gate:accept(intent(1,"MOVE",0,0)))
    assert(gate:accept(intent(1,"MOVE",4,0)))
end)
test("manual takeover permanently revokes pending ARM and intent",function()
    arm(); local old=gate.session; local pending=intent(1,"MOVE",1,0)
    gate:manual(); assert(not gate.armed and gate.session~=old and stops==1)
    for _=1,700 do clock=clock+16; gate:update(player) end
    assert(not gate.armed and not gate:accept(pending))
end)
test("held movement uses the Build 42 boolean signature and prevents arming",function()
    arm(); player.pressedMovement=function(_,cancel) assert(cancel==false); return true end
    gate:update(player);assert(not gate.armed and gate.reason=="manual_takeover")
end)
test("heartbeat expiry revokes the session",function()
    arm(); local old=gate.session
    clock=clock+1900; gate:update(player); clock=clock+101; gate:update(player)
    assert(not gate.armed and gate.session~=old and stops==1)
end)
test("fresh short leases continue past one hour while expiry and manual takeover still revoke",function()
    control=table.concat({1,gate.session,world,actor,"bridge-token","ARM",clock,clock+3001},"|")
    assert(not gate:update(player) and not gate.armed,"an oversized lease was accepted")
    assert(arm());local original=gate.session
    for _=1,14404 do
        clock=clock+250
        assert(arm(),"fresh heartbeat unexpectedly lost continuous control")
        assert(gate.session==original and stops==0,"an absolute lifetime reset the session")
    end
    -- Keep ticks regular while allowing the final two-second lease to expire.
    clock=clock+1900;gate:update(player);assert(gate.armed)
    clock=clock+101;gate:update(player)
    assert(not gate.armed and gate.reason=="heartbeat_expired" and gate.session~=original and stops==1)
    assert(arm());local revokedSession,revokedToken=gate.session,gate.token
    local pending=intent(1,"MOVE",1,0)
    gate:manual()
    for _=1,20 do
        clock=clock+250
        control=table.concat({1,revokedSession,world,actor,revokedToken,"ARM",clock,clock+2000},"|")
        assert(not gate:update(player),"a revoked controller reacquired the player")
    end
    assert(not gate.armed and gate.reason=="manual_takeover" and stops==2 and not gate:accept(pending))
end)
test("world and actor changes revoke ownership",function()
    arm(); local old=gate.session; world="other-world"; gate:update(player)
    assert(not gate.armed and gate.session~=old)
    arm(); old=gate.session; actor="2"; gate:update(player)
    assert(not gate.armed and gate.session~=old)
end)
test("death, missing player, and tick gap revoke control",function()
    arm(); player.isDead=function() return true end; gate:update(player); assert(not gate.armed)
    reset(); arm(); gate:update(nil); assert(not gate.armed)
    reset(); arm(); clock=clock+2100; gate:update(player); assert(not gate.armed)
end)
test("DISARM cannot be issued by another token",function()
    arm(); control=table.concat({1,gate.session,world,actor,"another-token","DISARM",clock,clock+2000},"|")
    gate:update(player); assert(gate.armed)
    control=control:gsub("another%-token","bridge-token"); gate:update(player); assert(not gate.armed)
end)
test("initial ARM preserves pre-existing human work but renewals can own a busy queue",function()
    busy=true; assert(not arm()); assert(not gate.armed and stops==0 and gate.reason=="player_busy")
    busy=false; assert(arm()); busy=true; assert(arm()); assert(stops==0)
end)
test("new model work cannot interrupt a newer local action",function()
    arm(); busy=true
    local _,reason=gate:accept(intent(1,"MOVE",1,0)); assert(reason=="body_busy" and gate.lastSeq==0)
    assert(gate:accept(intent(1,"STOP")))
end)
test("stop errors revoke ownership but remain visible as unverified cleanup",function()
    arm(); stopThrows=true; gate:manual()
    assert(not gate.armed and gate.stopFailed and stops==1)
end)

-- Load the actual body script with engine stubs and count all mutation calls.
local files, handlers, queue, effects, zombies = {}, {}, {}, {}, {}
local function effect(name) effects[name]=(effects[name] or 0)+1 end
local function vector(items) return {size=function() return #items end,get=function(_,i) return items[i+1] end} end
local function event(name) handlers[name]={}; return {Add=function(fn) table.insert(handlers[name],fn) end} end
Events={OnTick=event("tick"),OnKeyPressed=event("key"),OnMouseDown=event("mouse"),OnRightMouseDown=event("right"),
    OnGameStart=event("start"),OnCreatePlayer=event("create")}
require=function(name)
    assert(name=="ClaudeLabControl" or name=="ClaudeLootPolicy" or name=="ClaudeActionEvidence")
    if name~="ClaudeLabControl" then dofile(directory.."/"..name..".lua") end
end
ISUIElement={derive=function() return {} end}
Keyboard={KEY_H=35}
getTimestampMs=function() return clock end
ZombRand=function() return 1 end
getWorld=function() return {getWorld=function() return "fixture-world" end} end
getFileWriter=function(name) return {write=function(_,text) files[name]=text end,close=function() end} end
getFileReader=function(name)
    if not files[name] then return nil end
    return {readLine=function() return files[name] end,close=function() end}
end
CharacterStat={HUNGER=1,THIRST=2,FATIGUE=3,ENDURANCE=4,PANIC=5}
Fluid={Water="water"}
instanceof=function(item,kind) return item and item.kind==kind or false end
getGameTime=function() return {getHour=function() return 21 end,getNightsSurvived=function() return 0 end} end
local light={getDisplayName=function() return "fixture light" end,IsFood=function() return false end,
    getID=function() return 1 end,getFluidContainer=function() return nil end,
    getLightStrength=function() return 1 end,setActivated=function() effect("light") end}
local inventoryItems, statValues, squares, walkAllowed, walkTarget = {light}, {}, {}, true, nil
local inventory={getItems=function() return vector(inventoryItems) end}
player={getX=function() return 100.5 end,getY=function() return 100.5 end,getZ=function() return 0 end,
    getStats=function() return {get=function(_,stat) return statValues[stat] or 0 end} end,isDead=function() return false end,
    getOnlineID=function() return 0 end,isOutside=function() return false end,
    getBodyDamage=function() return {getOverallBodyHealth=function() return 100 end} end,
    getInventory=function() return inventory end,isKnownPoison=function(_,item) return item.poison or false end,
    getSquare=function() return {getRoom=function() return nil end} end,getPrimaryHandItem=function() return nil end,
    Say=function() effect("say") end,setSneaking=function() effect("sneak") end,
    faceLocation=function() effect("face") end,faceThisObject=function() effect("face") end,
    DoAttack=function() effect("attack") end,pressedMovement=function() return false end,pressedCancelAction=function() return false end}
getSpecificPlayer=function() return player end
local function square(x,y,z,objects)
    return {getX=function() return x end,getY=function() return y end,getZ=function() return z end,
        getObjects=function() return vector(objects or {}) end,getBuilding=function() return nil end}
end
getCell=function() return {getZombieList=function() return vector(zombies) end,
    getGridSquare=function(_,x,y,z) return squares[x..":"..y..":"..z] or square(x,y,z) end} end
ISTimedActionQueue={getTimedActionQueue=function() return {queue=queue} end,
    add=function(action) queue[#queue+1]=action; effect("queue") end,clear=function() queue={}; effect("clear") end}
ISWalkToTimedAction={new=function(_,_,target) return {kind="walk",square=target} end}
ISInventoryTransferAction={new=function(_,_,item,source,destination)
    return {kind="transfer",item=item,source=source,destination=destination}
end}
ISEatFoodAction={new=function(_,_,item) return {kind="eat",item=item} end}
ISDrinkFluidAction={new=function(_,_,item) return {kind="drink",item=item} end}
luautils={walkAdj=function(p,target,keepActions)
    assert(p==player and keepActions==true,"loot must preserve explicitly managed action queue")
    effect("walkAdj");walkTarget=target
    if not walkAllowed then return false end
    ISTimedActionQueue.add(ISWalkToTimedAction:new(p,target));return true
end}
getGameSpeed=function() return 1 end
setGameSpeed=function() error("the lab must never change game speed") end
dofile(directory.."/ClaudeSurvivor.lua")
local function tick(n)
    for _=1,n or 1 do clock=clock+16; for _,fn in ipairs(handlers.tick) do fn() end end
end
tick()
assert(next(effects)==nil,"initially disarmed body produced a mutation")
local function percept(field) return assert(files["claude_percept.json"]):match('"'..field..'":"([^"]+)"') end
local session=assert(percept("session"))
local function heartbeat()
    files["claude_control.txt"]=table.concat({1,session,"fixture-world","0","body-test-token","ARM",clock,clock+2000},"|")
end
heartbeat(); tick()
files["claude_intent.txt"]=table.concat({1,"MOVE",2,0,"","","","LAB1",session,"fixture-world","0","body-test-token",clock,clock+2000},"|")
tick(45)
assert(#queue==1,"armed body did not dispatch its validated bounded MOVE")
for _,fn in ipairs(handlers.mouse) do fn() end
assert(#queue==0,"mouse takeover did not clear the active queue")
effects={}
zombies={{getX=function() return 101 end,getY=function() return 100 end}}
for _=1,700 do heartbeat(); tick() end
assert(next(effects)==nil,"a body mutation resumed after permanent mouse takeover")
assert(files["claude_percept.json"]:find('"armed":false',1,true))
assert(percept("session")~=session)
zombies={};session=assert(percept("session"));heartbeat();tick()
for _,fn in ipairs(handlers.key) do fn(Keyboard.KEY_H) end
effects={}
for _=1,700 do heartbeat();tick() end
assert(next(effects)==nil,"a body mutation resumed after keyboard takeover")
assert(files["claude_percept.json"]:find('"armed":false',1,true))
count=count+1;print("ok whole-body manual gate blocks reflexes, motion, light, sneak, and speech beyond idle interval")
-- Even a failed engine queue clear must be observable after revoking the lease.
session=assert(percept("session"));heartbeat();tick()
files["claude_intent.txt"]=table.concat({1,"MOVE",2,0,"","","","LAB1",session,"fixture-world","0","body-test-token",clock,clock+2000},"|")
tick(45);assert(#queue==1)
assert(not effects.light and not effects.sneak,"lab silently changed persistent human settings")
local normalClear=ISTimedActionQueue.clear
ISTimedActionQueue.clear=function() error("synthetic engine queue-clear failure") end
for _,fn in ipairs(handlers.mouse) do fn() end
tick()
assert(#queue==1 and files["claude_percept.json"]:find('"stopFailed":true',1,true))
assert(files["claude_percept.json"]:find('"armed":false',1,true))
ISTimedActionQueue.clear=normalClear
count=count+1;print("ok whole-body queue clear failure is reported without resuming autonomy")

-- Exercise the actual body dispatch and serialized observations, not just helpers.
local function freshBody()
    files, handlers, queue, effects, zombies = {}, {}, {}, {}, {}
    inventoryItems, statValues, squares, walkAllowed, walkTarget = {light}, {}, {}, true, nil
    Events={OnTick=event("tick"),OnKeyPressed=event("key"),OnMouseDown=event("mouse"),OnRightMouseDown=event("right"),
        OnGameStart=event("start"),OnCreatePlayer=event("create")}
    dofile(directory.."/ClaudeSurvivor.lua");tick()
    session=assert(percept("session"));heartbeat();tick()
    assert(files["claude_percept.json"]:find('"armed":true',1,true))
end
local function bodyTest(name,fn)
    freshBody();fn();count=count+1;print("ok whole-body "..name)
end
local function advance(n)
    for _=1,n or 1 do heartbeat();tick() end
end
local function command(action,seq)
    seq=seq or 1
    files["claude_intent.txt"]=table.concat({seq,action,0,0,"","","","LAB1",session,"fixture-world","0","body-test-token",clock,clock+2000},"|")
    advance(45)
    assert(files["claude_percept.json"],"body did not publish a percept")
end
local function fixtureItem(id,kind,options)
    options=options or {}
    return {kind=kind,poison=options.poison,getID=function() return id end,
        getDisplayName=function() return "item-"..id end,
        getHungChange=function() return options.hungerChange or -0.2 end,
        getScriptItem=function() return {isCantEat=function() return options.cantEat or false end} end,
        isBurnt=function() return options.burnt or false end,isRotten=function() return options.rotten or false end,
        isbDangerousUncooked=function() return options.rawDanger or false end,isCooked=function() return options.cooked or false end,
        getCondition=function() return options.condition or 10 end,
        getFluidContainer=function()
            if not options.water and not options.mixed then return nil end
            return {isEmpty=function() return options.empty or false end,
                isPureFluid=function(_,fluid) return fluid==Fluid.Water and options.water==true and not options.mixed end}
        end}
end
local function stocked(x,y,items)
    local container={getItems=function() return vector(items) end}
    local object={getContainerCount=function() return 1 end,getContainerByIndex=function(_,index)
        assert(index==0);return container
    end}
    local target=square(x,y,0,{object});squares[x..":"..y..":0"]=target
    return container,target
end
local function outcome(field)
    local value=assert(files["claude_percept.json"]):match('"actionOutcome":({.-})')
    assert(value,"body did not serialize an action outcome")
    return value:match('"'..field..'":"([^"]*)"') or tonumber(value:match('"'..field..'":([%d%.%-]+)'))
end
bodyTest("loot prefers farther clean water over nearest junk and queues each item once",function()
    stocked(101,100,{fixtureItem(10,"Junk")})
    local water=fixtureItem(11,"WaterBottle",{water=true})
    local useful,target=stocked(104,100,{water,water})
    statValues[CharacterStat.THIRST]=0.7
    command("LOOT")
    assert(walkTarget==target and #queue==2,"loot chose clutter or queued a duplicate transfer")
    assert(queue[2].kind=="transfer" and queue[2].item==water and queue[2].source==useful)
end)
bodyTest("loot hunger priority chooses safe food over a nearer water container",function()
    stocked(101,100,{fixtureItem(12,"WaterBottle",{water=true})})
    local food=fixtureItem(13,"Food")
    local useful,target=stocked(103,100,{food})
    statValues[CharacterStat.HUNGER],statValues[CharacterStat.THIRST]=0.7,0.2
    command("LOOT")
    assert(walkTarget==target and #queue==2 and queue[2].item==food and queue[2].source==useful)
end)
bodyTest("loot excludes unsafe food and mixed or empty water containers",function()
    stocked(101,100,{fixtureItem(14,"Food",{rotten=true}),fixtureItem(15,"Food",{burnt=true}),
        fixtureItem(16,"Food",{poison=true}),fixtureItem(17,"Food",{rawDanger=true}),
        fixtureItem(18,"Food",{cantEat=true}),fixtureItem(19,"WaterBottle",{water=true,mixed=true}),
        fixtureItem(20,"WaterBottle",{water=true,empty=true})})
    command("LOOT");advance(60)
    assert(#queue==0 and not effects.walkAdj and not walkTarget)
    assert(files["claude_percept.json"]:find('"nearbyLoot":{"valid":true,"containers":1,"foods":0,"waters":0,"weapons":0,"useful":false}',1,true))
end)
bodyTest("failed walkAdj does not queue transfers or a fallback walk",function()
    stocked(101,100,{fixtureItem(21,"WaterBottle",{water=true})});walkAllowed=false
    command("LOOT");advance(60)
    assert(effects.walkAdj==1 and #queue==0 and not effects.queue)
    assert(percept("err")=="loot: no adjacent route")
end)
bodyTest("empty loot queue without a transfer reports no effect",function()
    stocked(101,100,{fixtureItem(22,"WaterBottle",{water=true})})
    command("LOOT");assert(#queue==2);queue={};advance(140)
    assert(outcome("status")=="no_effect" and outcome("added")==0)
end)
bodyTest("loot receipts use inventory IDs and require an actual new ID",function()
    stocked(101,100,{fixtureItem(23,"WaterBottle",{water=true})})
    command("LOOT");queue={}
    inventoryItems={fixtureItem(1,"Junk")};advance(35)
    -- A replacement engine object for the same network inventory ID is not a gain.
    assert(not files["claude_percept.json"]:find('"status":"observed_effect"',1,true))
    inventoryItems[#inventoryItems+1]=fixtureItem(23,"WaterBottle",{water=true});advance(60)
    assert(outcome("status")=="observed_effect" and outcome("added")==1)
end)
bodyTest("eat receipts need a real hunger decrease after the food action",function()
    inventoryItems[#inventoryItems+1]=fixtureItem(24,"Food")
    statValues[CharacterStat.HUNGER],statValues[CharacterStat.THIRST]=0.4,0.5
    command("EAT");assert(#queue==1 and queue[1].kind=="eat")
    queue={};statValues[CharacterStat.HUNGER]=0.25;advance(60)
    assert(outcome("status")=="observed_effect" and math.abs(outcome("hungerDrop")-0.15)<0.000001)
end)
bodyTest("drink receipts need a real thirst decrease after the drink action",function()
    inventoryItems[#inventoryItems+1]=fixtureItem(25,"WaterBottle",{water=true})
    statValues[CharacterStat.HUNGER],statValues[CharacterStat.THIRST]=0.4,0.5
    command("DRINK");assert(#queue==1 and queue[1].kind=="drink")
    queue={};statValues[CharacterStat.THIRST]=0.2;advance(60)
    assert(outcome("status")=="observed_effect" and math.abs(outcome("thirstDrop")-0.3)<0.000001)
end)
bodyTest("manual takeover marks pending loot interrupted rather than completed",function()
    stocked(101,100,{fixtureItem(26,"WaterBottle",{water=true})})
    command("LOOT");assert(#queue==2)
    for _,fn in ipairs(handlers.mouse) do fn() end
    advance(60)
    assert(#queue==0 and outcome("status")=="interrupted" and outcome("detail")=="control_revoked")
    assert(outcome("session")==session and percept("session")~=session,
        "receipt was relabelled as belonging to the replacement session")
    assert(files["claude_percept.json"]:find('"armed":false',1,true))
end)
bodyTest("reflex replacement interrupts partial loot and cannot later claim completion",function()
    local water=fixtureItem(27,"WaterBottle",{water=true})
    stocked(101,100,{water});command("LOOT");assert(#queue==2)
    inventoryItems[#inventoryItems+1]=water
    zombies={{getX=function() return 101 end,getY=function() return 100 end}}
    advance(5);zombies={};queue={};advance(100)
    assert(outcome("status")=="interrupted" and outcome("detail")=="movement_replaced_action")
end)
print("passed "..count.." lab Lua tests")
