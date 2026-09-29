<#
.SYNOPSIS
    Builds TopNotify from this checkout and installs it as a packaged (MSIX) app.

.DESCRIPTION
    Builds the project, copies the output beside the MSIX manifest into -InstallDir and registers that
    folder with Add-AppxPackage -Register. The package identity lets the notification listener work, so
    custom sounds and read-aloud function. The app runs from -InstallDir, so keep that folder.

    Settings survive a reinstall: the package's data folder is backed up before the old package is
    removed and restored after the new one is registered. Backups are kept under "<InstallDir>-backups".

    Requirements: Windows 10/11 x64, Developer Mode, the .NET 9 SDK and Node.js on PATH.

.PARAMETER ReplaceStore
    Uninstall the Microsoft Store version of TopNotify if it is installed. Without this switch the script
    stops when it finds the Store version.

.PARAMETER InstallDir
    Folder the app is installed into and runs from.

.EXAMPLE
    git clone -b combined https://github.com/leftos/TopNotify
    cd TopNotify
    powershell -ExecutionPolicy Bypass -File .\install-dev.ps1 -ReplaceStore
#>
[CmdletBinding()]
param(
    [switch]$ReplaceStore,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TopNotify-Dev')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$PackageName = '55968SamsidGameStudios.TopNotify'
$ProjectDir = Join-Path $PSScriptRoot 'TopNotify'

function Assert-Prerequisite {
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw "This script builds the x64 package only; this machine is $env:PROCESSOR_ARCHITECTURE."
    }
    foreach ($tool in 'dotnet', 'node', 'npm') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' is not on PATH. Install the .NET 9 SDK and Node.js, then run this script again."
        }
    }
    $unlock = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
    if (-not $unlock -or -not ($unlock.PSObject.Properties.Name -contains 'AllowDevelopmentWithoutDevLicense') -or $unlock.AllowDevelopmentWithoutDevLicense -ne 1) {
        throw 'Developer Mode is off. Turn it on in Settings > System > For developers, then run this script again.'
    }
}

function Get-DataFolder([string]$packageFamilyName) {
    return Join-Path $env:LOCALAPPDATA "Packages\$packageFamilyName\LocalCache\Local\SamsidParty\TopNotify"
}

function Invoke-Build {
    Write-Information 'Building TopNotify (Release)...'
    # The build fetches its scripts with Node, whose fetch times out on networks with broken IPv6 routing
    $env:NODE_OPTIONS = '--dns-result-order=ipv4first'
    & dotnet build (Join-Path $ProjectDir 'TopNotify.csproj') -c Release | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE."
    }
    $output = Get-ChildItem (Join-Path $ProjectDir 'bin\Release') -Directory -Filter 'net*-windows*' | Select-Object -First 1
    if (-not $output) {
        throw "Build output not found under $ProjectDir\bin\Release."
    }
    if (-not (Test-Path (Join-Path $output.FullName 'iv2runtime\TopNotify.igniteview'))) {
        throw "The UI bundle is missing from $($output.FullName)\iv2runtime; the build's frontend step did not run."
    }
    # The build rewrites this tracked bundle; the output has its copy, so keep the checkout clean for git pull
    & git -C $PSScriptRoot checkout -- 'TopNotify/iv2runtime/TopNotify.igniteview' | Out-Host
    return $output.FullName
}

# Copies file contents only: package data is EFS-encrypted, and Copy-Item fails trying to keep that at the destination
function Copy-FolderContent([string]$source, [string]$destination) {
    foreach ($file in Get-ChildItem $source -Recurse -File) {
        $target = Join-Path $destination $file.FullName.Substring($source.Length).TrimStart('\')
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($file.FullName))
    }
}

# Backs up the installed package's data and removes the package.
# Returns the backup folder, or $null when nothing was installed or there was no data.
function Uninstall-ExistingPackage([bool]$replaceStore) {
    $existing = Get-AppxPackage -Name $PackageName
    if (-not $existing) {
        return $null
    }
    if ($existing.SignatureKind -eq 'Store' -and -not $replaceStore) {
        throw 'The Microsoft Store version of TopNotify is installed. Run again with -ReplaceStore to uninstall it (settings are kept).'
    }

    $backup = $null
    $data = Get-DataFolder $existing.PackageFamilyName
    if (Test-Path $data) {
        $backup = Join-Path "$InstallDir-backups" (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-FolderContent $data $backup
        Write-Information "Backed up settings to $backup"
    }

    Write-Information "Removing installed package $($existing.PackageFullName) ($($existing.SignatureKind))..."
    Remove-AppxPackage $existing.PackageFullName
    return $backup
}

function Copy-PackageFile([string]$buildOutput) {
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    Copy-Item (Join-Path $ProjectDir 'MSIX\*') $InstallDir -Recurse -Force
    Copy-Item (Join-Path $buildOutput '*') $InstallDir -Recurse -Force
}

Assert-Prerequisite
$buildOutput = Invoke-Build
Get-Process TopNotify -ErrorAction SilentlyContinue | Stop-Process -Force
$backup = Uninstall-ExistingPackage $ReplaceStore.IsPresent
Copy-PackageFile $buildOutput

Write-Information "Registering package from $InstallDir..."
Add-AppxPackage -Register (Join-Path $InstallDir 'AppxManifest.xml')
$installed = Get-AppxPackage -Name $PackageName

if ($backup) {
    Copy-FolderContent $backup (Get-DataFolder $installed.PackageFamilyName)
    Write-Information 'Restored settings.'
}

Start-Process "shell:AppsFolder\$($installed.PackageFamilyName)!TopNotify"
Write-Information "Installed TopNotify $($installed.Version) from $InstallDir and started it."
