# deploy-fs25.ps1
#
# Deploys the working-tree mod files into the FS25 mods folder as a zipped mod
# so the game can load the in-development port. FS25 mods must be a .zip with
# modDesc.xml at the zip root (not a loose folder). Stages only the shippable
# mod content (excludes dev-only dirs/files) into a temp dir, then zips it.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts/deploy-fs25.ps1

$ErrorActionPreference = "Stop"

# Repo root = parent of this script's directory.
$repoRoot   = Split-Path -Parent $PSScriptRoot
$modName    = "FS25_guidanceSteering"
$destRoot   = "F:\FS25\mods"
$destZip    = Join-Path $destRoot "$modName.zip"
$staleDir   = Join-Path $destRoot $modName
$stagingDir = Join-Path $env:TEMP "guidanceSteering-deploy-staging"

Write-Host "Guidance Steering - FS25 deploy" -ForegroundColor Cyan
Write-Host "  source: $repoRoot"
Write-Host "  target: $destZip"

# Mods folder must already exist (do not silently create the drive path).
if (-not (Test-Path $destRoot)) {
    Write-Error "Mods folder not found: $destRoot. Create it (or fix the drive letter) and re-run."
}

# Clean staging dir from any previous run.
if (Test-Path $stagingDir) {
    Remove-Item -Recurse -Force $stagingDir
}
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

# Top-level files to stage (only if present).
$files = @("modDesc.xml", "icon.png", "icon.dds")
foreach ($f in $files) {
    $src = Join-Path $repoRoot $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $stagingDir -Force
        Write-Host "  + $f"
    }
}

# Directories to stage recursively.
$dirs = @("i18n", "resources", "src")
foreach ($d in $dirs) {
    $src = Join-Path $repoRoot $d
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $stagingDir -Recurse -Force
        Write-Host "  + $d/ (recursive)"
    }
}

# Excluded by design (not staged): .git, plans, scripts, .claude, .vscode,
# .github, README.md, *.yml, zip-builder.ps1, zip.bat, .editorconfig, .gitignore.

# Remove a stale unzipped deploy so the game doesn't load both copies.
if (Test-Path $staleDir) {
    Write-Host "  removing stale unzipped mod folder: $staleDir" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $staleDir
}

# Zip the staging dir's *contents* so modDesc.xml lands at the zip root.
# NOTE: do NOT use Compress-Archive here. Windows PowerShell 5.1 writes zip entry
# names with backslash separators, which the GIANTS engine cannot resolve -> the mod
# fails to load ("Can't load resource ... /src/loader.lua"). Build the archive via .NET
# and force forward-slash entry names relative to the staging dir.
if (Test-Path $destZip) {
    Remove-Item -Force $destZip
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stagingFull = (Resolve-Path $stagingDir).Path.TrimEnd('\')
$zipStream = [System.IO.File]::Open($destZip, [System.IO.FileMode]::Create)
$archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -Path $stagingDir -Recurse -File | ForEach-Object {
        $entryName = $_.FullName.Substring($stagingFull.Length + 1) -replace '\\', '/'
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entryName) | Out-Null
    }
}
finally {
    $archive.Dispose()
    $zipStream.Dispose()
}

# Clean up staging dir.
Remove-Item -Recurse -Force $stagingDir

Write-Host "Done. Deployed to:" -ForegroundColor Green
Write-Host "  $destZip"
