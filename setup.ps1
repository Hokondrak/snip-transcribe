<#
.SYNOPSIS
    SnipTranscribe — Full Cold-Start Setup Script
    
.DESCRIPTION
    Bootstraps a machine from zero to fully running SnipTranscribe.
    Each step is idempotent — safe to re-run at any time.
    
    Steps:
    1. Python 3.11+
    2. Pip dependencies  
    3. Ollama
    4. glm-ocr model pull
    5. Config file to %APPDATA%
    6. AutoHotkey v2
    7. Startup shortcut (optional)
#>

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Step { param($msg) Write-Host "`n[$([char]0x2713)] $msg" -ForegroundColor Green }
function Write-Skip { param($msg) Write-Host "    [SKIP] $msg" -ForegroundColor DarkGray }
function Write-Action { param($msg) Write-Host "    [....] $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDataDir = Join-Path $env:APPDATA "sniptranscribe"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  SnipTranscribe — Setup" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Python 3.11+
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Checking Python..."

$pythonOk = $false
try {
    $pyVersion = python --version 2>&1
    if ($pyVersion -match "Python (\d+)\.(\d+)") {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -ge 3 -and $minor -ge 11) {
            Write-Skip "Python $major.$minor found (>= 3.11 required)"
            $pythonOk = $true
        }
    }
} catch {}

if (-not $pythonOk) {
    Write-Action "Installing Python 3.12 via winget..."
    try {
        winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements
        Write-Host "    Please RESTART this script after Python installs (PATH needs refresh)." -ForegroundColor Yellow
        Read-Host "    Press Enter to exit"
        exit 0
    } catch {
        Write-Fail "Could not install Python. Please install Python 3.11+ manually."
        Write-Host "    Download: https://python.org/downloads" -ForegroundColor Gray
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Pip dependencies
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Installing Python dependencies..."

$requirementsPath = Join-Path $ScriptDir "requirements.txt"
if (Test-Path $requirementsPath) {
    try {
        python -m pip install --user --upgrade pip 2>&1 | Out-Null
        python -m pip install --user -r $requirementsPath 2>&1
        Write-Skip "Dependencies installed"
    } catch {
        Write-Fail "pip install failed: $_"
    }
} else {
    Write-Fail "requirements.txt not found at $requirementsPath"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Ollama
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Checking Ollama..."

$ollamaOk = $false
try {
    $ollamaVersion = ollama --version 2>&1
    Write-Skip "Ollama found: $ollamaVersion"
    $ollamaOk = $true
} catch {}

if (-not $ollamaOk) {
    Write-Action "Installing Ollama via winget..."
    try {
        winget install Ollama.Ollama --accept-package-agreements --accept-source-agreements
        Write-Host "    Ollama installed. Starting service..." -ForegroundColor Yellow
        Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
        $ollamaOk = $true
    } catch {
        Write-Fail "Could not install Ollama. Please install manually."
        Write-Host "    Download: https://ollama.com/download" -ForegroundColor Gray
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Pull glm-ocr model
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Checking glm-ocr model..."

if ($ollamaOk) {
    $modelFound = $false
    try {
        $modelList = ollama list 2>&1
        if ($modelList -match "glm-ocr") {
            Write-Skip "glm-ocr model already pulled"
            $modelFound = $true
        }
    } catch {}

    if (-not $modelFound) {
        Write-Action "Pulling glm-ocr model (this may take a few minutes)..."
        try {
            ollama pull glm-ocr
            Write-Skip "glm-ocr model pulled successfully"
        } catch {
            Write-Fail "Could not pull glm-ocr. Run manually: ollama pull glm-ocr"
        }
    }
} else {
    Write-Skip "Skipping model pull (Ollama not available)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Config file
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Setting up configuration..."

$configSource = Join-Path $ScriptDir "config.toml"
$configDest = Join-Path $AppDataDir "config.toml"

if (-not (Test-Path $AppDataDir)) {
    New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null
}

if (Test-Path $configDest) {
    Write-Skip "Config already exists at $configDest (not overwriting)"
} else {
    if (Test-Path $configSource) {
        Copy-Item $configSource $configDest
        Write-Skip "Config copied to $configDest"
    } else {
        Write-Fail "config.toml not found in script directory"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: AutoHotkey v2
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Checking AutoHotkey v2..."

$ahkExe = ""
$ahkPaths = @(
    "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
    "C:\Program Files\AutoHotkey\v2\AutoHotkey32.exe",
    "C:\Program Files\AutoHotkey\AutoHotkey.exe"
)

foreach ($p in $ahkPaths) {
    if (Test-Path $p) {
        $ahkExe = $p
        break
    }
}

if ($ahkExe -ne "") {
    Write-Skip "AutoHotkey v2 found at $ahkExe"
} else {
    # Check if ahk files are associated
    try {
        $assoc = cmd /c assoc .ahk 2>&1
        if ($assoc -match "AutoHotkey") {
            Write-Skip "AutoHotkey is associated with .ahk files"
            $ahkExe = "associated"
        }
    } catch {}

    if ($ahkExe -eq "") {
        Write-Action "Installing AutoHotkey via winget..."
        try {
            winget install AutoHotkey.AutoHotkey --accept-package-agreements --accept-source-agreements
            Write-Skip "AutoHotkey installed"
        } catch {
            Write-Fail "Could not install AutoHotkey. Please install manually."
            Write-Host "    Download: https://autohotkey.com" -ForegroundColor Gray
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Startup shortcut
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Startup shortcut..."

$ahkScript = Join-Path $ScriptDir "sniptranscribe.ahk"
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "SnipTranscribe.lnk"

if (Test-Path $shortcutPath) {
    Write-Skip "Startup shortcut already exists"
} else {
    $response = Read-Host "    Start SnipTranscribe automatically with Windows? (y/n)"
    if ($response -eq "y" -or $response -eq "Y") {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $ahkScript
            $shortcut.WorkingDirectory = $ScriptDir
            $shortcut.Description = "SnipTranscribe - Hotkey screen OCR"
            $shortcut.Save()
            Write-Skip "Startup shortcut created at $shortcutPath"
        } catch {
            Write-Fail "Could not create startup shortcut: $_"
        }
    } else {
        Write-Skip "Skipped (run sniptranscribe.ahk manually when needed)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To start: double-click sniptranscribe.ahk" -ForegroundColor White
Write-Host "  Then press Ctrl+Shift+T to snip & transcribe" -ForegroundColor White
Write-Host ""
Write-Host "  Config: $configDest" -ForegroundColor Gray
Write-Host ""
