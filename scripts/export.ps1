# Create a shareable bundle dist\CustomDeepseek-<version>.zip without
# dependencies, build output, Git metadata, logs, env files or keys.
$ErrorActionPreference = 'Stop'

$bundleRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $bundleRoot 'source'
$exportRoot = Join-Path $bundleRoot 'dist'
$version = try { (Get-Content (Join-Path $sourceRoot 'package.json') -Raw | ConvertFrom-Json).version } catch { 'local' }
$staging = Join-Path $exportRoot "CustomDeepseek-$version"
$archive = Join-Path $exportRoot "CustomDeepseek-$version.zip"

# Refuse to export when a secret-like file sits in the bundle root.
$secretPattern = '^\.env|^\.credentials\.yaml$|\.log$'
if (Get-ChildItem $bundleRoot -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $secretPattern }) {
  throw 'Refusing to export: possible secret/config files found in the bundle root.'
}

if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
if (Test-Path $archive) { Remove-Item -Force $archive }
New-Item -ItemType Directory -Force -Path (Join-Path $staging 'source'), (Join-Path $staging 'config'), (Join-Path $staging 'scripts') | Out-Null

# robocopy prunes excluded directories instead of walking into them, so
# node_modules, .git and every lib/ are never traversed (pnpm's junction
# cycles would otherwise error on PowerShell 5.1). Exit codes 0-7 are success.
$excludedDirs = @('.git', 'node_modules', 'lib', 'dist', 'coverage', '.tmp', '.vitest-results')
$excludedFiles = @('*.log', '.env*', '.credentials.yaml')
$robArgs = @($sourceRoot, (Join-Path $staging 'source'), '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XD') + $excludedDirs + @('/XF') + $excludedFiles
& robocopy @robArgs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying the source tree (exit $LASTEXITCODE)" }
$global:LASTEXITCODE = 0

Copy-Item -Recurse (Join-Path $bundleRoot 'custom') (Join-Path $staging 'custom')
Copy-Item (Join-Path $bundleRoot 'config\cordis.patch.yml.example') (Join-Path $staging 'config\cordis.patch.yml.example')
Copy-Item (Join-Path $bundleRoot 'README.md') (Join-Path $staging 'README.md')
Copy-Item (Join-Path $bundleRoot 'AI-INSTALL-GUIDE.md') (Join-Path $staging 'AI-INSTALL-GUIDE.md')
foreach ($script in 'install.ps1', 'install.sh', 'update.sh', 'export.ps1', 'export.sh', 'dsh-launcher.sh') {
  Copy-Item (Join-Path $bundleRoot "scripts\$script") (Join-Path $staging "scripts\$script")
}

# Refuse to export if a secret-like file reached the staging tree.
if (Get-ChildItem $staging -Recurse -Force -File | Where-Object { $_.Name -match $secretPattern }) {
  Remove-Item -Recurse -Force $staging
  throw 'Refusing to export: a secret-like file entered the staging directory.'
}

$keyPattern = 'closerouter_[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,}|sk-or-v1-[A-Za-z0-9]{32,}'
$keyFiles = Get-ChildItem -Path $staging -Recurse -File | Where-Object { Select-String -Path $_.FullName -Pattern $keyPattern -Quiet }
if ($keyFiles) {
  Remove-Item -Recurse -Force $staging
  throw "Refusing to export: an API key was found in: $($keyFiles.FullName -join ', ')"
}

Compress-Archive -Path $staging -DestinationPath $archive
Remove-Item -Recurse -Force $staging
Write-Host "Created $archive"
