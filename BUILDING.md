# Building

Only needed if you want to understand how the release is made. Using the release does not require any of this.

## Native helper (`core/LastSignalCore.cpp`)

Built with MSVC (Visual Studio Build Tools, x64 Native Tools prompt):

```
cl /nologo /std:c++17 /O2 /EHa /MT /LD /W3 /D_WIN32_WINNT=0x0A00 /D_CRT_SECURE_NO_WARNINGS /DWIN32_LEAN_AND_MEAN LastSignalCore.cpp /link psapi.lib winhttp.lib iphlpapi.lib ws2_32.lib /OUT:LastSignalCore.dll
```

## Installer (`installer/`)

The installer is a single C# file compiled with the C# compiler that ships with Windows (.NET Framework 4,
`csc.exe`). It embeds `payload.zip`, which contains the files that are copied into `SurrounDead\Binaries\Win64`:

```
payload.zip
├─ dwmapi.dll                      (UE4SS loader)
└─ ue4ss/
   ├─ UE4SS.dll, UE4SS-settings.ini, LICENSE, ...
   └─ Mods/
      ├─ mods.txt, mods.json, (UE4SS default mods)
      └─ LastSignal/
         ├─ enabled.txt, coop.txt
         ├─ LastSignalCore.dll
         └─ Scripts/main.lua, server.lua, ls_*.lua (modules)
```

Put `payload.zip` next to `Installer.cs` and run `build.cmd`.

## Dedicated server (`server/`)

`LastSignal-Server.tar.gz` contains the same `ue4ss/` folder plus `start.sh`, `server.cfg.example` and `SERVER.md`.
Hosting: Pterodactyl egg (`server/egg-surroundead-lastsignal.json`) or Docker Compose (`server/docker/`), see `server/SERVER.md`.

UE4SS: [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v3.0.1 Beta.
