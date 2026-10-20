@echo off
rem Builds LastSignal-Installer.exe from Installer.cs and payload.zip (see BUILDING.md)
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
set FW=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319
cd /d "%~dp0"
"%CSC%" /nologo /target:winexe /optimize+ /out:LastSignal-Installer.exe ^
  /reference:"%FW%\System.IO.Compression.dll" /reference:"%FW%\System.IO.Compression.FileSystem.dll" ^
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll ^
  /resource:payload.zip,payload.zip ^
  Installer.cs
