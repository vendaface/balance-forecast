#!/usr/bin/env bash
# reset-for-testing.sh — wipes all runtime files to simulate a fresh clone
# DO NOT run this on a live installation you care about.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Resolve APP_DATA_DIR (mirrors paths.py logic) ────────────────────────────
if [ "$(uname)" = "Darwin" ]; then
  APP_DATA_DIR="$HOME/Library/Application Support/Butterfly Effect"
else
  XDG="${XDG_DATA_HOME:-$HOME/.local/share}"
  APP_DATA_DIR="$XDG/butterfly-effect"
fi

PLAYWRIGHT_CACHE="$HOME/.cache/butterfly-effect/playwright"

# ── Quick browser-only reset ──────────────────────────────────────────────────
if [ "${1:-}" = "--browser-only" ]; then
  if [ -d "$PLAYWRIGHT_CACHE" ]; then
    rm -rf "$PLAYWRIGHT_CACHE"
    echo "Deleted Playwright cache: $PLAYWRIGHT_CACHE"
    echo "Chromium will re-download (~150 MB) on next launch or Connect to Monarch."
  else
    echo "Playwright cache not found — already clean."
  fi
  exit 0
fi

echo "This will kill the running server and delete all runtime files and the virtual environment."
echo ""
echo "  App data dir : $APP_DATA_DIR"
echo "  Project dir  : $SCRIPT_DIR"
echo ""
echo "Use this only for testing a fresh install simulation."
echo ""
read -p "Also delete the Playwright Chromium browser cache (~150 MB re-download)? (yes/no): " del_browser

echo ""
read -p "Are you sure you want to reset everything? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ""

# ── Kill running server ───────────────────────────────────────────────────────
if [ -f "$SCRIPT_DIR/.server.pid" ]; then
  pid=$(cat "$SCRIPT_DIR/.server.pid")
  if kill -0 "$pid" 2>/dev/null; then
    echo "  killing server (pid $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
fi

# Kill by port as well (covers run.sh and bundled app invocations)
port_pid=$(lsof -ti tcp:5002 2>/dev/null || true)
if [ -n "$port_pid" ]; then
  echo "  killing process on port 5002 (pid $port_pid)..."
  kill "$port_pid" 2>/dev/null || true
  sleep 1
fi

# ── Delete runtime files from APP_DATA_DIR ───────────────────────────────────
echo "  deleting runtime files from: $APP_DATA_DIR"

app_data_files=(
  .env
  config.yaml
  browser_state.json
  insights.json
  payment_overrides.json
  payment_monthly_amounts.json
  payment_skips.json
  payment_day_overrides.json
  scenarios.json
  dismissed_suggestions.json
  monarch_accounts_cache.json
  monarch_raw_cache.json
  user_context.md
)

for f in "${app_data_files[@]}"; do
  target="$APP_DATA_DIR/$f"
  if [ -e "$target" ]; then
    rm -f "$target"
    echo "    deleted: $target"
  fi
done

# Also catch macOS "duplicate" variants (e.g. ".env 2", "config 2.yaml")
while IFS= read -r -d '' f; do
  rm -f "$f"
  echo "    deleted: $f"
done < <(find "$APP_DATA_DIR" -maxdepth 1 \( \
    -name ".env [0-9]*"           \
    -o -name "config [0-9]*.yaml" \
    -o -name "user_context [0-9]*.md" \
  \) -print0 2>/dev/null)

# ── Delete leftover runtime files from project dir (pre-migration remnants) ──
echo "  checking project dir for pre-migration remnants..."

project_files=(
  .env
  ".env 2"
  config.yaml
  "config 2.yaml"
  browser_state.json
  insights.json
  payment_overrides.json
  payment_monthly_amounts.json
  payment_skips.json
  payment_day_overrides.json
  scenarios.json
  dismissed_suggestions.json
  monarch_accounts_cache.json
  monarch_raw_cache.json
  user_context.md
  .server.pid
  .server.log
)

for f in "${project_files[@]}"; do
  if [ -e "$SCRIPT_DIR/$f" ]; then
    rm -f "$SCRIPT_DIR/$f"
    echo "    deleted (legacy): $SCRIPT_DIR/$f"
  fi
done

# Numbered duplicate patterns in project dir
while IFS= read -r -d '' f; do
  rm -f "$f"
  echo "    deleted (legacy): $f"
done < <(find "$SCRIPT_DIR" -maxdepth 1 \( \
    -name ".env [0-9]*"           \
    -o -name "config [0-9]*.yaml" \
    -o -name "user_context [0-9]*.md" \
    -o -name "* [0-9]*.py"        \
    -o -name "* [0-9]*.sh"        \
    -o -name "* [0-9]*.command"   \
    -o -name ".server [0-9]*.pid" \
    -o -name ".server [0-9]*.log" \
    -o -name "*.json"             \
  \) -print0 2>/dev/null)

# ── Delete Playwright browser cache (optional) ────────────────────────────────
if [ "$del_browser" = "yes" ]; then
  if [ -d "$PLAYWRIGHT_CACHE" ]; then
    rm -rf "$PLAYWRIGHT_CACHE"
    echo "  deleted Playwright cache: $PLAYWRIGHT_CACHE"
  else
    echo "  Playwright cache not found (already clean)"
  fi
else
  echo "  skipping Playwright cache (will reuse existing browser)"
fi

# ── __pycache__ directories ───────────────────────────────────────────────────
while IFS= read -r -d '' d; do
  rm -rf "$d"
  echo "    deleted: $d"
done < <(find "$SCRIPT_DIR" -type d -name "__pycache__" -print0 2>/dev/null)

# ── Virtual environment ───────────────────────────────────────────────────────
VENV="$SCRIPT_DIR/.venv"
if [ -d "$VENV" ]; then
  chmod -R u+w "$VENV" 2>/dev/null || true
  rm -rf "$VENV"
  echo "  deleted: $VENV"
fi

# Clean up old venv locations if they still exist
for old in "$HOME/.cache/butterfly-effect-venv" "$HOME/.cache/balance-forecast-venv"; do
  if [ -d "$old" ]; then
    rm -rf "$old"
    echo "  deleted (legacy venv): $old"
  fi
done

# macOS-numbered duplicate venvs
while IFS= read -r -d '' d; do
  rm -rf "$d"
  echo "    deleted: $d"
done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name ".venv* [0-9]*" -print0 2>/dev/null)

echo ""
echo "Done. Run './run.sh' or open the .app bundle to test a fresh install."
