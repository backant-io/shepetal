; Per-user installer for shepetal.exe (Inno Setup 6). No admin rights: it installs to
; %LOCALAPPDATA%\Programs\Shepetal, adds a Start menu entry and, as a task that is on by default,
; starts Shepetal at sign-in. The uninstaller removes what setup installed, the Run value and the
; downloaded speech models, and keeps the recordings in %LOCALAPPDATA%\Shepetal (goal rule 4).
;
; Build after `cargo build --release`, from windows/:
;   ISCC.exe /DAppVersion=0.1.0 installer\shepetal.iss   ->  target\installer\shepetal-setup-0.1.0.exe
; installer\test-install.ps1 installs it silently, checks it, uninstalls it and checks the recordings.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
; The same names as windows/crates/app/src/system.rs (a test there checks them).
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
#define RunValue "Shepetal"

[Setup]
AppId={{7AE361D0-2D5F-4C5F-99A5-FD0F5BA42B9A}
AppName=Shepetal
AppVersion={#AppVersion}
AppPublisher=BackAnt
AppPublisherURL=https://github.com/backant-io/shepetal
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Shepetal
DisableDirPage=yes
DisableProgramGroupPage=yes
; Setup and the uninstaller ask the user to quit a running Shepetal first.
AppMutex=Shepetal.SingleInstance
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\shepetal.exe
OutputDir=..\target\installer
OutputBaseFilename=shepetal-setup-{#AppVersion}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Tasks]
Name: startup; Description: "Start Shepetal when I sign in"

[Files]
Source: "..\target\release\shepetal.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Shepetal"; Filename: "{app}\shepetal.exe"

[Registry]
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#RunValue}"; ValueData: """{app}\shepetal.exe"""; Tasks: startup

[Run]
Filename: "{app}\shepetal.exe"; Description: "Start Shepetal now"; Flags: nowait postinstall skipifsilent

; The speech models are downloaded, not the user's, and up to 574 MB. The recordings stay.
[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Shepetal\models"

[Code]
// The tray's start-at-login toggle writes the same value, so remove it whether or not the task ran.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, '{#RunKey}', '{#RunValue}');
end;
