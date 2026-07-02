#Requires -Version 5.1
<#
.SYNOPSIS
    bootstrap.ps1 — install a prebuilt CUDA llama.cpp into .\vendor (Windows).

.DESCRIPTION
    Windows/PowerShell counterpart of bootstrap.sh, but targeting NVIDIA/CUDA
    (this box has an RTX 4090) instead of Vulkan (the Linux box / bootstrap.sh
    stays on Vulkan for its AMD RX 7900 XTX). Fetches the official prebuilt
    Windows CUDA release zip (llama-<tag>-bin-win-cuda-<ver>-x64.zip) AND the
    matching CUDA runtime (cudart-llama-bin-win-cuda-<ver>-x64.zip), extracting
    both so cudart DLLs sit beside the binaries. No compiler, no CMake, no conda.

.PARAMETER Force
    Reinstall the same tag/CUDA version even if it is already present.

.EXAMPLE
    .\bootstrap.ps1
    .\bootstrap.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # faster Invoke-WebRequest downloads

if ($Help) {
    @"
Usage: .\bootstrap.ps1 [-Force]

Installs the prebuilt Windows CUDA llama.cpp release defined by LLAMA_VERSION +
LLAMA_CUDA (config.ps1) into .\vendor\llama.cpp, together with the matching CUDA
runtime. Use -Force to reinstall the same tag/CUDA version.
"@ | Write-Host
    return
}

$ScriptDir = $PSScriptRoot

# --- load config -----------------------------------------------------------
# PowerShell only dot-sources *.ps1 files; load the .example fallback by
# evaluating its contents in the current scope so its variables persist.
if (Test-Path "$ScriptDir\config.ps1") {
    . "$ScriptDir\config.ps1"
} elseif (Test-Path "$ScriptDir\config.ps1.example") {
    Write-Warning 'config.ps1 not found — using defaults from config.ps1.example'
    . ([ScriptBlock]::Create((Get-Content -Raw -LiteralPath "$ScriptDir\config.ps1.example")))
}

if (-not $LLAMA_VERSION) { $LLAMA_VERSION = 'latest' }
if (-not $LLAMA_CUDA)    { $LLAMA_CUDA = '12.4' }
$VendorDir = Join-Path $ScriptDir 'vendor\llama.cpp'
$CacheDir  = Join-Path $ScriptDir 'cache'
$Marker    = Join-Path $ScriptDir 'vendor\.llama-version-win'

function Write-Step($msg) { Write-Host $msg -ForegroundColor Yellow }

function Resolve-Tag {
    if ($LLAMA_VERSION -eq 'latest') {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' `
            -Headers @{ 'User-Agent' = 'tooling-llama-bootstrap' }
        return $rel.tag_name
    }
    return $LLAMA_VERSION
}

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' {
            # llama.cpp publishes no win-cuda-arm64 build.
            throw 'ARM64 Windows has no prebuilt CUDA release. Use a Vulkan or CPU build manually.'
        }
        default { throw "unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" }
    }
}

function Get-File {
    param([string]$Url, [string]$OutFile)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        # curl.exe supports resume (-C -), like the bash script.
        & $curl.Source -L --fail -C - -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE): $Url" }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile
    }
}

# --- run -------------------------------------------------------------------
Write-Step '[1/4] Resolving llama.cpp release...'
$Tag = Resolve-Tag
if (-not $Tag) { throw 'could not resolve release tag' }
$Arch     = Get-Arch
$BaseUrl  = "https://github.com/ggml-org/llama.cpp/releases/download/$Tag"
$Asset    = "llama-$Tag-bin-win-cuda-$LLAMA_CUDA-$Arch.zip"
$Cudart   = "cudart-llama-bin-win-cuda-$LLAMA_CUDA-$Arch.zip"
$MarkerId = "$Tag-cuda-$LLAMA_CUDA-$Arch"
Write-Host "  version=$Tag  backend=cuda-$LLAMA_CUDA  arch=$Arch"

$vendorRoot = Join-Path $ScriptDir 'vendor'
if (Test-Path $vendorRoot -PathType Container) {
    $existing = Get-ChildItem -Path $vendorRoot -Recurse -Filter 'llama-server.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
} else {
    $existing = $null
}

if (-not $Force -and (Test-Path $Marker) -and ((Get-Content $Marker -Raw).Trim() -eq $MarkerId) -and $existing) {
    Write-Step "[2/4] Already installed ($MarkerId) — skipping download (use -Force to reinstall)."
} else {
    Write-Step "[2/4] Downloading + extracting $Asset (+ cudart) ..."
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $ZipPath    = Join-Path $CacheDir $Asset
    $CudartPath = Join-Path $CacheDir $Cudart

    Get-File -Url "$BaseUrl/$Asset"  -OutFile $ZipPath
    Get-File -Url "$BaseUrl/$Cudart" -OutFile $CudartPath

    if (Test-Path $VendorDir) { Remove-Item -Recurse -Force $VendorDir }
    New-Item -ItemType Directory -Force -Path $VendorDir | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $VendorDir -Force

    # cudart DLLs (cudart64_*, cublas64_*, cublasLt64_*) must live next to
    # llama-server.exe. Extract them into the binary's directory.
    $srv = Get-ChildItem -Path $VendorDir -Recurse -Filter 'llama-server.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $srv) { throw 'llama-server.exe not found in the CUDA zip after extraction' }
    Expand-Archive -Path $CudartPath -DestinationPath (Split-Path $srv.FullName -Parent) -Force

    Set-Content -Path $Marker -Value $MarkerId -NoNewline
}

Write-Step '[3/4] Locating binaries...'
$BinItem = Get-ChildItem -Path $vendorRoot -Recurse -Filter 'llama-server.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $BinItem) { throw 'llama-server.exe not found after extraction' }
$BinPath = $BinItem.FullName
$BinDir  = Split-Path $BinPath -Parent
Write-Host "  bin dir: $BinDir"

Write-Step '[4/4] Verifying...'
# Windows resolves dependent DLLs from the executable's own directory, so the
# CUDA runtime DLLs extracted alongside llama-server.exe are picked up here.
try {
    & $BinPath --version
} catch {
    Write-Error @"
llama-server.exe failed to run. Common causes:
  - NVIDIA driver too old for CUDA $LLAMA_CUDA — update the driver, or set
    `$LLAMA_CUDA = "12.4" in config.ps1 (widest compatibility) and re-run -Force.
  - Missing 'Microsoft Visual C++ Redistributable (x64)' — install from
    https://aka.ms/vs/17/release/vc_redist.x64.exe
  - cudart DLLs missing next to the exe — re-run with -Force.
"@
    throw
}

$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    try {
        & $smi.Source --query-gpu=name,driver_version --format=csv,noheader
        Write-Host '  NVIDIA GPU: OK (visible via nvidia-smi)'
    } catch {
        Write-Warning 'nvidia-smi present but query failed; check your driver install.'
    }
} else {
    Write-Warning 'nvidia-smi not found — is an NVIDIA driver installed? CUDA build needs one.'
}

Write-Step 'Done. Start the server with: .\server.ps1'
