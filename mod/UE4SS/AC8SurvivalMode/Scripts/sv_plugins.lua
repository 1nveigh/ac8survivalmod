-- sv_plugins.lua: other mods' special rounds (plugins), the API they're given (SVP) and their loader.
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
--   SVP.spawn(cls, at, yaw)     an actor of class `cls` (a class or its path, "/Game/Mods/<its own>/...C") at `at`
--                               (X Y Z cm), turned `yaw` degrees; the actor, or nil and why. Survival's own way
--                               (GameplayStatics' deferred spawn, as its effects': sv_anomalies.lua SPC.V.billboard)
--   SVP.move(a, at, yaw)        moves (teleports) a plugin's actor; SVP.despawn(a) destroys it
--   SVP.players()               { { slot, X, Y, Z } }: you (co-op's other players from version 2)
--   SVP.pad()                   the Comona spaceport's shuttle pad (Mission 22's AA_Obj_01_Ground0_Shuttle_0), cm
--   SVP.runway()                Comona Airport's runway, the spawn anchor (AIRFIELD), cm
--   SVP.clock()                 the rounds' clock (D.now: game time, stops while paused)
--   SVP.round()                 the round number
--   SVP.levelGoing()            the level is going away (sv_core.lua levelGoing): touch no object then
--   SVP.callout(text, sub)      the round callout (hudCallout); SVP.say(who, text, secs) the subtitle strip (SUB.say)
--   SVP.log(msg)                Survival's log, the plugin's name first
--   SVP.isHost(), SVP.inCoop()  version 1: true / false (a plugin round never comes in co-op yet)
--   SVP.every(fn)               fn(now) on the game thread from Survival's own tick (every 250 ms, main menu too;
--                               `now` = os.clock()). A plugin must never use LoopAsync, ExecuteInGameThread,
--                               ExecuteWithDelay or RegisterKeyBind itself: they run its Lua off the game thread in
--                               Survival's one Lua state, which crashes the game (HISTORY 0.73.82; our own test of
--                               2026-11-07: a plugin's LoopAsync + ExecuteInGameThread aborted the game at launch)
--   SVP.send, SVP.on            co-op's message channel: version 2 (stubs now: send returns false)
-- A plugin's callbacks run in a pcall: its first error is logged once and the plugin is switched off (its round, if
-- one is on, ends as soon as Survival's checks allow: busy false, its targets taken off the watch).
-- A run with any plugin loaded isn't ranked (sv_leaderboard.lua LB.edited lists it), as with survival_config.lua.

PLUGINS = { loaded = {}, kinds = {}, targets = {}, nextId = 0 }

do
    local API_VERSION = 1
    -- Mission 22's shuttle (AA_Obj_01_Ground0_Shuttle_0), x / y / z cm: tools/re/SPECIAL_ROUNDS.md "The shuttle"
    local SHUTTLE_PAD = { X = -1324937.0, Y = 59740.0, Z = 6343.0 }
    local NAME_MAX = 15

    local function plog(p, msg) log("plugin " .. tostring(p and p.name or "?") .. ": " .. tostring(msg)) end

    -- a plugin's callback, guarded: its first error switches the plugin off
    local function guard(p, what, fn, fallback)
        if type(fn) ~= "function" then return fn end
        return function(...)
            if p.off then return fallback end
            local prev = PLUGINS.running
            PLUGINS.running = p                     -- (SVP.target from inside a callback: the target is this plugin's)
            local res = table.pack(pcall(fn, ...))
            PLUGINS.running = prev
            if res[1] then return table.unpack(res, 2, res.n) end
            p.off = true
            plog(p, what .. " error " .. tostring(res[2]) .. ": the plugin is switched off for this session")
            crumb("plugin " .. tostring(p.name) .. " off: " .. what)
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
    local function sweep(p)
        for id, t in pairs(PLUGINS.targets) do
            if t.p == p then
                if p.off then PLUGINS.targets[id] = nil
                elseif not liveAddr(t.actor) then down(id, t, "gone")
                else
                    local h = healthOf(t.actor)
                    if h and h <= 0 then down(id, t, "no health") end
                end
            end
        end
    end

    -- the SPC.kinds entry Survival runs for a plugin's kind: every callback guarded; tick also watches its targets;
    -- busy is false once the plugin is off, so its round can end
    local function kindEntry(p, k)
        local e = {}
        for name, v in pairs(k) do e[name] = guard(p, name, v, nil) end
        local tick, busy, ready, spawn = e.tick, e.busy, e.ready, e.spawn
        e.tick = function(now, s)
            if not (levelGoing and levelGoing()) then sweep(p) end
            if tick then return tick(now, s) end
        end
        e.busy = function(s) if p.off then return false end return busy and busy(s) or false end
        e.ready = function(round, forced)
            if p.off then return false end
            if COOP and COOP.open and p.coop ~= true then return false end      -- (version 1: solo only)
            if ready then return ready(round, forced) == true end
            return true
        end
        e.spawn = function(now)
            if p.off then return false end
            return spawn and spawn(now) == true or false
        end
        return e
    end

    SVP = {}
    SVP.version = API_VERSION

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
        p.ver, p.coop = tostring(def.ver or "?"):sub(1, 20), false
        local c = {}
        for k, v in pairs(type(def.cfg) == "table" and def.cfg or {}) do c[k] = v end
        if c.enabled == nil then c.enabled = true end
        local n = iniOver(kind, c)
        CFG.specials[kind] = c
        SPC.kinds[kind] = kindEntry(p, def.kind)
        PLUGINS.kinds[kind] = p
        p.kinds[#p.kinds + 1] = kind
        -- the rotation: the plugin's kind joins it unless the player wrote a rotation of their own (survival.ini's
        -- `rotation` line), which is theirs to change: "excalibur" in it brings the kind, leaving it out keeps it away
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
    function SVP.load(path)
        if type(path) ~= "string" then return nil, "a path" end
        return loadObject(path)
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
    -- (sv_main.lua's tick job, on the game thread, each tick's second half)
    function PLUGINS.tick()
        local now = os.clock()
        for _, e in ipairs(PLUGINS.every) do if not e.p.off then e.fn(now) end end
    end
    function SVP.send() return false end
    function SVP.on() return false end

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
