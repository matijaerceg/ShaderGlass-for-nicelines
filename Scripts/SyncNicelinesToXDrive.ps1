$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$dst = $scriptDir
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$list = gh codespace list --json name,state,lastUsedAt | ConvertFrom-Json

$pick = $list |
    Where-Object { $_.state -eq "Available" } |
    Sort-Object lastUsedAt -Descending |
    Select-Object -First 1

if (-not $pick) {
    $pick = $list | Sort-Object lastUsedAt -Descending | Select-Object -First 1
}

if (-not $pick) {
    throw "No Codespace found."
}

$cs = $pick.name

Get-ChildItem -Path $dst -Filter "nicelines*.slang*" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

gh codespace cp -c $cs -e -- "remote:/workspaces/ShaderGlass-for-nicelines/Misc/nicelines*.slang" "remote:/workspaces/ShaderGlass-for-nicelines/Misc/nicelines*.slangp" $dst

Write-Host "Synced nicelines files from codespace '$cs' to '$dst'."
