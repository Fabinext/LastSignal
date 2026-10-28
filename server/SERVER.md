# Last Signal Dedicated Server (Linux / Pterodactyl)

SurrounDead runs as a dedicated server under Wine, without graphics or sound. Nobody plays on the server
itself: the server character is invisible and stands still at the world start point (zombies and spawners
ignore it). New players spawn at a random spawn point with starter gear including a GPS, returning players
at their last position (random again after a death). Players join from the in-game server list in the
journal (J); they need the Last Signal client mod.

## Game version
Last Signal 0.10 runs on the SurrounDead **experimental** branch (0.8, Unreal Engine 5.6, tested with build 26165965). Both the egg and the Docker setup install it with `STEAM_BETA=experimental`; the stable branch is not supported.

## Setup with plain Docker (no Pterodactyl)
Files: `docker-compose.yml`, `install.sh` and `.env.example` from the release (`LastSignal-Docker.zip`).
1. `cp .env.example .env` and enter a Steam account that owns SurrounDead (`STEAM_USER`, `STEAM_PASS`, optional `STEAM_AUTH`).
2. Put `LastSignal-Server.tar.gz` next to `docker-compose.yml`.
3. `docker compose run --rm install` installs the game via SteamCMD and unpacks Last Signal into `./data`.
4. Edit `./data/server.cfg` (name, password, admins; same keys as below).
5. `docker compose up -d server`, logs with `docker compose logs -f server`. Open UDP `7777` (or `SERVER_PORT`).
- Update: replace the tar.gz, run step 3 again, then `docker compose up -d --force-recreate server`. Saves and `server.cfg` stay.
- Stop with `docker compose stop server` (75 s grace period so players and world are saved).

## Setup in Pterodactyl

1. **Import the egg:** Admin → Nests → Import Egg → `egg-surroundead-lastsignal.json`
2. **Create a server:**
   - egg "SurrounDead - Last Signal Dedicated Server"
   - one allocation (port, e.g. 7777; the game uses UDP)
   - about 8 GB RAM, 10 GB disk, 200 % CPU
3. **Game files** (either way):
   - **Steam:** enter Steam username and password under *Startup* (plus a fresh Steam Guard code if
     needed), then *Reinstall*. The login is only used for the download.
   - **SFTP:** upload the contents of your game folder (`SurrounDead/`, `Engine/`, `SurrounDead.exe`) to the
     server folder.
4. **Last Signal:** upload `LastSignal-Server.tar.gz` to the server folder via SFTP. It is unpacked
   automatically on the next start. Updates work the same way (saves and settings are kept). Update the players'
   client mod at the same time (see *Updates* under *Notes*).
5. **Save game:** upload to `saves/`, from your PC's `%LOCALAPPDATA%\SurrounDead\Saved\SaveGames`:
   - the save folder (with `Slot.sav`)
   - plus `<Name>_Quests.sav`, `<Name>_SkillTree.sav` and `SurrounDead.sav`
   - to keep inventories of earlier players: the folder `NetTest_Guests` and `NetTest_Guest_*.sav`

   The server loads the most recently played save (like "Continue") unless *Save Slot* is set.
6. **Start.** The server is ready when the console shows `Last-Signal-Server bereit`. The first start sets
   up Wine and takes 1–2 minutes longer.

## Settings (Panel → Startup)

| Variable | Default | Meaning |
|---|---|---|
| Server Name (`LASTSIGNAL_NAME`) | Last Signal Server | name in the in-game server list (max 48 characters) |
| Server Description (`LASTSIGNAL_DESCRIPTION`) | empty | short text in the server list (max 120 characters) |
| Message of the Day (`LASTSIGNAL_MOTD`) | empty | welcome message in chat when a player joins (max 150 characters) |
| Server Password (`LASTSIGNAL_PASSWORD`) | empty | players need it to join; empty = open. The server list only shows a lock, the password is never sent to it |
| Public Server (`LASTSIGNAL_PUBLIC`) | 1 | 1 = shown in the server list, 0 = hidden |
| Max Players (`LASTSIGNAL_MAX_PLAYERS`) | 8 | players online at the same time (1–64) |
| Admins (Player IDs) (`LASTSIGNAL_ADMINS`) | empty | admin player IDs, comma-separated, optional `steam:<id>` entries (see *Admins* below) |
| Admin Password (`LASTSIGNAL_ADMIN_PASSWORD`) | empty | if set, admins need `/admin <password>` in chat once per connection |
| Server FPS (`LASTSIGNAL_FPS`) | 60 | target updates per second with players (20–120), also the network update rate (`NetServerMaxTickRate`); the server lowers it by itself under load (see *FPS Automatic*); 5 without players |
| Server FPS Minimum (`LASTSIGNAL_FPS_MIN`) | 45 | lowest target the automatic throttle may choose under load (20 up to *Server FPS*); the console command `fps <n>` with a lower value lowers it until the next start |
| FPS Automatic (`LASTSIGNAL_FPS_AUTO`) | 1 | 1 = if the server cannot hold its target, it steps down (50, 45, 40, 30, 20, never below *Server FPS Minimum*) and goes back up when it has headroom again; 0 = fixed *Server FPS*. Console `fps auto on\|off`; the switch `server_fps_auto=0` in `coop.txt` also turns it off |
| Autosave (minutes) (`LASTSIGNAL_SAVE_MINUTES`) | 5 | world save interval (1–60); players are also saved every 10 s |
| Save Slot (`LASTSIGNAL_SAVE_SLOT`) | empty | folder name in `saves/` (empty = most recently played) |
| Corpse Cleanup (minutes) (`LASTSIGNAL_CORPSE_MINUTES`) | 60 | dead zombies disappear with their items. The same time applies to items the server sets down at a player's feet (admin `give`, consumed items) and, only with `srv_drophook_first=1` in `coop.txt`, to items players drop (detected fresh within 6 m of a player; picked up and dropped again = the time starts over). Never with a player within 15 m; 0 = never (everything stays) |
| Death Box Cleanup (minutes) (`LASTSIGNAL_DEATHBOX_MINUTES`) | 60 | player death boxes disappear with their contents (never with a player within 15 m); 0 = never |
| Loot Refill (`LASTSIGNAL_LOOT_REFILL`) | 1 | 1 = searched loot containers refill like in single player (`Difficulty.Refill`), 0 = never; set after the save is loaded, so it overrides the save's difficulty setting and is passed on to players |
| Loot Refill Time (`LASTSIGNAL_LOOT_REFILL_MIN`) | 30 | minutes until a searched container refills (`Difficulty.RefillTime`, 1–10080); containers whose timer was already running when the save loaded keep their old time for that one round |
| Save Backups (`LASTSIGNAL_BACKUPS`) | 5 | backups kept in `saves/_backup` (0–50, see *Backups*); 0 = none |
| Backup Interval (`LASTSIGNAL_BACKUP_MINUTES`) | 30 | at most one backup per this many minutes while running, taken right after a completed world save; 0 = only at server start after a clean stop (a server that never stops cleanly then gets no new backups) |
| Daily Restart (`LASTSIGNAL_RESTART_AT`) | empty | daily restart at `HH:MM` in the container's time (often UTC; `start.sh` prints the current container time at start): players are warned 10, 5 and 1 minute and 30 s before, then the server saves and stops like `stop`. Never within the first hour after a start; empty = off. **Needs an automatic restart** (see below) |
| Bring Own Inventory (`LASTSIGNAL_LOCAL_INVENTORY`) | 0 | 1 = players bring their own local save |
| Master List URL (`LASTSIGNAL_MASTER_URL`) | https://update.tacticalhardline.com | server list to announce to; only change it for your own master list; empty = not listed |
| Master List Key (`LASTSIGNAL_MASTER_KEY`) | empty | only for a private master list that requires a key; the public list needs none (masked in the log) |
| Public Address (`LASTSIGNAL_PUBLIC_ADDRESS`) | empty | IP/domain players connect to; empty = IP of the allocation (`SERVER_IP`) |
| Last Signal Package URL (`LASTSIGNAL_URL`) | empty | optional download link for the package (used by *Reinstall*); empty = upload it via SFTP |

**Daily Restart needs an automatic restart:** after the planned restart `start.sh` exits with code 0, like after
`stop`. The panel or Docker must start it again, otherwise the server stays off after the restart time:
- Pterodactyl: Wings crash detection on, with *detect clean exit as crash* (Wings `config.yml`:
  `system.crash_detection.enabled` and `detect_clean_exit_as_crash`, both `true` by default).
- Docker: `docker run --restart unless-stopped` (compose: `restart: unless-stopped`).

Without Pterodactyl: save `server.cfg.example` as `server.cfg`, adjust it, run `bash start.sh`. Environment
variables win over `server.cfg`; with `CONFIG_PRIORITY=file` in `server.cfg` the file wins. `start.sh` prints every
value where the two differ, with its source (passwords and keys are masked). Further keys (`server.cfg` or
environment):
- `SERVER_PORT` (7777): UDP port of the game; Pterodactyl sets it from the allocation.
- `LASTSIGNAL_STOP_WAIT` (45, 5–600): seconds `start.sh` waits for the final save after `docker stop`/Ctrl+C (see
  *Stopping* under *Notes*). The panel's Stop button sends `stop` and is not affected.
- `WINEPREFIX` (default `.wine` in the server folder) and `WINEDEBUG` (default `-all`): optional Wine settings.
- `LASTSIGNAL_SERVER=1` and `LASTSIGNAL_PORT` (= `SERVER_PORT`) are set by `start.sh` itself; don't set them.
- Old names `NETTEST_*` (older panels/`server.cfg`) are still read by the mod, but not by `start.sh` (backups, stop
  wait, server list, restart message): rename them to `LASTSIGNAL_*`.

## Console

| Command | Effect |
|---|---|
| `help` | short list of all commands |
| `status` | state, player count, FPS (target, minimum, automatic, throttle), last save, planned restart |
| `players` | players with number, `pid:`, ping, IP, player ID and Steam ID |
| `save` | save now |
| `stop` / `quit` | save and shut down cleanly (the Stop button does the same) |
| `shutdown` | same as `stop`; sent by `start.sh` on SIGTERM/SIGINT (`docker stop`, Ctrl+C) |
| `restart [<minutes>\|cancel]` | planned restart: warns players at 10/5/1 min and 30 s, then saves and stops like `stop` (`restart 0` = now); no argument shows the plan; `cancel` drops it (a daily restart then moves to the next day). The panel/Docker must start the server again (see *Daily Restart*) |
| `fps <n>` | change the server FPS with players (5–120) until the next start; permanently: *Server FPS* |
| `fps auto on\|off` | turn the automatic FPS throttle on/off until the next start (see *FPS Automatic*) |
| `time <hour>` | set the time of day, e.g. `time 12` or `time 1830` |
| `corpses` | number of corpses and death boxes, oldest, removed so far |
| `perf` | Lua memory and the most expensive mod tasks of the last 60 s (every 5 min the log also shows a `Leistung:` line with FPS, players, Lua memory and the top tasks) |
| `kick <player> [reason]` | kick a player |
| `ban <player\|ID\|IP> [reason]` | ban (player ID, IP and Steam ID at once); also works for offline players |
| `unban <ID\|IP>` / `bans` | lift a ban / ban list (`bans.txt` in the mod folder) |
| `tp <player> <player\|x y z>` | teleport a player |
| `say <text>` | message to everyone (top of the screen) |
| `weather <type> [seconds]` | weather: clear, cloudy, partly, overcast, fog, rain, lightrain, storm, snow, lightsnow, blizzard, dust, sandstorm, radiation |
| `flags` | lists the mod switches that turned themselves off after errors (autofallback), with age and next retry, and turns them all on again |
| `flags list` | the same list, without turning anything on |
| `mute [player]` | mute a player: no chat to everyone and no clan chat (`/c`), other chat commands still work; no argument lists the muted players |
| `unmute <player\|ID>` | lift a mute |
| `vehicles` | all cars by name with fuel, health, owner and lock |
| `vehicle_rm <name>` | remove a car (name from `vehicles`); refused while it is driven or a player sits in it or hangs on it |
| `dropmode <0\|1\|2>` | how the server puts debug-menu (cheat) items at a player's feet: 0 = spawns them itself, 1 = into the inventory and dropped by the game, 2 = the game's own drop (`RequestDropAsPickup`; needs `srv_gamedrop_out=1` in `coop.txt`, default on, otherwise it works like 0); until the next start, permanently `drop_mode` in `coop.txt` |
| `netstats` | network statistics of the mod (messages and bytes in/out, dropped messages) |
| `native_ev` / `r5` | diagnostics: state of the native `LastSignalCore.dll` / loaded modules, players and switched-off switches |

**Players** are given as `#number` or `pid:<PlayerId>` (both shown by `players`), part of the name, player ID, Steam ID or IP.

Other test commands of the mod (`test_cmd.txt` on a local test setup) only run on the server with `dev=1` or `test=1`
in `coop.txt`; otherwise the console says so. The package never contains these switches or `test_cmd.txt`.

**Admins:** put the player IDs of your admins into *Admins (Player IDs)*. Every player sees their own ID in
game under J > SERVER (the console command `players` lists them too). Admins get the **ADMIN** tab in the
journal: player list, "Go to", "Bring here", "Kick", "Ban" (click twice), time and weather. The player ID is
random per PC and secret; Steam IDs are public and not verified without a Steam login, so on their own they only
count for bans, not for admin rights.
- *Admin Password* (`LASTSIGNAL_ADMIN_PASSWORD`, empty = off): if set, a listed admin gets the rights only after
  typing `/admin <password>` in chat, once per connection (5 tries). The password is never shown in chat or the log.
- Entries `steam:<17 digits>` in *Admins* are an extra condition: as soon as one is listed, an admin needs a listed
  player ID **and** a listed Steam ID.

## Backups

`start.sh` copies the save folder to `saves/_backup/<YYYYMMDD-hhmmss>/`:
- at every start after a clean stop (stop/shutdown/daily restart) or when there is no backup yet, unless nothing
  changed since the newest backup; never after a crash, because its save may be incomplete (also not after a stop
  whose world save was still running after 30 s: `server_stopped.txt` then says `busy`)
- while running, right after a completed world save, at most every *Backup Interval* minutes: the mod asks for it
  with `backup_req.txt` in its folder once the world and the player inventories are committed (switch
  `srv_save_backup` in `coop.txt`, default on)
- it keeps the newest *Save Backups* (5); a backup is written to `<stamp>.part` first and only counts when complete.

A backup holds the world save folder, `SurrounDead.sav`, the quest/skill files and `NetTest_Guests` (player
inventories and quest slots, with the `*.commit` copies that match the saved world: `<Id>.commit` for the
inventory, `<Id>.werte.commit` / `<Id>.spawn.commit` for stats and spawn point). The folder `_mod` inside holds the
mod's server files (`owners.txt`/`owners.commit`, clans, `car_owners.txt`) and `backup.txt` (reason and time).
`bans.txt` and `admin_log.txt` are backed up, but a restore never puts them back (bans issued after the backup stay
in force). `guest_journal.txt`/`owners.pending` (the guest journal) are backed up and put back, so the mod matches
the guest inventories to the restored world at start. Not backed up: `*.tmp` and `*.crash` files.

If the world save cannot be loaded and `srv_auto_restore=1` is set in `coop.txt` (default off), the mod writes
`restore_req.txt` in its folder before it quits; the next start then restores the newest backup automatically (each
further attempt takes the next older one).

**Restore** (the server must be stopped):
- *Easy way:* create the file `saves/_backup/restore.txt` containing the backup's name (e.g. `20261024-031500`), or
  leave it empty for the newest backup, then start the server. If the name does not match an existing backup,
  nothing is restored (see the start log). `start.sh` keeps the current state in
  `saves/_backup/before-restore-<time>/` (the 2 newest are kept), restores the backup, sets every player inventory to
  its `.commit` and puts the `_mod` files back. An empty `restore.txt` again takes the next older backup until the
  restored world has run for 30 minutes (or made its first backup); after that it takes the newest backup again.
- If a restore fails and the previous saves cannot be put back either, `start.sh` writes
  `saves/_backup/restore_failed.txt` and does not start the game (not even on a panel restart) until you have
  checked `saves/` and deleted that file.
- *By hand:* delete everything in `saves/` except `_backup`, copy the backup folder's content (without `_mod`) into
  `saves/`, in `saves/NetTest_Guests/` copy every `<Id>.commit` to `<Id>.sav` and every `<Id>.werte.commit` /
  `<Id>.spawn.commit` to `<Id>.werte.txt` / `<Id>.spawn.txt`, copy the files from `_mod` except `admin_log.txt` and
  `bans.txt` into `SurrounDead/Binaries/Win64/ue4ss/Mods/LastSignal/` (`owners.commit` also as `owners.txt`); delete
  `guest_journal.txt`, `guest_journal.txt.bak` and `owners.pending` there, then copy `guest_journal.txt` and
  `owners.pending` from `_mod` if the backup has them.

## Server files

The mod folder is `SurrounDead/Binaries/Win64/ue4ss/Mods/LastSignal/`.

| File | Purpose |
|---|---|
| `saves/_backup/<YYYYMMDD-hhmmss>/` | one backup (see *Backups*); a `<stamp>.part` folder is an unfinished one and is deleted |
| `saves/_backup/before-restore-<time>/` | state before a restore (the 2 newest are kept) |
| `saves/_backup/restore.txt` | created by you: restore at the next start (deleted once read) |
| `saves/_backup/last_restore.txt` | the last restored backup, so that the next empty `restore.txt` takes an older one |
| `saves/_backup/restore_failed.txt` | blocks the start after a failed restore; delete it after checking `saves/` |
| mod folder `backup_req.txt` | mod → `start.sh`: make a backup now (after a committed world save) |
| mod folder `restore_req.txt` | mod → `start.sh`: the save did not load, restore at the next start (`srv_auto_restore=1`) |
| mod folder `server_cmd.txt` (`.work`) | console lines from `start.sh` to the mod; deleted at every start, so an old `stop` never runs |
| mod folder `status.txt` | state for the server list, written while the server runs |
| mod folder `server_stopping.txt` / `server_stopped.txt` | stop markers: `start.sh` starts its stop timer / the mod ended cleanly (with `busy`: world save not finished, no start backup) |
| mod folder `admin_log.txt` (`admin_log.1.txt`) | admin log (see *Notes*) |
| mod folder `bans.txt` | ban list |
| mod folder `owners.txt`, `owners.commit`, `clans.txt`, `car_owners.txt`, `guest_journal.txt`, `owners.pending` | the mod's world state (backed up with every backup) |

## Notes

- Don't continue the server save locally: it contains the server character, not yours.
- `start.sh` deletes old logs (older than 7 days) and crash dumps (older than 3 days) on every start.
- The server announces itself to the server list every 30 s while it runs and removes itself on shutdown.
- **Updates:** update the server package and the players' client mod together (same Last Signal version). Mixed
  versions still connect, but newer fixes then fall back to the old behaviour. Example, the debug menu (cheat): a
  new client sends `give … rm` (its placeholder item is already removed, no extra copy) only to a server that
  announces it understands it, otherwise the old `give` format; `cheat_rmpend2=0` in the client's `coop.txt` restores
  the old way completely.
- **Stopping:** `stop` (Stop button) saves every player at once (inventory, position), tells them the server is
  closing, saves the world, waits for the world save (at least 3 s, at most 30 s) and quits; `start.sh` waits up to
  90 s from the start of the stop (`server_stopping.txt`) before it kills the game (Pterodactyl's Wings waits longer,
  so the Stop button is always clean; only *Kill* is not). The same timer applies when the mod stops by itself
  (`restart`, *Daily Restart*). On **SIGTERM/SIGINT** (`docker stop`, Ctrl+C) `start.sh` sends `shutdown` (same as
  `stop`) and waits up to 45 s (`LASTSIGNAL_STOP_WAIT`, seconds) before it kills the game; a second signal kills it
  at once. The game, its X display and the log output run in their own session (`setsid`), so the stop signal
  reaches only `start.sh`.
  - Docker's grace period must be longer than that (default 10 s): `docker stop -t 75`, or in docker-compose
    `stop_grace_period: 75s`.
  - `start.sh` must be the container's main process or the direct child of an init (`tini`, `docker run --init`,
    compose `init: true`): start it with `exec bash ./start.sh`. The Wine image (yolks) already has tini and stops with
    SIGINT, which works either way; SIGTERM only works with `exec`. Servers created from an older egg: change the
    startup command under *Startup* from `bash ./start.sh` to `exec bash ./start.sh`.
  - The log then ends with `Welt gespeichert (Server stoppt)` and `[start] Server stopped (code 0)`. If the game is
    killed anyway, the last autosave and the last player save remain, and the next start rolls the players back to
    the last world save (`Letzter Lauf ohne sauberes Ende`).
  - After `stop`, `restart` and *Daily Restart* `start.sh` exits with code 0; after a crash with an error code, so
    Pterodactyl restarts it.
- **Admin log:** `admin_log.txt` in the mod folder (`SurrounDead/Binaries/Win64/ue4ss/Mods/LastSignal/`) records
  admin actions: console commands (not pure displays), admin commands in game with their result, refused attempts,
  `/admin` logins (never the password), AFK kicks and restarts. Append-only; above 2 MB it is renamed to
  `admin_log.1.txt` (one old file is kept). Switch `srv_adminlog` in `coop.txt` (default on).
- **Log size:** `UE4SS.log` is cleared at every start. While the server runs, `start.sh` checks it hourly and moves it
  to `UE4SS.log.1` above 50 MB (only if the game appends to it; otherwise it says so once and a restart clears it).
- The package (`pack_server.sh`) contains `main.lua`, `server.lua`, all modules `ls_*.lua`, the newest
  `LastSignalCore.dll`, `coop.txt` with every switch documented (`test`/`dev` are never included), `start.sh`,
  `server.cfg.example` and this file (never `test_cmd.txt`, `netcore.log` or `*.vor-*` copies).
