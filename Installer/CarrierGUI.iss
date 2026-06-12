; CarrierGUI installer (Inno Setup 6.7+)
;
; Compile with:  ISCC.exe Installer\CarrierGUI.iss
; Output:        dist\CarrierGUI-Setup-vX.Y.exe
;
; Source files are pulled from dist\CarrierGUI-v{#MyAppVersion}\  — that
; folder is produced by Tools\build_release.py and already contains the
; Hooks\, Patcher\ (incl. python\), and LSO\ subtrees ready to ship.

#define MyAppName        "CarrierGUI"
#define MyAppVersion     "1.3-beta5"
#define MyAppPublisher   "ExpertFett"
#define MyAppURL         "https://github.com/ExpertFett/CarrierGUI"
#define MyAppExeBase     "CarrierGUI-Setup-v" + MyAppVersion
#define SrcStaging       "..\dist\CarrierGUI-v" + MyAppVersion

[Setup]
AppId={{4F6A2C50-8C9A-4F3F-B7E0-CARRIERGUI001}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=no
OutputDir=..\dist
OutputBaseFilename={#MyAppExeBase}
SetupIconFile=
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
; PER-USER install by default — no admin UAC for the install itself. Under
; this mode {autopf} resolves to %LOCALAPPDATA%\Programs and {userdocs} ->
; the actual user's Documents (not the admin's). The LSO Tools patch step
; (which writes into Program Files\Eagle Dynamics\) self-elevates via UAC
; when it actually runs — that's the only point that needs admin.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayName={#MyAppName} v{#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "full";    Description: "Full install (recommended)"
Name: "custom";  Description: "Custom"; Flags: iscustom

[Components]
Name: "hook";    Description: "GUI panel  (Ctrl+Shift+c)";                  Types: full custom; Flags: fixed
Name: "patcher"; Description: "Mission patcher  (drag .miz to embed bridge)"; Types: full custom
Name: "lso";     Description: "LSO Tools  (NVG dial, foul deck, wire, zoom — patches DCS shader)"; Types: full custom

[Tasks]
Name: "runlso";  Description: "Apply LSO tools patch right now (recommended). Will prompt UAC."; \
                 GroupDescription: "After install:"; Components: lso; Flags: checkedonce
Name: "deskicon";Description: "Create a desktop shortcut to the patcher folder";              \
                 GroupDescription: "Shortcuts:"; Flags: unchecked

[Dirs]
; Make sure the per-user Saved Games\DCS\Scripts\Hooks tree exists.
Name: "{%USERPROFILE}\Saved Games\DCS\Scripts\Hooks"

[Files]
; ---- Hook files: into Saved Games (per-user) -----------------------------
Source: "{#SrcStaging}\Hooks\carrier-gui-hook.lua";   DestDir: "{%USERPROFILE}\Saved Games\DCS\Scripts\Hooks"; Components: hook; Flags: ignoreversion
Source: "{#SrcStaging}\Hooks\carrier-gui.dlg";        DestDir: "{%USERPROFILE}\Saved Games\DCS\Scripts\Hooks"; Components: hook; Flags: ignoreversion

; ---- Patcher (incl. bundled Python) into Program Files -------------------
Source: "{#SrcStaging}\Patcher\*";                    DestDir: "{app}\Patcher"; Components: patcher; Flags: ignoreversion recursesubdirs createallsubdirs

; ---- LSO Tools scripts ---------------------------------------------------
Source: "{#SrcStaging}\LSO\*";                        DestDir: "{app}\LSO";     Components: lso;     Flags: ignoreversion recursesubdirs

; ---- Docs ----------------------------------------------------------------
Source: "{#SrcStaging}\README.txt";                   DestDir: "{app}";         Flags: ignoreversion isreadme

[Icons]
Name: "{group}\Patcher folder";          Filename: "{app}\Patcher";       Components: patcher
Name: "{group}\LSO Tools folder";        Filename: "{app}\LSO";           Components: lso
Name: "{group}\README";                  Filename: "{app}\README.txt"
Name: "{group}\Uninstall {#MyAppName}";  Filename: "{uninstallexe}"
Name: "{autodesktop}\CarrierGUI Patcher"; Filename: "{app}\Patcher";      Tasks: deskicon

[Run]
; Optional post-install: run Enable-LsoTools to apply the gui.fx + PLATCameraUI patches.
; PowerShell self-elevates internally, so we just call it.
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\LSO\Enable-LsoTools.ps1"""; \
    StatusMsg: "Applying LSO tools patch (gui.fx + PLATCameraUI)..."; \
    Flags: postinstall waituntilterminated; \
    Tasks: runlso

[UninstallDelete]
; Sweep the Hooks files out on uninstall (they live outside {app}).
Type: files; Name: "{%USERPROFILE}\Saved Games\DCS\Scripts\Hooks\carrier-gui-hook.lua"
Type: files; Name: "{%USERPROFILE}\Saved Games\DCS\Scripts\Hooks\carrier-gui.dlg"

[Code]
function InitializeSetup(): Boolean;
begin
  // Soft warning panel — clearer than silent failure later. We can't reliably
  // detect a running DCS from here (Exec doesn't capture stdout) so we ask
  // the user to confirm + close DCS first.
  Result := MsgBox(
    'CarrierGUI installer' + #13#10 + #13#10 +
    'Before continuing:' + #13#10 +
    '  - Close DCS World if it is running.' + #13#10 +
    '  - The LSO Tools component patches a core DCS shader,' + #13#10 +
    '    which causes DCS to fail multiplayer integrity check.' + #13#10 +
    '    Single-player / IC-disabled servers only.' + #13#10 + #13#10 +
    'Continue?',
    mbConfirmation, MB_YESNO) = IDYES;
end;
