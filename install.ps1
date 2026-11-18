<#
.SYNOPSIS
  Installs Neovim + everything this config needs on Windows, then clones and bootstraps it.

.DESCRIPTION
  Idempotent: only installs what is missing (via winget).
    - Neovim (>= 0.12), git, ripgrep, fd, Node.js LTS, .NET SDK 10, tree-sitter CLI
    - a C compiler for treesitter parsers (zig, unless MSVC cl.exe is already present)
    - JetBrainsMono Nerd Font
    - on ARM64: lua-language-server and stylua (Mason has no Windows ARM64 builds)
  Then clones the config to %LOCALAPPDATA%\nvim (if not already there) and installs
  plugins, treesitter parsers and Mason tools headlessly.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1
#>
param(
  [string]$RepoUrl = '',
  [switch]$SkipBootstrap
)

$ErrorActionPreference = 'Stop'
$ConfigDir = Join-Path $env:LOCALAPPDATA 'nvim'
$DefaultRepoUrl = 'https://github.com/CypheronX/kickstart.nvim.git'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

function Update-SessionPath {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Test-Command($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Install-WingetPackage($id) {
  Write-Step "Installing $id"
  winget install --id $id --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
  # winget returns non-zero for "already installed / no upgrade", so verify by command afterwards instead
  Update-SessionPath
}

function Ensure-Tool($command, $wingetId) {
  if (Test-Command $command) { Write-Ok "$command found"; return }
  Install-WingetPackage $wingetId
  if (-not (Test-Command $command)) { throw "$command still not found after installing $wingetId (open a new terminal and re-run?)" }
}

if (-not (Test-Command 'winget')) {
  throw 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
}
Update-SessionPath
$isArm64 = $env:PROCESSOR_ARCHITECTURE -eq 'ARM64'

# --- Neovim (>= 0.12 is required: the config uses the built-in vim.pack) ---
$needNvim = $true
if (Test-Command 'nvim') {
  $v = (nvim --version | Select-Object -First 1) -replace '^NVIM v', ''
  $parts = $v.Split('.-')
  if ([int]$parts[0] -gt 0 -or [int]$parts[1] -ge 12) { $needNvim = $false; Write-Ok "nvim $v found" }
  else { Write-Ok "nvim $v is too old (need >= 0.12)" }
}
if ($needNvim) {
  Install-WingetPackage 'Neovim.Neovim'
  if (Test-Command 'nvim') { winget upgrade --id Neovim.Neovim --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null }
  Update-SessionPath
  if (-not (Test-Command 'nvim')) { throw 'nvim not found after install' }
}

# --- CLI tools ---
Ensure-Tool 'git' 'Git.Git'
Ensure-Tool 'rg' 'BurntSushi.ripgrep.MSVC'
Ensure-Tool 'fd' 'sharkdp.fd'
Ensure-Tool 'node' 'OpenJS.NodeJS.LTS'   # needed by Mason's npm-based servers (ts_ls)
Ensure-Tool 'tree-sitter' 'tree-sitter.tree-sitter-cli'

# --- C compiler for treesitter parsers (init.lua switches tree-sitter to zig when cl.exe is absent) ---
if ((Test-Command 'cl') -or (Test-Command 'zig')) { Write-Ok 'C compiler found' } else { Ensure-Tool 'zig' 'zig.zig' }

# --- gcc for telescope-fzf-native (its Makefile hardcodes gcc; init.lua only adds it when make exists) ---
if (Test-Command 'make') { Ensure-Tool 'gcc' 'BrechtSanders.WinLibs.POSIX.UCRT' }

# --- .NET SDK (for the Roslyn C# language server and building projects) ---
$hasSdk = (Test-Command 'dotnet') -and (@(dotnet --list-sdks 2>$null).Count -gt 0)
if ($hasSdk) { Write-Ok '.NET SDK found' } else {
  Install-WingetPackage 'Microsoft.DotNet.SDK.10'
  if (-not (Test-Command 'dotnet')) { throw 'dotnet not found after install' }
}

# --- Mason has no Windows ARM64 builds of these; install system-wide instead ---
if ($isArm64) {
  Ensure-Tool 'lua-language-server' 'LuaLS.lua-language-server'
  Ensure-Tool 'stylua' 'JohnnyMorganz.StyLua'
}

# --- Nerd Font (the config sets vim.g.have_nerd_font = true) ---
$fontDirs = @("$env:WINDIR\Fonts", "$env:LOCALAPPDATA\Microsoft\Windows\Fonts")
$hasFont = $fontDirs | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem $_ -Filter 'JetBrainsMonoNerdFont*' -ErrorAction SilentlyContinue } | Select-Object -First 1
if ($hasFont) { Write-Ok 'JetBrainsMono Nerd Font found' } else { Install-WingetPackage 'DEVCOM.JetBrainsMonoNerdFont' }

# --- Config ---
if (-not $RepoUrl) {
  $RepoUrl = $DefaultRepoUrl
  if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot '.git'))) {
    $origin = git -C $PSScriptRoot remote get-url origin 2>$null
    if ($origin) { $RepoUrl = $origin }
  }
}
if (Test-Path (Join-Path $ConfigDir '.git')) {
  Write-Ok "config already at $ConfigDir (not touching it; git pull to update)"
} else {
  if (Test-Path $ConfigDir) {
    $backup = "$ConfigDir.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Write-Step "Backing up existing $ConfigDir to $backup"
    Move-Item $ConfigDir $backup
  }
  Write-Step "Cloning $RepoUrl to $ConfigDir"
  git clone $RepoUrl $ConfigDir
  if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
}

# --- Plugins, parsers, language servers ---
if (-not $SkipBootstrap) {
  Write-Step 'Bootstrapping plugins, treesitter parsers and language servers (takes a few minutes)'
  nvim --headless "+luafile $ConfigDir\scripts\bootstrap.lua"
  if ($LASTEXITCODE -ne 0) { Write-Warning 'Bootstrap reported problems; open nvim and run :checkhealth' }
}

Write-Host ''
Write-Host 'Done. Open a NEW terminal (so PATH updates apply) and run: nvim' -ForegroundColor Green
Write-Host 'Set your terminal font to "JetBrainsMono Nerd Font" for icons' -ForegroundColor Green
Write-Host '  (Windows Terminal: Settings > Profiles > Defaults > Appearance > Font face).' -ForegroundColor Green
