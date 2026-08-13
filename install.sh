#!/usr/bin/env bash
# Convenience installer: clone okx-p2p-api and run the interactive expose.sh.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sarakmacbook/okx-p2p-api/main/install.sh | bash
# or just:
#   ./install.sh
set -euo pipefail
REPO="https://github.com/sarakmacbook/okx-p2p-api.git"
DIR="okx-p2p-api"

if [[ ! -d "$DIR" ]]; then
  echo "==> cloning $REPO"
  git clone "$REPO" "$DIR"
fi
cd "$DIR"
chmod +x expose.sh
echo "==> running installer (this will prompt for merchant / fiat / payment / port / domain)"
./expose.sh
