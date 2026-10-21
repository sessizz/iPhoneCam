#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

echo "==> 1. Checking OBS Studio and SIMDe header dependencies..."
if [ ! -f "/tmp/obs-studio-32.1.2/libobs/obs-module.h" ]; then
    echo "Cloning OBS Studio 32.1.2 headers to /tmp/obs-studio-32.1.2..."
    git clone --depth 1 --branch 32.1.2 https://github.com/obsproject/obs-studio.git /tmp/obs-studio-32.1.2
fi

if [ ! -f "/tmp/simde/simde/x86/sse2.h" ]; then
    echo "Cloning SIMDe headers to /tmp/simde..."
    git clone --depth 1 https://github.com/simd-everywhere/simde.git /tmp/simde
fi

echo "==> 2. Configuring CMake for obs-plugin..."
cmake -S obs-plugin -B build/obs-plugin \
  -DIPHONECAM_BUILD_OBS_PLUGIN=ON \
  -DOBS_APP_PATH=/Applications/OBS.app \
  -DOBS_SOURCE_DIR=/tmp/obs-studio-32.1.2 \
  -DSIMDE_INCLUDE_DIR=/tmp/simde

echo "==> 3. Compiling iphonecam-obs plugin..."
cmake --build build/obs-plugin --target iphonecam-obs

TARGET_DIR="$HOME/Library/Application Support/obs-studio/plugins"
PLUGIN_SRC="build/obs-plugin/iphonecam-obs.plugin"

echo "==> 4. Installing plugin to OBS Studio..."
mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_DIR/iphonecam-obs.plugin"
cp -R "$PLUGIN_SRC" "$TARGET_DIR/"

echo ""
echo "✅ Başarılı! Eklenti yüklendi:"
echo "   $TARGET_DIR/iphonecam-obs.plugin"
echo ""
echo "👉 Lütfen OBS Studio uygulamasını tamamen kapatıp (Cmd+Q) yeniden başlatın."
