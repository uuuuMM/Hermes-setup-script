#!/usr/bin/env bash
# hermes-setup.sh — bring up Hermes + 9Router on a fresh Linux server
# (built from the working Altare "hermes" app setup: Node 24.22.3,
#  9Router 0.5.116, Hermes Agent v0.23.3, GLM default, 1M context)
#
# Usage:
#   1. Fill in the three keys at the top of this file (or export them).
#   2. Run:  bash hermes-setup.sh
#   3. After a server restart, run it again — it restarts 9Router + gateway
#      (there is no systemd in an Altare sandbox, so nothing auto-starts).
#
# No real secrets are in this file: keys live only in the variables below
# and in the generated config files (mode 600) on the server itself.
# Safe to put in a public repo — just never fill the keys in before pushing.
set -euo pipefail

# ======================= FILL THESE IN =======================
NUMES_API_KEY="${NUMES_API_KEY:-}"            # numes.ai API key (https://api.numes.ai)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"  # Telegram bot token from @BotFather
GEMINI_API_KEY="${GEMINI_API_KEY:-}"          # Google AI Studio (Gemini) API key
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-5967788164}"  # only this Telegram user may use the bot
DEFAULT_MODEL="${DEFAULT_MODEL:-numes/dealignai/glm-5.3-flash-uncensored-fp8}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-1000000}"
# =============================================================

ROUTER_HOST="127.0.0.1"
ROUTER_PORT="20128"
NODE_VERSION="24.22.3"
ROUTER_VERSION="0.5.116"
NUMES_BASE_URL="https://api.numes.ai/api/v1"
GEMINI_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai/"

log() { echo "[hermes-setup] $*"; }
die() { echo "[hermes-setup] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root (Altare apps run as root)"
[ -n "$NUMES_API_KEY" ] || die "NUMES_API_KEY is empty — fill it in at the top of this script"
[ -n "$TELEGRAM_BOT_TOKEN" ] || die "TELEGRAM_BOT_TOKEN is empty — fill it in at the top of this script"
[ -n "$GEMINI_API_KEY" ] || die "GEMINI_API_KEY is empty — fill it in at the top of this script"
case "$TELEGRAM_BOT_TOKEN" in *:* ) ;; * ) die "TELEGRAM_BOT_TOKEN looks wrong (a bot token contains ':')";; esac

# ---------- base tools (git/curl/xz) ----------
if command -v dnf >/dev/null 2>&1; then
  dnf install -y curl git xz 2>/dev/null || true
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y curl git xz-utils 2>/dev/null || true
fi
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v git >/dev/null 2>&1 || die "git is required (the Hermes installer clones its repo)"

# ---------- Node (official tarball, works on AlmaLinux and Debian) ----------
if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q '^v24\.'; then
  log "installing Node $NODE_VERSION ..."
  cd /tmp
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz" -o node.tar.xz
  tar -xJf node.tar.xz
  rm -rf /usr/local/node && mv "node-v$NODE_VERSION-linux-x64" /usr/local/node
  ln -sf /usr/local/node/bin/node /usr/local/bin/node
  ln -sf /usr/local/node/bin/npm /usr/local/bin/npm
  ln -sf /usr/local/node/bin/npx /usr/local/bin/npx
  rm -f node.tar.xz
fi
log "node $(node --version), npm $(npm --version)"

# ---------- 9Router ----------
if ! command -v 9router >/dev/null 2>&1; then
  log "installing 9Router $ROUTER_VERSION ..."
  npm install -g "9router@$ROUTER_VERSION"
fi
log "9router installed: $(command -v 9router)"

# ---------- Hermes Agent (official installer, non-interactive) ----------
if ! command -v hermes >/dev/null 2>&1; then
  log "installing Hermes Agent (official installer) ..."
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v hermes >/dev/null 2>&1 || die "hermes CLI not found after install — read the installer output above"
log "hermes installed: $(command -v hermes)"

# ---------- provider files for 9Router ----------
cat > "$HOME/numes-provider.json" <<EOF
{
  "provider": "openai-compatible",
  "name": "numes",
  "displayName": "Numes",
  "providerSpecificData": {
    "prefix": "numes",
    "apiType": "chat",
    "baseUrl": "$NUMES_BASE_URL"
  },
  "baseUrl": "$NUMES_BASE_URL",
  "apiKey": "$NUMES_API_KEY"
}
EOF
cat > "$HOME/gemini-provider.json" <<EOF
{
  "provider": "openai-compatible",
  "name": "gemini",
  "displayName": "Gemini",
  "providerSpecificData": {
    "prefix": "gemini",
    "apiType": "chat",
    "baseUrl": "$GEMINI_BASE_URL"
  },
  "apiKey": "$GEMINI_API_KEY"
}
EOF
chmod 600 "$HOME/numes-provider.json" "$HOME/gemini-provider.json"
log "provider files written: ~/numes-provider.json ~/gemini-provider.json"

# ---------- Hermes config ----------
mkdir -p "$HOME/.hermes/logs"
cat > "$HOME/.hermes/.env" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ALLOWED_USERS=$TELEGRAM_USER_ID
EOF
chmod 600 "$HOME/.hermes/.env"
cat > "$HOME/.hermes/config.yaml" <<EOF
provider: custom
base_url: http://$ROUTER_HOST:$ROUTER_PORT/v1
model: $DEFAULT_MODEL
context_length: $CONTEXT_LENGTH
platforms:
  telegram:
    enabled: true
    token: \${TELEGRAM_BOT_TOKEN}
    allow_from:
      - $TELEGRAM_USER_ID
EOF
log "Hermes config written: ~/.hermes/config.yaml (model $DEFAULT_MODEL, context $CONTEXT_LENGTH)"

# ---------- (re)start 9Router ----------
kill_matching() {
  local pat="$1"
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$pat" 2>/dev/null || true
    return
  fi
  # no pkill and no ps on Altare sandboxes — scan /proc instead
  local d pid cmd
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ "$pid" = "$$" ] && continue
    [ -r "$d/cmdline" ] || continue
    cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null || true)"
    case "$cmd" in *"$pat"*) kill "$pid" 2>/dev/null || true ;; esac
  done
}
kill_matching "9router"
kill_matching "hermes gateway"
sleep 2
log "starting 9Router on $ROUTER_HOST:$ROUTER_PORT ..."
nohup 9router -H "$ROUTER_HOST" -p "$ROUTER_PORT" --no-browser -t --skip-update > "$HOME/9router.log" 2>&1 &
ROUTER_OK=0
for _ in $(seq 1 30); do
  if curl -s "http://$ROUTER_HOST:$ROUTER_PORT/v1/models" 2>/dev/null | grep -q "numes/"; then
    log "9Router answers /v1/models and lists numes models"
    ROUTER_OK=1
    break
  fi
  sleep 2
done
if [ "$ROUTER_OK" != "1" ]; then
  echo "WARNING: 9Router is up but no numes model is listed in /v1/models."
  echo "Add the providers by hand in the dashboard: http://$ROUTER_HOST:$ROUTER_PORT/dashboard"
  echo "  Providers -> OpenAI Compatible: Name=numes Prefix=numes API type=chat Base URL=$NUMES_BASE_URL, then add a connection with your numes key."
  echo "  Same for Gemini: Name=gemini Prefix=gemini API type=chat Base URL=$GEMINI_BASE_URL, connection with your Gemini key."
fi

# ---------- (re)start Hermes gateway ----------
log "starting Hermes gateway ..."
nohup hermes gateway run > "$HOME/.hermes/logs/gateway.log" 2>&1 &
sleep 10
if grep -q "Connected to Telegram" "$HOME/.hermes/logs/gateway.log" 2>/dev/null; then
  log "Telegram CONNECTED (polling mode)"
else
  echo "WARNING: gateway log does not show 'Connected to Telegram' yet."
  echo "Check: tail -50 ~/.hermes/logs/gateway.log"
  echo "If it says 'no adapter available for enabled telegram', run once: hermes setup  (interactive)"
fi

echo
echo "[hermes-setup] DONE."
echo "  9Router dashboard: http://$ROUTER_HOST:$ROUTER_PORT/dashboard  (default password 123456 — CHANGE IT)"
echo "  In Telegram, send /set-home in the bot chat to set the home channel."
echo "  If the server restarts, run this script again (no systemd in the sandbox)."
