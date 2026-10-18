#!/bin/sh
# Renders the Claude Design canvas (design/VoxFlow.dc.html) to a PDF with headless Chrome so the
# actual pixels — not a text extraction — are the reference for UI work and design-fidelity reviews.
# Usage: scripts/render_design.sh [output.pdf]   (default: .superpowers/design/canvas.pdf, git-ignored)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.superpowers/design/canvas.pdf}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
"$CHROME" --headless=new --disable-gpu --no-sandbox --virtual-time-budget=15000 \
  --run-all-compositor-stages-before-draw --window-size=1440,900 --no-pdf-header-footer \
  --print-to-pdf="$OUT" "file://$ROOT/design/VoxFlow.dc.html" 2>/dev/null
echo "$OUT"
