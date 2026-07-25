' CarrierGUI controller agent — windowless launcher.
' Double-click to start the agent (it runs hidden in the background and bridges
' the relay to your in-DCS panel).  Uses the bundled Python, so nothing to install.
Dim sh, fso, base
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = base
If Not fso.FileExists(base & "\carriergui_agent.json") Then
    MsgBox "Run Setup.bat first to enter your squad's relay URL / token / server ID.", 48, "CarrierGUI"
    WScript.Quit
End If
' 0 = hidden window, False = don't wait
sh.Run """" & base & "\python\pythonw.exe"" """ & base & "\carriergui_controller.py""", 0, False
