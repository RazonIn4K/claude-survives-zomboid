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
    assert(name=="ClaudeLabControl" or name=="ClaudeLootPolicy" or name=="ClaudeActionEvidence"
        or name=="ClaudeHealthFacts" or name=="ClaudeWindowPolicy" or name=="ClaudeWaterFacts"
        or name=="ClaudeWaterSkill" or name=="TimedActions/ClaudeTakeWaterAction"
        or name=="ClaudeTreatmentFacts" or name=="ClaudeTreatmentSkill" or name=="TimedActions/ClaudeApplyBandageAction")
    if name=="ClaudeWaterFacts" then dofile(directory.."/../shared/ClaudeWaterFacts.lua")
    elseif name=="ClaudeTreatmentFacts" then dofile(directory.."/../shared/ClaudeTreatmentFacts.lua")
    elseif name=="TimedActions/ClaudeApplyBandageAction" then
        -- Native medical mutation/server guards are exercised by the separate
        -- action suite. This fixture connects the real body, facts and task.
        ClaudeApplyBandageAction={new=function(_,p,other,item,part,doIt,supplyKey,partIndex)
            return {kind="bandage",character=p,otherPlayer=other,item=item,bodyPart=part,
                isValid=function(self)
                    if self.claudeAuthorized==nil or self.claudeAuthorized()~=true then return false end
                    if p~=other or doIt~=true then return false end
                    local wound=ClaudeTreatmentFacts.inspectWound(p,part)
                    local supply=ClaudeTreatmentFacts.inspectSupply(p,item)
                    return wound.allowed and wound.index==partIndex and supply.allowed and supply.key==supplyKey
                end}
        end}
    elseif name=="TimedActions/ClaudeTakeWaterAction" then
        -- Only the custom native action is stubbed here. Its actual shared
        -- implementation/server transfer guards have their own separate suite.
        ClaudeTakeWaterAction={new=function(_,p,item,source,sourceKey,vesselKey)
            return {kind="takeWater",character=p,item=item,waterObject=source,
                isValid=function(self)
                    if self.claudeAuthorized and self.claudeAuthorized()~=true then return false end
                    local fact=ClaudeWaterFacts.inspectSource(p,source,true)
                    if not fact.allowed or fact.key~=sourceKey then return false end
                    if item then local vessel=ClaudeWaterFacts.inspectVessel(p,item)
                        return vessel.allowed and vessel.key==vesselKey end
                    return true
                end}
        end}
    elseif name~="ClaudeLabControl" then dofile(directory.."/"..name..".lua") end
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
IsoFlagType={waterPiped="waterPiped",water="water",solidfloor="solidfloor"}
instanceof=function(item,kind) return item and (item.kind==kind or (kind=="IsoObject" and item.isoObject==true)) or false end
getGameTime=function() return {getHour=function() return 21 end,getNightsSurvived=function() return 0 end} end
local light={getDisplayName=function() return "fixture light" end,IsFood=function() return false end,
    getID=function() return 1 end,getFluidContainer=function() return nil end,
    getLightStrength=function() return 1 end,setActivated=function() effect("light") end}
local inventoryItems, statValues, squares, walkAllowed, walkTarget = {light}, {}, {}, true, nil
local nativeBusy, traversingWindow = false, false
local medicalParts=nil
local playerPosition,waterReach={x=100.5,y=100.5,z=0},true
ClimbThroughWindowState={instance=function() return "fixture-window-state" end}
local inventory={getItems=function() return vector(inventoryItems) end,
    getItemById=function(_,id)
        for _,item in ipairs(inventoryItems) do if item:getID()==id then return item end end
    end}
light.getContainer=function() return inventory end
light.getType=function() return "Light" end
light.getFullType=function() return "Base.Light" end
light.getModule=function() return "Base" end
player={getX=function() return playerPosition.x end,getY=function() return playerPosition.y end,getZ=function() return playerPosition.z end,
    getStats=function() return {get=function(_,stat) return statValues[stat] or 0 end} end,isDead=function() return false end,
    getOnlineID=function() return 0 end,getUsername=function() return "fixture-user" end,isOutside=function() return false end,
    getCurrentState=function() return traversingWindow and "fixture-window-state" or "fixture-idle-state" end,
    getBodyDamage=function()
        local damage={getOverallBodyHealth=function() return 100 end}
        if medicalParts then damage.getBodyParts=function() return vector(medicalParts) end end
        return damage
    end,
    getInventory=function() return inventory end,isKnownPoison=function(_,item) return item.poison or false end,
    getSquare=function() return {getRoom=function() return nil end} end,getPrimaryHandItem=function() return nil end,
    Say=function() effect("say") end,setSneaking=function() effect("sneak") end,
    faceLocation=function() effect("face") end,faceThisObject=function() effect("face") end,
    DoAttack=function() effect("attack") end,pressedMovement=function() return false end,pressedCancelAction=function() return false end}
getSpecificPlayer=function() return player end
local function square(x,y,z,objects)
    return {getX=function() return x end,getY=function() return y end,getZ=function() return z end,
        getObjects=function() return vector(objects or {}) end,getBuilding=function() return nil end,
        getRoom=function() return nil end,canReachTo=function() return waterReach end}
end
player.getCurrentSquare=function()
    local x,y,z=math.floor(playerPosition.x),math.floor(playerPosition.y),math.floor(playerPosition.z)
    return squares[x..":"..y..":"..z] or square(x,y,z)
end
getCell=function() return {getZombieList=function() return vector(zombies) end,
    getGridSquare=function(_,x,y,z) return squares[x..":"..y..":"..z] or square(x,y,z) end} end
ISTimedActionQueue={getTimedActionQueue=function() return {queue=queue} end,
    isPlayerDoingAction=function() return nativeBusy end,
    hasAction=function(action) for _,candidate in ipairs(queue) do if candidate==action then return true end end;return false end,
    add=function(action) queue[#queue+1]=action; effect("queue");return {queue=queue} end,clear=function() queue={}; effect("clear") end}
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
end,
    getCorrectSquareForWall=function(_,target) return target end,
    walkAdjObject=function(p,source,allowDiagonal,keepActions)
        assert(p==player and allowDiagonal==true and keepActions==true)
        effect("walkAdjObject");walkTarget=source:getSquare()
        if not walkAllowed then return false end
        if ClaudeWaterFacts.inspectSource(p,source,true).allowed then return true end
        ISTimedActionQueue.add({kind="waterApproach",isValid=function() return true end})
        return true
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
    nativeBusy, traversingWindow = false, false
    medicalParts=nil
    playerPosition,waterReach={x=100.5,y=100.5,z=0},true
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
bodyTest("BREAKIN rejects unchecked windows without clearing work or smashing glass",function()
    local target=square(100,100,0)
    local window={kind="IsoWindow",getSquare=function() return target end}
    squares["100:100:0"]=square(100,100,0,{window})
    ISSmashWindow={new=function() return {kind="smash"} end}
    ISClimbThroughWindow={new=function() return {kind="climb"} end}
    command("BREAKIN");advance(60)
    assert(#queue==0 and not effects.clear and not effects.queue,
        "an unchecked window caused a smash, climb or queue mutation")
    assert(percept("err"):match("^breakin:"),"rejection did not explain the blocked window")
end)
bodyTest("unavailable injury APIs are visible as unknown health facts",function()
    advance(60)
    local facts=assert(files["claude_percept.json"]):match('"health":({.-})')
    assert(facts and facts:find('"valid":false',1,true),"missing injury APIs were omitted or reported healthy")
end)
bodyTest("observed bleeding reaches the serialized body percept",function()
    local original=player.getBodyDamage
    BodyPartType={MAX=17,ToIndex=function(kind) return kind end,
        ToString=function(kind) return kind==0 and "Hand_L" or "Part_"..kind end}
    local parts={}
    for index=0,16 do
        local id=index
        parts[#parts+1]={getType=function() return id end,HasInjury=function() return id==0 end,
            bleeding=function() return id==0 end,scratched=function() return false end,isCut=function() return id==0 end,
            deepWounded=function() return false end,bitten=function() return false end,
            haveGlass=function() return false end,bandaged=function() return false end}
    end
    player.getBodyDamage=function() return {getOverallBodyHealth=function() return 100 end,
        getBodyParts=function() return vector(parts) end} end
    advance(60)
    player.getBodyDamage=original
    local text=assert(files["claude_percept.json"])
    assert(text:find('"health":{"valid":true',1,true) and text:find('"bleedingParts":1',1,true))
    assert(text:find('"name":"Hand_L"',1,true) and text:find('"urgency":"bleeding"',1,true))
end)
bodyTest("safe adjacent traversal rechecks hazards and reports a late blocked window",function()
    local original=player.getCurrentSquare
    local a,b=square(100,100,0),square(100,99,0)
    for _,sq in ipairs({a,b}) do
        sq.TreatAsSolidFloor=function() return true end;sq.canStand=function() return true end
        sq.getBrokenGlass=function() return nil end
    end
    local window={kind="IsoWindow",open=true,getObjectIndex=function() return 0 end,
        getSquare=function() return a end,getOppositeSquare=function() return b end,
        IsOpen=function(self) return self.open end,isDestroyed=function() return false end,
        isSmashed=function() return false end,isBarricaded=function() return false end,
        canClimbThrough=function() return true end}
    a.getObjects=function() return vector({window}) end;squares["100:100:0"]=a
    player.getCurrentSquare=function() return a end
    ISClimbThroughWindow={new=function() return {kind="climb",isValid=function() return true end,
        perform=function() effect("actualClimb") end} end}
    ISBaseTimedAction={perform=function() table.remove(queue,1) end}
    command("BREAKIN")
    assert(#queue==1 and queue[1].kind=="climb" and not effects.clear)
    window.open=false;queue[1]:perform();advance(60)
    assert(not effects.actualClimb and #queue==0)
    assert(percept("err")=="breakin: window_closed_no_smashing","late window rejection was hidden")
    window.open=true;command("BREAKIN",2);assert(#queue==1)
    local retained=queue[1];local clear=ISTimedActionQueue.clear
    ISTimedActionQueue.clear=function() error("synthetic queue-clear failure") end
    for _,fn in ipairs(handlers.mouse) do fn() end
    retained:perform();advance(60)
    ISTimedActionQueue.clear=clear;player.getCurrentSquare=original
    assert(not effects.actualClimb and #queue==0,"revoked retained climb executed after failed queue cleanup")
    assert(files["claude_percept.json"]:find('"stopFailed":true',1,true))
end)
bodyTest("native window traversal blocks new work and reflexes despite an empty Lua queue",function()
    nativeBusy,traversingWindow=true,true
    zombies={{getX=function() return 101 end,getY=function() return 100 end}}
    command("MOVE");advance(60)
    assert(#queue==0 and not effects.queue and not effects.attack and not effects.face)
    assert(percept("err")=="intent:body_busy")
    assert(files["claude_percept.json"]:find('"qlen":0,"nativeBusy":true,"traversingWindow":true',1,true))
    command("STOP")
    assert(effects.clear==1,"explicit STOP was not allowed while native traversal was busy")
end)
bodyTest("unreadable action queue remains unknown instead of empty",function()
    local original=ISTimedActionQueue.getTimedActionQueue
    ISTimedActionQueue.getTimedActionQueue=function() error("synthetic unreadable action queue") end
    advance(60)
    ISTimedActionQueue.getTimedActionQueue=original
    assert(files["claude_percept.json"]:find('"qlen":-1',1,true),"unreadable queue was reported empty")
end)
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
    local text=value:match('"'..field..'":"([^"]*)"')
    if text~=nil then return text end
    if value:find('"'..field..'":true',1,true) then return true end
    if value:find('"'..field..'":false',1,true) then return false end
    return tonumber(value:match('"'..field..'":([%d%.%-]+)'))
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

local function waterFluid(amount,capacity)
    local fluid={amount=amount,capacity=capacity,pure=true,tainted=false,poisoned=false}
    function fluid:getAmount() return self.amount end
    function fluid:getCapacity() return self.capacity end
    function fluid:isEmpty() return self.amount==0 end
    function fluid:isPureFluid(kind) return kind==Fluid.Water and self.pure end
    function fluid:isTainted() return self.tainted end
    function fluid:isPoisonous() return self.poisoned end
    function fluid:isInputLocked() return false end
    function fluid:canAddFluid(kind) return kind==Fluid.Water end
    return fluid
end
local function tap(x,y)
    local objects={}
    local target=square(x,y,0,objects)
    local source={kind="IsoObject",isoObject=true,amount=10,external=false,tainted=false}
    objects[1]=source;squares[x..":"..y..":0"]=target
    function source:getSquare() return target end
    function source:getObjectIndex() return 0 end
    function source:getProperties() return {has=function(_,flag) return flag==IsoFlagType.waterPiped end} end
    function source:getUsesExternalWaterSource() return self.external end
    function source:getFluidAmount() return self.amount end
    function source:hasFluid() return self.amount>0 end
    function source:hasWater() return true end
    function source:getPrimaryFluid() return Fluid.Water end
    function source:isTaintedWater() return self.tainted end
    function source:getFluidContainer() return self.fluid end
    return source,target
end
local function waterVessel(id,amount,capacity)
    local item={kind="WaterBottle",fluid=waterFluid(amount,capacity)}
    function item:getID() return id end
    function item:getDisplayName() return "fixture-water-vessel" end
    function item:getContainer() return inventory end
    function item:getFluidContainer() return self.fluid end
    inventoryItems[#inventoryItems+1]=item
    return item
end

bodyTest("water observations and capabilities describe the prepared narrow skills",function()
    tap(101,100);waterVessel(70,0,1);advance(60)
    local text=assert(files["claude_percept.json"])
    assert(text:find('"bodyRevision":"care-1"',1,true))
    assert(text:find('"tapDrinking":"safe_local_piped_only"',1,true))
    assert(text:find('"bottleFilling":"owned_compatible_vessel"',1,true))
    assert(text:find('"water":{',1,true) and text:find('"key":"101:100:0:0"',1,true))
    assert(text:find('"key":"item:70"',1,true))
end)
bodyTest("tap drinking waits for approach then reports measured thirst change",function()
    local source,target=tap(102,100)
    statValues[CharacterStat.THIRST]=0.6
    command("DRINKTAP");advance(60)
    assert(#queue==1 and queue[1].kind=="waterApproach" and walkTarget==target,
        "native drinking was queued before route completion")
    assert(outcome("action")=="DRINKTAP" and outcome("status")=="pending")
    queue={};playerPosition.x=101.5;advance()
    assert(#queue==1 and queue[1].kind=="takeWater" and queue[1].waterObject==source and queue[1].item==nil)
    queue={};statValues[CharacterStat.THIRST]=0.2;advance(60)
    assert(outcome("status")=="observed_effect" and math.abs(outcome("thirstDrop")-0.4)<0.000001)
    assert(outcome("sourceKey")=="102:100:0:0")
end)
bodyTest("bottle filling reports gain in the same clean inventory vessel",function()
    local source=tap(101,100);local vessel=waterVessel(71,0.1,1)
    command("FILLBOTTLE");advance(60)
    assert(#queue==1 and queue[1].kind=="takeWater" and queue[1].waterObject==source and queue[1].item==vessel)
    assert(outcome("status")=="pending" and outcome("vesselKey")=="item:71")
    queue={};vessel.fluid.amount=1;advance(60)
    assert(outcome("status")=="observed_effect" and math.abs(outcome("amountGain")-0.9)<0.000001)
end)
bodyTest("unsafe or unreadable tap water is refused without fake effects",function()
    local source=tap(101,100);source.fluid=waterFluid(2,5);source.fluid.pure=false
    statValues[CharacterStat.THIRST]=0.7
    command("DRINKTAP");advance(60)
    assert(#queue==0 and not effects.walkAdjObject and not effects.queue)
    assert(outcome("status")=="no_effect" and outcome("thirstDrop")==0)
    source.fluid=nil;source.getUsesExternalWaterSource=nil
    command("DRINKTAP",2);advance(60)
    assert(#queue==0 and not effects.queue and outcome("status")=="no_effect")
end)
bodyTest("source contamination during approach prevents a water action",function()
    local source=tap(102,100);statValues[CharacterStat.THIRST]=0.7
    command("DRINKTAP");assert(#queue==1 and queue[1].kind=="waterApproach")
    source.fluid=waterFluid(2,5);source.fluid.poisoned=true
    queue={};playerPosition.x=101.5;advance(60)
    assert(#queue==0 and outcome("status")=="no_effect" and outcome("thirstDrop")==0)
    assert(outcome("detail")=="water_source_mixed_tainted_or_poisoned")
end)
bodyTest("queue completion alone cannot claim drinking succeeded",function()
    tap(101,100);statValues[CharacterStat.THIRST]=0.7
    command("DRINKTAP");assert(#queue==1 and queue[1].kind=="takeWater")
    queue={};advance(160)
    assert(outcome("status")=="no_effect" and outcome("thirstDrop")==0)
    assert(outcome("detail")=="water_queue_empty_without_measured_effect")
end)
bodyTest("manual takeover interrupts water and invalidates retained action authority",function()
    tap(101,100);statValues[CharacterStat.THIRST]=0.7
    command("DRINKTAP");assert(#queue==1 and queue[1].kind=="takeWater")
    local retained=queue[1]
    for _,fn in ipairs(handlers.mouse) do fn() end
    advance(60)
    assert(#queue==0 and outcome("status")=="interrupted" and retained:isValid()==false)
    assert(outcome("session")==session and percept("session")~=session)
    assert(files["claude_percept.json"]:find('"armed":false',1,true))
end)
bodyTest("failed approach never queues fallback consumption",function()
    tap(102,100);walkAllowed=false;statValues[CharacterStat.THIRST]=0.7
    command("DRINKTAP");advance(60)
    assert(effects.walkAdjObject==1 and #queue==0 and not effects.queue)
    assert(outcome("status")=="no_effect" and outcome("detail")=="water_approach_refused")
end)
bodyTest("new water outcome supersedes an older completed inventory action",function()
    inventoryItems[#inventoryItems+1]=fixtureItem(72,"Food")
    statValues[CharacterStat.HUNGER],statValues[CharacterStat.THIRST]=0.5,0.7
    command("EAT");queue={};statValues[CharacterStat.HUNGER]=0.2;advance(60)
    assert(outcome("seq")==1 and outcome("status")=="observed_effect")
    tap(101,100);command("DRINKTAP",2);advance(60)
    assert(outcome("seq")==2 and outcome("action")=="DRINKTAP" and outcome("status")=="pending")
end)
bodyTest("later inventory action supersedes a completed water outcome",function()
    tap(101,100);statValues[CharacterStat.THIRST]=0.7
    command("DRINKTAP");queue={};statValues[CharacterStat.THIRST]=0.2;advance(60)
    assert(outcome("seq")==1 and outcome("status")=="observed_effect")
    inventoryItems[#inventoryItems+1]=fixtureItem(73,"Food");statValues[CharacterStat.HUNGER]=0.5
    command("EAT",2);advance(60)
    assert(outcome("seq")==2 and outcome("action")=="EAT" and outcome("status")=="pending")
end)

local function medicalBody()
    BodyPartType={MAX=17,ToIndex=function(kind) return kind end,
        ToString=function(kind) return kind==0 and "Hand_L" or "Part_"..kind end}
    medicalParts={}
    for index=0,16 do
        local id=index
        local part={dressed=false,bleeds=id==0,cut=id==0,glass=false,life=0,dressingType=nil}
        function part:getParentChar() return player end
        function part:getIndex() return id end
        function part:getType() return id end
        function part:HasInjury() return self.bleeds or self.cut or self.glass end
        function part:bleeding() return self.bleeds end
        function part:scratched() return false end
        function part:isCut() return self.cut end
        function part:deepWounded() return false end
        function part:bitten() return false end
        function part:haveGlass() return self.glass end
        function part:haveBullet() return false end
        function part:stitched() return false end
        function part:isBurnt() return false end
        function part:isSplint() return false end
        function part:getBurnTime() return 0 end
        function part:getFractureTime() return 0 end
        function part:manipulatingUsername() return nil end
        function part:bandaged() return self.dressed end
        function part:getBandageLife() return self.life end
        function part:getBandageType() return self.dressingType end
        medicalParts[#medicalParts+1]=part
    end
    return medicalParts[1]
end
local function bandageSupply(id,kind)
    local item={kind="InventoryItem",supplyType=kind or "Bandage",infected=false,container=inventory}
    function item:getID() return id end
    function item:getDisplayName() return self.supplyType end
    function item:getType() return self.supplyType end
    function item:getModule() return "Base" end
    function item:getFullType() return "Base."..self.supplyType end
    function item:getContainer() return self.container end
    function item:getUses() return 1 end
    function item:getBandagePower() return 4 end
    function item:isCanBandage() return true end
    function item:isInfected() return self.infected end
    function item:getFluidContainer() return nil end
    inventoryItems[#inventoryItems+1]=item
    return item
end
local function consumeSupply(item)
    for i,candidate in ipairs(inventoryItems) do if candidate==item then table.remove(inventoryItems,i);break end end
    item.container=nil
end
local function dressed(part,kind)
    part.dressed,part.bleeds,part.life,part.dressingType=true,false,4,kind or "Base.Bandage"
end

bodyTest("treatment observations advertise only supported self bandaging",function()
    medicalBody();bandageSupply(80);advance(60)
    local text=assert(files["claude_percept.json"])
    assert(text:find('"bodyRevision":"care-1"',1,true))
    assert(text:find('"injuryTreatment":"self_bandage_simple_bleeding"',1,true))
    assert(text:find('"treatment":{',1,true) and text:find('"eligibleWounds":[{"index":0,"name":"Hand_L"}]',1,true))
    assert(text:find('"key":"item:80"',1,true) and text:find('"fullType":"Base.Bandage"',1,true))
end)
bodyTest("BANDAGE connects native task and requires dressing plus exact supply consumption",function()
    local part=medicalBody();local item=bandageSupply(81)
    command("BANDAGE");advance(60)
    assert(#queue==1 and queue[1].kind=="bandage" and queue[1].item==item and queue[1].bodyPart==part)
    assert(outcome("action")=="BANDAGE" and outcome("status")=="pending" and outcome("partIndex")==0)
    dressed(part);consumeSupply(item);queue={};advance(60)
    assert(outcome("status")=="observed_effect" and outcome("bandaged")==true and outcome("consumed")==true)
    assert(outcome("supplyKey")=="item:81" and outcome("session")==session)
end)
bodyTest("BANDAGE refuses dirty supplies and unsupported complex wounds",function()
    local part=medicalBody();local item=bandageSupply(82);item.infected=true
    command("BANDAGE");advance(60)
    assert(#queue==0 and not effects.queue and outcome("status")=="no_effect")
    item.infected=false;part.glass=true;command("BANDAGE",2);advance(60)
    assert(#queue==0 and not effects.queue and outcome("status")=="no_effect")
end)
bodyTest("empty medical queue alone does not claim treatment success",function()
    medicalBody();bandageSupply(83);command("BANDAGE");queue={};advance(160)
    assert(outcome("status")=="no_effect" and outcome("bandaged")==false and outcome("consumed")==false)
end)
bodyTest("dressing alone is insufficient medical completion evidence",function()
    local part=medicalBody();bandageSupply(84);command("BANDAGE");dressed(part);queue={};advance(160)
    assert(outcome("status")=="unverified" and outcome("bandaged")==true and outcome("consumed")==false)
end)
bodyTest("supply disappearance alone is insufficient medical completion evidence",function()
    medicalBody();local item=bandageSupply(85);command("BANDAGE");consumeSupply(item);queue={};advance(160)
    assert(outcome("status")=="unverified" and outcome("bandaged")==false and outcome("consumed")==true)
end)
bodyTest("different dressing type cannot claim the requested treatment succeeded",function()
    local part=medicalBody();local item=bandageSupply(86);command("BANDAGE")
    dressed(part,"Base.RippedSheets");consumeSupply(item);queue={};advance(160)
    assert(outcome("status")=="unverified" and outcome("consumed")==true)
end)
bodyTest("manual takeover cancels medical work and invalidates its retained action",function()
    medicalBody();bandageSupply(87);command("BANDAGE");local retained=assert(queue[1])
    for _,fn in ipairs(handlers.mouse) do fn() end
    advance(60)
    assert(#queue==0 and outcome("status")=="interrupted" and retained:isValid()==false)
    retained.claudeOnBlocked("late_retained_blocker");advance(60)
    assert(outcome("status")=="interrupted" and outcome("session")==session and percept("session")~=session)
end)
bodyTest("old medical callback cannot finish a newer bandage task",function()
    local part=medicalBody();local item=bandageSupply(88);command("BANDAGE");local old=assert(queue[1])
    dressed(part);consumeSupply(item);queue={};advance(60)
    medicalParts[2].bleeds,medicalParts[2].cut=true,true;bandageSupply(89)
    command("BANDAGE",2);advance(60)
    assert(outcome("seq")==2 and outcome("status")=="pending" and outcome("partIndex")==1)
    old.claudeOnBlocked("late_old_failure");advance(60)
    assert(outcome("seq")==2 and outcome("status")=="pending" and old:isValid()==false)
end)
bodyTest("medical receipt supersedes an older completed water result",function()
    tap(101,100);statValues[CharacterStat.THIRST]=0.7;command("DRINKTAP")
    queue={};statValues[CharacterStat.THIRST]=0.2;advance(60)
    assert(outcome("status")=="observed_effect")
    medicalBody();bandageSupply(90);command("BANDAGE",2);advance(60)
    assert(outcome("seq")==2 and outcome("action")=="BANDAGE" and outcome("status")=="pending")
end)
bodyTest("later inventory receipt supersedes a completed medical result",function()
    local part=medicalBody();local item=bandageSupply(91);command("BANDAGE")
    dressed(part);consumeSupply(item);queue={};advance(60)
    inventoryItems[#inventoryItems+1]=fixtureItem(92,"Food");statValues[CharacterStat.HUNGER]=0.5
    command("EAT",2);advance(60)
    assert(outcome("seq")==2 and outcome("action")=="EAT" and outcome("status")=="pending")
end)
bodyTest("native activity prevents medical success despite measured changes and an empty Lua queue",function()
    local part=medicalBody();local item=bandageSupply(93);command("BANDAGE")
    dressed(part);consumeSupply(item);queue={};nativeBusy=true;advance(60)
    assert(outcome("status")=="pending")
    nativeBusy=false;advance(60)
    assert(outcome("status")=="observed_effect")
end)
bodyTest("moving a dressing item into another container is not consumption",function()
    local part=medicalBody();local item=bandageSupply(94);command("BANDAGE")
    dressed(part);consumeSupply(item);item.container={};queue={};advance(160)
    assert(outcome("status")=="unverified" and outcome("consumed")==false)
end)
print("passed "..count.." lab Lua tests")
