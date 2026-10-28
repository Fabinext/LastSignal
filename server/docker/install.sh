#!/bin/bash
# Installs SurrounDead (Windows build, branch STEAM_BETA, default experimental = 0.8 / UE 5.6) via SteamCMD into
# /mnt/server and unpacks the Last Signal server package. Same steps as the Pterodactyl egg.
set -e
apt-get update -qq
apt-get install -y -qq curl ca-certificates lib32gcc-s1 tar >/dev/null
mkdir -p /mnt/server /mnt/server/saves
cd /mnt/server
if [ -n "${STEAM_USER}" ]; then
    mkdir -p /tmp/steamcmd
    curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /tmp/steamcmd
    /tmp/steamcmd/steamcmd.sh +@sSteamCmdForcePlatformType windows +force_install_dir /mnt/server \
        +login "${STEAM_USER}" "${STEAM_PASS}" ${STEAM_AUTH} \
        +app_update 1645820 ${STEAM_BETA:+-beta ${STEAM_BETA}} validate +quit
else
    echo "STEAM_USER not set: copy the SurrounDead game files (SurrounDead/ and Engine/) into ./data yourself."
fi
if [ -f /mnt/LastSignal-Server.tar.gz ]; then
    tar -xzf /mnt/LastSignal-Server.tar.gz -C /mnt/server
else
    echo "LastSignal-Server.tar.gz not found next to docker-compose.yml"
fi
if [ ! -f /mnt/server/server.cfg ] && [ -f /mnt/server/server.cfg.example ]; then
    cp /mnt/server/server.cfg.example /mnt/server/server.cfg
fi
chown -R 1000:1000 /mnt/server      # the wine image runs as user "container" (uid 1000)
echo "Installation complete. Edit data/server.cfg, then: docker compose up -d server"
