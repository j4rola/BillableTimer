#!/bin/bash
# Installs BillableTimer for the current user. Nothing here needs root.
#
#   ./install.sh              install or update
#   ./install.sh --uninstall  remove the app (your billing data is left alone)
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

APP_ID="io.github.j4rola.BillableTimer"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LIB_DIR="$DATA_HOME/billabletimer-app"
BIN="$HOME/.local/bin/billabletimer"
DESKTOP="$DATA_HOME/applications/$APP_ID.desktop"
ICON="$DATA_HOME/icons/hicolor/512x512/apps/$APP_ID.png"

if [ "${1:-}" = "--uninstall" ]; then
    rm -rf "$LIB_DIR"
    rm -f "$BIN" "$DESKTOP" "$ICON"
    echo "Removed. Billing data remains in $DATA_HOME/BillableTimer"
    exit 0
fi

mkdir -p "$LIB_DIR" "$(dirname "$BIN")" "$(dirname "$DESKTOP")" "$(dirname "$ICON")"
rm -rf "$LIB_DIR/billabletimer"
cp -R billabletimer "$LIB_DIR/billabletimer"
find "$LIB_DIR" -name __pycache__ -type d -prune -exec rm -rf {} +
cp billabletimer/icon.png "$ICON"
cp "data/$APP_ID.desktop" "$DESKTOP"

cat > "$BIN" <<WRAPPER
#!/bin/bash
export PYTHONPATH="$LIB_DIR\${PYTHONPATH:+:\$PYTHONPATH}"
exec python3 -m billabletimer "\$@"
WRAPPER
chmod +x "$BIN"

gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true
update-desktop-database -q "$DATA_HOME/applications" 2>/dev/null || true
echo "Installed. Launch BillableTimer from your app launcher, or run: billabletimer"
