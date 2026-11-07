# Plugins: other mods' special rounds (sv_plugins.lua, API version 1)

UE4SS gives every Lua mod its own Lua state, so another mod can't reach Survival's SPC.kinds from its own main.lua.
A plugin is a Lua file the other mod installs into `AC8SurvivalMode/plugins/` (Survival's zip has no such folder; its
assets stay in the other mod's own container, never in Survival). Survival runs each `plugins/*.lua`, in name order,
in its own Lua state after every part has loaded (sv_plugins.lua is the last entry of main.lua's MODULES).

## Loading
- Found with UE4SS's `IterateGameDirectories()`, walked down to this mod's folder by SCRIPT_DIR's names; without it,
  `plugins/plugins.txt` lists the files (one name a line).
- Each file is loaded and run in a pcall. An error at load: logged, the kinds it registered taken off again.
- While a file runs, `SVP` is there; it registers its kinds with `SVP.register`.

## SVP (every name 15 characters or fewer, hard rule 25's limit kept for the Lua side too)
| call | what |
|---|---|
| `SVP.version` | 1 |
| `SVP.register(kind, def)` | `true` or `false, why`. `kind`: letters, digits, `_`, at most 15, not taken. `def.kind`: the SPC.kinds entry (`spawn` needed; `sub`, `alone`, `aircraft`, `budget`, `ready`, `tick`, `busy`, `over`, `row`, `hold`, as Survival's own kinds). `def.cfg`: its settings' defaults, becomes `CFG.specials[kind]` with `[specials.<kind>]` from survival.ini read over it (each value takes its default's type; `enabled = false` switches it off). `def.rotation = true`: joins the rotation, unless the player wrote their own `rotation` (then it's theirs to add). `def.name`, `def.ver`: the log and the leaderboard. |
| `SVP.target(actor, opts)` | an id: the actor is watched on every tick of the plugin's round; gone or no health = down: `opts.pay` x the round's tier (as the Spaceport's ships; `opts.flat` = as given), a ground stat (`opts.class = "air"`: air), `opts.onDown(id, why)`. |
| `SVP.untarget(id)` / `SVP.kill(id, why)` / `SVP.alive(id)` | off the watch (no pay) / down now, paid / still up |
| `SVP.pay(n, why)` | zollars |
| `SVP.load(path)` | an object of the plugin's container (`loadObject`, hard rule 9) |
| `SVP.spawn(cls, at, yaw)` | an actor of a class (or its path) at `at` (cm), `yaw` deg; Survival's deferred spawn |
| `SVP.move(a, at, yaw)` / `SVP.despawn(a)` | teleport / destroy |
| `SVP.players()` | `{ {slot, X, Y, Z} }` (you; co-op's players from version 2) |
| `SVP.pad()` / `SVP.runway()` | Mission 22's shuttle pad / Comona Airport's runway (AIRFIELD), cm |
| `SVP.clock()` / `SVP.round()` | the rounds' clock (D.now) / the round |
| `SVP.levelGoing()` | the level is going away: touch nothing |
| `SVP.callout(text, sub)` / `SVP.say(who, text, secs)` / `SVP.log(msg)` | round callout / subtitle / log |
| `SVP.isHost()` / `SVP.inCoop()` | version 1: solo only |
| `SVP.send` / `SVP.on` | version 2 (co-op's channel, host-authoritative kills); stubs now |

## Safety
- Every callback of a plugin runs in a pcall: its first error is logged and switches the plugin off for the session
  (busy false, ready false, its targets off the watch), so its round ends as soon as Survival's checks allow.
- Version 1: a plugin's kind never comes in co-op (`ready` false while COOP is open). Version 2 adds the channel, the
  joiners' side (`def.remote`) and the co-op version check (every player the same plugins and versions).
- A run with any plugin loaded isn't ranked (LB.edited: "plugin <name>").

## Log lines
`plugin <name>: kind <kind> registered (...)`, `plugin <name>: loaded (...)`, `plugin <name>: target <id> (<label>)
down (<why>; +<pay>)`, `plugin <name>: <callback> error ...: the plugin is switched off for this session`,
`plugins: none (...)`.
