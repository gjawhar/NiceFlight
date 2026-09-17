#!/bin/sh
# Copies the widget's code into every simulator persist folder that has a
# scripts/ directory. Never touches an existing Files/ folder's data.
SRC="$(cd "$(dirname "$0")/.." && pwd)/NiceFlt"
SIM="$HOME/Library/Application Support/FrSky Suite/.simulator"
for rel in 26.1.1 26.1.2; do
  for radio in X14 X20RS; do
    dst="$SIM/$rel/persist/$radio/scripts"
    [ -d "$dst" ] || continue
    mkdir -p "$dst/NiceFlt/Files" "$dst/NiceFlt/icons"
    cp "$SRC"/*.lua "$dst/NiceFlt/"
    cp "$SRC"/icons/*.png "$dst/NiceFlt/icons/"
    [ -e "$dst/NiceFlt/Files/.gitkeep" ] || touch "$dst/NiceFlt/Files/.gitkeep"
    # simulator macros: one folder each, because Run Macro runs every .lua in a folder
    for m in "$SRC"/../sim/NiceSim*; do
      [ -d "$m" ] || continue
      mkdir -p "$dst/$(basename "$m")"
      cp "$m"/*.lua "$dst/$(basename "$m")/"
    done
    echo "deployed -> $rel/$radio"
  done
done
