#Requires -Version 5.1
<#
.SYNOPSIS
    server.ps1 — start llama-server in router mode (default) or for a single
    model. Windows counterpart of server.sh.

.DESCRIPTION
    Heavy per-model tuning lives in the preset INI; this script stays portable.

.EXAMPLE
    .\server.ps1                       # Router mode (multi-model) via $LLAMA_PRESET
    .\server.ps1 model.gguf [args]     # Single model; extra args pass through
    .\server.ps1 -List                 # List GGUF files under $LLAMA_MODELS_DIR
#>
[CmdletBinding(DefaultParameterSetName = 'Serve')]
param(
    [Parameter(ParameterSetName = 'List')] [switch]$List,
    [Parameter(ParameterSetName = 'Help')] [switch]$Help,
    [Parameter(ParameterSetName = 'Serve', Position = 0)] [string]$Model,
    [Parameter(ParameterSetName = 'Serve', ValueFromRemainingArguments = $true)] [string[]]$ExtraArgs
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot

# PowerShell only dot-sources *.ps1 files; load the .example fallback by
# evaluating its contents in the current scope so its variables persist.
if (Test-Path "$ScriptDir\config.ps1") {
    . "$ScriptDir\config.ps1"
} elseif (Test-Path "$ScriptDir\config.ps1.example") {
    . ([ScriptBlock]::Create((Get-Content -Raw -LiteralPath "$ScriptDir\config.ps1.example")))
}

if (-not $LLAMA_MODELS_DIR) { $LLAMA_MODELS_DIR = "$env:LOCALAPPDATA\llama.cpp\models" }
if (-not $LLAMA_HOST)       { $LLAMA_HOST = '127.0.0.1' }
if (-not $LLAMA_PORT)       { $LLAMA_PORT = '8081' }
if (-not $LLAMA_PRESET)     { $LLAMA_PRESET = 'presets\models.ini' }
if (-not $LLAMA_MODELS_MAX) { $LLAMA_MODELS_MAX = '1' }
if (-not $LLAMA_NGL)        { $LLAMA_NGL = '999' }
if (-not $LLAMA_CTX)        { $LLAMA_CTX = '0' }
if (-not $LLAMA_KV)         { $LLAMA_KV = 'f16' }
if (-not $LLAMA_AUTO_UPDATE)          { $LLAMA_AUTO_UPDATE = '1' }
if (-not $LLAMA_UPDATE_CHECK_INTERVAL) { $LLAMA_UPDATE_CHECK_INTERVAL = '3600' }   # seconds; 0 = always check

# Allow per-run env overrides (mirrors "LLAMA_CTX=8192 ./server.sh ...").
if ($env:LLAMA_NGL) { $LLAMA_NGL = $env:LLAMA_NGL }
if ($env:LLAMA_CTX) { $LLAMA_CTX = $env:LLAMA_CTX }
if ($env:LLAMA_KV)  { $LLAMA_KV  = $env:LLAMA_KV }
if ($env:LLAMA_AUTO_UPDATE)           { $LLAMA_AUTO_UPDATE = $env:LLAMA_AUTO_UPDATE }
if ($env:LLAMA_UPDATE_CHECK_INTERVAL) { $LLAMA_UPDATE_CHECK_INTERVAL = $env:LLAMA_UPDATE_CHECK_INTERVAL }

# --- auto-update (throttled) ------------------------------------------------
# Runs bootstrap.ps1 before serving so LLAMA_VERSION=latest actually stays
# current. bootstrap.ps1 itself is idempotent (skips the download if the
# resolved tag/CUDA combo is already installed), so this is cheap once up to
# date. Throttled by a local marker so restarts within
# LLAMA_UPDATE_CHECK_INTERVAL don't re-hit the GitHub API or need network.
function Invoke-MaybeAutoUpdate {
    if ($LLAMA_AUTO_UPDATE -eq '0') { return }
    $marker = Join-Path $ScriptDir 'vendor\.last-auto-check'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $interval = [int]$LLAMA_UPDATE_CHECK_INTERVAL
    if ($interval -ne 0 -and (Test-Path $marker)) {
        $last = 0L
        [void][int64]::TryParse((Get-Content -Raw -LiteralPath $marker -ErrorAction SilentlyContinue), [ref]$last)
        if ($last -gt 0 -and ($now - $last) -lt $interval) { return }
    }
    Write-Host "Checking for llama.cpp updates (LLAMA_VERSION=$LLAMA_VERSION, recheck every ${interval}s)..."
    New-Item -ItemType Directory -Force -Path (Join-Path $ScriptDir 'vendor') | Out-Null
    Set-Content -Path $marker -Value $now -NoNewline
    try {
        & (Join-Path $ScriptDir 'bootstrap.ps1')
    } catch {
        Write-Warning 'Update check failed (offline / rate-limited?) — continuing with the installed build if present.'
    }
}

function Resolve-Bin {
    $item = Get-ChildItem -Path (Join-Path $ScriptDir 'vendor') -Recurse -Filter 'llama-server.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $item) { throw 'llama-server.exe not found. Run .\bootstrap.ps1 first.' }
    return $item.FullName
}

function Get-PhysicalCores {
    try {
        $sum = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
            Measure-Object -Property NumberOfCores -Sum).Sum
        if ($sum -gt 0) { return [int]$sum }
    } catch { }
    if ($env:NUMBER_OF_PROCESSORS) { return [int]$env:NUMBER_OF_PROCESSORS }
    return 1
}

function Show-Models {
    Write-Host "GGUF models under ${LLAMA_MODELS_DIR}:"
    if (Test-Path $LLAMA_MODELS_DIR) {
        Get-ChildItem -Path $LLAMA_MODELS_DIR -Recurse -Filter '*.gguf' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'mmproj.*' -and $_.Name -notlike 'ggml-vocab-*' } |
            Select-Object -ExpandProperty FullName | Sort-Object
    }
}

function Start-Router {
    $preset = Join-Path $ScriptDir $LLAMA_PRESET
    if (-not (Test-Path $preset)) {
        Write-Error @"
Preset not found: $preset
Copy presets\models.example.ini to $LLAMA_PRESET and edit the paths.
"@
        exit 1
    }
    Invoke-MaybeAutoUpdate
    $bin = Resolve-Bin
    Write-Host "Router mode @ http://${LLAMA_HOST}:${LLAMA_PORT}  (preset: $LLAMA_PRESET, max: $LLAMA_MODELS_MAX)"
    & $bin `
        --host $LLAMA_HOST `
        --port $LLAMA_PORT `
        --models-dir $LLAMA_MODELS_DIR `
        --models-preset $preset `
        --models-max $LLAMA_MODELS_MAX
}

function Start-Single {
    param([string]$ModelPath, [string[]]$Passthrough)

    if (-not (Test-Path $ModelPath)) { throw "Model not found: $ModelPath" }
    Invoke-MaybeAutoUpdate
    $bin = Resolve-Bin
    $threads = Get-PhysicalCores
    $modelName = Split-Path $ModelPath -Leaf

    $cliArgs = @(
        '--host', $LLAMA_HOST
        '--port', $LLAMA_PORT
        '--model', $ModelPath
        '--alias', $modelName
        '--threads', "$threads"
        '--n-gpu-layers', $LLAMA_NGL
        '--ctx-size', $LLAMA_CTX
        '--cache-type-k', $LLAMA_KV
        '--cache-type-v', $LLAMA_KV
    )

    # mmproj autodetect (multimodal projector next to the model file)
    $mmproj = Get-ChildItem -Path (Split-Path $ModelPath -Parent) -Filter 'mmproj.*' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($mmproj) { $cliArgs += @('--mmproj', $mmproj.FullName) }

    if ($Passthrough) { $cliArgs += $Passthrough }

    Write-Host "Single model @ http://${LLAMA_HOST}:${LLAMA_PORT}  ($modelName, threads=$threads)"
    & $bin @cliArgs
}

switch ($PSCmdlet.ParameterSetName) {
    'Help' {
        @"
Usage:
  .\server.ps1                       Router mode (multi-model) via `$LLAMA_PRESET
  .\server.ps1 <model.gguf> [args]   Single model; extra args pass through to llama-server
  .\server.ps1 -List                 List GGUF files under `$LLAMA_MODELS_DIR

Auto-update (config.ps1): `$LLAMA_AUTO_UPDATE = "0" disables the update check;
`$LLAMA_UPDATE_CHECK_INTERVAL (seconds, default 3600) throttles how often
serving re-checks GitHub for a newer LLAMA_VERSION build.
"@ | Write-Host
    }
    'List' { Show-Models }
    'Serve' {
        if ($Model) {
            Start-Single -ModelPath $Model -Passthrough $ExtraArgs
        } else {
            Start-Router
        }
    }
}
