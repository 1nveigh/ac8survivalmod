# Target practice: an example add-on sortie

The smallest useful add-on on Survival's add-on API 2.0 (`docs/ADDONS.md`): three stock trucks parked around the
spaceport's shuttle pad, 500 credits each, the round over when all three are down or after 120 s. Stock assets only,
so it has no container of its own.

## Try it
1. Copy `plugins/target_practice.lua` into `Mods/AC8SurvivalMode/plugins/`.
2. In `Mods/AC8SurvivalMode/config/survival.ini`, add `practice` to the specials' `rotation` line (it doesn't join the
   rotation by itself), and if you like:
   ```
   [specials.practice]
   from_round = 2
   trucks = 3
   pay = 500
   time_s = 120
   ```
3. Play Survival. The log shows `plugin Target practice: kind practice registered (...)` at the start, and
   `plugin Target practice: 3 trucks on the pad` when its round comes.

## What it shows
- `def.api`: the API version it needs. `def.check`: its own readiness (here: the truck class loads).
- `spawn` -> `SVP.spawn` + `SVP.target` (paid kills), `SVP.callout`.
- `busy` holding the round until it's decided; `tick` deciding it (all down, or the time limit).
- `over` / `abort` taking the trucks off: `SVP.untarget` first (so nothing is paid for them), `SVP.liveObj` before
  touching a kept actor, nothing touched while the level goes.

Its offline test: `sh tools/checks/plugins_test.sh`.
