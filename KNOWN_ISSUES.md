# Known issues

Last Signal is in an early test phase. These problems are known; please only report new ones (with
`UE4SS.log`).

## Stability
- **Rare crashes or freezes** (often while shooting a lot or right after joining). Most causes are fixed, a few
  may remain. If the game hangs ("not responding"), please report the time and send `UE4SS.log`.

## Vehicles
- SurrounDead has no passenger seat, Last Signal adds one. On some vehicles the passenger sits slightly off.
- Other players' vehicles can jitter a little.

## Zombies and NPCs
- Zombies far away from all players can stand still for a moment or jump to a new position.
- Zombie health bars update with a short delay.
- Aiming of other players can look slightly off.

## Weapons and sound
- Suppressors: other players may sometimes hear the unsuppressed shot.
- A weapon dragged from a container directly into a weapon slot can lose the scope view. Unequip and equip it
  again.

## Inventory and items
- Pressing **F** on a backpack lying on the ground can say *"Not enough space"*. Pick it up via the inventory
  instead (drag it into the backpack slot).
- When an admin gives items, the inventory empties for a moment and fills again.
- After drinking, an empty water bottle can blink and be locked in the inventory.

## Death and loot boxes
- The *Last Death* marker can disappear early after respawning.

## Server list
- The ping shows `-` when the server's host blocks ping (ICMP).
- Joining is only possible after loading your own save (not from the main menu).

## Not supported
- The SurrounDead experimental/beta branch.
- Other UE4SS or pak mods at the same time (the installer moves them to a backup folder).
