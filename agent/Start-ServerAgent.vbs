' CarrierGUI server agent — windowless launcher (run on the DCS server box).
' Pushes the live recovery snapshot to the relay and pulls commands back.
' Uses the bundled Python next to this file.  Auto-start it with your server.
Dim sh, fso, base
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = base
If Not fso.FileExists(base & "\carriergui_agent.json") Then
    MsgBox "Run Install-Server.ps1 first (it writes carriergui_agent.json).", 48, "CarrierGUI"
    WScript.Quit
End If
sh.Run """" & base & "\python\pythonw.exe"" """ & base & "\carriergui_serveragent.py""", 0, False
