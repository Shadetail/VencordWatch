; VencordWatch.ahk - alerts when a Discord update has silently removed the Vencord patch,
; and offers a one-click repair through Vencord's official CLI installer.
;
; Detection: Vencord's installer renames Discord's resources\app.asar to _app.asar and drops
; in a tiny stub app.asar. A Discord update installs into a fresh app-<version> folder with a
; stock app.asar, so "newest app-* folder has no _app.asar" means Vencord is gone.
;
; Repair downloads the latest VencordInstallerCli.exe (cached in %LOCALAPPDATA%\VencordWatch,
; the cached copy is used when offline), runs it with -install (which closes Discord and pulls
; the latest Vencord build), then relaunches Discord if it was running.
;
; Switches: --root <dir>  Discord install to watch (default %LOCALAPPDATA%\Discord; e.g.
;                         %LOCALAPPDATA%\DiscordPTB or ...\DiscordCanary, or a fake folder for tests)
;           --poll <ms>   poll interval (default 60000)
;           --dryrun      Repair logs the command instead of running it
;           --demo        show the alert immediately, no polling (implies --dryrun)
; Run test instances from a copy at another path, or #SingleInstance Force replaces the live one.

#NoEnv
#Persistent
#SingleInstance Force
SetWorkingDir %A_ScriptDir%
FileEncoding, UTF-8-RAW

EnvGet, LocalAppData, LOCALAPPDATA
global DiscordRoot := LocalAppData "\Discord"
global CliPath := LocalAppData "\VencordWatch\VencordInstallerCli.exe"
global CliUrl := "https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe"
global LogFile := A_ScriptDir "\VencordWatch.log"
global StartupLink := A_Startup "\VencordWatch.lnk"
global PollMs := 60000
global ConfirmPolls := 2                 ; unpatched must persist this many polls (skips mid-update states)
global SnoozeMs := 2 * 60 * 60 * 1000    ; "Later" hides the alert for 2 h
global DryRun := false, Demo := false
global UnpatchedCount := 0, AlertShown := false, SnoozeUntil := 0, Repairing := false
global AlertText, RepairBtn, LaterBtn    ; Gui control vars must be global

i := 1
while (i <= A_Args.Length()) {
    arg := A_Args[i]
    if (arg = "--root")
        DiscordRoot := A_Args[++i]
    else if (arg = "--poll")
        PollMs := A_Args[++i] + 0
    else if (arg = "--dryrun")
        DryRun := true
    else if (arg = "--demo") {
        Demo := true
        DryRun := true
    }
    i++
}
SplitPath, DiscordRoot, rootName
global DiscordExe := rootName ".exe"     ; Discord.exe, DiscordPTB.exe, DiscordCanary.exe

Menu, Tray, NoStandard
Menu, Tray, Add, Check now, MenuCheck
Menu, Tray, Add, Repair Vencord now, MenuRepair
Menu, Tray, Add, Start with Windows, MenuStartup
Menu, Tray, Add, Open log, MenuLog
Menu, Tray, Add
Menu, Tray, Add, Reload, MenuReload
Menu, Tray, Add, Exit, MenuExit
Menu, Tray, Tip, VencordWatch
if FileExist(StartupLink)
    Menu, Tray, Check, Start with Windows
else if (!Demo)
    TrayTip, VencordWatch, % "Watching " DiscordRoot " for Discord updates that remove Vencord.`n"
        . "Right-click the tray icon to turn on Start with Windows."

Log("started, watching " DiscordRoot (DryRun ? " (dry run)" : ""))
if (Demo) {
    ShowAlert(DiscordRoot "\app-1.0.9999")
    return
}
SetTimer, CheckPatch, %PollMs%
Gosub, CheckPatch
return

CheckPatch:
    if (Repairing)
        return
    state := PatchState(appDir)
    if (state = "patched") {
        if (UnpatchedCount >= ConfirmPolls)
            Log("Vencord patch present again in " appDir)
        UnpatchedCount := 0
        SnoozeUntil := 0
        HideAlert()
    } else if (state = "unpatched") {
        UnpatchedCount++
        if (UnpatchedCount = ConfirmPolls)
            Log("Vencord patch missing in " appDir)
        if (UnpatchedCount >= ConfirmPolls && !AlertShown && A_TickCount >= SnoozeUntil)
            ShowAlert(appDir)
    }
    return

; "patched", "unpatched", or "" when there is nothing to judge (no Discord, update in progress).
PatchState(ByRef appDir) {
    appDir := NewestAppDir()
    if (appDir = "")
        return ""
    res := appDir "\resources"
    if FileExist(res "\_app.asar")
        return "patched"
    if FileExist(res "\app.asar")
        return "unpatched"
    return ""
}

; Newest app-<version> folder by numeric version, "" if none. Keys are "v"-prefixed so AHK
; compares them as strings (all-digit keys would be compared as overflowing numbers).
NewestAppDir() {
    best := "", bestKey := ""
    Loop, Files, %DiscordRoot%\app-*, D
    {
        key := "v"
        for _, part in StrSplit(SubStr(A_LoopFileName, 5), ".")
            key .= Format("{:08d}", part + 0)
        if (key > bestKey) {
            best := A_LoopFileFullPath
            bestKey := key
        }
    }
    return best
}

ShowAlert(appDir) {
    SplitPath, appDir, appName
    Gui, Alert:New, +AlwaysOnTop -MinimizeBox, VencordWatch
    Gui, Alert:Font, s10, Segoe UI
    Gui, Alert:Add, Picture, x16 y16 w32 h32 Icon2, user32.dll
    Gui, Alert:Add, Text, x64 y16 w400 vAlertText
        , % "Discord updated (" appName ") and Vencord is no longer installed.`n`n"
        . "Repair reinstalls it with the latest Vencord installer. Discord closes and restarts, "
        . "so don't click it mid-call."
    Gui, Alert:Add, Button, x64 y+16 w180 h30 vRepairBtn gAlertRepair, Repair now
    Gui, Alert:Add, Button, x+10 w100 h30 vLaterBtn gAlertLater, Later
    Gui, Alert:Show, NoActivate AutoSize, VencordWatch
    AlertShown := true
    SoundPlay, *48
}

HideAlert() {
    if (AlertShown) {
        Gui, Alert:Destroy
        AlertShown := false
    }
}

AlertRepair:
    Repair()
    return

AlertLater:
AlertGuiClose:
AlertGuiEscape:
    SnoozeUntil := A_TickCount + SnoozeMs
    HideAlert()
    Log("alert snoozed for 2 h")
    return

Repair() {
    if (Repairing)
        return
    Repairing := true
    SetAlertText("Repairing... (downloading the latest Vencord installer)", false)
    ok := RunRepair(msg)
    Log(msg)
    Repairing := false
    if (ok) {
        UnpatchedCount := 0
        SnoozeUntil := 0
        if (AlertShown) {
            SetAlertText(msg, false)
            SetTimer, HideAlertLater, -5000
        } else
            TrayTip, VencordWatch, %msg%
    } else {
        if (AlertShown)
            SetAlertText(msg, true)
        else
            TrayTip, VencordWatch, %msg%, , 3
    }
}

HideAlertLater:
    HideAlert()
    return

SetAlertText(text, buttonsEnabled) {
    if (!AlertShown)
        return
    GuiControl, Alert:, AlertText, %text%
    GuiControl, % "Alert:" (buttonsEnabled ? "Enable" : "Disable"), RepairBtn
    GuiControl, % "Alert:" (buttonsEnabled ? "Enable" : "Disable"), LaterBtn
}

RunRepair(ByRef msg) {
    ; Refresh the CLI from the latest release; keep the cached copy if the download fails.
    SplitPath, CliPath, , cliDir
    FileCreateDir, %cliDir%
    tmp := CliPath ".download"
    UrlDownloadToFile, %CliUrl%, %tmp%
    if (!ErrorLevel) {
        FileGetSize, size, %tmp%
        if (size > 1000000)
            FileMove, %tmp%, %CliPath%, 1
    }
    FileDelete, %tmp%
    if !FileExist(CliPath) {
        msg := "Repair failed: couldn't download VencordInstallerCli.exe (offline?)"
        return false
    }

    cmd := """" CliPath """ -install -location """ DiscordRoot """"
    if (DryRun) {
        msg := "Dry run, would run: " cmd
        return false
    }
    Process, Exist, %DiscordExe%
    wasRunning := ErrorLevel
    Log("running: " cmd)
    Run, %ComSpec% /c "%cmd% >> "%LogFile%" 2>&1", , Hide UseErrorLevel, pid
    if (ErrorLevel = "ERROR") {
        msg := "Repair failed: couldn't start the installer"
        return false
    }
    Process, WaitClose, %pid%, 180
    if (ErrorLevel) {
        msg := "Repair failed: installer still running after 3 min (see log)"
        return false
    }
    if (PatchState(appDir) != "patched") {
        msg := "Repair failed: Discord still unpatched after the installer ran (see log)"
        return false
    }
    if (wasRunning) {
        Process, Exist, %DiscordExe%
        if (!ErrorLevel)
            Run, "%DiscordRoot%\Update.exe" --processStart %DiscordExe%, , UseErrorLevel
    }
    msg := "Vencord reinstalled" (wasRunning ? ", Discord is restarting." : ".")
    return true
}

Log(msg) {
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    FileAppend, %ts%  %msg%`n, %LogFile%
}

MenuCheck:
    state := PatchState(appDir)
    SplitPath, appDir, appName
    TrayTip, VencordWatch, % (state = "patched" ? "Vencord is installed" : state = "unpatched" ? "Vencord is NOT installed" : "No Discord install found") (appName != "" ? " (" appName ")" : "")
    return

MenuRepair:
    Repair()
    return

; The shortcut carries --root along, so a PTB/Canary watcher restarts as one.
MenuStartup:
    if FileExist(StartupLink) {
        FileDelete, %StartupLink%
        Menu, Tray, Uncheck, Start with Windows
    } else {
        EnvGet, LocalAppData, LOCALAPPDATA
        args := (DiscordRoot != LocalAppData "\Discord") ? "--root """ DiscordRoot """" : ""
        FileCreateShortcut, %A_ScriptFullPath%, %StartupLink%, %A_ScriptDir%, %args%
        Menu, Tray, Check, Start with Windows
    }
    return

MenuLog:
    Run, notepad.exe "%LogFile%"
    return

MenuReload:
    Reload
    return

MenuExit:
    ExitApp
