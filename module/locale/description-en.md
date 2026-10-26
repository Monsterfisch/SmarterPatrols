# Smarter Patrols

**Author**: Monsterfish
**Version**: 1.0.0

Makes the AI's patrol and siege defence troops actually use all their groups during an
attack. Both parts can be switched off in the settings.

## Patrol troops

In the normal game only the first patrol group ever gets orders. The second one just stands at
the rally point for the whole attack.

With this module every patrol group gets its own route around the castle you are attacking:

- **Group 1** circles the castle one way.
- **Group 2** circles the other way.
- **Group 3** runs back and forth along the front of the castle (the side facing the attacker).
- **Groups 4, 5, 6** do the same as 1, 2, 3, but a quarter circle behind them. Then 7, 8, 9
  are behind those, and so on.

They walk at a set walking distance outside the castle (12 tiles by default, same as the
game's own patrol), so they go around walls and moats rather than into them. A group that runs
into enemies fights first and moves on after.

## Siege defence troops

These troops already walk from one siege engine to the next. But both groups walk the same
route at the same time, so they look like one group.

With this module:

- Each group starts at a different siege engine, and every second group walks the other way,
  so they spread out over all the engines.
- Groups that are mostly melee troops walk a few tiles in front of the engines (towards the
  castle), so the defenders shoot at them instead of at the engines. Archers stay at the
  engines.
- When the wall assault starts, every group attacks, as in the normal game.

## More groups

The game can only handle 2 patrol groups and 2 siege defence groups. If an AI file asks for
more, the extra units end up in the wrong troops (moat diggers or the main army). This module
lets you have up to 12 of each. The number comes from the AI's own file unless you set one in
the settings (siege defence: 4 by default). A troop is only split as far as each group still
gets at least 4 units (you can change that).

The extra groups exist only while the army is out attacking. When the castle is breached, the
lord dies or the AI retreats, they join back up with the rest and do what the AI tells them.

## Good to know

- Only AI attacks are affected; your own troops are left alone.
- Works with Lord Hunt.
- Nothing extra is written to save games.
