' CarrierGUI Olympus agent - windowless launcher.
' Double-click to start (runs hidden, pulls the picture from Olympus, feeds the panel).
Dim sh, fso, base
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = base
If Not fso.FileExists(base & "\carriergui_olympus.json") Then
    MsgBox "Run Setup-Olympus.bat first (enter your Olympus host + password).", 48, "CarrierGUI"
    WScript.Quit
End If
sh.Run """" & base & "\python\pythonw.exe"" """ & base & "\carriergui_olympus.py""", 0, False
