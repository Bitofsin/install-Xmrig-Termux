#!/data/data/com.termux/files/usr/bin/bash
# XMRig build + setup for Android (Termux)
# Builds either upstream XMRig or the MoneroOcean fork (algo-switching).
# Both can be installed side by side - just run the script twice.
# Re-run any time to change pool/wallet without rebuilding.
#
# Usage: bash xmrig-setup.sh        (no sudo/root needed)
#   Optional env overrides (skip the matching prompt):
#     VARIANT=upstream|moneroocean   XMRIG_VERSION=<tag>
#     POOL=host:port   TLS=y|n   WALLET=<address>   WORKER=<name>
set -euo pipefail

# ---------- Defaults ----------
DEFAULT_WALLET="49EerUEecJxcFaJUGfEpyna91u5HU1ykHVJnP2BmnT4N3NpDd6qmdfPXzaFx6uRRzEiTMErpieeCiKwyhrbJ1JC29rtu66L"
PROMPT_TIMEOUT=120

# ---------- Preflight ----------
if [[ "${PREFIX:-}" != *com.termux* ]]; then
  echo "This script is meant to run inside Termux on Android." >&2
  exit 1
fi
if [[ $EUID -eq 0 ]]; then
  echo "Don't run this as root - run it as the normal Termux user." >&2
  exit 1
fi

# Prompt with timeout; falls back to default on timeout, blank input, or no TTY
ask() {
  local prompt="$1" default="$2" reply=""
  if [[ -t 0 ]]; then
    if ! read -r -t "$PROMPT_TIMEOUT" -p "$prompt [$default]: " reply; then
      echo >&2   # newline after timeout
    fi
  fi
  echo "${reply:-$default}"
}

yes_no() { [[ "$1" =~ ^[Yy] ]]; }

section() { echo; echo "=== $1 ==="; }

# ---------- Detected hardware ----------
CORES="$(nproc)"
ARCH="$(uname -m)"
MEM_TOTAL_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_AVAIL_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
MODEL="$(getprop ro.product.model 2>/dev/null || true)"
section "Device"
echo "${MODEL:-Android device}: $ARCH, $CORES cores, ${MEM_TOTAL_MB} MB RAM (${MEM_AVAIL_MB} MB free)"
case "$ARCH" in
  aarch64|arm64|x86_64) ;;
  *) echo "Note: $ARCH is a 32-bit CPU mode - RandomX will be much slower here." ;;
esac

# =====================================================================
#  ALL QUESTIONS UP FRONT - the build then runs unattended
# =====================================================================

# ---------- 1. Miner variant ----------
section "Miner"
if [[ -z "${VARIANT:-}" ]]; then
  echo "  1) Standard XMRig     - xmrig/xmrig, works with any Monero pool"
  echo "  2) MoneroOcean XMRig  - MoneroOcean/xmrig, auto-switches to the most"
  echo "                          profitable algo (only on the MoneroOcean pool)"
  choice="$(ask "Choose 1 or 2" "1")"
  case "$choice" in
    1|upstream|standard|s|u) VARIANT="upstream" ;;
    2|moneroocean|mo|m)      VARIANT="moneroocean" ;;
    *) echo "Invalid choice '$choice'" >&2; exit 1 ;;
  esac
fi

case "$VARIANT" in
  upstream)    REPO="https://github.com/xmrig/xmrig.git";       SUFFIX="";    LABEL="Standard XMRig" ;;
  moneroocean) REPO="https://github.com/MoneroOcean/xmrig.git"; SUFFIX="-mo"; LABEL="MoneroOcean XMRig" ;;
  *) echo "Unknown VARIANT '$VARIANT' (use upstream or moneroocean)" >&2; exit 1 ;;
esac

INSTALL_DIR="$HOME/xmrig$SUFFIX"
START_SCRIPT="$HOME/startxmrig$SUFFIX.sh"
STOP_SCRIPT="$HOME/stopxmrig.sh"
BOOT_DIR="$HOME/.termux/boot"
BOOT_SCRIPT="$BOOT_DIR/start-xmrig$SUFFIX"

DO_BUILD=1
if [[ -x "$INSTALL_DIR/xmrig" ]]; then
  echo "$LABEL is already built in $INSTALL_DIR."
  yes_no "$(ask "Rebuild it? (n = just change settings)" "n")" || DO_BUILD=0
fi

# ---------- 2. Pool ----------
section "Pool"
if [[ -z "${POOL:-}" ]]; then
  if [[ "$VARIANT" == "moneroocean" ]]; then default_pool=1; else default_pool=2; fi
  echo "  1) MoneroOcean        gulf.moneroocean.stream:10128"
  echo "  2) SupportXMR         pool.supportxmr.com:3333"
  echo "  3) Custom             enter your own host:port"
  pchoice="$(ask "Choose a pool" "$default_pool")"
  case "$pchoice" in
    1) POOL="gulf.moneroocean.stream:10128" ;;
    2) POOL="pool.supportxmr.com:3333" ;;
    3)
      POOL=""
      while [[ -z "$POOL" ]]; do
        POOL="$(ask "Pool address (host:port)" "")"
        if ! [[ "$POOL" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]]; then
          echo "That doesn't look like host:port - try again."
          POOL=""
          [[ -t 0 ]] || { echo "No pool given." >&2; exit 1; }
        fi
      done
      ;;
    *) echo "Invalid choice '$pchoice'" >&2; exit 1 ;;
  esac
fi

if [[ -z "${TLS:-}" ]]; then
  TLS="$(ask "Use TLS for this pool? Only if the port supports it (y/n)" "n")"
fi
yes_no "$TLS" && TLS_FLAG="--tls" || TLS_FLAG=""

if [[ "$VARIANT" == "moneroocean" && "$POOL" != *moneroocean* ]]; then
  echo "Note: algo switching only works on the MoneroOcean pool - on $POOL"
  echo "      the MoneroOcean build will just mine like standard XMRig."
fi

# ---------- 3. Wallet ----------
section "Wallet"
if [[ -z "${WALLET:-}" ]]; then
  while :; do
    WALLET="$(ask "Monero wallet address (or pool username)" "$DEFAULT_WALLET")"
    # Standard (95 char) or integrated (106 char) address starting with 4 or 8
    if [[ "$WALLET" =~ ^[48][1-9A-HJ-NP-Za-km-z]{94}$ || "$WALLET" =~ ^4[1-9A-HJ-NP-Za-km-z]{105}$ ]]; then
      break
    fi
    echo "That isn't a standard Monero address."
    yes_no "$(ask "Use it anyway? (fine for custom pools with usernames) (y/n)" "n")" && break
    [[ -t 0 ]] || { echo "Invalid wallet." >&2; exit 1; }
  done
fi

if [[ -z "${WORKER:-}" ]]; then
  default_worker="$(echo "${MODEL:-android}" | tr -c 'A-Za-z0-9_-' '_' | sed 's/_*$//')"
  WORKER="$(ask "Worker name (shows on the pool dashboard; sent as the password)" "${default_worker:-x}")"
fi

# ---------- 4. Performance ----------
section "Performance"
echo "'auto' re-detects cores and free RAM every time the miner starts."
THREADS="$(ask "Mining threads (auto or a number, phone has $CORES cores)" "auto")"
if [[ "$THREADS" != "auto" ]] && { ! [[ "$THREADS" =~ ^[0-9]+$ ]] || (( THREADS < 1 )); }; then
  echo "Invalid thread count '$THREADS', using auto"; THREADS="auto"
fi
MODE="$(ask "RandomX mode (auto/fast/light)" "auto")"
case "$MODE" in auto|fast|light) ;; *) echo "Invalid mode, using auto"; MODE="auto" ;; esac

# ---------- 5. Autostart ----------
BOOT="$(ask "Start this miner automatically on boot? Needs the Termux:Boot app (y/n)" "n")"

# ---------- Confirm ----------
section "Summary"
echo "  Miner:     $LABEL $([[ $DO_BUILD == 1 ]] && echo '(will build)' || echo '(keep existing build)')"
echo "  Pool:      $POOL ${TLS_FLAG:+(TLS)}"
if (( ${#WALLET} > 24 )); then
  echo "  Wallet:    ${WALLET:0:12}...${WALLET: -8}"
else
  echo "  Wallet:    $WALLET"
fi
echo "  Worker:    $WORKER"
echo "  Threads:   $THREADS    Mode: $MODE"
echo "  Autostart: $(yes_no "$BOOT" && echo yes || echo no)"
yes_no "$(ask "Continue? (y/n)" "y")" || { echo "Cancelled."; exit 0; }

# =====================================================================
#  BUILD
# =====================================================================
if (( DO_BUILD )); then
  section "Installing packages"
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confnew" upgrade
  apt-get -y install git cmake clang make binutils libuv openssl

  if [[ -z "${XMRIG_VERSION:-}" ]]; then
    XMRIG_VERSION="$(git ls-remote --tags --sort=-v:refname "$REPO" 'v*' \
      | grep -v '\^{}' | head -n1 | sed 's#.*refs/tags/##' || true)"
  fi

  BUILD_ROOT="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/xmrig-build.XXXXXX")"
  trap 'rm -rf "$BUILD_ROOT"' EXIT

  section "Building $LABEL ${XMRIG_VERSION:-(default branch)}"
  if [[ -n "$XMRIG_VERSION" ]]; then
    git clone --depth 1 --branch "$XMRIG_VERSION" "$REPO" "$BUILD_ROOT/xmrig"
  else
    git clone --depth 1 "$REPO" "$BUILD_ROOT/xmrig"
  fi

  # hwloc OFF: Android doesn't expose the CPU topology it needs.
  # Jobs scale with free RAM (~1 GB each), capped at 4 to avoid OOM/overheating.
  JOBS=$(( MEM_AVAIL_MB / 1024 ))
  (( JOBS > CORES )) && JOBS=$CORES
  (( JOBS > 4 )) && JOBS=4
  (( JOBS < 1 )) && JOBS=1
  echo "Compiling with $JOBS parallel jobs"
  cmake -S "$BUILD_ROOT/xmrig" -B "$BUILD_ROOT/xmrig/build" \
    -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=OFF
  cmake --build "$BUILD_ROOT/xmrig/build" -j"$JOBS"

  mkdir -p "$INSTALL_DIR"
  install -m 755 "$BUILD_ROOT/xmrig/build/xmrig" "$INSTALL_DIR/xmrig"
fi

# =====================================================================
#  WRITE LAUNCHER, STOP SCRIPT, AUTOSTART
# =====================================================================

# Part 1: saved settings (values safely quoted)
cat > "$START_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# $LABEL launcher - re-run xmrig-setup.sh to change these settings
# Override per run:  THREADS=4 MODE=light $START_SCRIPT
INSTALL_DIR=$(printf %q "$INSTALL_DIR")
POOL=$(printf %q "$POOL")
TLS_FLAG=$(printf %q "$TLS_FLAG")
WALLET=$(printf %q "$WALLET")
PASS=$(printf %q "$WORKER")
THREADS="\${THREADS:-$THREADS}"
MODE="\${MODE:-$MODE}"
EOF

# Part 2: runtime detection + wake-lock handling (written literally)
cat >> "$START_SCRIPT" <<'EOF'

# ---- Auto-detect resources at launch ----
CORES="$(nproc)"
MEM_AVAIL_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"

if [[ "$THREADS" == "auto" ]]; then
  # Leave one core free on bigger chips so the phone stays responsive
  THREADS=$CORES
  (( CORES > 4 )) && THREADS=$(( CORES - 1 ))
fi

if [[ "$MODE" == "auto" ]]; then
  # Fast mode needs ~2.3 GB for the RandomX dataset; keep headroom for Android
  if (( MEM_AVAIL_MB >= 3000 )); then MODE="fast"; else MODE="light"; fi
fi

echo "Starting XMRig on $POOL: $THREADS threads, RandomX $MODE mode (${MEM_AVAIL_MB} MB free, $CORES cores)"

# ---- Wake lock: held while mining, always released on exit ----
have_wakelock=0
command -v termux-wake-lock >/dev/null 2>&1 && have_wakelock=1

cleanup() {
  trap - EXIT INT TERM HUP
  if [[ -n "${MINER_PID:-}" ]] && kill -0 "$MINER_PID" 2>/dev/null; then
    kill -TERM "$MINER_PID" 2>/dev/null
    wait "$MINER_PID" 2>/dev/null
  fi
  if (( have_wakelock )); then
    termux-wake-unlock
    echo "Miner stopped - wake lock released."
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

(( have_wakelock )) && termux-wake-lock

cd "$INSTALL_DIR" || exit 1
ARGS=(-o "$POOL" -u "$WALLET" -p "$PASS" -t "$THREADS" --randomx-mode="$MODE")
[[ -n "$TLS_FLAG" ]] && ARGS+=("$TLS_FLAG")

# Keep the keyboard attached so XMRig hotkeys (h = hashrate, p = pause) still work
if [[ -t 0 ]]; then
  ./xmrig "${ARGS[@]}" "$@" <&0 &
else
  ./xmrig "${ARGS[@]}" "$@" &
fi
MINER_PID=$!
wait "$MINER_PID"
EOF
chmod +x "$START_SCRIPT"

# Stop script (works for both variants)
cat > "$STOP_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Stops any running XMRig launcher; its exit handler releases the wake lock.
if pkill -TERM -f 'startxmrig(-mo)?\.sh'; then
  sleep 2
  echo "XMRig stopped."
else
  echo "No XMRig launcher was running."
fi
# Catch a stray miner or a lock left behind by a crash
pkill -TERM -x xmrig 2>/dev/null || true
command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
EOF
chmod +x "$STOP_SCRIPT"

# Autostart via Termux:Boot
if yes_no "$BOOT"; then
  mkdir -p "$BOOT_DIR"
  # Only one miner should autostart - they'd fight over the same cores
  for other in "$BOOT_DIR/start-xmrig" "$BOOT_DIR/start-xmrig-mo"; do
    if [[ "$other" != "$BOOT_SCRIPT" && -e "$other" ]]; then
      echo "Removing $(basename "$other") from autostart"
      rm -f "$other"
    fi
  done
  cat > "$BOOT_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec $(printf %q "$START_SCRIPT") >> $(printf %q "$HOME/xmrig$SUFFIX.log") 2>&1
EOF
  chmod +x "$BOOT_SCRIPT"
  echo "Autostart set. Open the Termux:Boot app once so Android lets it run."
  echo "Boot log: ~/xmrig$SUFFIX.log"
else
  rm -f "$BOOT_SCRIPT"
fi

section "Done"
echo "  Start:  $START_SCRIPT"
echo "  Stop:   Ctrl+C, or run $STOP_SCRIPT from another session"
echo "  Change pool/wallet later: run this setup again and choose not to rebuild."
