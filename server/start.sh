#!/bin/bash
# Last-Signal-Server: startet SurrounDead ohne Grafik und Ton unter Wine (Pterodactyl oder normales Linux).
#   Konsole rein: jede Zeile geht an den Mod (help, status, players, save, stop)
#   Konsole raus: das Mod-Log (UE4SS.log)
# Einstellungen: Umgebungsvariablen LASTSIGNAL_* (Pterodactyl-Panel, alte NETTEST_* gelten weiter) oder server.cfg daneben.
# Runde 9: Spiel, Xvfb und Log-Ausgabe laufen in eigener Sitzung (setsid). Stop-Signale (docker stop schickt beim
# Wine-Image SIGINT an die ganze Prozessgruppe, tini -g) erreichen so nur dieses Skript, das "shutdown" an den Mod gibt
# (Gaeste speichern, bye, Welt speichern, festschreiben, beenden). Vorher toetete das Signal Wine sofort (Code 58).
# Sicherungen der Spielstaende in saves/_backup (beim Start und nach jedem Festschreiben, siehe backup_saves).
cd "$(dirname "$0")" || exit 1
ROOT="$PWD"
WIN64="$ROOT/SurrounDead/Binaries/Win64"
EXE="$WIN64/SurrounDead-Win64-Shipping.exe"
MOD="$WIN64/ue4ss/Mods/LastSignal"
LOG="$WIN64/ue4ss/UE4SS.log"
CMD_FILE="$MOD/server_cmd.txt"

# server.cfg (KEY=Wert): Standard = Umgebung (Panel) gewinnt, die Datei fuellt nur fehlende Werte.
# CONFIG_PRIORITY=file (in server.cfg oder als Umgebungsvariable): bei LASTSIGNAL_*/NETTEST_*/SERVER_PORT gewinnt die
# Datei. Jeder Unterschied wird mit seiner Quelle gemeldet (Werte mit PASS/KEY/SECRET/TOKEN im Namen verdeckt).
declare -A CFG_FROM=()
cfg_show() { case "$1" in *PASS*|*KEY*|*SECRET*|*TOKEN*) echo "***" ;; *) echo "'$2'" ;; esac; }
cfg_src() {   # Quelle eines Werts fuer das Log: server.cfg, environment oder default
    if [ -n "${CFG_FROM[$1]:-}" ]; then echo "server.cfg"; elif [ -n "${!1+x}" ]; then echo "environment"; else echo "default"; fi
}
if [ -f "$ROOT/server.cfg" ]; then
    CFG_KEYS=()
    CFG_VALS=()
    CFG_PRIO="${CONFIG_PRIORITY:-}"
    while IFS='=' read -r KEY VALUE || [ -n "$KEY" ]; do
        KEY="${KEY//[[:space:]]/}"
        [[ "$KEY" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        VALUE="${VALUE%$'\r'}"
        if [ "$KEY" = "CONFIG_PRIORITY" ]; then
            [ -z "$CFG_PRIO" ] && CFG_PRIO="${VALUE//[[:space:]]/}"
            continue
        fi
        CFG_KEYS+=("$KEY")
        CFG_VALS+=("$VALUE")
    done < "$ROOT/server.cfg"
    CFG_PRIO="${CFG_PRIO,,}"
    for I in "${!CFG_KEYS[@]}"; do
        KEY="${CFG_KEYS[$I]}"
        VALUE="${CFG_VALS[$I]}"
        if [ -z "${!KEY+x}" ]; then
            export "$KEY=$VALUE"
            CFG_FROM[$KEY]=1
        elif [ "${!KEY}" != "$VALUE" ]; then
            case "$CFG_PRIO:$KEY" in
                file:LASTSIGNAL_*|file:NETTEST_*|file:SERVER_PORT)
                    echo "[start] $KEY=$(cfg_show "$KEY" "$VALUE") (server.cfg, CONFIG_PRIORITY=file) - environment value $(cfg_show "$KEY" "${!KEY}") ignored"
                    export "$KEY=$VALUE"
                    CFG_FROM[$KEY]=1 ;;
                *)
                    echo "[start] $KEY=$(cfg_show "$KEY" "${!KEY}") (environment) - server.cfg says $(cfg_show "$KEY" "$VALUE") and is ignored (CONFIG_PRIORITY=file in server.cfg: file wins)" ;;
            esac
        fi
    done
    unset CFG_KEYS CFG_VALS CFG_PRIO I KEY VALUE
fi
PORT="${SERVER_PORT:-7777}"

export WINEPREFIX="${WINEPREFIX:-$ROOT/.wine}"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
# UE4SS haengt sich ueber dwmapi.dll im Spielordner ein: Wine muss diese statt der eigenen laden.
export WINEDLLOVERRIDES="dwmapi=n,b;mscoree,mshtml="
export LASTSIGNAL_SERVER=1
export LASTSIGNAL_PORT="$PORT"

# Ganze Zahl im Bereich: $1 Wert, $2 Standard (bei ungueltigem Wert), $3 Minimum, $4 Maximum
clamp_int() {
    local V="${1//[[:space:]]/}"
    if [[ "$V" =~ ^[0-9]{1,6}$ ]]; then V=$((10#$V)); else V=$2; fi
    [ "$V" -lt "$3" ] && V=$3
    [ "$V" -gt "$4" ] && V=$4
    echo "$V"
}

if [ ! -f "$EXE" ]; then
    echo "[start] Game files missing: $EXE"
    echo "[start] Upload the game files via SFTP, or enter a Steam login in the panel (Startup) and reinstall."
    exit 1
fi
if [ ! -f "$WIN64/dwmapi.dll" ] || [ ! -f "$MOD/Scripts/server.lua" ]; then
    echo "[start] Last Signal missing: upload LastSignal-Server.tar.gz to the server folder and restart."
    exit 1
fi
# Umbenennung NetTest -> Last Signal: den alten Mod-Ordner entfernen, sonst laedt der Mod doppelt
if [ -d "$WIN64/ue4ss/Mods/NetTest" ]; then
    rm -rf "$WIN64/ue4ss/Mods/NetTest"
    sed -i '/^NetTest : /d' "$WIN64/ue4ss/Mods/mods.txt"
    echo "[start] Removed old mod folder NetTest (now LastSignal)"
fi
echo "[start] Server FPS ${LASTSIGNAL_FPS:-60} ($(cfg_src LASTSIGNAL_FPS)), autosave ${LASTSIGNAL_SAVE_MINUTES:-5} min ($(cfg_src LASTSIGNAL_SAVE_MINUTES)), backups ${LASTSIGNAL_BACKUPS:-5} ($(cfg_src LASTSIGNAL_BACKUPS))"
# Taeglicher Neustart (server.lua X-CORE1, LASTSIGNAL_RESTART_AT=HH:MM): Uhrzeit des Containers (oft UTC), zum Vergleich
# die aktuelle melden. Danach endet dieses Skript wie bei stop mit Code 0: neu starten muss das Panel bzw. Docker.
if [ -n "${LASTSIGNAL_RESTART_AT//[[:space:]]/}" ]; then
    echo "[start] Daily restart at ${LASTSIGNAL_RESTART_AT//[[:space:]]/} ($(cfg_src LASTSIGNAL_RESTART_AT), container time, now $(date '+%H:%M %Z')); start.sh then exits with code 0: the panel/Docker must start the server again"
fi

# Beenden: Panel "Stop" schickt "stop" auf die Konsole (bis 90 s Zeit, Wings wartet laenger). SIGTERM/SIGINT (docker
# stop, Strg+C): "shutdown" an den Mod (= stop) und hoechstens STOP_SIGNAL_WAIT s (LASTSIGNAL_STOP_WAIT, Standard 45)
# warten, dann hart beenden; ein zweites Signal beendet sofort hart. Die Frist von Docker muss laenger sein:
# docker stop -t 75 bzw. stop_grace_period: 75s (Standard 10 s: Docker toetet sonst vorher).
# SIGTERM kommt hier nur an, wenn dieses Skript direktes Kind von tini/docker --init ist (Egg: "exec bash ./start.sh"),
# sonst stirbt die Shell darueber und tini beendet den ganzen Container. SIGINT (Wine-Image) geht in beiden Faellen.
# Die Falle steht vor allem anderen: ein Stop waehrend Wine-Einrichtung/Sicherung startet das Spiel gar nicht erst.
STOP_AT=""
STOP_LIMIT=90
STOP_SIGNAL_WAIT=$(clamp_int "${LASTSIGNAL_STOP_WAIT:-45}" 45 5 600)
SIG_COUNT=0
GAME=""
STOP_SENT=""
request_stop() {
    SIG_COUNT=$((SIG_COUNT + 1))
    if [ "$SIG_COUNT" -ge 2 ]; then
        STOP_LIMIT=0
        echo "[start] Second stop signal: stopping the game without waiting"
        return 0
    fi
    if [ -n "$STOP_AT" ]; then   # Konsolen-"stop" laeuft schon: hoechstens noch STOP_SIGNAL_WAIT s (Docker-Frist)
        local Left=$(( $(date +%s) - STOP_AT + STOP_SIGNAL_WAIT ))
        [ "$Left" -lt "$STOP_LIMIT" ] && STOP_LIMIT=$Left
        echo "[start] Stop signal received: shutdown is already running"
        return 0
    fi
    STOP_AT=$(date +%s)
    STOP_LIMIT=$STOP_SIGNAL_WAIT
    echo "[start] Stop signal received: saving players and world (up to ${STOP_LIMIT} s) ..."
    if [ -n "$GAME" ]; then
        printf 'shutdown\n' >> "$CMD_FILE"
        STOP_SENT=1
    fi
}
trap request_stop TERM INT

# Eigene Sitzung (setsid) fuer Spiel, Xvfb und Log-Ausgabe: Signale an die Prozessgruppe dieses Skripts erreichen sie
# nicht. Wine macht aus SIGINT ein CTRL_C_EVENT und beendet das Spiel sofort (0xC000013A) ohne Speichern, Xvfb beendet
# sich bei SIGINT/SIGTERM. Die Unterprozesse ignorieren INT/TERM zusaetzlich (trap ''), falls setsid fehlt oder
# forken muss (der wartende Elternteil ueberlebt dann). -w nur, wenn setsid es kennt (busybox nicht).
SETSID_MODE=""
if command -v setsid >/dev/null 2>&1; then
    if setsid -w true >/dev/null 2>&1; then SETSID_MODE="w"; else SETSID_MODE="1"; fi
else
    echo "[start] WARNING: setsid (util-linux) not found: docker stop may end the game before it has saved"
fi
own_session() {
    case "$SETSID_MODE" in
        w) exec setsid -w "$@" ;;
        1) exec setsid "$@" ;;
        *) exec "$@" ;;
    esac
}

# Wine braucht einen Bildschirm, auch wenn das Spiel nichts zeichnet: immer ein eigener Xvfb (fast kostenlos) in eigener
# Sitzung. Den des Wine-Images (XVFB=1, Display :0) nicht nehmen: er liegt in der Signal-Gruppe, stirbt beim Stop mit
# und nimmt Wine die X-Verbindung mitten im Speichern.
x_alive() {   # laeuft auf Display $1 (z. B. :99) wirklich ein X-Server? PID aus der Lock-Datei, Name aus /proc/<pid>/comm
    local N="${1#*:}" P
    N="${N%%.*}"
    [ -n "$N" ] && [ -f "/tmp/.X$N-lock" ] || return 1
    P=$(tr -d ' \n' < "/tmp/.X$N-lock" 2>/dev/null)
    if [[ "$P" =~ ^[0-9]+$ ]] && grep -qE '^(Xvfb|Xorg|X)$' "/proc/$P/comm" 2>/dev/null; then return 0; fi
    rm -f "/tmp/.X$N-lock" "/tmp/.X11-unix/X$N" 2>/dev/null   # veraltete Sperre (Container-Neustart: /tmp bleibt)
    return 1
}
XVFB_PID=""
if command -v Xvfb >/dev/null 2>&1; then
    XNUM=99
    while [ "$XNUM" -lt 199 ] && { x_alive ":$XNUM" || [ -e "/tmp/.X11-unix/X$XNUM" ]; }; do XNUM=$((XNUM + 1)); done
    ( trap '' INT TERM
      own_session Xvfb ":$XNUM" -screen 0 "${DISPLAY_WIDTH:-640}x${DISPLAY_HEIGHT:-480}x${DISPLAY_DEPTH:-24}" \
          -nolisten tcp >/dev/null 2>&1 ) &
    XVFB_PID=$!
    export DISPLAY=":$XNUM"
    for _ in 1 2 3 4 5 6 7 8 9 10; do x_alive "$DISPLAY" && break; sleep 0.5; done
    x_alive "$DISPLAY" || echo "[start] WARNING: Xvfb on $DISPLAY did not start, Wine may fail to start"
elif [ -n "${DISPLAY:-}" ] && x_alive "$DISPLAY"; then
    echo "[start] WARNING: Xvfb is not installed, using display $DISPLAY (it may stop together with the container)"
else
    echo "[start] WARNING: no X display and Xvfb is not installed, Wine may fail to start"
fi

if [ ! -d "$WINEPREFIX/drive_c" ]; then
    echo "[start] First start: setting up Wine (1-2 minutes) ..."
    ( trap '' INT TERM; own_session sh -c 'wineboot --init >/dev/null 2>&1; wineserver -w' )
fi

# Ordner des Spiels in der Wine-Umgebung
USERDIR="$WINEPREFIX/drive_c/users/${USER:-$(whoami)}"
GAMEDATA="$USERDIR/AppData/Local/SurrounDead/Saved"
mkdir -p "$GAMEDATA/Config/Windows" "$ROOT/saves"

# Spielstaende liegen sichtbar in saves/ (Datei-Manager des Panels): Wine-Ordner zeigt darauf
if [ -d "$GAMEDATA/SaveGames" ] && [ ! -L "$GAMEDATA/SaveGames" ]; then
    # Signal-fest (trap ''): ein Stop-Signal mitten im cp darf nicht das rm danach die Originale loeschen lassen.
    # ";" statt "&&": cp -n meldet bei manchen coreutils (9.2) Fehler, wenn es vorhandene Dateien auslaesst
    ( trap '' INT TERM
      cp -rn "$GAMEDATA/SaveGames/." "$ROOT/saves/" 2>/dev/null
      rm -rf "$GAMEDATA/SaveGames" )
fi
ln -sfn "$ROOT/saves" "$GAMEDATA/SaveGames"

# Engine.ini des Servers: kein Steam (Null-Onlinesystem), normales IP-Netzwerk. Steam-Mitspieler lässt
# server.lua zur Laufzeit zu (das geht nicht per Engine.ini). Die eigenen Abschnitte werden bei jedem
# Start neu geschrieben; das Spiel schreibt die Datei beim Beenden mit Windows-Zeilenenden neu.
INI="$GAMEDATA/Config/Windows/Engine.ini"
touch "$INI"
awk '
    { sub(/\r$/, "") }
    /^\[/ { skip = ($0 == "[OnlineSubsystem]" || $0 == "[OnlineSubsystemSteam]" ||
                    $0 == "[/Script/OnlineSubsystemUtils.OnlineEngineInterfaceImpl]" ||
                    $0 == "[/Script/OnlineSubsystemUtils.IpNetDriver]") }
    !skip
' "$INI" > "$INI.tmp" && mv "$INI.tmp" "$INI"
# ConnectionTimeout: abgestuerzte/getrennte Mitspieler nach 20 s statt 60 s entfernen (ihre Figur ist in der
# Zeit eingefroren und geschuetzt, siehe Coop.Link in main.lua)
# NetServerMaxTickRate: Obergrenze der Netzwerk-Updates pro Sekunde = Server-FPS (LASTSIGNAL_FPS, 20-120, Standard 60)
TICK=$(clamp_int "${LASTSIGNAL_FPS:-60}" 60 20 120)
cat >> "$INI" <<EOF

[OnlineSubsystem]
DefaultPlatformService=Null

[OnlineSubsystemSteam]
bEnabled=false
bUseSteamNetworking=false

[/Script/OnlineSubsystemUtils.IpNetDriver]
ConnectionTimeout=20.0
; Netzwerk-Updates pro Sekunde (Engine-Standard 30) = LASTSIGNAL_FPS (20-120)
NetServerMaxTickRate=$TICK
EOF

# Alte Logs und Absturz-Dateien aufraeumen, damit die SSD ueber Monate nicht volllaeuft
find "$GAMEDATA/Logs" -type f -mtime +7 -delete 2>/dev/null
find "$WIN64/ue4ss" -maxdepth 1 -name 'crash_*.dmp' -mtime +3 -delete 2>/dev/null

if ! ls "$ROOT"/saves/*/Slot.sav >/dev/null 2>&1; then
    echo "[start] WARNING: no save in saves/. Upload it from your PC: %LOCALAPPDATA%\\SurrounDead\\Saved\\SaveGames"
    echo "[start]          (the save folder with Slot.sav and the file SurrounDead.sav)"
fi

# Sicherungen (Runde 9): Kopie von saves/ (Welt-Slot, SurrounDead.sav, Quests/SkillTree, NetTest_Guests mit den zur
# Welt passenden <Id>.commit) nach saves/_backup/<JJJJMMTT-hhmmss>/, die Server-Dateien des Mods (Besitzer, Clans,
# Autos; MOD_STATE) nach <Stempel>/_mod/, dazu Admin-Protokoll und Bans (MOD_LOGS: nur gesichert, beim
# Zurueckspielen nie ueberschrieben - sie gehoeren nicht zum Welt-Stand; ein Bann nach der Sicherung bleibt) und das
# Gast-Journal (MOD_JOURNAL: beim Zurueckspielen zurueckgelegt, server.lua J.Rollback gleicht dann die Gast-Inventare
# beim Start genau wie nach einem Absturz mit der Welt ab). Beim Start nur nach sauberem Ende des letzten Laufs (oder
# ohne jede Sicherung): nach einem Absturz kann der Spielstand halb geschrieben sein und verdraengte sonst eine gute
# Sicherung; und nur wenn sich seit der letzten Sicherung etwas geaendert hat (eine Neustart-Schleife verdraengt so
# keine guten Sicherungen). Dazu auf Anforderung des Mods (backup_req.txt nach fertigem Festschreiben von Welt und
# Gast-Inventaren, server.lua srv_save_backup).
# LASTSIGNAL_BACKUPS = Anzahl behaltener Sicherungen (Standard 5, 0 = aus). Erst nach <Stempel>.part kopieren, fertig
# umbenennen: ein Abbruch hinterlaesst nie eine halbe Sicherung, die als gueltig zaehlt. Signale unterbrechen das
# Kopieren nicht: backup_saves und restore_saves laufen ganz in Subshells mit trap '' INT TERM (auch cp/find/rm/mv
# und prune_dirs), request_stop laeuft danach im Skript.
BACKUP_DIR="$ROOT/saves/_backup"
BACKUP_KEEP=$(clamp_int "${LASTSIGNAL_BACKUPS:-5}" 5 0 50)
STAMP_GLOB='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
# ls_build_beds.txt seit BUILD-24 entfernt (Spawnpunkt: NetTest_Guests/<Id>.spawn.txt, ls_player)
MOD_STATE="owners.txt owners.commit clans.txt car_owners.txt"
# admin_log.txt: server.lua srv_adminlog, nur angehaengt (ab 2 MB admin_log.1.txt). bans.txt: Moderation, nicht an die
# Welt gebunden - ein Zurueckspielen darf seit der Sicherung Gebannte nie wieder hereinlassen (von Hand aus _mod/)
MOD_LOGS="admin_log.txt bans.txt"
# server.lua J.File / J.OwnPath(".pending"): mitsichern und beim Zurueckspielen zuruecklegen, damit J.Rollback /
# J.OwnRollback nach dem Zurueckspielen genau wie nach dem Absturz abgleichen (.pending bei "#S" = "#F", Gaeste ohne
# .commit starten neu, "#N" = Tod)
MOD_JOURNAL="guest_journal.txt owners.pending"
backup_list() { ls -1d "$BACKUP_DIR"/$STAMP_GLOB 2>/dev/null | sort; }
copy_tree() {   # $1 von, $2 nach, Rest: tar-Optionen (--exclude=...)
    local From="$1" To="$2" Err Rc
    shift 2
    Err=$(mktemp 2>/dev/null) || Err=""
    # Kein pipefail: Status je Teil pruefen. Der schreibende tar muss 0 liefern (voll/E/A-Fehler = abbrechen).
    # Der lesende tar liefert 1 (GNU tar), wenn eine Datei beim Lesen geaendert/geschrumpft/entfernt wurde oder sich die
    # ctime eines Ordners geaendert hat - im laufenden Spiel (Sicherung "after save") normal: Gast-Slots, werte/world/
    # bar.txt (Core.WriteAtomic alle 10 s), audit_*.log in NetTest_Guests. Das darf nur fuer Live-Dateien direkt in
    # NetTest_Guests (ausser .commit) gelten: beim Zurueckspielen gelten dort die stabilen <Id>.commit (restore_saves).
    # Welt-Dateien (Slot.sav) oder .commit geaendert -> verwerfen (sonst gaelte eine zerrissene Welt als neueste
    # Sicherung). Ohne Fehlerdatei (mktemp fehlgeschlagen) nur 0.
    ( trap '' INT TERM
      tar -C "$From" "$@" -cf - . 2>"${Err:-/dev/null}" | tar -C "$To" -xf - 2>/dev/null
      S=("${PIPESTATUS[@]}")
      [ "${S[1]}" -eq 0 ] || exit 1
      [ "${S[0]}" -eq 0 ] && exit 0
      [ "${S[0]}" -eq 1 ] && [ -n "$Err" ] && ! grep -v -E '^tar: \./NetTest_Guests(/[^/:]*)?: ' "$Err" | grep -q . \
          && ! grep -q -E '\.commit: ' "$Err" )
    Rc=$?
    [ -n "$Err" ] && rm -f "$Err"
    return $Rc
}
prune_dirs() {   # Eingabe: Ordner aufsteigend sortiert (eine Zeile je Ordner), $1 = Anzahl behalten: aelteste loeschen
    local Keep="$1" F N
    local List=()
    while IFS= read -r F; do [ -n "$F" ] && List+=("$F"); done
    N=$(( ${#List[@]} - Keep ))
    for F in "${List[@]}"; do
        [ "$N" -gt 0 ] || break
        rm -rf -- "$F"
        N=$((N - 1))
    done
}
backup_saves() {   # $1 = Anlass (Log), $2 = force: auch ohne Aenderung seit der letzten Sicherung
    [ "$BACKUP_KEEP" -gt 0 ] || return 1
    ls "$ROOT"/saves/*/Slot.sav >/dev/null 2>&1 || return 1   # noch keine Welt
    local Last Stamp Dest Part F
    Last=$(backup_list | tail -n 1)
    if [ "$2" != "force" ] && [ -n "$Last" ] && [ -f "$Last/_mod/backup.txt" ] && [ -z "$(find "$ROOT/saves" \
        -name _backup -prune -o -type f -newer "$Last/_mod/backup.txt" -print 2>/dev/null | head -n 1)" ]; then
        echo "[start] Saves unchanged since backup ${Last##*/}: no new backup"
        return 1
    fi
    Stamp=$(date +%Y%m%d-%H%M%S)
    Dest="$BACKUP_DIR/$Stamp"
    [ -e "$Dest" ] && return 1
    Part="$Dest.part"
    rm -rf "$BACKUP_DIR"/*.part 2>/dev/null
    if ! mkdir -p "$Part/_mod" || ! printf 'reason=%s\ndate=%s\n' "$1" "$(date '+%Y-%m-%d %H:%M:%S')" > "$Part/_mod/backup.txt"; then
        echo "[start] WARNING: backup folder saves/_backup is not writable"
        rm -rf "$Part"
        return 1
    fi
    # Journal VOR saves/ kopieren: eine Sicherung im laufenden Betrieb haelt so nie Merker (#F/#S/#N) oder
    # owners.pending, die neuer sind als ihre Welt-Kopie (fehlt guest_journal.txt, gilt wie in Srv.ReadText das .bak)
    for F in $MOD_JOURNAL; do [ -f "$MOD/$F" ] && cp -p "$MOD/$F" "$Part/_mod/" 2>/dev/null; done
    [ ! -f "$MOD/guest_journal.txt" ] && [ -f "$MOD/guest_journal.txt.bak" ] && \
        cp -p "$MOD/guest_journal.txt.bak" "$Part/_mod/guest_journal.txt" 2>/dev/null
    if ! copy_tree "$ROOT/saves" "$Part" --exclude=./_backup --exclude='*.tmp' --exclude='*.crash'; then
        rm -rf "$Part"
        echo "[start] WARNING: backup failed ($1), disk full?"
        return 1
    fi
    for F in $MOD_STATE $MOD_LOGS; do [ -f "$MOD/$F" ] && cp -p "$MOD/$F" "$Part/_mod/" 2>/dev/null; done
    mv "$Part" "$Dest" || { rm -rf "$Part"; return 1; }
    backup_list | prune_dirs "$BACKUP_KEEP"
    echo "[start] Saves backed up ($1): saves/_backup/$Stamp (keeping the newest $BACKUP_KEEP)"
    return 0
}
# Wiederherstellen vor dem Spielstart: restore_req.txt im Mod-Ordner (der Mod bei srv_auto_restore=1, wenn der
# Spielstand nicht ladbar war) oder saves/_backup/restore.txt (von Hand anlegen). Inhalt: Zeitstempel einer Sicherung
# (z. B. 20261024-031500; gibt es den Namen nicht, wird nichts zurueckgespielt), leer die neueste - bei wiederholter
# Anforderung jeweils die naechst aeltere (last_restore.txt; nur bis der zurueckgespielte Stand 30 min laeuft oder eine
# Sicherung nach dem Speichern kommt, siehe Hauptschleife). Der bisherige Stand bleibt in
# saves/_backup/before-restore-<Zeit>/ (die 2 neuesten). Gast-Inventare und -Werte werden die zur Welt passenden
# *.commit, die Server-Dateien kommen aus _mod/ (owners.commit = owners.txt; Bans und Admin-Protokoll nie), das
# Gast-Journal ebenso (J.Rollback gleicht beim Start ab). Laeuft vor backup_saves: sonst verdraengte die Sicherung des
# kaputten Stands eine gute.
# Rueckgabe: 0 = zurueckgespielt oder nichts verlangt, 1 = nicht zurueckgespielt (Startsicherung wie sonst), 2 = keine
# Startsicherung, 3 = Spiel NICHT starten (saves/ unbrauchbar; Merker saves/_backup/restore_failed.txt bleibt, bis
# der Admin ihn loescht - auch ein Neustart durch das Panel startet so nie auf dem halben Stand).
restore_block() {   # $1 = Meldung; der Aufrufer gibt danach 3 zurueck
    echo "[start] ERROR: $1 - not starting. Check saves/ by hand, then delete saves/_backup/restore_failed.txt"
}
restore_saves() {
    local Req="" Want="" Src Last Keep F
    if [ -f "$BACKUP_DIR/restore_failed.txt" ]; then
        restore_block "an earlier restore failed ($(tr -d '\r\n' < "$BACKUP_DIR/restore_failed.txt" 2>/dev/null))"
        return 3
    fi
    for F in "$MOD/restore_req.txt" "$BACKUP_DIR/restore.txt"; do
        [ -f "$F" ] || continue
        Req="$F"
        Want=$(tr -d '\r\n[:space:]' < "$F" 2>/dev/null)
        rm -f "$F" "$F.bak"
        break
    done
    [ -n "$Req" ] || return 0
    # Von Hand verlangter Name, den es nicht (mehr) gibt (Tippfehler, schon verdraengt): nichts zurueckspielen statt
    # still eine andere Sicherung. Rueckgabe 2 = auch keine Startsicherung (sie verdraengte sonst die aelteste - evtl.
    # genau die gemeinte). Die Anforderung des Mods (restore_req.txt: "Datum Grund") nimmt weiter die neueste/naechst aeltere.
    if [ "$Req" = "$BACKUP_DIR/restore.txt" ] && [ -n "$Want" ] && \
        ! { [[ "$Want" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [ -d "$BACKUP_DIR/$Want" ]; }; then
        echo "[start] Restore requested: backup '$Want' not found in saves/_backup (available: $(backup_list | sed 's#.*/##' | tr '\n' ' ')) - nothing restored, no start backup"
        return 2
    fi
    if [[ "$Want" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [ -d "$BACKUP_DIR/$Want" ]; then
        Src="$BACKUP_DIR/$Want"
    else
        Last=""
        [ -f "$BACKUP_DIR/last_restore.txt" ] && Last=$(tr -d '\r\n[:space:]' < "$BACKUP_DIR/last_restore.txt")
        Src=$(backup_list | while IFS= read -r F; do
                  if [ -z "$Last" ] || [[ "${F##*/}" < "$Last" ]]; then echo "$F"; fi
              done | tail -n 1)
    fi
    if [ -z "$Src" ] || ! ls "$Src"/*/Slot.sav >/dev/null 2>&1; then
        echo "[start] Restore requested (${Req##*/}), but there is no usable backup in saves/_backup"
        return 1
    fi
    Keep="$BACKUP_DIR/before-restore-$(date +%Y%m%d-%H%M%S)"
    F=1
    while [ -e "$Keep" ]; do   # nie einen frueheren Stand ueberschreiben (zwei Wiederherstellungen in einer Sekunde)
        F=$((F + 1))
        Keep="$BACKUP_DIR/before-restore-$(date +%Y%m%d-%H%M%S)-$F"
    done
    if ! mkdir -p "$Keep/_mod" || ! copy_tree "$ROOT/saves" "$Keep" --exclude=./_backup; then
        echo "[start] Restore aborted: the current saves could not be kept (disk full?)"
        rm -rf "$Keep"
        return 1
    fi
    for F in $MOD_STATE $MOD_JOURNAL guest_journal.txt.bak; do
        [ -f "$MOD/$F" ] && cp -p "$MOD/$F" "$Keep/_mod/" 2>/dev/null
    done
    find "$ROOT/saves" -mindepth 1 -maxdepth 1 ! -name _backup -exec rm -rf {} +
    if ! copy_tree "$Src" "$ROOT/saves" --exclude=./_mod; then
        # Halb zurueckgespielt (voll/E/A-Fehler): $MOD ist bis hier unberuehrt -> nur saves/ auf den bewahrten Stand
        find "$ROOT/saves" -mindepth 1 -maxdepth 1 ! -name _backup -exec rm -rf {} +
        if copy_tree "$Keep" "$ROOT/saves" --exclude=./_mod; then
            rm -rf "$Keep"   # jetzt genaue Kopie von saves/: Platz frei machen (fehlender Platz war wohl der Grund)
            echo "[start] WARNING: restore from saves/_backup/${Src##*/} failed (disk full?) - previous saves put back, no start backup"
            return 2
        fi
        # Halben Rest weg (der bewahrte Stand liegt vollstaendig in $Keep): macht Platz fuer den Merker
        find "$ROOT/saves" -mindepth 1 -maxdepth 1 ! -name _backup -exec rm -rf {} +
        printf 'restore of %s failed, previous saves in saves/_backup/%s\n' "${Src##*/}" "${Keep##*/}" \
            > "$BACKUP_DIR/restore_failed.txt" || echo "[start] ERROR: saves/_backup/restore_failed.txt not writable"
        restore_block "restore failed and the previous saves could not be put back (they are in saves/_backup/${Keep##*/})"
        return 3
    fi
    # Zur Welt passende Kopien (Journal in server.lua): <Id>.commit = Inventar-Slot, <Id>.werte/.spawn.commit = Textdateien
    for F in "$ROOT"/saves/NetTest_Guests/*.commit; do
        [ -f "$F" ] || continue
        case "$F" in
            *.werte.commit|*.spawn.commit) cp -p "$F" "${F%.commit}.txt" ;;
            *) cp -p "$F" "${F%.commit}.sav" ;;
        esac
    done
    for F in $MOD_STATE; do [ -f "$Src/_mod/$F" ] && cp -p "$Src/_mod/$F" "$MOD/$F"; done
    [ -f "$Src/_mod/owners.commit" ] && cp -p "$Src/_mod/owners.commit" "$MOD/owners.txt"
    # Journale des ersetzten Stands weg (server.lua liest auch .bak): Gast-Slots und owners.txt passen schon zur Welt
    rm -f "$MOD/guest_journal.txt" "$MOD/guest_journal.txt.bak" "$MOD/guest_journal.txt.tmp" "$MOD/owners.pending" \
        "$MOD/owners.txt.bak"
    # Journal der Sicherung zuruecklegen (aeltere Sicherungen haben keins: dann wie bisher): server.lua J.Rollback
    # gleicht beim Start ab wie nach dem Absturz (.pending bei "#S" = "#F", Gaeste ohne .commit neu, "#N"), die
    # .commit-Kopie oben wiederholt es ohne Schaden. owners.pending nur zusammen mit dem Journal (ohne Journal laeuft
    # kein J.Rollback -> J.OwnRollback, das es auswertet: allein bliebe nur ein alter Stand liegen)
    if [ -f "$Src/_mod/guest_journal.txt" ]; then
        for F in $MOD_JOURNAL; do [ -f "$Src/_mod/$F" ] && cp -p "$Src/_mod/$F" "$MOD/$F"; done
        echo "[start] Guest journal of the backup put back: the mod matches the guest inventories to the world at start"
    fi
    printf '%s\n' "${Src##*/}" > "$BACKUP_DIR/last_restore.txt"
    ls -1d "$BACKUP_DIR"/before-restore-* 2>/dev/null | sort | prune_dirs 2
    echo "[start] Saves restored from saves/_backup/${Src##*/} (previous state kept in saves/_backup/${Keep##*/})"
    return 0
}
# Subshell mit trap '' INT TERM: ein Stop-Signal toetet kein cp/rm mittendrin (request_stop laeuft danach)
( trap '' INT TERM; restore_saves ); RESTORE_RC=$?
if [ "$RESTORE_RC" -eq 3 ]; then
    if [ -n "$XVFB_PID" ]; then kill -- -"$XVFB_PID" 2>/dev/null || kill "$XVFB_PID" 2>/dev/null; fi
    exit 1
fi
# Startsicherung nur nach sauberem Ende (server.lua schreibt server_stopped.txt bei stop/shutdown/Tagesneustart; weg
# erst direkt vor dem Spielstart) oder ohne jede Sicherung: nach Absturz/Kill kann Slot.sav halb geschrieben sein,
# die Sicherung davon verdraengte eine gute (bei LASTSIGNAL_BACKUPS=1 die einzige). Ein Merker mit "busy" (EMS meldete
# das Welt-Speichern beim Beenden nach 30 s nicht fertig, server.lua) zaehlt dafuer wie ein Absturz. Nie nach einem
# Restore-Namen, den es nicht gibt, oder nach gescheitertem Zurueckspielen (RESTORE_RC 2). LASTSIGNAL_BACKUPS=0:
# backup_saves tut nichts, keine irrefuehrende Meldung.
if [ "$RESTORE_RC" -eq 2 ]; then
    :
elif [ "$BACKUP_KEEP" -le 0 ] || [ -z "$(backup_list)" ] || \
    { [ -f "$MOD/server_stopped.txt" ] && ! grep -q busy "$MOD/server_stopped.txt" 2>/dev/null; }; then
    ( trap '' INT TERM; backup_saves "start" )
elif [ -f "$MOD/server_stopped.txt" ]; then
    echo "[start] Previous stop did not finish the world save: no start backup (the newest backup from a completed save stays)"
else
    echo "[start] Previous run did not end cleanly: no start backup (the newest backup from a completed save stays)"
fi

# UE4SS.log waechst auf einem Dauer-Server um zig MB am Tag (geloescht wird sie nur beim Start): stuendlich pruefen und
# ab 50 MB nach UE4SS.log.1 kopieren und kuerzen (tail -F folgt). Nur wenn das Spiel die Datei mit O_APPEND offen hat
# (/proc/<pid>/fdinfo), sonst schriebe es nach dem Kuerzen an der alten Stelle weiter (Datei voller Nullbytes).
LOG_ROTATE_KB=51200
LOG_ROTATE_WARNED=""
log_appends() {
    local Real F Fl Found=""
    Real=$(readlink -f "$LOG" 2>/dev/null) || return 1
    for F in /proc/"$GAME"/fd/*; do
        [ "$(readlink -f "$F" 2>/dev/null)" = "$Real" ] || continue
        Fl=$(sed -n 's/^flags:[[:space:]]*//p' "/proc/$GAME/fdinfo/${F##*/}" 2>/dev/null)
        [[ "$Fl" =~ ^[0-7]+$ ]] || return 1
        [ $(( 8#$Fl & 8#2000 )) -ne 0 ] || return 1
        Found=1
    done
    [ -n "$Found" ]
}
rotate_log() {
    local Kb
    [ -f "$LOG" ] || return 0
    Kb=$(du -k "$LOG" 2>/dev/null | cut -f1)
    [[ "$Kb" =~ ^[0-9]+$ ]] && [ "$Kb" -gt "$LOG_ROTATE_KB" ] || return 0
    if ! log_appends; then
        [ -z "$LOG_ROTATE_WARNED" ] && echo "[start] UE4SS.log has $((Kb / 1024)) MB, but the game does not append to it: not rotated (a restart clears it)"
        LOG_ROTATE_WARNED=1
        return 0
    fi
    cp -p "$LOG" "$LOG.1" 2>/dev/null && : > "$LOG" && echo "[start] UE4SS.log rotated at $((Kb / 1024)) MB (previous part: UE4SS.log.1)"
}

# server_cmd.work: Lese-Kopie des Mods (server.lua srv_cmd_rename) - ein Rest vom letzten Lauf darf kein altes "stop"
# ausfuehren. backup_req.txt: die Startsicherung ist eben gelaufen.
rm -f "$LOG" "$CMD_FILE" "$MOD/server_cmd.work" "$MOD/backup_req.txt" "$MOD/backup_req.txt.bak" \
    "$MOD/status.txt" "$MOD/master_listed.txt" "$MOD/server_stopping.txt"
if [ -n "$STOP_AT" ]; then
    echo "[start] Stop requested before the game started: not starting it"
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    exit 0
fi
# Merker "sauber beendet" erst direkt vor dem Spielstart weg: ein Lauf, der das Spiel gar nicht startet, laesst so den
# Merker des vorigen Laufs stehen (Startsicherung oben haengt daran)
rm -f "$MOD/server_stopped.txt"
echo "[start] Starting SurrounDead server on UDP port $PORT ..."
# Aus dem Spielordner starten: der Mod liest/schreibt relativ dazu (ue4ss/Mods/LastSignal/...)
( trap '' INT TERM
  cd "$WIN64" && own_session wine ./SurrounDead-Win64-Shipping.exe -nullrhi -nosound -unattended -nosteam \
      -nosplash -port="$PORT" >/dev/null 2>&1 ) &
GAME=$!
GAME_AT=$(date +%s)   # Hauptschleife: last_restore.txt weg, wenn der zurueckgespielte Stand 30 min laeuft
# Signal genau zwischen Start und GAME=$!: "shutdown" nachreichen (der Mod liest server_cmd.txt in jedem Zustand)
if [ -n "$STOP_AT" ] && [ -z "$STOP_SENT" ]; then
    printf 'shutdown\n' >> "$CMD_FILE"
    STOP_SENT=1
fi

# Mod-Log in die Konsole, sobald es da ist (eigene Sitzung: die letzten Zeilen beim Beenden kommen noch an)
( trap '' INT TERM
  for _ in $(seq 1 120); do [ -f "$LOG" ] && break; sleep 1; done
  own_session tail -n +1 -F "$LOG" 2>/dev/null ) &
TAIL=$!

# Master-Liste (Server-Liste im Spiel): alle 30 s anmelden, solange der Mod status.txt schreibt
# (nur im laufenden Spiel, nicht beim Laden oder Beenden). Nicht gelistet mit LASTSIGNAL_PUBLIC=0 oder leerer
# LASTSIGNAL_MASTER_URL (nicht gesetzt = oeffentliche Liste). Vom Passwort geht nur locked=1 an die Liste, nie
# das Passwort selbst. LASTSIGNAL_MASTER_KEY nur fuer private Master-Listen, die oeffentliche ist offen.
MASTER_URL="${LASTSIGNAL_MASTER_URL-https://update.tacticalhardline.com}"
MASTER_URL="${MASTER_URL//[[:space:]]/}"
PUBLIC="${LASTSIGNAL_PUBLIC:-1}"
PUBLIC="${PUBLIC//[[:space:]]/}"
case "${PUBLIC,,}" in 1|true|yes|on) ;; *) MASTER_URL="" ;; esac
STATUS_FILE="$MOD/status.txt"
LISTED_FILE="$MOD/master_listed.txt"   # da = mindestens einmal angemeldet, nur dann beim Beenden abmelden
master_call() {   # $1 = heartbeat oder bye
    [ -n "$MASTER_URL" ] || return 0
    local PLAYERS VERSION LOCKED=0
    PLAYERS=$(sed -n 's/^players=//p' "$STATUS_FILE" 2>/dev/null)
    VERSION=$(sed -n 's/^version=//p' "$STATUS_FILE" 2>/dev/null)
    [ -n "${LASTSIGNAL_PASSWORD:-}" ] && LOCKED=1
    local ARGS=(
        --data-urlencode "name=${LASTSIGNAL_NAME:-Last Signal Server}"
        --data-urlencode "desc=${LASTSIGNAL_DESCRIPTION:-}"
        --data-urlencode "port=$PORT"
        --data-urlencode "players=${PLAYERS:-0}"
        --data-urlencode "max=$(clamp_int "${LASTSIGNAL_MAX_PLAYERS:-8}" 8 1 64)"
        --data-urlencode "locked=$LOCKED"
        --data-urlencode "version=${VERSION:-}"
        --data-urlencode "host=${LASTSIGNAL_PUBLIC_ADDRESS:-${SERVER_IP:-}}"
    )
    [ -n "${LASTSIGNAL_MASTER_KEY:-}" ] && ARGS+=(--data-urlencode "key=$LASTSIGNAL_MASTER_KEY")
    curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "${MASTER_URL%/}/api/$1" "${ARGS[@]}" 2>/dev/null
}
BEAT=""
if [ -n "$MASTER_URL" ]; then
    ( LAST=""
      while kill -0 "$GAME" 2>/dev/null; do
          if [ -f "$STATUS_FILE" ]; then
              CODE=$(master_call heartbeat)
              case "$CODE" in 2??) : > "$LISTED_FILE" ;; esac
              # Nur Wechsel melden (ok <-> Fehler), nicht alle 30 s
              if [ "$CODE" != "$LAST" ]; then
                  case "$CODE" in
                      2??)    echo "[start] Listed in the server list ($MASTER_URL)" ;;
                      403)    echo "[start] Server list rejected the server: wrong key (LASTSIGNAL_MASTER_KEY)" ;;
                      4??)    echo "[start] Server list rejected the server (HTTP $CODE)" ;;
                      000|"") echo "[start] Server list not reachable (no answer), retrying" ;;
                      *)      echo "[start] Server list not reachable (HTTP $CODE), retrying" ;;
                  esac
                  LAST="$CODE"
              fi
          fi
          sleep 30
      done ) &
    BEAT=$!
else
    echo "[start] Not listed in the server list (LASTSIGNAL_PUBLIC=0 or no LASTSIGNAL_MASTER_URL)"
fi

# Hauptschleife: Konsole -> server_cmd.txt, Sicherung auf Anforderung, Log-Rotation, Frist beim Beenden
BACKUP_NEXT=0
LOG_CHECK_AT=$(( $(date +%s) + 3600 ))
while kill -0 "$GAME" 2>/dev/null; do
    read -r -t 1 LINE
    RC=$?
    if [ $RC -eq 0 ]; then
        case "$(printf '%s' "$LINE" | tr -d '[:space:]')" in
            stop|quit|shutdown) [ -z "$STOP_AT" ] && STOP_AT=$(date +%s); STOP_SENT=1 ;;
        esac
        printf '%s\n' "$LINE" >> "$CMD_FILE"
    elif [ $RC -le 128 ]; then
        sleep 1   # keine Konsole angeschlossen
    fi
    NOW=$(date +%s)
    # Stop vom Mod selbst (restart, taeglicher Neustart, Testbefehl shutdown): Frist wie bei Konsolen-stop, sonst haengt
    # ein Haenger beim Beenden ewig (Panel/Docker starten erst nach dem Ende neu). server_stopped.txt schreibt server.lua
    # direkt vor QuitGame; start.sh loescht sie vor dem Spielstart, es zaehlt also nur der Merker dieses Laufs.
    # server_stopping.txt (falls server.lua ihn bei Srv.Commands.stop schreibt) deckt einen Haenger schon davor ab.
    # Nicht status.txt nehmen: Core.WriteAtomic dreht sie alle 10 s ueber .bak, sie fehlt dabei kurz.
    if [ -z "$STOP_AT" ] && { [ -f "$MOD/server_stopped.txt" ] || [ -f "$MOD/server_stopping.txt" ]; }; then
        STOP_AT=$NOW
        STOP_SENT=1
        echo "[start] Mod stopped the server: waiting up to ${STOP_LIMIT} s for the game to exit"
    fi
    # Sicherung auf Anforderung des Mods (nach fertigem Festschreiben); hoechstens 1x pro Minute. Laeuft der Server
    # danach, ist eine fruehere automatische Wiederherstellung erledigt (last_restore.txt weg). Subshell mit trap '':
    # ein Stop-Signal toetet kein cp mittendrin (sonst gaelte eine Sicherung mit abgeschnittener Datei als gueltig).
    if [ -f "$MOD/backup_req.txt" ] && [ "$NOW" -ge "$BACKUP_NEXT" ]; then
        BACKUP_NEXT=$((NOW + 60))
        rm -f "$MOD/backup_req.txt" "$MOD/backup_req.txt.bak"
        ( trap '' INT TERM; backup_saves "after save" force ) && rm -f "$BACKUP_DIR/last_restore.txt"
    fi
    # Auch ohne Sicherung nach dem Speichern (LASTSIGNAL_BACKUP_MINUTES=0, srv_save_backup=0, kurze Laeufe): laeuft der
    # zurueckgespielte Stand 30 min (status.txt schreibt server.lua nur im Zustand "running", start.sh loescht sie vor
    # dem Spielstart), ist die Wiederherstellung erledigt - die naechste leere Anforderung nimmt wieder die neueste.
    # Ein Stand, der nicht laedt, erreicht "running" nie: der naechste Versuch nimmt weiter die naechst aeltere.
    if [ -f "$BACKUP_DIR/last_restore.txt" ] && [ -f "$STATUS_FILE" ] && [ $((NOW - GAME_AT)) -ge 1800 ]; then
        rm -f "$BACKUP_DIR/last_restore.txt" && \
            echo "[start] Restored world has been running for 30 min: the next empty restore.txt takes the newest backup again"
    fi
    if [ "$NOW" -ge "$LOG_CHECK_AT" ]; then
        LOG_CHECK_AT=$((NOW + 3600))
        rotate_log
    fi
    # Haengt das Beenden laenger als STOP_LIMIT s (Konsole 90 s, Signal LASTSIGNAL_STOP_WAIT, zweites Signal 0 s):
    # hart beenden (der letzte Save bleibt)
    if [ -n "$STOP_AT" ] && [ $(( NOW - STOP_AT )) -ge "$STOP_LIMIT" ]; then
        echo "[start] Server not responding, killing it"
        wineserver -k
        break
    fi
done
# Ein Signal unterbricht wait: weiter warten, bis das Spiel wirklich weg ist (sein Code zaehlt)
wait "$GAME" 2>/dev/null
CODE=$?
while kill -0 "$GAME" 2>/dev/null; do
    wait "$GAME" 2>/dev/null
    CODE=$?
done
sleep 2   # tail die letzten Zeilen ausgeben lassen
# tail und Xvfb ignorieren INT/TERM (eigene Sitzung): ganze Gruppe gezielt beenden
kill -KILL -- -"$TAIL" 2>/dev/null || kill -KILL "$TAIL" 2>/dev/null
# Sofort aus der Master-Liste austragen, aber nur wenn der Server dort angemeldet war
if [ -n "$BEAT" ]; then
    kill "$BEAT" 2>/dev/null
    [ -f "$LISTED_FILE" ] && master_call bye >/dev/null
fi
rm -f "$LISTED_FILE"
wineserver -k 2>/dev/null
if [ -n "$XVFB_PID" ]; then kill -- -"$XVFB_PID" 2>/dev/null || kill "$XVFB_PID" 2>/dev/null; fi
echo "[start] Server stopped (code $CODE)"
[ -n "$STOP_AT" ] && exit 0
[ -f "$MOD/server_stopped.txt" ] && exit 0   # "stop" kam auf anderem Weg (z. B. Datei), Mod hat gespeichert
# Von selbst beendet (Absturz oder Startfehler): Fehlercode, damit Pterodactyl neu startet
[ "$CODE" -eq 0 ] && CODE=1
exit "$CODE"
