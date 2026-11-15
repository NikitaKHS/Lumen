;=====================================================================
; Автозапуск с Windows
;=====================================================================
; С правами администратора — задача планировщика «Lumen» с наивысшими
; правами: запускается при входе без окна UAC. Без прав — ключ Run в HKCU
; (тогда при входе Windows спросит UAC, если RunAsAdmin=1).
global RUN_KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"

AutostartCommand() {
    if A_IsCompiled
        return {exe: A_ScriptFullPath, args: "--tray"}
    return {exe: A_AhkPath, args: '"' A_ScriptFullPath '" --tray'}
}

AutostartIsOn() {
    try {
        if RunWait('schtasks.exe /Query /TN "Lumen"', , "Hide") = 0
            return true
    }
    try {
        return RegRead(RUN_KEY, "Lumen") != ""
    }
    return false
}

SetAutostart(on) {
    if !on {
        try RunWait('schtasks.exe /Delete /TN "Lumen" /F', , "Hide")
        try RegDelete(RUN_KEY, "Lumen")
        return true
    }
    cmd := AutostartCommand()
    if A_IsAdmin {
        x(s) => StrReplace(StrReplace(StrReplace(StrReplace(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"), '"', "&quot;")
        user := EnvGet("USERDOMAIN") "\" A_UserName
        xml := '<?xml version="1.0" encoding="UTF-16"?>`n'
            . '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">`n'
            . '  <RegistrationInfo><Description>Lumen — режимы освещённости для игр</Description></RegistrationInfo>`n'
            . '  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>' x(user) '</UserId><Delay>PT5S</Delay></LogonTrigger></Triggers>`n'
            . '  <Principals><Principal id="Author"><UserId>' x(user) '</UserId><LogonType>InteractiveToken</LogonType>'
            . '<RunLevel>HighestAvailable</RunLevel></Principal></Principals>`n'
            . '  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
            . '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
            . '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>6</Priority></Settings>`n'
            . '  <Actions Context="Author"><Exec><Command>' x(cmd.exe) '</Command><Arguments>' x(cmd.args) '</Arguments>'
            . '<WorkingDirectory>' x(A_ScriptDir) '</WorkingDirectory></Exec></Actions>`n'
            . '</Task>`n'
        tmp := A_Temp "\lumen_task.xml"
        try FileDelete(tmp)
        FileAppend(xml, tmp, "UTF-16")
        r := RunWait('schtasks.exe /Create /TN "Lumen" /XML "' tmp '" /F', , "Hide")
        try FileDelete(tmp)
        if r = 0 {
            try RegDelete(RUN_KEY, "Lumen")
            return true
        }
    }
    try {
        RegWrite('"' cmd.exe '" ' cmd.args, "REG_SZ", RUN_KEY, "Lumen")
        return true
    }
    return false
}
