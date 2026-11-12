# Add-on sorties for AC8 Survival Mode (add-on API 2.1)

An add-on adds a special round of its own to Survival: its units, its targets and pay, its callouts, radio and music.
It runs inside Survival's Lua state, through the API Survival gives it (`SVP`). Survival needs nothing from the add-on
to run: with no add-ons installed, or with one that can't run, Survival plays as before.

The internals (the loader, the guard, the targets' watch) are in `docs/re/PLUGINS.md`. A complete small add-on is in
`examples/addons/target_practice/`.

## Install layout
```
Mods/AC8SurvivalMode/plugins/<your_addon>.lua     the add-on's Lua: Survival runs every plugins/*.lua, in name order
Mods/AC8SurvivalMode/plugins/<your_addon>/         its data files, if it has any (read them with io.open)
Mods/<your C++ mod>/                               its native mod, if it needs one (optional)
<your IoStore container>                           its assets (load them with SVP.load); never in Survival's own
```
Survival's zip ships an empty `plugins/` folder. Its settings come from `[specials.<kind>]` in Survival's
`config/survival.ini`, over the defaults the add-on gives.

## The smallest add-on
```lua
SVP.register("practice", {                    -- the kind: letters, digits, _, 15 at most
    name = "Target practice", ver = "1.0",
    api = "2.0",                               -- the lowest add-on API this add-on needs
    cfg = { from_round = 2 },                  -- its settings' defaults: CFG.specials.practice
    kind = {
        sub = function() return "TARGET PRACTICE" end,
        ready = function(round, forced) return forced or round >= CFG.specials.practice.from_round end,
        spawn = function(now) --[[ spawn its units, SVP.target them ]] return true end,
        busy = function() return false end,     -- true holds the round
    },
})
```

## Versions
- `SVP.api` = `{ major = 2, minor = 1 }`. A minor version only adds calls; a major one may change them (2.1 added
  co-op, below; a 2.0 add-on is served unchanged).
- `def.api = "2.0"`: the lowest version your add-on needs. Survival refuses an add-on it can't serve (a newer major, or a
  newer minor of its own major) and says so in one log line:
  `plugin <name>: not loaded: it needs add-on API 3.0; this Survival has 2.0`. An add-on with no `def.api` is taken
  as an API 1 add-on, and served.
- For a native mod, before Lua runs: line 2 of `Mods/AC8SurvivalMode/Scripts/sv_plugins.lua` is
  `-- add-on API <major>.<minor>` (no such line, or no file: no add-on framework).
- `def.requires = { "SV_Something", ... }`: native functions it needs (Survival's runtime's, or its own native mod's).
  One missing: not loaded, one line.

## A round's life
Every callback is optional except `spawn`. Survival calls them on its game thread.
| callback | when, and what to return |
|---|---|
| `def.check()` | before every `ready`: the add-on's own readiness (its native mod up, its data found). `true`, or `false, why`: its round is skipped (Survival picks another special or plays a normal round), said once a run |
| `ready(round, forced)` | may the round come now (`forced`: a test key) |
| `spawn(now)` | the round starts: spawn, target, call out. `true` = started; `false` = Survival plays a normal round instead |
| `tick(now, s)` | every tick of the round |
| `busy(s)` | `true` holds the round open (its targets aren't done) |
| `over(now, result)` | the round is over: take your actors off |
| `abort(why)` | the run ended under the round (every player down, the level left). When `why` is `"the level is going"`, touch no game object |
| `sub()`, `alone`, `aircraft`, `budget(b)`, `row`, `hold` | as Survival's own specials (`alone`: no Survival fighters with it) |
| `def.rotation = true` | joins the specials' rotation, unless the player wrote their own `rotation` line |

Survival's moments, for any add-on: `SVP.on(event, fn)` with `"runStart"`, `"roundStart"` (round),
`"roundEnd"` (round), `"runEnd"`, `"levelGoing"`. `runEnd` and `levelGoing` can come while the level is torn down:
touch no game object in them. `SVP.every(fn)`: `fn(now)` every Survival tick (250 ms), also between rounds.

## The API
| call | what |
|---|---|
| `SVP.target(actor, opts)` | an id; the actor is watched each tick of the round: gone or no health = down, paid `opts.pay` (x the round's tier, unless `opts.flat`), a ground kill (`opts.class = "air"`: air), `opts.onDown(id, why)` |
| `SVP.untarget(id)` / `SVP.kill(id, why)` / `SVP.alive(id)` | off the watch, unpaid / down now, paid / still up |
| `SVP.pay(n, why)` | credits |
| `SVP.load(path)` | an object of your container (Survival's own loader: UE4SS `LoadAsset` can't load a mod's new packages) |
| `SVP.spawn(cls, at, yaw)` / `SVP.move(a, at, yaw)` / `SVP.despawn(a)` | an actor (a class or its path) at `at` (cm), turned `yaw` degrees / teleported / destroyed |
| `SVP.retire(a)` | the game kills your unit through its damage path; nothing counted or paid |
| `SVP.hurt(a, n, causer)` | `n` damage (MaxHealth units). `causer` nil = no one's kill: counted and paid to no one |
| `SVP.killPlayer(why)` | the player's plane destroyed (Survival's own sure kill) |
| `SVP.playerPlane()` | `{ a, X, Y, Z, VX, VY, VZ, health, down }` or nil |
| `SVP.players()` | `{ { slot, X, Y, Z } }`: you; on a co-op host every player (2.1) |
| `SVP.pad()` / `SVP.runway()` | the spaceport's shuttle pad / Comona Airport's runway, cm |
| `SVP.clock()` / `SVP.round()` / `SVP.run()` | the rounds' clock / the round / a token of the run in progress |
| `SVP.levelGoing()` | the level is being torn down: touch nothing |
| `SVP.callout(text, sub)` / `SVP.say(who, text, secs)` / `SVP.log(msg)` | the round callout / the subtitle strip / Survival's log, your name first |
| `SVP.play2d(path, vol)` / `SVP.hold2d(path)` | a 2D sound for you alone (ok, length, its audio component) / one held ready, played with no lookup |
| `SVP.sound(path, at)` / `SVP.fx(path, at, scale, rot, floats)` | a Wwise event at a spot / a Niagara system (its component) |
| `SVP.bgm(on)` | Survival's music off (`false`) for your own track, or back (`true`). The API gives it back by itself at your round's end, your run's end, the level going, or your add-on switched off |
| `SVP.hud(on, why)` | Survival's own HUD (its panel, the callout banner, the subtitle strip) off (`false`) for your cutscene, or back (`true`); `why` goes in the log. Callouts and subtitle lines said meanwhile wait and show after, in order. The API gives it back by itself at your round's end, your run's end, the level going, your add-on switched off, or 60 s after you hid it. The game's own HUD isn't touched (a stock cutscene hides it itself) |
| `SVP.liveObj(o)` | `o` is still the engine's live object. Ask it before using anything kept between ticks |
| `SVP.provide(name, fn)` | give the API what your native mod has: `"hurtPlayer"` = `fn(playerAddress, -healthPoints, causerAddress)` -> 1 (the player's damage through the game's own health path). Survival's own function wins when it has one |
| `SVP.isHost()` / `SVP.inCoop()` | not a co-op joiner (solo is a host) / co-op open |
| `SVP.net` | co-op's add-on channel (2.1; `SVP.net.ready` true): below |

## Rules (each one learned from a crash)
- Never call `LoopAsync`, `ExecuteInGameThread`, `ExecuteWithDelay` or `RegisterKeyBind`: they run your Lua off the game
  thread in Survival's one Lua state, which crashes the game. Use `SVP.every`.
- A Lua reference doesn't keep a game object alive. An actor, asset or component you keep between ticks can be freed
  by the game's garbage collection, and UE4SS's `IsValid` can still say yes on freed memory. `SVP.liveObj(o)` says
  whether the address is a live object, but not whether it's still YOURS: the allocator can put a new object where a
  freed one was. So keep the path, not the asset: `SVP.load(path)` / `SVP.play2d(path)` each time (they're cached and
  check both, cheaply). For an actor you spawned, check `SVP.liveObj` and that it's the one you made (its full name).
- Touch no game object while `SVP.levelGoing()` is true.
- Native Lua function names (a C++ mod's) are 15 characters or fewer.
- Keep a callback short: a tick over 100 ms three times running is logged; a call over 2 s is logged as a hitch, and
  three of them within 60 s switch the add-on off (a stall).

## What Survival does to keep itself safe
- Each add-on file loads in a pcall: an error at load takes its kinds off again. A version it can't serve, or a
  missing `requires`, is refused with one line.
- Every callback runs guarded: the first error (or a stall: three calls over 2 s within 60 s) switches the add-on off for the session. Its round
  ends as soon as Survival's checks allow (`busy` false), its targets come off the watch unpaid, Survival's music is
  given back.
- A `check`, `ready` or `spawn` that says no: Survival plays its normal round.
- A run with any add-on loaded isn't ranked on the leaderboard (`LB.edited` lists it).

## Co-op (API 2.1)
Survival's co-op is the host's: its rounds, kills and pay; the joiners' games mirror them. An add-on's round follows
the same rule.
- Opt in with both `def.coop = true` and `def.remote` (the joiner's side). Without them the kind is single player, as
  in 2.0: its round never comes while co-op is open (one log line a run).
- The round comes only when every player in the room has the same add-on kind at the same `def.ver`. Each game with
  API 2.1 tells the host its co-op kinds as it links; a player who hasn't (no add-on, an older Survival, a stock one)
  keeps the round away, and the host's log says who and why:
  `plugin <name>: its round skipped in co-op: player 3 (NAME) has version 0.4, this game 0.5`.
- The host runs the kind's callbacks as in solo. When its round starts, ends or is aborted, each joiner that has it
  is told, and its `def.remote` runs there:
  - `start(now, round)`, `tick(now)` (every tick while the host's round is on), `over(now, result)`, `abort(why)`.
  - The joiner's round is also aborted if the host's goes quiet (15 s with no word), its own run or level ends, or the
    room changes hands. Music and HUD taken there (`SVP.bgm`, `SVP.hud`) are given back as in solo.
- `def.joined(slot, has)` (optional, the host): a player came during your round; `has` = they have it (their round
  has been started). Send them what they need to catch up with `SVP.net.sendTo`.
- Host only (refused on a joiner, one line): `SVP.target`, `SVP.untarget`'s targets, `SVP.kill`, `SVP.pay`. Pay on
  the host goes through Survival's co-op pay, so every player gets their share as for Survival's own specials.
  Everything else is local to each game: spawns and despawns, sounds, effects, callouts, music, `SVP.playerPlane`, and
  `SVP.hurt` / `SVP.retire` of that game's own actors (a joiner's local copies of your units).
- `SVP.net` (your add-on's channel, on Survival's own co-op link):
  - `SVP.net.send(event, ...)`: the host's goes to every joiner, a joiner's to the host. `SVP.net.sendTo(slot, event,
    ...)`: the host to one player. Fields: numbers, booleans (as "1" / "0"), strings of 200 bytes at most; `|` becomes
    `/`. A message is 400 bytes at most, 20 a second for each add-on; over: refused (false and why), never cut short.
  - `SVP.net.on(event, fn)`: `fn(fromSlot, ...)`, its fields as strings. A joiner hears only the host. Guarded as
    every callback.
  - `SVP.net.peers()`: `{ { slot, name, same } }`, the other players and whether each has your add-on's kinds at your
    version (a joiner sees the host). `SVP.net.slot()`: this game's slot.
- Damage to a joiner: the host decides it (it has every player's plane, `SVP.players`) and sends it; the joiner hurts
  its own plane (`SVP.hurt(SVP.playerPlane().a, n)`), so each player's death stays their game's own.
- A friend's game without the API drops the add-on's messages (Survival's dispatch ignores a tag it doesn't know) and
  plays plain Survival; the host's add-on rounds stay away while they're in the room.

## Log lines to look for
`plugin <name>: kind <kind> registered (...)`, `plugin <name>: loaded (...)`, `plugin <name>: not loaded: ...`,
`plugin <name>: its round skipped: <why>`, `plugin <name>: its round skipped in co-op: <why>`,
`plugins: co-op: player N (NAME) has add-on API 2.1, co-op add-ons: ...`, `plugins: co-op: the host has add-on API ...`,
`plugin <name>: the host's <kind> round <n> here`, `plugin <name>: <callback> error ...: the add-on is switched off for this
session`, `plugin <name>: Survival's music given back (...)`, `plugins: none (...)`.
