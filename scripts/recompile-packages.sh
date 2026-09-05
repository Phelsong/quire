#!/usr/bin/env bash
# Recompile the `crypto` and `uuid` precompiled Mojo packages from source
# against the current environment's mojo compiler.
#
# The conda packages (crypto 0.1.0, uuid 1.1.0) from the modular-community
# channel ship .mojopkg files built with an internal compiler version
# (26.3.0) that is newer than the public mojo 1.0.0b2 release. Loading them
# fails with:
#   "Mojo precompiled file is incompatible with the current version of the
#    Mojo compiler. ... version 26.3.0 is newer than compiler version 1.0.0b2"
#
# This script rebuilds both packages from their upstream source so the
# precompiled files match the local compiler.
#
# Sources:
#   crypto: https://github.com/lczerniawski/crypto  rev 3f537eb
#   uuid:   https://github.com/lczerniawski/uuid    rev 77613ab
#
# Usage:  pixi run recompile-packages
# Run this after `pixi install` (which overwrites the .mojopkg files).
set -euo pipefail

MOJO_LIB="$CONDA_PREFIX/lib/mojo"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

CRYPTO_REV="3f537eba59563066c2eeb206da4c26405d8b66ab"
UUID_REV="77613ab60c9fcf73c848c5cdd1df5d1cc432ff3d"

echo "==> Cloning crypto @ $CRYPTO_REV"
git clone --quiet https://github.com/lczerniawski/crypto.git "$WORK_DIR/crypto"
git -C "$WORK_DIR/crypto" checkout --quiet "$CRYPTO_REV"

echo "==> Precompiling crypto"
mojo precompile "$WORK_DIR/crypto/src/crypto" -o "$WORK_DIR/crypto.mojopkg" 2>&1 | grep -v "deprecated" || true

echo "==> Installing crypto.mojopkg -> $MOJO_LIB/crypto.mojopkg"
cp "$WORK_DIR/crypto.mojopkg" "$MOJO_LIB/crypto.mojopkg"

echo "==> Cloning uuid @ $UUID_REV"
git clone --quiet https://github.com/lczerniawski/uuid.git "$WORK_DIR/uuid"
git -C "$WORK_DIR/uuid" checkout --quiet "$UUID_REV"

echo "==> Precompiling uuid (against freshly built crypto)"
mojo precompile -I "$MOJO_LIB" "$WORK_DIR/uuid/src/uuid" -o "$WORK_DIR/uuid.mojopkg" 2>&1 | grep -v "deprecated" || true

echo "==> Installing uuid.mojopkg -> $MOJO_LIB/uuid.mojopkg"
cp "$WORK_DIR/uuid.mojopkg" "$MOJO_LIB/uuid.mojopkg"

echo "==> Done. crypto and uuid recompiled against $(mojo --version)."
