; DevKit installer. Build with tool/build_installer.ps1 (it passes AppVersion from pubspec.yaml).

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "Flutter DevKit"
#define AppExe "devkit.exe"
#define Root "..\.."

[Setup]
AppId={{8C1E5B3A-6F0D-4C7E-9B52-2D7A1F4E9C10}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=DevKit
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Upgrades keep their folder, but the Start menu entry should carry the new name.
UsePreviousGroup=no
; Per-user by default so teammates can install without admin rights.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#Root}\dist
OutputBaseFilename=DevKit-Setup
SetupIconFile={#Root}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
WizardImageFile=wizard-1x.bmp,wizard-2x.bmp
WizardSmallImageFile=wizard-small-1x.bmp,wizard-small-2x.bmp
Compression=lzma2/ultra64
SolidCompression=yes
; A running DevKit and its adb/scrcpy lock files during upgrades.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "Start {#AppName} when Windows starts"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

; Leftovers from when the app had its previous name.
[InstallDelete]
Type: files; Name: "{app}\ravo_devkit.exe"
Type: filesandordirs; Name: "{autoprograms}\Ravo DevKit"
Type: filesandordirs; Name: "{autoprograms}\DevKit"
Type: files; Name: "{autodesktop}\DevKit.lnk"
Type: files; Name: "{autodesktop}\Ravo DevKit.lnk"
Type: files; Name: "{userstartup}\Ravo DevKit.lnk"

[Files]
Source: "{#Root}\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#AppExe}"; Flags: runhidden; RunOnceId: "KillDevKit"
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im scrcpy.exe"; Flags: runhidden; RunOnceId: "KillScrcpy"
