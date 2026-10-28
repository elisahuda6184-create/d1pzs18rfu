# Install CustomDeepseek on Windows from this folder: builds source\, puts the
# provider configuration into the dsh web profile when it is still empty, and
# installs a `dsh` launcher next to npm's global commands.
$ErrorActionPreference = 'Stop'

$bundleRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $bundleRoot 'source'
$configTemplate = Join-Path $bundleRoot 'config\cordis.patch.yml.example'
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$profileDir = Join-Path $dshHome 'profiles\web'
$profilePatch = Join-Path $profileDir 'cordis.patch.yml'

$nodeVersion = (& node --version 2>$null)
if (-not $nodeVersion) { throw 'Node.js 24.9 or newer is required.' }
$parts = $nodeVersion.TrimStart('v').Split('.')
if ([int]$parts[0] -lt 24 -or ([int]$parts[0] -eq 24 -and [int]$parts[1] -lt 9)) {
  throw "Node.js 24.9 or newer is required; found $nodeVersion"
}
if (-not (Get-Command corepack -ErrorAction SilentlyContinue)) { throw 'Corepack is required (it provides the pinned pnpm).' }
if (-not (Test-Path (Join-Path $sourceRoot 'package.json'))) { throw "there is no source\ build in $bundleRoot" }

if (-not $env:CLOSEROUTER_API_KEY) {
  $secure = Read-Host -Prompt 'CloseRouter API key (leave blank to set it later)' -AsSecureString
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  if ($plain) { $env:CLOSEROUTER_API_KEY = $plain }
}

Push-Location $sourceRoot
try {
  Write-Host 'Installing dependencies...'
  corepack pnpm install --frozen-lockfile
  if ($LASTEXITCODE -ne 0) { throw 'pnpm install failed' }
  Write-Host 'Building DeepSeek Harness...'
  corepack pnpm run build
  if ($LASTEXITCODE -ne 0) { throw 'build failed' }
  $env:DSH_TELEMETRY_MODE = 'DISABLED'
  $built = (& node apps/cli/lib/bin.js --version)
  Write-Host "Built dsh $built."
  & node apps/cli/lib/bin.js web --dump-default-config | Out-Null
} finally {
  Pop-Location
}

$existing = if (Test-Path $profilePatch) { (Get-Content $profilePatch | Where-Object { $_ -notmatch '^#' }) -join '' -replace '\s', '' } else { '' }
if (-not (Test-Path $profilePatch) -or $existing -eq '[]') {
  New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
  Copy-Item $configTemplate $profilePatch
  Write-Host "Installed the provider configuration at $profilePatch"
} else {
  Write-Host "Keeping the existing provider configuration at $profilePatch"
}

$binDir = (& npm prefix -g).Trim()
$launcher = Join-Path $binDir 'dsh.cmd'
$binJs = Join-Path $sourceRoot 'apps\cli\lib\bin.js'
$content = @"
@echo off
if "%DSH_TELEMETRY_MODE%"=="" set DSH_TELEMETRY_MODE=DISABLED
node "$binJs" %*
"@
# cmd.exe reads .cmd files in the console's OEM code page, so write the file in
# that encoding; -Encoding ASCII would mangle a non-ASCII install path (for
# example C:\Users\Jose\...) to '?' and node could not find bin.js.
$oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
[IO.File]::WriteAllText($launcher, $content, $oem)
Write-Host "Installed the launcher as $launcher"

if ($env:CLOSEROUTER_API_KEY) {
  Write-Host 'CloseRouter key is available for this session. Set CLOSEROUTER_API_KEY (and SEVENAPI_API_KEY, OPENROUTER_API_KEY) in the user environment to keep it.'
} else {
  Write-Host 'No key entered. Set CLOSEROUTER_API_KEY in the user environment before launching dsh.'
}
Write-Host 'For the Superpowers skills, run scripts/superpowers.sh in Git Bash (it needs git and a POSIX shell).'
Write-Host 'CustomDeepseek is installed. Open a new terminal and run: dsh --version   then: dsh web'
