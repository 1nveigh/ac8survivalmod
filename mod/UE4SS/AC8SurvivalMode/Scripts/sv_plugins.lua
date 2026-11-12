-- sv_plugins.lua: other mods' special rounds (plugins), the API they're given (SVP) and their loader.
-- add-on API 2.0
-- (the line above: the API's version for a native mod to read from this file before Lua runs; kept equal to API below
-- by tools/checks/plugins_test.lua. Its form stays "-- add-on API <major>.<minor>" on line 2)
-- Part of AC8 Survival Mode's runtime, run by main.lua last (after sv_main): a name another part uses is a global of
-- this mod's Lua state, its own helpers stay local (tools/lua_split.py).
--
-- UE4SS gives every Lua mod its own Lua state, so another mod can't reach SPC.kinds from its own main.lua. A plugin is
-- a file AC8SurvivalMode/plugins/<name>.lua that Survival runs here, in its own state, after every part has loaded;
-- it calls SVP.register to add a special kind. Nothing of a plugin's ships in Survival: the folder is empty in every
-- zip, the plugin's mod installs its file there (and its assets in its own container).
--
-- What a plugin gets (every name 15 characters or fewer, hard rule 25's limit kept for the Lua side too):
--   SVP.version                 the API's version (1)
--   SVP.register(kind, def)     a special kind: def.kind = the SPC.kinds entry (sub, alone, aircraft, budget, ready,
--                               spawn, tick, busy, over, row, hold), def.cfg = its settings' defaults (CFG.specials
--                               [kind], [specials.<kind>] in survival.ini over them), def.rotation = true to join the
--                               rotation, def.coop = true when it can run in co-op (version 1: never; solo only),
--                               def.name / def.ver (the log, the leaderboard, later the co-op version check)
--   SVP.target(actor, opts)     a target of the plugin's round: watched every tick of it; down (gone or no health) it
--                               pays opts.pay (x the round's tier, as the Spaceport's ships, unless opts.flat), counts
--                               as a ground (or opts.class "air") kill and calls opts.onDown(id, why). Returns its id.
--   SVP.untarget(id)            taken off the watch, no pay
--   SVP.kill(id, why)           counted down now (the plugin decided it: a scripted kill), paid as above
--   SVP.alive(id)               whether it's still up
--   SVP.pay(n, why)             zollars (addCredits)
--   SVP.load(path)              an object of the plugin's own container by its path (sv_core.lua loadObject: hard
--                               rule 9), or nil and why
--   SVP.hold2d(path)            a 2D sound of the plugin's container held ready (its audio component, not playing,
--                               kept for the level): play2d then plays it with no lookup and no spawn
--   SVP.spawn(cls, at, yaw)     an actor of class `cls` (a class or its path, "/Game/Mods/<its own>/...C") at `at`
--                               (X Y Z cm), turned `yaw` degrees; the actor, or nil and why. Survival's own way
--                               (GameplayStatics' deferred spawn, as its effects': sv_anomalies.lua SPC.V.billboard)
--   SVP.move(a, at, yaw)        moves (teleports) a plugin's actor; SVP.despawn(a) destroys it
--   SVP.players()               { { slot, X, Y, Z } }: you (co-op's other players from version 2)
--   SVP.pad()                   the Comona spaceport's shuttle pad (Mission 22's AA_Obj_01_Ground0_Shuttle_0), cm
--   SVP.runway()                Comona Airport's runway, the spawn anchor (AIRFIELD), cm
--   SVP.clock()                 the rounds' clock (D.now: game time, stops while paused)
--   SVP.round()                 the round number; SVP.run() a token of the run in progress (new each run)
--   SVP.levelGoing()            the level is going away (sv_core.lua levelGoing): touch no object then
--   SVP.callout(text, sub)      the round callout (hudCallout); SVP.say(who, text, secs) the subtitle strip (SUB.say)
--   SVP.log(msg)                Survival's log, the plugin's name first
--   SVP.isHost(), SVP.inCoop()  version 1: true / false (a plugin round never comes in co-op yet)
--   SVP.every(fn)               fn(now) on the game thread from Survival's own tick (every 250 ms, main menu too,
--                               never while the level is being torn down (levelGoing), nor a kind's tick then;
--                               SVP.going(fn) runs fn(now) once as that starts: a plugin's round-over flag;
--                               `now` = os.clock()). A plugin must never use LoopAsync, ExecuteInGameThread,
--                               ExecuteWithDelay or RegisterKeyBind itself: they run its Lua off the game thread in
--                               Survival's one Lua state, which crashes the game (HISTORY 0.73.82; a plugin's
--                               LoopAsync + ExecuteInGameThread aborted the game at launch in a test)
--   SVP.net                     co-op's add-on channel (host -> joiners): API 2.1, a stub now (SVP.send: API 1's)
--   SVP.on(event, fn)           Survival's moments: runStart, roundStart, roundEnd, runEnd, levelGoing (API 2)
--   SVP.provide(name, fn)       what an add-on's native mod gives the API: "hurtPlayer" (API 2)
--   SVP.liveObj(o)              o still the engine's live object (ask it for anything kept between ticks; API 2)
--   SVP.bgm(on)                 Survival's music off / back for an add-on's track, always given back (API 2)
--   SVP.api                     { major, minor }; an add-on's def.api = "2.0" is the lowest it needs; def.requires
--                               = native function names it needs; def.check() = its own readiness (API 2)
--   SVP.sound(path, at)         a Wwise event at a spot; SVP.fx(path, at, scale, rot, floats) a Niagara system (the
--                               component back); SVP.play2d(path, vol) a sound wave heard by you alone (ok, length s,
--                               its audio component: :Stop() cuts it short)
--   SVP.playerPlane()           { a, X, Y, Z, VX, VY, VZ, health, down } of your plane, or nil
--   SVP.retire(a)               the game kills one of the plugin's units (ModifyHealth): freed as a stock unit is,
--                               nothing counted or paid for it
--   SVP.hurt(a, n, causer)      n damage (MaxHealth units) to an AI object (ModifyHealth; causer nil = no one's kill,
--                               counted and paid to no one) or your plane (the hurtPlayer provider, else its health
--                               written; a lethal hit is SVP.killPlayer); SVP.killPlayer(why) the stock sure kill
-- A kind may also give abort(why): called when the run its round belongs to ends under it (every player down, the
-- level left); without one, over(now, nil). Its targets are taken off unpaid. Touch no object when why is
-- "the level is going".
-- A plugin's callbacks run in a pcall: its first error is logged once and the plugin is switched off (its round, if
-- one is on, ends as soon as Survival's checks allow: busy false, its targets taken off the watch).
-- A run with any plugin loaded isn't ranked (sv_leaderboard.lua LB.edited lists it), as with survival_config.lua.

PLUGINS = { loaded = {}, kinds = {}, targets = {}, nextId = 0 }

do
    -- the add-on API's version: an add-on declares the lowest it needs (def.api = "2.0"); a minor version only adds
    -- calls, so every add-on of a lower minor (and API 1's, which declared none) keeps working
    local API = { major = 2, minor = 0 }
    -- Mission 22's shuttle (AA_Obj_01_Ground0_Shuttle_0), x / y / z cm: tools/re/SPECIAL_ROUNDS.md "The shuttle"
    local SHUTTLE_PAD = { X = -1324937.0, Y = 59740.0, Z = 6343.0 }
    local NAME_MAX = 15

    local function plog(p, msg) log("plugin " .. tostring(p and p.name or "?") .. ": " .. tostring(msg)) end

    -- One add-on can't stall Survival: a callback over STALL_OFF_MS in one call switches it off as an error does;
    -- STALL_WARN_MS three times in a row is said once
    local STALL_WARN_MS, STALL_OFF_MS = 100, 2000

    -- Survival's music muted for an add-on's own track (SVP.bgm), and ALWAYS given back: at its round's end, its run's
    -- end, the level going, or the add-on switched off. SV_PlayBGM is refused while a level is torn down: Survival's
    -- own sound tick then posts the unmute in the next level (sv_sound.lua unmuteTick).
    local function bgmBack(p, why)
        if not (p and p.bgmMuted) then return end
        p.bgmMuted = false
        local ok, r = false, nil
        if type(SV_PlayBGM) == "function" then ok, r = pcall(SV_PlayBGM, "AKE_System_BGM_Mute_Off") end
        ok = ok and type(r) == "number" and r > 0
        if not ok and type(SND) == "table" then SND.unmuteDue, SND.unmuteAt, SND.unmuteTries = true, nil, 0 end
        plog(p, "Survival's music given back (" .. tostring(why) .. ")" .. (ok and "" or ": left to Survival's sound tick"))
    end
    PLUGINS.bgmBack = bgmBack

    -- an add-on switched off for the session: its round ends as soon as Survival's checks allow (busy false), its
    -- targets come off unpaid, Survival's music is given back
    function PLUGINS.switchOff(p, why)
        if p.off then return end
        p.off = true
        plog(p, tostring(why) .. ": the add-on is switched off for this session")
        crumb("plugin " .. tostring(p.name) .. " off")
        for id, t in pairs(PLUGINS.targets) do if t.p == p then PLUGINS.targets[id] = nil end end
        bgmBack(p, "switched off")
    end

    -- a plugin's callback, guarded: its first error switches the plugin off
    local function guard(p, what, fn, fallback)
        if type(fn) ~= "function" then return fn end
        return function(...)
            if p.off then return fallback end
            local prev = PLUGINS.running
            PLUGINS.running = p                     -- (SVP.target from inside a callback: the target is this plugin's)
            local t0 = os.clock()
            local res = table.pack(pcall(fn, ...))
            local ms = (os.clock() - t0) * 1000
            PLUGINS.running = prev
            if res[1] and ms > STALL_OFF_MS then
                PLUGINS.switchOff(p, string.format("%s took %.0f ms (a stall: over %d ms in one call)", what, ms, STALL_OFF_MS))
                return fallback
            end
            if res[1] and ms > STALL_WARN_MS then
                p.slow = (p.slow or 0) + 1
                if p.slow == 3 then plog(p, string.format("%s took %.0f ms, 3 slow calls in a row (over %d ms): the game hitches", what, ms, STALL_WARN_MS)) end
            elseif res[1] then
                p.slow = 0
            end
            if res[1] then return table.unpack(res, 2, res.n) end
            PLUGINS.switchOff(p, what .. " error " .. tostring(res[2]))
            return fallback
        end
    end

    -- [specials.<kind>] read from survival.ini over the plugin's defaults (survival.ini was read before any plugin
    -- existed, so its section was skipped then, "no section"). Each value takes its default's type.
    local function iniOver(kind, t)
        local f = io.open(SCRIPT_DIR .. "..\\config\\survival.ini", "r")
        if not f then return 0 end
        local want, inSec, n = ("specials." .. kind):lower(), false, 0
        for line in f:lines() do
            line = line:gsub("^\239\187\191", ""):gsub("%s*[;#].*$", ""):match("^%s*(.-)%s*$")
            local sec = line:match("^%[%s*(.-)%s*%]$")
            if sec then inSec = (sec:lower() == want)
            elseif inSec and line ~= "" then
                local key, val = line:match("^([^=]-)%s*=%s*(.*)$")
                local field = nil
                if key then for k in pairs(t) do if type(k) == "string" and k:lower() == key:lower() then field = k end end end
                if field then
                    local old, v = t[field], nil
                    if type(old) == "number" then v = tonumber(val)
                    elseif type(old) == "boolean" then
                        if val:lower() == "true" then v = true elseif val:lower() == "false" then v = false end
                    elseif type(old) == "string" then v = val
                    elseif type(old) == "table" then
                        v = {}
                        for item in val:gmatch("[^,]+") do
                            local s = item:match("^%s*(.-)%s*$")
                            if s ~= "" then v[#v + 1] = tonumber(s) or s end
                        end
                    end
                    if v ~= nil then t[field], n = v, n + 1 end
                end
            end
        end
        f:close()
        return n
    end

    local function sameList(a, b)
        if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
        for i = 1, #a do if a[i] ~= b[i] then return false end end
        return true
    end

    local function inList(l, v) for _, x in ipairs(l or {}) do if x == v then return true end end return false end

    -- the targets' watch: a target is down when its actor is gone or its health is 0
    local function healthOf(o)
        local ok, h = pcall(function() return o.HealthInternal end)
        if ok and type(h) == "number" then return h end
        return nil
    end
    local function down(id, t, why)
        PLUGINS.targets[id] = nil
        local o = t.opts
        local pay = tonumber(o.pay) or 0
        if pay > 0 and not o.flat and TIER and TIER.pay then
            pay = TIER.pay(pay * TIER.specialX(), D and D.round and TIER.index(D.round))
        end
        if pay > 0 then addCredits(pay, string.format("%s: %s down", tostring(t.p.name), tostring(o.label or ("target " .. id)))) end
        if LB and LB.stat then LB.stat(o.class == "air" and "air" or "ground", 1) end
        plog(t.p, string.format("target %d (%s) down (%s; +%d)", id, tostring(o.label or "?"), why, pay))
        if type(o.onDown) == "function" then guard(t.p, "onDown", o.onDown)(id, why) end
    end
    -- (a slice a tick, SWEEP_N targets: a round of 150 targets read in one tick cost the game thread; a target's death
    -- is seen within a few ticks)
    local SWEEP_N = 24
    -- (a slice a tick, SWEEP_N targets: a round of 150 targets read in one tick cost the game thread; a target's death
    -- is seen within a few ticks)
    local SWEEP_N = 24
    local function sweep(p)
        if p.off then
            for id, t in pairs(PLUGINS.targets) do if t.p == p then PLUGINS.targets[id] = nil end end
            return
        end
        local L = p.sweepList
        if not L or p.sweepI > #L then
            L = {}
            for id, t in pairs(PLUGINS.targets) do if t.p == p then L[#L + 1] = id end end
            p.sweepList, p.sweepI = L, 1
        end
        local stop = math.min(#L, p.sweepI + SWEEP_N - 1)
        for i = p.sweepI, stop do
            local id = L[i]
            local t = PLUGINS.targets[id]
            if t then
                if not liveAddr(t.actor) then down(id, t, "gone")
                else
                    local h = healthOf(t.actor)
                    if h and h <= 0 then down(id, t, "no health") end
                end
            end
        end
        p.sweepI = stop + 1
    end

    -- the game-thread cost of a plugin's work (its tick + the API's sweep, its `every` jobs): a summary in the log every
    -- 30 s while it runs, worst first (a game-thread job should stay under ~5 ms)
    local function perf(p, what, ms)
        local P = p.perf or { at = os.clock() }
        p.perf = P
        local e = P[what] or { n = 0, sum = 0, max = 0, over = 0 }
        P[what] = e
        e.n, e.sum = e.n + 1, e.sum + ms
        if ms > e.max then e.max = ms end
        if ms > 5 then e.over = e.over + 1 end
        if os.clock() - P.at >= 30 then
            local parts = {}
            for k, v in pairs(P) do
                if type(v) == "table" then
                    parts[#parts + 1] = string.format("%s avg %.2f / max %.1f ms over %d calls (%d over 5 ms)", k, v.sum / v.n, v.max, v.n, v.over)
                end
            end
            table.sort(parts)
            plog(p, "per-tick cost: " .. table.concat(parts, "; "))
            p.perf = { at = os.clock() }
        end
    end
    PLUGINS.perf = perf

    -- the SPC.kinds entry Survival runs for a plugin's kind: every callback guarded; tick also watches its targets;
    -- busy is false once the plugin is off, so its round can end
    local function kindEntry(p, k, check)
        local e = {}
        check = guard(p, "check", check, false)
        for name, v in pairs(k) do e[name] = guard(p, name, v, nil) end
        local tick, busy, ready, spawn = e.tick, e.busy, e.ready, e.spawn
        e.tick = function(now, s)
            if levelGoing and levelGoing() then return end     -- (the round-over rule: no tick while the level goes)
            local t0 = os.clock()
            sweep(p)
            local t1 = os.clock()
            local r = table.pack(tick and tick(now, s))
            local t2 = os.clock()
            perf(p, "sweep", (t1 - t0) * 1000)
            perf(p, "tick", (t2 - t1) * 1000)
            return table.unpack(r, 1, r.n)
        end
        e.busy = function(s) if p.off then return false end return busy and busy(s) or false end
        e.ready = function(round, forced)
            if p.off then return false end
            if COOP and COOP.open and p.coop ~= true then return false end      -- (version 1: solo only)
            if check then
                -- (the add-on's own readiness: its native mod, its data. No = its round skipped, Survival's normal wave;
                -- said once a run for each reason)
                local ok, why = check()
                if ok ~= true then
                    local key = tostring(D) .. "|" .. tostring(why)
                    if p.checkSaid ~= key then p.checkSaid = key; plog(p, "its round skipped: " .. tostring(why or "not ready")) end
                    return false
                end
            end
            if ready then return ready(round, forced) == true end
            return true
        end
        e.spawn = function(now)
            if p.off then return false end
            local ok = spawn and spawn(now) == true or false
            if ok then p.liveRun = D end                -- (the run this round belongs to: PLUGINS.tick's run-over check)
            return ok
        end
        local over = e.over
        e.over = function(now, s)
            p.liveRun = nil
            local r = table.pack(over and over(now, s))
            bgmBack(p, "its round is over")
            return table.unpack(r, 1, r.n)
        end
        return e
    end

    -- A plugin round whose run ended under it (every player down: DOWN.runOver; the level left; a new run): Survival
    -- doesn't finish a special then (its own specials check `S.D ~= D` themselves, sv_escort_li.lua), so the API
    -- does it for plugins: the kind's abort(why) (or over(now, nil) without one) and its targets off the watch, unpaid.
    local function runCheck(now)
        for _, p in ipairs(PLUGINS.loaded) do
            if p.liveRun ~= nil and (D ~= p.liveRun or (levelGoing and levelGoing())) then
                local why = (levelGoing and levelGoing()) and "the level is going" or (D == nil and "the run is over" or "a new run")
                p.liveRun = nil
                for id, t in pairs(PLUGINS.targets) do if t.p == p then PLUGINS.targets[id] = nil end end
                plog(p, "its round's run ended (" .. why .. "): round taken off")
                bgmBack(p, "its run ended")
                for _, k in ipairs(p.kinds) do
                    local def = p.defs and p.defs[k]
                    if def and type(def.abort) == "function" then guard(p, "abort", def.abort)(why)
                    elseif def and type(def.over) == "function" then guard(p, "over", def.over)(now, nil) end
                end
            end
        end
    end

    SVP = {}
    SVP.version = API.major
    SVP.api = { major = API.major, minor = API.minor }

    -- "M.m" (or a number) -> major, minor; nil when it isn't a version
    local function parseVer(v)
        local maj, min = tostring(v):match("^%s*(%d+)%.?(%d*)%s*$")
        if not maj then return nil end
        return tonumber(maj), tonumber(min) or 0
    end
    -- whether this API serves an add-on that needs `need` (nil: an API 1 add-on, from before versions were declared)
    local function serves(need)
        if need == nil then return true end
        local maj, min = parseVer(need)
        if not maj then return false, "its def.api \"" .. tostring(need) .. "\" isn't a version (\"2.0\")" end
        if maj >= 1 and (maj < API.major or (maj == API.major and min <= API.minor)) then return true end
        return false, string.format("it needs add-on API %d.%d; this Survival has %d.%d", maj, min, API.major, API.minor)
    end

    function SVP.register(kind, def)
        local p = PLUGINS.current
        if not p then return false, "register only while a plugin loads" end
        if type(kind) ~= "string" or not kind:match("^[%a][%w_]*$") or #kind > NAME_MAX then
            return false, "a kind is a name of letters, digits and _, 15 at most"
        end
        if SPC.kinds[kind] then return false, "kind " .. kind .. " is taken" end
        if type(def) ~= "table" or type(def.kind) ~= "table" or type(def.kind.spawn) ~= "function" then
            return false, "def.kind with a spawn function needed"
        end
        if type(def.name) == "string" and def.name ~= "" then p.name = def.name:sub(1, 40) end
        local okV, whyV = serves(def.api)
        if not okV then p.refused = whyV; plog(p, "not loaded: " .. whyV); return false, whyV end
        for _, fn in ipairs(type(def.requires) == "table" and def.requires or {}) do
            if type(_G[fn]) ~= "function" then
                local why = "it requires " .. tostring(fn) .. ", which this game doesn't have"
                p.refused = why; plog(p, "not loaded: " .. why); return false, why
            end
        end
        if def.check ~= nil and type(def.check) ~= "function" then return false, "def.check must be a function" end
        if type(def.name) == "string" and def.name ~= "" then p.name = def.name:sub(1, 40) end
        p.ver, p.coop, p.api = tostring(def.ver or "?"):sub(1, 20), false, def.api and tostring(def.api) or "1"
        local c = {}
        for k, v in pairs(type(def.cfg) == "table" and def.cfg or {}) do c[k] = v end
        if c.enabled == nil then c.enabled = true end
        local n = iniOver(kind, c)
        CFG.specials[kind] = c
        SPC.kinds[kind] = kindEntry(p, def.kind, def.check)
        PLUGINS.kinds[kind] = p
        p.defs = p.defs or {}
        p.defs[kind] = def.kind                       -- (abort / over for a round whose run ended: runCheck)
        p.kinds[#p.kinds + 1] = kind
        -- the rotation: the plugin's kind joins it unless the player wrote a rotation of their own (survival.ini's
        -- `rotation` line), which is theirs to change: the kind's name in it brings the kind, leaving it out keeps it away
        local rot = CFG.specials.rotation
        local shipped = CFG_DEFAULTS and CFG_DEFAULTS.specials and CFG_DEFAULTS.specials.rotation
        local own = shipped and not sameList(rot, shipped)
        if def.rotation == true and type(rot) == "table" and not inList(rot, kind) and not own then rot[#rot + 1] = kind end
        plog(p, string.format("kind %s registered (%d settings from survival.ini; %s)", kind, n,
            inList(rot, kind) and "in the rotation" or "not in the rotation"))
        return true
    end

    function SVP.target(actor, opts)
        local p = PLUGINS.current or PLUGINS.running
        if not (p and liveAddr(actor)) then return nil end
        PLUGINS.nextId = PLUGINS.nextId + 1
        PLUGINS.targets[PLUGINS.nextId] = { actor = actor, opts = type(opts) == "table" and opts or {}, p = p }
        return PLUGINS.nextId
    end
    function SVP.untarget(id) PLUGINS.targets[id] = nil end
    function SVP.alive(id) return PLUGINS.targets[id] ~= nil end
    function SVP.kill(id, why)
        local t = PLUGINS.targets[id]
        if not t then return false end
        down(id, t, tostring(why or "the plugin's"))
        return true
    end
    function SVP.pay(n, why)
        n = math.floor(tonumber(n) or 0)
        if n ~= 0 then addCredits(n, tostring(why or "a plugin's round")) end
    end
    local loadMiss = {}
    local assetHit, assetMiss = {}, {}               -- (plAsset's, below; SVP.load fills the hits too)
    -- An asset or audio component kept in Lua is NOT kept alive by it: the game's garbage collection frees a sound wave
    -- nothing references, and valid() (UE4SS IsValid) can pass on the freed memory. A kept object is used only while
    -- liveObj says it is still the engine's live object; else it is looked up again. (SpawnSound2D on a wave freed since
    -- its last play crashed AC8 in UAudioComponent::PlayInternal, reading the "wave"'s vtable: exe+0x3fb7102)
    local function kept(o) return o ~= nil and liveObj(o) end
    function SVP.load(path)
        if type(path) ~= "string" then return nil, "a path" end
        local m = loadMiss[path]
        if m and os.clock() - m < 30 then return nil, "not found (kept 30 s)" end   -- (a miss isn't loaded again at once)
        local h = assetHit[path]
        if h and kept(h) then return h end               -- (StaticFindObject by path costs 12-37 ms too: kept)
        local okF, f = pcall(StaticFindObject, path)     -- (already in memory: found, not loaded again)
        if okF and valid(f) then assetHit[path] = f; return f end
        local o, why = loadObject(path)
        if o == nil then loadMiss[path] = os.clock() else loadMiss[path] = nil; assetHit[path] = o end   -- (play2d / sound / fx find it)
        return o, why
    end
    local function xform(at, yaw)
        local h = math.rad(tonumber(yaw) or 0) / 2
        return { Rotation = { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) },
                 Translation = { X = at.X, Y = at.Y, Z = at.Z or 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    end
    function SVP.spawn(cls, at, yaw)
        if type(at) ~= "table" then return nil, "no spot" end
        if SVP.levelGoing() then return nil, "the level is going away" end
        if type(cls) == "string" then
            local c, why = loadObject(cls)
            if not valid(c) then return nil, "class " .. cls .. " not loaded: " .. tostring(why) end
            cls = c
        end
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if not (valid(gs) and valid(cls)) then return nil, "no GameplayStatics or class" end
        local t = xform(at, yaw)
        local okA, a = pcall(function()
            local x = gs:BeginDeferredActorSpawnFromClass(survivalPC, cls, t, 1, nil, 1)   -- (AlwaysSpawn, MultiplyWithRoot)
            return gs:FinishSpawningActor(x, t, 1)
        end)
        if not okA or not valid(a) then return nil, "not spawned (" .. tostring(a) .. ")" end
        crumb("plugin spawn " .. tostring(cls:GetFullName()):sub(1, 120))
        return a
    end
    function SVP.move(a, at, yaw)
        if not (liveAddr(a) and type(at) == "table") then return false end
        local ok = pcall(function()
            if yaw ~= nil then
                a:K2_SetActorLocationAndRotation({ X = at.X, Y = at.Y, Z = at.Z or 0 }, { Pitch = 0, Yaw = tonumber(yaw) or 0, Roll = 0 },
                    false, {}, true)
            else
                a:K2_SetActorLocation({ X = at.X, Y = at.Y, Z = at.Z or 0 }, false, {}, true)
            end
        end)
        return ok
    end
    function SVP.despawn(a)
        if not liveAddr(a) then return false end
        crumb("plugin despawn")
        return (pcall(function() a:K2_DestroyActor() end))
    end
    function SVP.players()
        local l = playerLocation()
        if not l then return {} end
        return { { slot = 0, X = l.X, Y = l.Y, Z = l.Z } }
    end
    function SVP.pad() return { X = SHUTTLE_PAD.X, Y = SHUTTLE_PAD.Y, Z = SHUTTLE_PAD.Z } end
    function SVP.runway() return { X = AIRFIELD.X, Y = AIRFIELD.Y } end
    function SVP.clock() return D and D.now or nil end
    function SVP.round() return D and D.round or nil end
    -- the run in progress as a token (a new one each run: e.g. a special that comes once a run), nil between runs
    function SVP.run() return D and tostring(D) or nil end
    function SVP.levelGoing() return levelGoing and levelGoing() or false end
    function SVP.callout(text, sub) hudCallout(tostring(text or ""), sub and tostring(sub) or nil) end
    function SVP.say(who, text, secs) if SUB and SUB.say then return SUB.say(who, text, secs) end end
    function SVP.log(msg) plog(PLUGINS.current or PLUGINS.running, msg) end
    function SVP.isHost() return not (COOP and COOP.client and COOP.client()) end
    function SVP.inCoop() return (COOP and COOP.open) == true end
    PLUGINS.every = {}
    function SVP.every(fn)
        local p = PLUGINS.current or PLUGINS.running
        if not (p and type(fn) == "function") then return false end
        PLUGINS.every[#PLUGINS.every + 1] = { p = p, fn = guard(p, "every", fn) }
        return true
    end
    -- SVP.going(fn): fn(now) once when Survival's level starts being torn down (a run's end, a quit), before nothing else
    -- of the plugin runs: for a plugin's own "round over" flag. It must not touch a game object.
    PLUGINS.going = {}
    function SVP.going(fn)
        local p = PLUGINS.current or PLUGINS.running
        if not (p and type(fn) == "function") then return false end
        PLUGINS.going[#PLUGINS.going + 1] = { p = p, fn = guard(p, "going", fn) }
        return true
    end
    -- SVP.on(event, fn): Survival's moments, any add-on. fn(now, ...) on the game thread:
    --   "runStart" (round 1 of a run is on), "roundStart" (round), "roundEnd" (round), "runEnd" (its last round),
    --   "levelGoing" (the level is being torn down: touch no game object, as SVP.going).
    -- runEnd and levelGoing may come while the level goes: a handler must not touch a game object then.
    local EVENTS = { runStart = true, roundStart = true, roundEnd = true, runEnd = true, levelGoing = true }
    PLUGINS.on = {}
    function SVP.on(event, fn)
        local p = PLUGINS.current or PLUGINS.running
        if not (p and EVENTS[event] and type(fn) == "function") then return false end
        if event == "levelGoing" then return SVP.going(fn) end
        PLUGINS.on[#PLUGINS.on + 1] = { p = p, ev = event, fn = guard(p, event, fn) }
        return true
    end
    local function emit(ev, now, a)
        for _, e in ipairs(PLUGINS.on) do if e.ev == ev and not e.p.off then e.fn(now, a) end end
    end
    -- the run and its round as Survival's tick sees them: the events above when they change
    local seenRun, seenRound = nil, nil
    local function eventsTick(now)
        local run, round = D, D and D.round or nil
        if seenRun ~= nil and run ~= seenRun then
            if seenRound then emit("roundEnd", now, seenRound) end
            emit("runEnd", now, seenRound)
            seenRound = nil
        end
        if run ~= nil and run ~= seenRun then emit("runStart", now) end
        seenRun = run
        if run ~= nil and round ~= seenRound then
            if seenRound then emit("roundEnd", now, seenRound) end
            if round then emit("roundStart", now, round) end
            seenRound = round
        end
    end

    -- (sv_main.lua's tick job, on the game thread, each tick's second half)
    function PLUGINS.tick()
        local now = os.clock()
        local okR, errR = pcall(runCheck, now)
        if not okR then log("plugins: run check error " .. tostring(errR)) end
        local okE, errE = pcall(eventsTick, now)
        if not okE then log("plugins: events error " .. tostring(errE)) end
        -- (nothing of a plugin's reads a game object while the level is being torn down: reads then crashed the game.
        -- Survival's teardown flag is levelGoing; every job waits it out)
        if levelGoing and levelGoing() then
            if not PLUGINS.wentGoing then                  -- (once, the first tick of it: SVP.going's jobs, no game object)
                PLUGINS.wentGoing = true
                for _, e in ipairs(PLUGINS.going) do if not e.p.off then e.fn(now) end end
                for _, p in ipairs(PLUGINS.loaded) do bgmBack(p, "the level is going") end
            end
            return
        end
        PLUGINS.wentGoing = false
        for _, e in ipairs(PLUGINS.every) do
            if not e.p.off then
                local t0 = os.clock()
                e.fn(now)
                perf(e.p, "every", (os.clock() - t0) * 1000)
            end
        end
    end
    -- co-op's add-on channel (host -> joiners): API 2.1. Stubs until then; an add-on can test for it
    SVP.net = { send = function() return false end, on = function() return false end, ready = false }
    function SVP.send() return false end                -- (API 1's name for it)

    -- An add-on's native mod can give the API what Survival's runtime hasn't got, by name:
    --   SVP.provide("hurtPlayer", fn): fn(playerAddress, -healthPoints, causerAddress) -> 1 = dealt through the
    --   game's own health path (the player's ModifyHealthInternal), so a lethal hit is the game's own death.
    -- Survival's own runtime function wins when it has one (SV_HurtPlayer). The first provider of a name keeps it.
    PLUGINS.providers = {}
    local PROVIDES = { hurtPlayer = "SV_HurtPlayer" }
    function SVP.provide(name, fn)
        local p = PLUGINS.current or PLUGINS.running
        if not (p and PROVIDES[name] and type(fn) == "function") then return false end
        if PLUGINS.providers[name] then return false, "already given by " .. tostring(PLUGINS.providers[name].p.name) end
        PLUGINS.providers[name] = { p = p, fn = guard(p, "provide " .. name, fn) }
        plog(p, "gives " .. name)
        return true
    end
    local function provider(name)
        local own = _G[PROVIDES[name]]
        if type(own) == "function" then return own end
        local e = PLUGINS.providers[name]
        return e and not e.p.off and e.fn or nil
    end

    -- whether o is still the engine's live object (the GUObjectArray check): ask it, not IsValid, before using anything
    -- kept between ticks (an actor, an asset, a component). IsValid can pass on freed memory
    function SVP.liveObj(o) return o ~= nil and liveObj(o) == true end

    -- Survival's music off (false) for an add-on's own track, or back (true). Given back by the API in any case when
    -- the add-on's round ends, its run ends, the level goes or the add-on is switched off.
    function SVP.bgm(on)
        local p = PLUGINS.current or PLUGINS.running
        if not p then return false end
        if on then bgmBack(p, "the add-on's call"); return true end
        if p.bgmMuted then return true end
        if type(SV_PlayBGM) ~= "function" or SVP.levelGoing() then return false end
        local ok, r = pcall(SV_PlayBGM, "AKE_System_BGM_Mute_On")
        if ok and type(r) == "number" and r > 0 then p.bgmMuted = true; return true end
        return false
    end

    -- Sound, effects and the player's plane (version 1, second part). Each is Survival's own way of doing it
    -- (sv_escort_laser.lua's sound / fx, sv_decoy.lua's sure kill), so a plugin needs no UE calls of its own for them.
    -- (an asset a plugin plays: found ones kept while valid, a miss kept 30 s, so a sound missing from the pack isn't
    -- looked up and loaded again on every play: 15-46 ms each)
    local function fullPath(path)
        return path:find(".", 1, true) and path or (path .. "." .. path:match("[^/]+$"))
    end
    local plWhy = "?"                                    -- (how the last plAsset got its object: the p2dMs line)
    local function plAsset(path)
        if type(path) ~= "string" then return nil end
        local full = fullPath(path)
        local h = assetHit[full]
        if h and kept(h) then plWhy = "kept"; return h end
        local m = assetMiss[full]
        if m and os.clock() - m < 30 then plWhy = "miss kept"; return nil end
        -- (LoadObject takes 14-20 ms even for a wave already in memory: an asset that's loaded is
        -- found first (StaticFindObject, well under 1 ms), so a plugin can load its assets ahead and play them cheaply)
        local okF, f = pcall(StaticFindObject, full)
        if okF and valid(f) then assetHit[full], assetMiss[full] = f, nil; plWhy = "found"; return f end
        local o = loadObject(full)
        if valid(o) then assetHit[full], assetMiss[full] = o, nil; plWhy = "loaded"; return o end
        assetHit[full], assetMiss[full] = nil, os.clock()
        plWhy = "miss"
        return nil
    end
    local soundWay = nil                            -- (PostEventAtLocation's two signatures: the first that works kept)
    function SVP.sound(path, at)
        if type(at) ~= "table" or SVP.levelGoing() then return false end
        local ev, ak = plAsset(path), StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics")
        if not (ev and valid(ak) and liveObj(survivalPC)) then return false end
        local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
        local tries = {
            function() return ak:PostEventAtLocation(ev, at, rot, survivalPC) end,
            function() return ak:PostEventAtLocation(ev, at, rot, "", survivalPC) end,
        }
        for i = soundWay or 1, soundWay or #tries do
            if pcall(tries[i]) then soundWay = i; return true end
        end
        return false
    end
    -- a Niagara system at `at`: scale (uniform), rot (yaw degrees or a rotator), floats (user floats, e.g. BeamLength);
    -- the component (switch it off with comp:Deactivate()), or nil
    function SVP.fx(path, at, scale, rot, floats)
        if type(at) ~= "table" or SVP.levelGoing() then return nil end
        local lib, sys = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary"), plAsset(path)
        if not (valid(lib) and sys and liveObj(survivalPC)) then return nil end
        local sc = tonumber(scale) or 1
        local r = type(rot) == "table" and rot or { Pitch = 0, Yaw = tonumber(rot) or 0, Roll = 0 }
        local ok, comp = pcall(function()
            local c = lib:SpawnSystemAtLocation(survivalPC, sys, at, r, { X = sc, Y = sc, Z = sc }, true, true, 0, true)
            -- (SpawnSystemAtLocation doesn't apply its rotation: set after, as the ZFA-44's laser does)
            pcall(function() c:K2_SetWorldRotation(r, false, {}, false) end)
            for k, v in pairs(type(floats) == "table" and floats or {}) do
                pcall(function() c:SetVariableFloat(FName("User." .. k), v) end)
                pcall(function() c:SetVariableFloat(FName(k), v) end)
            end
            return c
        end)
        return ok and comp or nil
    end
    -- a sound wave (or cue) heard by you alone, not placed (GameplayStatics.SpawnSound2D): true and its length in s
    -- (SVP.p2dMs: the last play's parts in ms, asset / statics / pc / spawn / duration: a line can cost 16-37 ms to
    -- start even when the wave is in memory; which part)
    local gsObj
    -- (radio lines stuttered: every line start spent 20-38 ms in plAsset, loaded ahead or not: a wave that has been
    -- played holds no reference once its spawned component is gone, so the next
    -- play finds / loads it again. A HELD audio component (CreateSound2D, not playing, never auto-destroyed) keeps the
    -- wave alive and plays it with no spawn: SVP.hold2d(path) makes one; play2d uses it when it isn't already playing.
    -- Held components belong to the level: gone with it, made again on the next hold2d)
    local held2d = {}
    function SVP.hold2d(path)
        if type(path) ~= "string" then return nil, "a path" end
        if SVP.levelGoing() then return nil, "the level is going away" end
        local full = fullPath(path)
        local h = held2d[full]
        if h and kept(h) then return h end
        local sw = plAsset(path)
        if not valid(gsObj) then gsObj = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
        if not (sw and valid(gsObj) and liveObj(survivalPC)) then return nil, "not loaded" end
        local ok, comp = pcall(function() return gsObj:CreateSound2D(survivalPC, sw, 1.0, 1.0, 0.0, nil, false, false) end)
        if not (ok and valid(comp)) then return nil, "CreateSound2D: " .. tostring(comp) end
        held2d[full] = comp
        return comp
    end
    function SVP.play2d(path, volume)
        if SVP.levelGoing() then return false end
        local t0 = os.clock()
        local h = type(path) == "string" and held2d[fullPath(path)]
        if h and kept(h) then
            local okP, playing = pcall(function() return h:IsPlaying() end)
            if okP and not playing then
                pcall(function() h:SetVolumeMultiplier(tonumber(volume) or 1.0) end)
                local okPl = pcall(function() h:Play(0.0) end)
                if okPl then
                    local okD, d = pcall(function() return h.Sound.Duration end)
                    SVP.p2dMs = string.format("held %.0f", (os.clock() - t0) * 1000)
                    return true, (okD and type(d) == "number" and d > 0) and d or nil, h
                end
            end
        end
        local sw = plAsset(path)
        local t1 = os.clock()
        if not valid(gsObj) then gsObj = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
        local gs = gsObj
        local t2 = os.clock()
        local pcOk = liveObj(survivalPC)
        local t3 = os.clock()
        if not (sw and valid(gs) and pcOk) then return false end
        local ok, comp = pcall(function() return gs:SpawnSound2D(survivalPC, sw, tonumber(volume) or 1.0, 1.0, 0.0, nil, false, true) end)
        local t4 = os.clock()
        local okD, d = pcall(function() return sw.Duration end)
        SVP.p2dMs = string.format("asset %.0f (%s) / statics %.0f / pc %.0f / spawn %.0f / duration %.0f", (t1 - t0) * 1000,
            plWhy, (t2 - t1) * 1000, (t3 - t2) * 1000, (t4 - t3) * 1000, (os.clock() - t4) * 1000)
        -- (the audio component third: comp:Stop() cuts the sound short)
        return ok, (okD and type(d) == "number" and d > 0) and d or nil, ok and comp or nil
    end
    -- your plane: { a = the pawn, X, Y, Z (cm), VX, VY, VZ (cm/s), health (HealthInternal: health x 10), down }
    local function myPawn()
        local pawn
        pcall(function() pawn = survivalPC and valid(survivalPC) and survivalPC.Pawn end)
        if pawn and valid(pawn) then return pawn end
        return nil
    end
    function SVP.playerPlane()
        local p = myPawn()
        if not p then return nil end
        local okL, l = pcall(function() return p:K2_GetActorLocation() end)
        if not (okL and l) then return nil end
        local okV, v = pcall(function() return p:GetVelocity() end)
        return { a = p, X = l.X, Y = l.Y, Z = l.Z, VX = okV and v.X or 0, VY = okV and v.Y or 0, VZ = okV and v.Z or 0,
                 health = healthOf(p), down = (DOWN and DOWN.me and DOWN.me()) == true }
    end
    -- you destroyed now, the stock way (Mission 26's LiveDestroyPlayerPlaneExecution, THE DECOY's sure-kill event
    -- RE_SV_DecoyKill in Survival's world data): Survival's own DOWN takes it from there. False when the build has
    -- no such event, you're already down, or the level is going.
    function SVP.killPlayer(why)
        if SVP.levelGoing() or type(SV_Event) ~= "function" then return false end
        if DOWN and DOWN.me and DOWN.me() == true then return false end
        local ok, r = pcall(SV_Event, "RE_SV_DecoyKill")
        plog(PLUGINS.current or PLUGINS.running, "your plane destroyed (" .. tostring(why or "the plugin's") .. "): RE_SV_DecoyKill "
            .. tostring(ok and r or "error"))
        return ok and type(r) == "number" and r >= 0
    end
    -- `n` damage (AC8's unit: MaxHealth units; HealthInternal = health x 10) to an actor, `causer` credited where the
    -- game takes one. An AI object: ModifyHealth. Your plane: ModifyHealth does nothing on it (tools/re/
    -- KILLS_HEALTH_DEATH.md), so its health is written, never to 0: a hit that would kill is SVP.killPlayer.
    -- true, health before, after, how
    -- SVP.retire(a): the game itself retires one of the plugin's units (its own death, ModifyHealth), so it's freed as a
    -- stock unit is; Survival counts and pays nothing for it (no kill, no credits, no stats: PLUGINS.retired, the plane
    -- sweep skips it). For an add-on's units at its round's end: a unit the game still has registered can't be spawned
    -- again by name (hard rule 16), and taking it off the phase by hand crashed the game later
    PLUGINS.retired = {}
    function SVP.retire(a)
        if SVP.levelGoing() or not valid(a) then return false end
        local k = addrOf(a)
        if k then PLUGINS.retired[k] = true end
        local okM, mx = pcall(function() return a.MaxHealth end)
        local n = (okM and type(mx) == "number" and mx > 0) and mx * 20 or 100000
        return SVP.hurt and SVP.hurt(a, n, nil) or false
    end
    function SVP.hurt(a, n, causer)
        n = tonumber(n) or 0
        if not liveAddr(a) or n <= 0 then return false end
        local before = healthOf(a)
        if before and before <= 0 then return false, before, before, "dead (left alone)" end
        local isMe = a == myPawn() or (addrOf and myPawn() and addrOf(a) == addrOf(myPawn()))
        if not isMe then
            -- (a plugin's hit with NO causer is no one's: if it kills, Survival counts and pays nothing for it, as
            -- SVP.retire: e.g. an add-on's weapon hitting enemy aircraft)
            local k = (causer == nil) and addrOf and addrOf(a)
            if k and before and before - n <= 0 then PLUGINS.retired[k] = true end
            local ok = pcall(function() a:ModifyHealth(-n, causer, true) end)
            local after = healthOf(a)
            if k and after and after <= 0 then PLUGINS.retired[k] = true end
            return ok, before, after, "ModifyHealth"
        end
        if not before then return false end
        if DOWN and DOWN.me and DOWN.me() == true then return false, before, before, "down" end
        -- the game's own health path when a runtime gives it (hurtPlayer: the player's ModifyHealthInternal, so a
        -- lethal hit is the game's own death); else the health is written and a lethal hit is the stock sure kill.
        -- hurtPlayer takes HEALTH points (MaxHealth units); HealthInternal reads x 10
        local hurt = provider("hurtPlayer")
        if hurt then
            local pa, ca = addrOf and addrOf(a), causer and addrOf and addrOf(causer)
            if pa then
                local okH, rc = pcall(hurt, pa, -n, ca or pa)
                if okH and rc == 1 then return true, before, healthOf(a), "the game's own health path" end
            end
        end
        if before - n * 10 <= 0 then
            if SVP.killPlayer("a hit of " .. n) then return true, before, healthOf(a), "killed" end
        end
        local nv = math.max(10, math.floor(before - n * 10))
        local ok = pcall(function() a.HealthInternal = nv end)
        return ok, before, healthOf(a), "health"
    end

    -- The plugins folder's .lua files: UE4SS's IterateGameDirectories (no directory listing in plain Lua), walked
    -- down to this mod's folder by SCRIPT_DIR's names
    local function pluginFiles()
        local out = {}
        local okD, dirs = pcall(IterateGameDirectories)
        if not (okD and type(dirs) == "table") then return out, "no IterateGameDirectories" end
        local node = nil
        local function child(t, name)
            if type(t) ~= "table" then return nil end
            for k, v in pairs(t) do if type(k) == "string" and k:lower() == name:lower() then return v end end
            return nil
        end
        -- SCRIPT_DIR ends ...\Game\Binaries\Win64\ue4ss\Mods\AC8SurvivalMode\Scripts\ (or without ue4ss\)
        local parts = {}
        for s in SCRIPT_DIR:gmatch("[^/\\]+") do parts[#parts + 1] = s end
        for i = #parts - 1, 1, -1 do                -- (the last Game\Binaries in it: a library folder may be called Game too)
            if parts[i]:lower() == "game" and parts[i + 1]:lower() == "binaries" then
                node = child(dirs, "Game")
                for j = i + 1, #parts - 1 do node = child(node, parts[j]) end
                node = child(node, "plugins")
                break
            end
        end
        if not node then return out, "no plugins folder" end
        for _, f in pairs(type(node.__files) == "table" and node.__files or {}) do
            local okN, name = pcall(function() return f.__name end)
            local okP, path = pcall(function() return f.__absolute_path end)
            if okN and okP and type(name) == "string" and name:lower():match("%.lua$") then
                out[#out + 1] = { name = name, path = tostring(path) }
            end
        end
        table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
        return out
    end

    local function loadOne(file)
        local p = { name = file.name:gsub("%.[Ll][Uu][Aa]$", ""), file = file.name, kinds = {} }
        local f = io.open(file.path, "rb")
        if not f then plog(p, "can't be read: " .. file.path); return end
        local src = f:read("a")
        f:close()
        local chunk, err = load(src, "@" .. file.path, "t")
        if not chunk then plog(p, "doesn't load: " .. tostring(err)); return end
        PLUGINS.current = p
        local ok, e2 = pcall(chunk)
        PLUGINS.current = nil
        if not ok then
            plog(p, "error at load: " .. tostring(e2) .. " (its kinds taken off)")
            for _, k in ipairs(p.kinds) do SPC.kinds[k], PLUGINS.kinds[k], CFG.specials[k] = nil, nil, nil end
            return
        end
        PLUGINS.loaded[#PLUGINS.loaded + 1] = p
        plog(p, string.format("loaded (%s, version %s, %d kinds: %s)", p.file, tostring(p.ver or "?"), #p.kinds,
            table.concat(p.kinds, ", ")))
    end

    -- without IterateGameDirectories (an older UE4SS): plugins\plugins.txt, one file name a line
    local function listedFiles()
        local dir = SCRIPT_DIR .. "..\\plugins\\"
        local f = io.open(dir .. "plugins.txt", "r")
        if not f then return nil end
        local out = {}
        for line in f:lines() do
            local name = line:match("^%s*([^;#]-%.[Ll][Uu][Aa])%s*$")
            if name and not name:find("[/\\]") then out[#out + 1] = { name = name, path = dir .. name } end
        end
        f:close()
        return out
    end

    function PLUGINS.load()
        local files, why = pluginFiles()
        if why then
            local l = listedFiles()
            if l then files, why = l, nil end
        end
        if why then log("plugins: none (" .. why .. ")"); return end
        if #files == 0 then log("plugins: none in plugins\\"); return end
        for _, file in ipairs(files) do
            local ok, err = pcall(loadOne, file)
            if not ok then log("plugins: " .. file.name .. " error " .. tostring(err)) end
        end
    end
end

PLUGINS.load()
