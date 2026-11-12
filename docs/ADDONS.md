# Add-on sorties for AC8 Survival Mode (add-on API 2.0)

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
- `SVP.api` = `{ major = 2, minor = 0 }`. A minor version only adds calls; a major one may change them.
- `def.api = "2.0"`: the lowest version your add-on needs. Survival refuses an add-on it can't serve (a newer major, or a
  newer minor of its own major) and says so in one log line:
  `plugin <name>: not loaded: it needs add-on API 3.0; this Survival has 2.0`. An add-on with no `def.api` is taken
  as an API 1 add-on, and served.
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
| `SVP.players()` | `{ { slot, X, Y, Z } }` |
| `SVP.pad()` / `SVP.runway()` | the spaceport's shuttle pad / Comona Airport's runway, cm |
| `SVP.clock()` / `SVP.round()` / `SVP.run()` | the rounds' clock / the round / a token of the run in progress |
| `SVP.levelGoing()` | the level is being torn down: touch nothing |
| `SVP.callout(text, sub)` / `SVP.say(who, text, secs)` / `SVP.log(msg)` | the round callout / the subtitle strip / Survival's log, your name first |
| `SVP.play2d(path, vol)` / `SVP.hold2d(path)` | a 2D sound for you alone (ok, length, its audio component) / one held ready, played with no lookup |
| `SVP.sound(path, at)` / `SVP.fx(path, at, scale, rot, floats)` | a Wwise event at a spot / a Niagara system (its component) |
| `SVP.bgm(on)` | Survival's music off (`false`) for your own track, or back (`true`). The API gives it back by itself at your round's end, your run's end, the level going, or your add-on switched off |
| `SVP.liveObj(o)` | `o` is still the engine's live object. Ask it before using anything kept between ticks |
| `SVP.provide(name, fn)` | give the API what your native mod has: `"hurtPlayer"` = `fn(playerAddress, -healthPoints, causerAddress)` -> 1 (the player's damage through the game's own health path). Survival's own function wins when it has one |
| `SVP.isHost()` / `SVP.inCoop()` | co-op state |
| `SVP.net` | co-op's add-on channel: API 2.1 (a stub in 2.0: `SVP.net.ready` false) |

## Rules (each one learned from a crash)
- Never call `LoopAsync`, `ExecuteInGameThread`, `ExecuteWithDelay` or `RegisterKeyBind`: they run your Lua off the game
  thread in Survival's one Lua state, which crashes the game. Use `SVP.every`.
- A Lua reference doesn't keep a game object alive. An actor, asset or component you keep between ticks can be freed
  by the game's garbage collection, and UE4SS's `IsValid` can still say yes on freed memory: check `SVP.liveObj(o)`
  first, and look it up again when it says no.
- Touch no game object while `SVP.levelGoing()` is true.
- Native Lua function names (a C++ mod's) are 15 characters or fewer.
- Keep a callback short: a tick over 100 ms three times running is logged; over 2 s in one call switches the add-on off.

## What Survival does to keep itself safe
- Each add-on file loads in a pcall: an error at load takes its kinds off again. A version it can't serve, or a
  missing `requires`, is refused with one line.
- Every callback runs guarded: the first error (or a stall, above) switches the add-on off for the session. Its round
  ends as soon as Survival's checks allow (`busy` false), its targets come off the watch unpaid, Survival's music is
  given back.
- A `check`, `ready` or `spawn` that says no: Survival plays its normal round.
- A run with any add-on loaded isn't ranked on the leaderboard (`LB.edited` lists it).

## Co-op
API 2.0 is single player: an add-on's round never comes in co-op unless the add-on says it can (`def.coop = true`,
API 2.1, with its joiner side). Planned for 2.1: `SVP.net.send(event, ...)` from the host to every joiner on Survival's
channel, `def.remote` (the joiner's start / tick / over and its message handlers), and a check that every player has
the same add-ons and versions before an add-on's round comes.

## Log lines to look for
`plugin <name>: kind <kind> registered (...)`, `plugin <name>: loaded (...)`, `plugin <name>: not loaded: ...`,
`plugin <name>: its round skipped: <why>`, `plugin <name>: <callback> error ...: the add-on is switched off for this
session`, `plugin <name>: Survival's music given back (...)`, `plugins: none (...)`.
