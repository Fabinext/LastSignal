# Building

Only needed if you want to understand how the release is made. Using the release does not require any of this.

## Native helper (`core/LastSignalCore.cpp`)

Built with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw):

```
x86_64-w64-mingw32-clang++ -std=c++17 -O2 -D_WIN32_WINNT=0x0A00 -shared -static -s -o LastSignalCore.dll LastSignalCore.cpp -lpsapi -lwinhttp -liphlpapi -lws2_32
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
         └─ Scripts/main.lua
```

Put `payload.zip` next to `Installer.cs` and run `build.cmd`.

UE4SS: [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v3.0.1 Beta.
