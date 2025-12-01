<#
.SYNOPSIS
    Skia Builder Script
    Automates the setup of the environment and building of Skia on Windows.

.DESCRIPTION
    This script performs the following actions:
    1. Checks for Visual Studio installation and installs it if missing (requires UAC).
    2. Downloads and sets up utilities: Aria2c, 7zr, LLVM, Git.
    3. Clones Depot Tools and Skia repositories.
    4. Configures the environment.
    5. Builds Skia using GN and Ninja.

.NOTES
    Run this script as Administrator if VS installation is required.
#>

$ErrorActionPreference = "Stop"
$BASE = $PSScriptRoot
if (-not $BASE) { $BASE = Get-Location }

# --- Configuration ---
$VS_EDITION = "community" # Options: community, professional, enterprise
$VS_VERSION = "17"        # VS 2022
$VS_INSTALLER_URL = "https://aka.ms/vs/$VS_VERSION/release/vs_$VS_EDITION.exe"

$ARIA2_URL = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"
$SEVENZR_URL = "https://www.7-zip.org/a/7zr.exe"
# Note: The user provided LLVM version 21.1.6 which might not exist yet. Using the URL provided but be aware it might fail if invalid.
$LLVM_URL = "https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.6/clang+llvm-21.1.6-x86_64-pc-windows-msvc.tar.xz"
$GIT_URL = "https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/PortableGit-2.52.0-64-bit.7z.exe"

$DEPOT_TOOLS_REPO = "https://chromium.googlesource.com/chromium/tools/depot_tools.git"
$SKIA_REPO = "https://github.com/google/skia.git"

# --- Helper Functions ---

function Test-Command ($Command) {
    return (Get-Command $Command -ErrorAction SilentlyContinue) -ne $null
}

function Invoke-Aria2c {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Dir = "$BASE/temp"
    )
    $AriaExe = "$BASE/tools/aria2c.exe"
    Write-Host "Downloading $OutFile using aria2c..." -ForegroundColor Cyan
    & $AriaExe -x 16 -s 16 -d $Dir -o $OutFile $Url
    if ($LASTEXITCODE -ne 0) { throw "Aria2c download failed for $Url" }
}

# --- 1. Init ---
Write-Host "--- [Init] ---" -ForegroundColor Green
$Dirs = @("$BASE/temp", "$BASE/tools", "$BASE/bin")
foreach ($d in $Dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d | Out-Null
        Write-Host "Created $d"
    }
}

# --- 2. Check VS2022 ---
Write-Host "--- [Check Visual Studio] ---" -ForegroundColor Green
$VSWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VSInstalled = $false

if (Test-Path $VSWhere) {
    $VSPath = & $VSWhere -version "[17.0,18.0)" -property installationPath
    if ($VSPath) {
        Write-Host "Visual Studio found at: $VSPath"
        $VSInstalled = $true
    }
}

if (-not $VSInstalled) {
    Write-Host "Visual Studio not found. Attempting to install..." -ForegroundColor Yellow
    $InstallerPath = "$BASE/temp/vs_installer.exe"
    
    Write-Host "Downloading VS Installer..."
    Invoke-WebRequest -Uri $VS_INSTALLER_URL -OutFile $InstallerPath
    
    Write-Host "Installing Visual Studio + C++ Desktop Development..."
    Write-Host "NOTE: This requires UAC approval and may take a while."
    
    # Arguments for passive install of C++ Desktop workload
    $Args = @(
        "--add", "Microsoft.VisualStudio.Workload.NativeDesktop",
        "--includeRecommended",
        "--passive",
        "--norestart",
        "--wait"
    )
    
    Start-Process -FilePath $InstallerPath -ArgumentList $Args -Wait -Verb RunAs
    Write-Host "VS Installation completed (or skipped)."
}

# --- 3. Download Utilities ---
Write-Host "--- [Download Utilities] ---" -ForegroundColor Green

# 3.1 Aria2c
$AriaZip = "$BASE/temp/aria2.zip"
if (-not (Test-Path "$BASE/tools/aria2c.exe")) {
    Write-Host "Downloading Aria2c..."
    Invoke-WebRequest -Uri $ARIA2_URL -OutFile $AriaZip
    
    Write-Host "Extracting Aria2c..."
    Expand-Archive -Path $AriaZip -DestinationPath "$BASE/temp/aria2_extract" -Force
    
    # Find the exe (it's usually in a subfolder)
    $AriaExeFound = Get-ChildItem "$BASE/temp/aria2_extract" -Recurse -Filter "aria2c.exe" | Select-Object -First 1
    if ($AriaExeFound) {
        Move-Item $AriaExeFound.FullName "$BASE/tools/aria2c.exe" -Force
    } else {
        throw "Could not find aria2c.exe in extracted archive."
    }
}

# 3.2 7zr
if (-not (Test-Path "$BASE/tools/7zr.exe")) {
    Invoke-Aria2c -Url $SEVENZR_URL -OutFile "7zr.exe" -Dir "$BASE/tools"
}

# 3.3 LLVM
if (-not (Test-Path "$BASE/bin/llvm/bin/clang-cl.exe")) {
    $LLVMArchive = "llvm.tar.xz"
    if (-not (Test-Path "$BASE/temp/$LLVMArchive")) {
        Invoke-Aria2c -Url $LLVM_URL -OutFile $LLVMArchive
    }
    
    Write-Host "Extracting LLVM (this may take time)..."
    # Use 7zr to extract .xz then .tar
    # 7zr x file.tar.xz -> file.tar
    # 7zr x file.tar -> content
    
    $7zr = "$BASE/tools/7zr.exe"
    $TarFile = "$BASE/temp/llvm.tar"
    
    if (-not (Test-Path $TarFile)) {
        & $7zr x "$BASE/temp/$LLVMArchive" -o"$BASE/temp" -y
    }
    
    & $7zr x "$TarFile" -o"$BASE/bin" -y
    
    # Rename folder
    $ExtractedLLVM = Get-ChildItem "$BASE/bin" -Directory | Where-Object { $_.Name -like "clang+llvm*" } | Select-Object -First 1
    if ($ExtractedLLVM) {
        Rename-Item $ExtractedLLVM.FullName "llvm"
    }
}

# 3.4 Git
if (-not (Test-Command "git")) {
    Write-Host "Git not found in PATH."
    if (-not (Test-Path "$BASE/bin/git/cmd/git.exe")) {
        $GitArchive = "git.7z.exe"
        if (-not (Test-Path "$BASE/temp/$GitArchive")) {
             Invoke-Aria2c -Url $GIT_URL -OutFile $GitArchive
        }
        
        Write-Host "Extracting Portable Git..."
        $7zr = "$BASE/tools/7zr.exe"
        # The exe is a self-extracting 7z, can be opened with 7zr
        & $7zr x "$BASE/temp/$GitArchive" -o"$BASE/bin/git" -y
    }
    $env:PATH = "$BASE/bin/git/cmd;" + $env:PATH
}

# --- 4. Environments ---
Write-Host "--- [Environments] ---" -ForegroundColor Green
$env:PATH = "$BASE/bin/llvm/bin;$env:PATH"
Write-Host "Path updated: $env:PATH"

# --- 5. Clone ---
Write-Host "--- [Clone] ---" -ForegroundColor Green
Set-Location $BASE

if (-not (Test-Path "depot_tools")) {
    Write-Host "Cloning depot_tools..."
    git clone $DEPOT_TOOLS_REPO
}

if (-not (Test-Path "skia")) {
    Write-Host "Cloning skia..."
    git clone $SKIA_REPO
}

# --- 6. Build Skia ---
Write-Host "--- [Build Skia] ---" -ForegroundColor Green

# Add depot_tools to PATH
$env:PATH = "$BASE/depot_tools;" + $env:PATH
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = 0 # Tell depot_tools to use local VS if needed, or handle toolchain manually

Set-Location "$BASE/skia"

Write-Host "Syncing dependencies (git-sync-deps)..."
# Try using python from depot_tools or system
if (Test-Command "python3") {
    python3 tools/git-sync-deps
} elseif (Test-Command "python") {
    python tools/git-sync-deps
} else {
    Write-Warning "Python not found. git-sync-deps might fail."
    ./tools/git-sync-deps
}

Write-Host "Generating build files (gn gen)..."
# Construct arguments
$ClangWinPath = "$BASE\bin\llvm\bin\clang-cl.exe"
# Escape backslashes for GN string
$ClangWinPathGN = $ClangWinPath -replace "\\", "\\"

$GnArgs = @"
is_official_build=false
is_component_build=false
is_clang=true
clang_use_chrome_plugins=false
clang_win="$ClangWinPathGN"
skia_enable_gpu=true
skia_use_vulkan=true
skia_use_d3d=true
skia_use_direct3d12=true
skia_use_gl=false
skia_use_metal=false
skia_use_glslang=true
skia_use_spirv_cross=true
use_lld=true
use_jumbo_build=true
"@

# GN might be in depot_tools or bin/gn
if (Test-Path "bin/gn.exe") {
    $GN_EXE = "bin/gn.exe"
} else {
    $GN_EXE = "gn" # Hope it's in path from depot_tools
}

& $GN_EXE gen out/Release --args=$GnArgs

Write-Host "Building with Ninja..."
ninja -C out/Release

Write-Host "Done!" -ForegroundColor Green
