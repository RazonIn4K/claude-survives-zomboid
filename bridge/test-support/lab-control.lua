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
require=function(name) assert(name=="ClaudeLabControl") end
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
getGameTime=function() return {getHour=function() return 21 end,getNightsSurvived=function() return 0 end} end
local light={getDisplayName=function() return "fixture light" end,IsFood=function() return false end,
    getFluidContainer=function() return nil end,getLightStrength=function() return 1 end,setActivated=function() effect("light") end}
player={getX=function() return 100.5 end,getY=function() return 100.5 end,getZ=function() return 0 end,
    getStats=function() return {get=function() return 0 end} end,isDead=function() return false end,
    getOnlineID=function() return 0 end,isOutside=function() return false end,
    getBodyDamage=function() return {getOverallBodyHealth=function() return 100 end} end,
    getInventory=function() return {getItems=function() return vector({light}) end} end,
    getSquare=function() return {getRoom=function() return nil end} end,getPrimaryHandItem=function() return nil end,
    Say=function() effect("say") end,setSneaking=function() effect("sneak") end,
    faceLocation=function() effect("face") end,faceThisObject=function() effect("face") end,
    DoAttack=function() effect("attack") end,pressedMovement=function() return false end,pressedCancelAction=function() return false end}
getSpecificPlayer=function() return player end
getCell=function() return {getZombieList=function() return vector(zombies) end,
    getGridSquare=function(_,x,y,z) return {getX=function() return x end,getY=function() return y end,getZ=function() return z end,
        getObjects=function() return vector({}) end,getBuilding=function() return nil end} end} end
ISTimedActionQueue={getTimedActionQueue=function() return {queue=queue} end,
    add=function(action) queue[#queue+1]=action; effect("queue") end,clear=function() queue={}; effect("clear") end}
ISWalkToTimedAction={new=function(_,_,square) return {square=square} end}
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
print("passed "..count.." lab Lua tests")
