-- plugins_test.lua <mod dir> <example add-on dir> (run by tools/checks/plugins_test.sh): the add-on API
-- (Scripts/sv_plugins.lua, docs/ADDONS.md) with the game stubbed: the loader, versions, requires, check, the guard
-- (an error, a stall), run / round events, Survival's music given back, and the example add-on
-- (examples/addons/target_practice) played through: spawn, paid kills, busy, the time limit, the clean-up.
local MOD, EX = arg[1], arg[2]
local fails = 0
local function check(ok, what) if ok then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end end
local function readAll(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end

-- Survival's globals the API uses, stubbed
local logs = {}
function log(s) logs[#logs + 1] = s end
function crumb() end
local function said(pat) for _, l in ipairs(logs) do if l:find(pat, 1, true) then return true end end return false end
CFG = { specials = { rotation = { "shuttle" } } }
CFG_DEFAULTS = { specials = { rotation = { "shuttle" } } }
SPC = { kinds = {} }
AIRFIELD = { X = 1609639.0, Y = -436414.0 }
D = nil
local paid = {}
function addCredits(n, why) paid[#paid + 1] = { n = n, why = why } end
TIER = { pay = function(b) return b, 1 end, specialX = function() return 1 end, index = function() return 1 end }
LB = { stat = function() end }
function playerLocation() return { X = 0, Y = 0, Z = 0 } end
local callouts = {}
function hudCallout(t, s) callouts[#callouts + 1] = t .. " / " .. tostring(s) end
local going = false
function levelGoing() return going end
local fakeClock = 0
local realClock = os.clock
os.clock = function() return realClock() + fakeClock end   -- luacheck: ignore
local bgm = {}
function SV_PlayBGM(ev) bgm[#bgm + 1] = ev; return 1 end
local actors = {}
local function actor(cls)
    local a = { cls = cls, HealthInternal = 100, live = true }
    function a:K2_DestroyActor() self.live = false end
    actors[#actors + 1] = a
    return a
end
function valid(o) return type(o) == "table" and o.live ~= false end
function liveObj(o) return valid(o) end
function liveAddr(o) return valid(o) and 1 or nil end
function addrOf(o) return o end
function loadObject(p) return { path = p, live = true, GetFullName = function() return p end } end
local GS = {
    BeginDeferredActorSpawnFromClass = function(_, pc, cls) return actor(cls.path) end,
    FinishSpawningActor = function(_, a) return a end,
}
function StaticFindObject(p) if p:find("GameplayStatics", 1, true) then return GS end end
survivalPC = { live = true }

-- the plugins folder: the example add-on and the test's own
local TEST_FILES = {
    ["n_newer.lua"] = [[NEWER = { SVP.register("newerk", { name = "Newer", api = "3.0", kind = { spawn = function() return true end } }) }]],
    ["r_req.lua"] = [[REQ = { SVP.register("reqk", { name = "Req", api = "2.0", requires = { "SV_NoSuchThing" },
        kind = { spawn = function() return true end } }) }]],
    ["v_one.lua"] = [[ONE = { SVP.register("onek", { name = "One", kind = { spawn = function() return true end } }) }]],
    ["x_bad.lua"] = [[SVP.register("badk", { name = "Bad", api = "2.0", kind = { spawn = function() return true end,
        tick = function() error("boom") end, busy = function() return true end } })]],
    ["y_slow.lua"] = [[SVP.register("slowk", { name = "Slow", api = "2.0", kind = { spawn = function() SVP.bgm(false); return true end,
        tick = function() SLOW_FAKE() end, busy = function() return true end } })
        EV = {}
        for _, e in ipairs({ "runStart", "roundStart", "roundEnd", "runEnd" }) do
            SVP.on(e, function(now, a) EV[#EV + 1] = e .. (a and (":" .. a) or "") end)
        end]],
}
local files = { { name = "target_practice.lua", path = EX .. "/plugins/target_practice.lua" } }
local tmp = os.tmpname()
for n, src in pairs(TEST_FILES) do
    local p = tmp .. "_" .. n
    local f = assert(io.open(p, "wb")); f:write(src); f:close()
    files[#files + 1] = { name = n, path = p }
end
function IterateGameDirectories()
    local fl = {}
    for _, f in ipairs(files) do fl[#fl + 1] = { __name = f.name, __absolute_path = f.path } end
    return { Game = { Binaries = { Win64 = { ue4ss = { Mods = { AC8SurvivalMode = { plugins = { __files = fl } } } } } } } }
end
SCRIPT_DIR = "x\\Game\\Binaries\\Win64\\ue4ss\\Mods\\AC8SurvivalMode\\Scripts\\"   -- (no drive letter: paths_check)
function SLOW_FAKE() fakeClock = fakeClock + 3 end

assert(load(readAll(MOD .. "/Scripts/sv_plugins.lua"), "@sv_plugins.lua"))()
for _, f in ipairs(files) do if f.path:find(tmp, 1, true) then os.remove(f.path) end end

print("versions and requirements")
check(SVP.api.major == 2 and SVP.api.minor >= 0, "SVP.api is 2.x")
local l2 = select(2, readAll(MOD .. "/Scripts/sv_plugins.lua"):match("^([^\n]*)\n([^\r\n]*)"))
check(l2 == string.format("-- add-on API %d.%d", SVP.api.major, SVP.api.minor),
    "line 2 of sv_plugins.lua (what a native mod reads) is the API's version: " .. tostring(l2))
check(NEWER[1] == false and SPC.kinds.newerk == nil and said("Newer: not loaded: it needs add-on API 3.0"),
    "an add-on needing a newer API: refused, one line")
check(REQ[1] == false and said("requires SV_NoSuchThing"), "an add-on missing a native function it requires: refused")
check(ONE[1] == true and SPC.kinds.onek ~= nil, "an API 1 add-on (no def.api) still served")

print("the example add-on: target practice")
local k = SPC.kinds.practice
check(k ~= nil and CFG.specials.practice.trucks == 3, "registered, its settings in CFG.specials.practice")
local inRot = false
for _, x in ipairs(CFG.specials.rotation) do if x == "practice" then inRot = true end end
check(not inRot, "not in the rotation by itself (def.rotation false)")
D = { round = 1, now = 0 }
check(k.ready(1, false) == false and k.ready(2, false) == true, "ready from round 2")
check(k.spawn(10) == true and #actors == 3 and callouts[#callouts]:find("TARGET PRACTICE", 1, true) ~= nil,
    "spawn: 3 trucks on the pad, the callout")
check(k.busy({}) == true, "busy while trucks are up")
actors[1].HealthInternal = 0
k.tick(11, {})
check(#paid == 1 and paid[1].n == 500, "a destroyed truck is paid (500)")
actors[2].HealthInternal, actors[3].HealthInternal = 0, 0
k.tick(12, {})
check(#paid == 3 and k.busy({}) == false, "all three down: paid, the round no longer held")
k.over(13, nil)
check(actors[1].live == false and actors[2].live == false and actors[3].live == false, "over: its trucks taken off")
check(k.spawn(20) == true, "a second round spawns")
k.tick(20 + 121, {})
check(k.busy({}) == false and callouts[#callouts]:find("TIME UP", 1, true) ~= nil, "the time limit ends it (TIME UP)")
k.over(142, nil)
check(#paid == 3 and actors[4].live == false and actors[6].live == false, "the trucks left at the time limit taken off, unpaid")

print("events")
D = { round = 1, now = 0 }; PLUGINS.tick()
D.round = 2; PLUGINS.tick()
D = nil; PLUGINS.tick()
check(table.concat(EV, " ") == "runStart roundStart:1 roundEnd:1 roundStart:2 roundEnd:2 runEnd:2", "run / round events in order")

print("a freed object's address taken by another")
-- (the GC frees a cached asset and the allocator puts a new object at its address: the old pointer is "live" again,
-- but another object. The cache must look again, never hand it back)
do
    local made = 0
    local realLoad = loadObject
    loadObject = function(p)
        made = made + 1
        return setmetatable({ path = p, live = true, n = made },
            { __index = { GetFullName = function(self) return self.fullname or ("Object " .. p) end } })
    end
    local a1 = SVP.load("/Game/X/MI_A.MI_A")
    local a2 = SVP.load("/Game/X/MI_A.MI_A")
    a1.fullname = "SoundWave /Game/Y/SW_B.SW_B"            -- (its memory is another object now, still a live one)
    local a3 = SVP.load("/Game/X/MI_A.MI_A")
    check(a1 == a2 and a3 ~= a1 and made == 2, "SVP.load: kept while it's the same object, looked up again once it isn't")
    loadObject = realLoad
end

print("isolation")
local kb = SPC.kinds.badk
kb.spawn(1); kb.tick(2, {})
check(kb.busy({}) == false and kb.ready(9, false) == false and said("Bad: tick error"), "an error switches the add-on off: its round ends")
local ks = SPC.kinds.slowk
ks.spawn(1)
check(bgm[#bgm] == "AKE_System_BGM_Mute_On", "SVP.bgm(false) mutes Survival's music")
ks.tick(2, {})
check(ks.ready(9, false) == true and said("a hitch") and bgm[#bgm] == "AKE_System_BGM_Mute_On",
    "one call over 2 s is a hitch: logged, the add-on stays on")
ks.tick(3, {}); ks.tick(4, {})
check(ks.ready(9, false) == false and said("a stall") and bgm[#bgm] == "AKE_System_BGM_Mute_Off",
    "three calls over 2 s within 60 s switch the add-on off and give Survival's music back")

print(fails == 0 and "plugins_test: all passed" or ("plugins_test: " .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
