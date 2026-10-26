# Smarter Patrols

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme. It makes the AI's attack
patrol and siege defence troops use all their groups: every patrol group gets its own route
around the castle, siege defence groups spread out over the siege engines (melee in front to
draw fire), and both can have up to 12 groups instead of the game's 2.

What the module does, in plain English, is in `module/locale/description-en.md`.

## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - this is the source of truth, edited in place |
| `tools/publish.py` | copies `module/` into the game's module folder under a new version |

## Working on it

1. Edit under `module/`.
2. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/smarter-patrols-<version>`. Do this with the game closed.
3. In the UCP GUI press F5, then apply.
4. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.

## How it works

* **Three replaced AI functions** (a `jmp` at each start into a stub that runs lua):
  `sendAITribe_0xf_toAttackPatrol` (attack states 3-5; the game only ever orders patrol slot 15),
  `moveAttackingUnitsToNextRallyPoint` (states 3-4; siege defence slots 190/191 walk between the
  team's built catapults, trebuchets and fire ballistas) and `aiCommandWallAssaultTribes` (state 5;
  `assignAttackTargetsForTribe(tribe, 0x3F2)` for both siege defence slots).
* **The 2-group cap.** `addUnitToSmallestBehaviourTypeTribe` puts a recruit in slots
  `start .. start + GroupsCount - 1`: a 3rd patrol group would be slot 17 (moat diggers), a 3rd siege
  defence group slot 192 (main army). The module makes both counts read 1 and splits the troop itself
  once the army has set out, into troops the AI never registers. It gives those every order the AI
  would, and puts them back into the AI's troop (`addUnitToItsTribe`) as soon as the attack state
  leaves 3-5, re-giving the retreat order on a retreat. That check runs from the call right after
  `updateAIPlayerState` in `updateAIBehaviour`, chained like lord-hunt's hook on the same call.
* **Patrol routes** use the AI's distance-from-the-attacked-castle layer (1105, the one the game's own
  patrol walks along at 12): 16 directions from the attacked keep, each the first tile out on the ring.
  Group g: (g-1)%3 = 0 clockwise, 1 the other way, 2 back and forth across the 5 points facing the
  attacker's keep; every later round of three a quarter circle (4 points) behind.
* Nothing is saved. After a load, patrol / siege defence units in unregistered troops (other than
  lord-hunt's) go back to the AI.
