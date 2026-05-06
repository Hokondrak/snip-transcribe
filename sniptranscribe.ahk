/*
    SnipTranscribe — AutoHotkey v2 Hotkey Launcher
    
    Registers a global hotkey (default: Ctrl+Shift+T) that:
    1. Triggers the Windows Snipping Tool (Win+Shift+S)
    2. Launches the Python transcription worker in the background
    
    This script is the ONLY persistent background process. Python spawns
    on-demand and exits after each transcription (~2 MB RAM idle).
*/

#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ---------------------------------------------------------------------------
; Resolve paths
; ---------------------------------------------------------------------------
ScriptDir := A_ScriptDir
ConfigPath := ""
PythonScript := ScriptDir "\transcribe.py"

; Check for config in %APPDATA%\sniptranscribe first, then script dir
AppDataConfig := EnvGet("APPDATA") "\sniptranscribe\config.toml"
LocalConfig := ScriptDir "\config.toml"

if FileExist(AppDataConfig)
    ConfigPath := AppDataConfig
else if FileExist(LocalConfig)
    ConfigPath := LocalConfig

; ---------------------------------------------------------------------------
; Parse hotkey from config.toml
; ---------------------------------------------------------------------------
HotkeyBinding := "^+t"  ; Default: Ctrl+Shift+T

if (ConfigPath != "") {
    try {
        ConfigText := FileRead(ConfigPath)
        ; Extract binding value from [hotkey] section
        if RegExMatch(ConfigText, 'im)^\s*binding\s*=\s*"([^"]+)"', &match) {
            RawBinding := match[1]
            HotkeyBinding := ConvertBinding(RawBinding)
        }
    }
}

; ---------------------------------------------------------------------------
; Convert human-readable binding to AHK hotkey syntax
; ---------------------------------------------------------------------------
ConvertBinding(binding) {
    result := ""
    binding := Trim(binding)
    
    ; Split on + and process each part
    parts := StrSplit(binding, "+")
    
    for part in parts {
        part := Trim(part)
        lower := StrLower(part)
        
        switch lower {
            case "ctrl", "control":
                result .= "^"
            case "shift":
                result .= "+"
            case "alt":
                result .= "!"
            case "win":
                result .= "#"
            default:
                ; Final key — convert to lowercase for AHK
                result .= StrLower(part)
        }
    }
    
    return result
}

; ---------------------------------------------------------------------------
; Ensure Ollama is running (silent, no console window)
; ---------------------------------------------------------------------------
try {
    ; Check if Ollama is already running by looking for its process
    if !ProcessExist("ollama.exe") {
        Run("ollama serve", , "Hide")
        ; Give it a moment to start up
        Sleep(1000)
    }
}

; ---------------------------------------------------------------------------
; Register the hotkey
; ---------------------------------------------------------------------------
Hotkey(HotkeyBinding, TriggerTranscription)

; Show a brief tooltip on startup so user knows the script is active
ToolTip("SnipTranscribe ready: " HotkeyBinding)
SetTimer(() => ToolTip(), -2000)

; ---------------------------------------------------------------------------
; Hotkey handler
; ---------------------------------------------------------------------------
TriggerTranscription(*) {
    ; Step 1: Trigger Windows Snipping Tool
    Send("#+s")
    
    ; Step 2: Small delay to let the snipping overlay appear
    Sleep(300)
    
    ; Step 3: Launch the Python worker in the background (no console window)
    ; Using pythonw.exe so no cmd window flashes
    try {
        Run('pythonw.exe "' PythonScript '"', ScriptDir, "Hide")
    } catch as err {
        ; Fallback: try python.exe if pythonw.exe is not found
        try {
            Run('python.exe "' PythonScript '"', ScriptDir, "Hide")
        } catch as err2 {
            MsgBox("Could not launch Python.`n`nEnsure python is in your PATH.`n`nError: " err2.Message, "SnipTranscribe Error", "Icon!")
        }
    }
}
