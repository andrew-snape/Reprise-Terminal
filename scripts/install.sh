#!/bin/zsh
# Builds reprise in release mode and links it into ~/.local/bin.
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release
mkdir -p ~/.local/bin
ln -sf "$PWD/.build/release/reprise" ~/.local/bin/reprise
echo "Installed: ~/.local/bin/reprise"
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || echo "Add ~/.local/bin to your PATH to run it as 'reprise'."
