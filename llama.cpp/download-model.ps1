#Requires -Version 5.1
<#
.SYNOPSIS
    download-model.ps1 — fetch prebuilt GGUF files from HuggingFace into
    $LLAMA_MODELS_DIR (outside this repo; never committed). Windows counterpart
    of download-model.sh.

.DESCRIPTION
    Prefers the 'hf' / 'huggingface-cli' tool (resume, auth); falls back to
    curl.exe (resume) or Invoke-WebRequest.

.EXAMPLE
    .\download-model.ps1 <repo_id> <filename> [dest_subdir]   # one file
    .\download-model.ps1 -All                                 # everything in models.list
    .\download-model.ps1 -List                                # show manifest
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(ParameterSetName = 'All')]  [switch]$All,
    [Parameter(ParameterSetName = 'List')] [switch]$List,
    [Parameter(ParameterSetName = 'Help')] [switch]$Help,
    [Parameter(ParameterSetName = 'File', Position = 0)] [string]$RepoId,
    [Parameter(ParameterSetName = 'File', Position = 1)] [string]$FileName,
    [Parameter(ParameterSetName = 'File', Position = 2)] [string]$DestSubdir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = $PSScriptRoot

# PowerShell only dot-sources *.ps1 files; load the .example fallback by
# evaluating its contents in the current scope so its variables persist.
if (Test-Path "$ScriptDir\config.ps1") {
    . "$ScriptDir\config.ps1"
} elseif (Test-Path "$ScriptDir\config.ps1.example") {
    . ([ScriptBlock]::Create((Get-Content -Raw -LiteralPath "$ScriptDir\config.ps1.example")))
}

if (-not $LLAMA_MODELS_DIR) { $LLAMA_MODELS_DIR = "$env:LOCALAPPDATA\llama.cpp\models" }
$Manifest = Join-Path $ScriptDir 'models.list'

function Show-Usage {
    @"
Usage:
  .\download-model.ps1 <repo_id> <filename> [dest_subdir]   Download one file
  .\download-model.ps1 -All                                 Download every entry in models.list
  .\download-model.ps1 -List                                Show manifest entries
  .\download-model.ps1 -Help

Target dir: `$LLAMA_MODELS_DIR = $LLAMA_MODELS_DIR
Gated models: set `$HF_TOKEN in config.ps1 or run 'hf auth login'.
"@ | Write-Host
}

function Invoke-DownloadOne {
    param([string]$Repo, [string]$File, [string]$Dest)

    if ($Dest) {
        $TargetDir = Join-Path $LLAMA_MODELS_DIR $Dest
    } else {
        $TargetDir = $LLAMA_MODELS_DIR
    }
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    $Target = Join-Path $TargetDir (Split-Path $File -Leaf)

    if ((Test-Path $Target) -and (Get-Item $Target).Length -gt 0) {
        Write-Host "  SKIP (exists): $Target"
        return
    }

    Write-Host "  GET $Repo :: $File -> $TargetDir"

    $hf = Get-Command hf -ErrorAction SilentlyContinue
    $hfcli = Get-Command huggingface-cli -ErrorAction SilentlyContinue
    if ($hf -or $hfcli) {
        $tool = if ($hf) { $hf.Source } else { $hfcli.Source }
        $cliArgs = @('download', $Repo, $File, '--local-dir', $TargetDir)
        if ($HF_TOKEN) { $cliArgs += @('--token', $HF_TOKEN) }
        & $tool @cliArgs
        if ($LASTEXITCODE -ne 0) { throw "download failed ($tool exit $LASTEXITCODE)" }
        return
    }

    $Uri = "https://huggingface.co/$Repo/resolve/main/$File"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $cliArgs = @('-L', '--fail', '-C', '-', '-o', $Target)
        if ($HF_TOKEN) { $cliArgs += @('-H', "Authorization: Bearer $HF_TOKEN") }
        $cliArgs += $Uri
        & $curl.Source @cliArgs
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE)" }
    } else {
        $headers = @{}
        if ($HF_TOKEN) { $headers['Authorization'] = "Bearer $HF_TOKEN" }
        Invoke-WebRequest -Uri $Uri -OutFile $Target -Headers $headers
    }
}

function Invoke-DownloadAll {
    if (-not (Test-Path $Manifest)) { throw "No manifest: $Manifest" }
    Write-Host "Downloading all entries from $Manifest"
    foreach ($line in Get-Content $Manifest) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed.Split('|')
        $repo = $parts[0].Trim()
        $file = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
        $dest = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
        if (-not $repo -or -not $file) {
            Write-Warning "  skipping malformed line: $line"
            continue
        }
        Invoke-DownloadOne -Repo $repo -File $file -Dest $dest
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Help' { Show-Usage }
    'List' {
        if (-not (Test-Path $Manifest)) { throw "No manifest: $Manifest" }
        Get-Content $Manifest | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }
    }
    'All'  { Invoke-DownloadAll }
    'File' {
        if (-not $RepoId -or -not $FileName) { Show-Usage; return }
        Invoke-DownloadOne -Repo $RepoId -File $FileName -Dest $DestSubdir
    }
}
