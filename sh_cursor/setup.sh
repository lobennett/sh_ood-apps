#!/usr/bin/env bash
#
# Cursor IDE tunnel setup for Sherlock
#
# Run this on a Sherlock login node to:
#   1. Install the Cursor CLI
#   2. Install patchelf + glibc 2.28 sysroot
#   3. Authenticate your Cursor tunnel
#   4. Install the OOD app to ~/ondemand/dev/
#
# Usage: bash setup.sh

set -euo pipefail

echo "======================================"
echo "  Cursor IDE Tunnel Setup for Sherlock"
echo "======================================"
echo ""

# Determine script directory (where the OOD app files live)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify we're on Sherlock
if [[ -z "${SCRATCH:-}" ]]; then
  echo "ERROR: \$SCRATCH is not set. Are you on Sherlock?"
  echo "       Run this script on a Sherlock login node."
  exit 1
fi

# --- 1. Install Cursor CLI ---
CURSOR_CLI_DIR="$HOME/.cursor-tunnel"
CURSOR_CLI="$CURSOR_CLI_DIR/cursor"

echo "[1/5] Installing Cursor CLI..."
if [[ -x "$CURSOR_CLI" ]]; then
  echo "      Already installed at $CURSOR_CLI"
else
  mkdir -p "$CURSOR_CLI_DIR"
  echo "      Downloading from api2.cursor.sh (linux-x64)..."
  curl -fsSL "https://api2.cursor.sh/updates/download-latest?os=cli-linux-x64" \
    -o "$CURSOR_CLI_DIR/cursor.tar.gz"
  tar xzf "$CURSOR_CLI_DIR/cursor.tar.gz" -C "$CURSOR_CLI_DIR"
  rm -f "$CURSOR_CLI_DIR/cursor.tar.gz"
  chmod +x "$CURSOR_CLI"
  echo "      Installed at $CURSOR_CLI"
fi
echo ""

# --- 2. Install patchelf ---
CURSOR_DEPS="$SCRATCH/.cursor-deps"
PATCHELF="$CURSOR_DEPS/bin/patchelf"

echo "[2/5] Installing patchelf 0.18.0..."
if [[ -x "$PATCHELF" ]]; then
  echo "      Already installed at $PATCHELF"
else
  mkdir -p "$CURSOR_DEPS/bin"
  echo "      Downloading from GitHub..."
  curl -fsSL "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz" \
    -o "$CURSOR_DEPS/patchelf.tar.gz"
  tar xzf "$CURSOR_DEPS/patchelf.tar.gz" -C "$CURSOR_DEPS" --strip-components=1 ./bin/patchelf
  rm -f "$CURSOR_DEPS/patchelf.tar.gz"
  echo "      Installed at $PATCHELF"
fi
echo ""

# --- 3. Install glibc 2.28 sysroot ---
SYSROOT="$CURSOR_DEPS/sysroot"

echo "[3/5] Installing glibc 2.28 sysroot..."
if [[ -d "$SYSROOT/lib/x86_64-linux-gnu" ]]; then
  echo "      Already installed at $SYSROOT"
else
  mkdir -p "$SYSROOT"
  TMPDIR_DEB=$(mktemp -d)
  echo "      Downloading Debian buster libc6..."
  curl -fsSL "https://snapshot.debian.org/archive/debian-security/20240630T105336Z/pool/updates/main/g/glibc/libc6_2.28-10%2Bdeb10u4_amd64.deb" \
    -o "$TMPDIR_DEB/libc6.deb"
  cd "$TMPDIR_DEB"
  ar x libc6.deb
  tar xf data.tar.* -C "$SYSROOT"
  cd -
  rm -rf "$TMPDIR_DEB"
  echo "      Installed at $SYSROOT"
fi
echo ""

# --- 3b. Patch Cursor CLI to use glibc 2.28 sysroot ---
SYSROOT_LIB="$SYSROOT/lib/x86_64-linux-gnu"
echo "      Patching Cursor CLI to use glibc 2.28..."
"$PATCHELF" --set-interpreter "$SYSROOT_LIB/ld-linux-x86-64.so.2" \
  --set-rpath "$SYSROOT_LIB" \
  "$CURSOR_CLI"
echo "      Patched successfully"

# --- 3c. Build IPv4 LD_PRELOAD shim ---
FORCE_IPV4_SO="$CURSOR_DEPS/lib/force_ipv4.so"
echo "      Building IPv4 shim library..."
mkdir -p "$CURSOR_DEPS/lib"
gcc -shared -fPIC -o "$FORCE_IPV4_SO" "$SCRIPT_DIR/template/force_ipv4.c" -ldl
echo "      Built $FORCE_IPV4_SO"
echo ""

# --- 4. Symlink ~/.cursor-server to $SCRATCH ---
CURSOR_SERVER_DIR="$HOME/.cursor-server"
CURSOR_SERVER_SCRATCH="$SCRATCH/.cursor-server"

echo "[4/5] Setting up ~/.cursor-server symlink..."
if [[ -L "$CURSOR_SERVER_DIR" ]]; then
  echo "      Symlink already exists: $CURSOR_SERVER_DIR -> $(readlink "$CURSOR_SERVER_DIR")"
else
  mkdir -p "$CURSOR_SERVER_SCRATCH"
  if [[ -d "$CURSOR_SERVER_DIR" ]]; then
    echo "      Moving existing data to $SCRATCH..."
    mv "$CURSOR_SERVER_DIR"/* "$CURSOR_SERVER_SCRATCH/" 2>/dev/null || true
    rmdir "$CURSOR_SERVER_DIR" 2>/dev/null || rm -rf "$CURSOR_SERVER_DIR"
  fi
  ln -s "$CURSOR_SERVER_SCRATCH" "$CURSOR_SERVER_DIR"
  echo "      Symlinked $CURSOR_SERVER_DIR -> $CURSOR_SERVER_SCRATCH"
fi
echo ""

# --- 5. Authenticate ---
echo "[5/5] Authenticating Cursor tunnel..."
echo ""
echo "      This will open a device code flow. Follow the instructions"
echo "      to sign in with your Microsoft account."
echo ""
"$CURSOR_CLI" tunnel user login --provider microsoft
echo ""

# --- 6. Install OOD app ---
OOD_DEV_DIR="$HOME/ondemand/dev/sh_cursor"

echo "--------------------------------------"
echo "Installing OOD app to $OOD_DEV_DIR..."
mkdir -p "$OOD_DEV_DIR"
rsync -av --delete \
  --exclude='setup.sh' \
  "$SCRIPT_DIR/" "$OOD_DEV_DIR/"

# Install shared _common directory (required by form.yml.erb)
OOD_COMMON_DIR="$HOME/ondemand/dev/_common"
echo "Installing shared files to $OOD_COMMON_DIR..."
mkdir -p "$OOD_COMMON_DIR"
rsync -av --delete \
  "$SCRIPT_DIR/../_common/" "$OOD_COMMON_DIR/"
echo ""

echo "======================================"
echo "  Setup complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. Go to https://ondemand.sherlock.stanford.edu"
echo "  2. Navigate to Interactive Apps -> Cursor IDE"
echo "  3. Fill in the form and launch a session"
echo "  4. Connect from your local Cursor client"
echo ""
