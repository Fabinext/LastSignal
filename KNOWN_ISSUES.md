# Known issues (Last Signal 0.10.0)

- Only the SurrounDead **experimental** branch (0.8, UE 5.6, build 26165965) is supported. After a game update the mod may need an update too.
- Many fixes in 0.10.0 are checked by code review only and still need broader play-testing. Confirmed in game: server stutter, aiming/shooting, weapon hold pose, driving after exiting, zombies while driving, empty bottles, map markers, disassembly workbench.
- Items dropped by players stay on the ground unless the server enables cleanup (`srv_drophook_first=1`, see SERVER.md). Dropping an equipped weapon or backpack is never cleaned up.
- Some protections only log instead of blocking for now: guest weapon durability (`combat_dur_gate=0`), hit checks (`combat_hitcheck_deny=0`).
- Towing/pushing cars, the trunk lock and the debug-menu time dilation were changed last and are the least tested.
- Guests with an older client: `/unstuck` and admin teleport only move the server-side character.
- `bans.txt` and `admin_log.txt` are backed up but not restored automatically.
- Not included yet: name tags, base decay, whitelist, PvP statistics, raid log, permadeath.

Please report bugs with the `UE4SS.log` from `SurrounDead\Binaries\Win64\ue4ss\`.
