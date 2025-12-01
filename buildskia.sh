#!/bin/bash
set -e

# --- Configuration ---
SKIA_REPO="https://github.com/google/skia.git"
DEPOT_TOOLS_REPO="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
BASE_DIR="$(pwd)"
DEPOT_TOOLS_DIR="$BASE_DIR/depot_tools"
SKIA_DIR="$BASE_DIR/skia"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# --- 1. Dependencies ---
log "Checking dependencies..."

install_deps_apt() {
    log "Detected apt package manager. Installing dependencies..."
    sudo apt-get update
    sudo apt-get install -y git curl python3 python3-pip build-essential clang libgl1-mesa-dev libglu1-mesa-dev libfontconfig-dev
}

install_deps_dnf() {
    log "Detected dnf package manager. Installing dependencies..."
    sudo dnf install -y git curl python3 python3-pip @development-tools clang mesa-libGL-devel mesa-libGLU-devel fontconfig-devel
}

if command -v apt-get &> /dev/null; then
    install_deps_apt
elif command -v dnf &> /dev/null; then
    install_deps_dnf
else
    warn "Package manager not found (apt/dnf). Please ensure dependencies are installed manually: git, curl, python3, clang, build-essential."
fi

# --- 2. Depot Tools ---
if [ ! -d "$DEPOT_TOOLS_DIR" ]; then
    log "Cloning depot_tools..."
    git clone "$DEPOT_TOOLS_REPO" "$DEPOT_TOOLS_DIR"
else
    log "depot_tools already exists."
fi

export PATH="$DEPOT_TOOLS_DIR:$PATH"

# --- 3. Skia ---
if [ ! -d "$SKIA_DIR" ]; then
    log "Cloning Skia..."
    git clone "$SKIA_REPO" "$SKIA_DIR"
else
    log "Skia already exists."
fi

cd "$SKIA_DIR"

log "Syncing dependencies (git-sync-deps)..."
python3 tools/git-sync-deps

# --- 4. Build ---
log "Generating build files..."

# Ensure gn is available
if ! command -v gn &> /dev/null; then
    log "Downloading gn..."
    bin/fetch-gn
fi

GN_ARGS='is_official_build=false is_component_build=false is_clang=true skia_use_system_expat=false skia_use_system_icu=false skia_use_libjpeg_turbo_decode=true skia_use_libpng_decode=true skia_use_libwebp_decode=true skia_use_zlib=true skia_enable_gpu=true skia_use_gl=true'

bin/gn gen out/Release --args="$GN_ARGS"

log "Building with Ninja..."
ninja -C out/Release

log "Build complete!"
