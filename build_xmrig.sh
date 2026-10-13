#!/data/data/com.termux/files/usr/bin/bash
# XMRig build + setup for Android (Termux)
# Builds either upstream XMRig or the MoneroOcean fork (algo-switching).
# Both can be installed side by side - just run the script twice.
# Re-run any time to change pool/wallet without rebuilding.
#
# Usage: ./build_xmrig.sh            full-screen setup (uses 'dialog')
#        ./build_xmrig.sh --update   update installed miner(s) to the latest
#                                    release; settings are left untouched
#        ./build_xmrig.sh --no-tui   plain text prompts
#   Optional env overrides (skip the matching question):
#     VARIANT=upstream|moneroocean   XMRIG_VERSION=<tag or branch, e.g. master>
#     POOL=host:port   TLS=y|n   WALLET=<address>   WORKER=<name>   PASSWORD=<pass>
#     FORCE=1  rebuild on --update even if already on the latest release
set -euo pipefail

ACTION="setup"
for arg in "$@"; do
  case "$arg" in
    --update|-u) ACTION="update" ;;
    --no-tui)    NO_TUI=1 ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

# ---------- Defaults ----------
DEFAULT_ADDRESS="4AWoQHUkUKXM1V14ouEZPob6vanoBixWShagabfC6pbbdLNz1Gonu2TC3oHbucze4LSZndL4UAkYaS1esnakwbY1MKR7CZu"
THEMULE_POOL="pool.themule.online:6337"
MONEROOCEAN_POOL="gulf.moneroocean.stream:10128"
SUPPORTXMR_POOL="pool.supportxmr.com:3333"
PROMPT_TIMEOUT=120
LOG="$HOME/xmrig-build.log"
LOG_SHOW="${LOG/#"$HOME"/\~}"   # ~/xmrig-build.log for display
BACKTITLE="XMRig setup for Termux"

# ---------- Preflight ----------
if [[ "${PREFIX:-}" != *com.termux* ]]; then
  echo "This script is meant to run inside Termux on Android." >&2
  exit 1
fi
if [[ $EUID -eq 0 ]]; then
  echo "Don't run this as root - run it as the normal Termux user." >&2
  exit 1
fi

# =====================================================================
#  UI LAYER - full-screen 'dialog' screens, or plain prompts as fallback
# =====================================================================
USE_TUI=0
if [[ -t 0 && -t 1 && "${NO_TUI:-0}" != 1 ]]; then
  if ! command -v dialog >/dev/null 2>&1; then
    echo "Installing 'dialog' for the setup screens..."
    { apt-get update && apt-get -y install dialog; } >/dev/null 2>&1 || true
  fi
  command -v dialog >/dev/null 2>&1 && USE_TUI=1
fi
# Distinct exit codes so a timeout means "use the default", Cancel means quit
export DIALOG_OK=0 DIALOG_CANCEL=1 DIALOG_ESC=255 DIALOG_TIMEOUT=5

term_size() {
  local s; s="$(stty size 2>/dev/null || echo "24 80")"
  TERM_H="${s% *}"; TERM_W="${s#* }"
  (( TERM_H < 12 )) && TERM_H=12
  (( TERM_W < 40 )) && TERM_W=40
  return 0
}

dlg() { dialog --stdout --cr-wrap --no-collapse --backtitle "$BACKTITLE" --timeout "$PROMPT_TIMEOUT" "$@"; }

cancel_setup() {
  (( USE_TUI )) && clear
  echo "Setup cancelled - nothing was changed."
  exit 0
}

# Plain-text prompt with timeout; default on timeout, blank input, or no TTY
ask() {
  local prompt="$1" default="$2" reply=""
  if [[ -t 0 ]]; then
    if ! read -r -t "$PROMPT_TIMEOUT" -p "$prompt [$default]: " reply; then
      echo >&2
    fi
  fi
  echo "${reply:-$default}"
}
yes_no() { [[ "$1" =~ ^[Yy] ]]; }

# ui_menu VAR "title" "text" default tag1 desc1 tag2 desc2 ...
ui_menu() {
  local __var="$1" title="$2" text="$3" default="$4" res="" rc=0
  shift 4
  if (( USE_TUI )); then
    res="$(dlg --title "$title" --default-item "$default" --menu "$text" 0 0 0 "$@")" || rc=$?
    (( rc == 1 )) && cancel_setup
    (( rc == 0 )) || res="$default"
  else
    echo; echo "== $title =="; echo -e "$text"
    while (( $# )); do printf '  %s) %s\n' "$1" "$2"; shift 2; done
    res="$(ask "Choose" "$default")"
  fi
  printf -v "$__var" '%s' "$res"
}

# ui_input VAR "title" "text" default
ui_input() {
  local __var="$1" title="$2" text="$3" default="$4" res="" rc=0
  if (( USE_TUI )); then
    res="$(dlg --title "$title" --inputbox "$text" 0 0 "$default")" || rc=$?
    (( rc == 1 )) && cancel_setup
    (( rc == 0 )) || res="$default"
    res="${res:-$default}"
  else
    echo; echo "== $title =="
    res="$(ask "$(echo -e "$text" | head -n1)" "$default")"
  fi
  printf -v "$__var" '%s' "$res"
}

# ui_yesno "title" "text" y|n   -> returns 0 for yes
ui_yesno() {
  local title="$1" text="$2" default="$3" rc=0
  if (( USE_TUI )); then
    local extra=(); [[ "$default" == n ]] && extra=(--defaultno)
    dlg --title "$title" "${extra[@]+"${extra[@]}"}" --yesno "$text" 0 0 >/dev/null || rc=$?
    case $rc in
      0) return 0 ;;
      1) return 1 ;;
      *) [[ "$default" == y ]]; return ;;   # timeout / Esc -> default
    esac
  else
    yes_no "$(ask "$(echo -e "$text" | tr '\n' ' ') (y/n)" "$default")"
  fi
}

# ui_msg "title" "text"  (short timeout so it never blocks unattended runs)
ui_msg() {
  if (( USE_TUI )); then
    dialog --cr-wrap --no-collapse --backtitle "$BACKTITLE" --title "$1" --timeout 30 --msgbox "$2" 0 0 || true
  else
    echo; echo "== $1 =="; echo -e "$2"
  fi
}

fail() {
  if (( USE_TUI )); then
    term_size
    dialog --cr-wrap --no-collapse --backtitle "$BACKTITLE" --title "Setup failed" --msgbox \
      "$1\n\nLast lines of $LOG_SHOW:\n\n$(tail -n $(( TERM_H - 14 > 3 ? TERM_H - 14 : 3 )) "$LOG" 2>/dev/null)" \
      $(( TERM_H - 2 )) $(( TERM_W - 2 )) || true
    clear
  fi
  echo "$1 - full log: $LOG" >&2
  exit 1
}

# run_step "title" cmd...   streams output in a scrolling box, logs everything
run_step() {
  local title="$1"; shift
  echo "### $title" >> "$LOG"
  if (( USE_TUI )); then
    term_size
    { "$@" 2>&1 | tee -a "$LOG"; } \
      | dialog --backtitle "$BACKTITLE" --title "$title" --progressbox $(( TERM_H - 4 )) $(( TERM_W - 4 ))
  else
    section "$title"
    "$@" 2>&1 | tee -a "$LOG"
  fi
}

section() { echo; echo "=== $1 ==="; }

# ---------- Pool helpers ----------
POOL_IS_SSL=0
normalize_pool() {   # strips stratum+tcp:// etc. and any path -> host:port
  local p="$1"; p="${p#*://}"; p="${p%%/*}"; echo "$p"
}
is_ssl_url() { [[ "$1" =~ ^(stratum\+ssl|stratum\+tls|ssl|tls):// ]]; }
valid_pool() { [[ "$1" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]]; }

# ---------- Detected hardware ----------
CORES="$(nproc)"
ARCH="$(uname -m)"
MEM_TOTAL_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_AVAIL_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
MODEL="$(getprop ro.product.model 2>/dev/null || true)"
DEVICE_LINE="${MODEL:-Android device}: $ARCH, $CORES cores, ${MEM_TOTAL_MB} MB RAM (${MEM_AVAIL_MB} MB free)"
case "$ARCH" in
  aarch64|arm64|x86_64) ARCH_NOTE="" ;;
  *) ARCH_NOTE="\nNote: $ARCH is a 32-bit CPU mode - RandomX will be much slower." ;;
esac
(( USE_TUI )) || { section "Device"; echo -e "$DEVICE_LINE$ARCH_NOTE"; }

# =====================================================================
#  VARIANTS, VERSIONS AND BUILD
# =====================================================================
set_variant() {
  case "$1" in
    upstream)    REPO="https://github.com/xmrig/xmrig.git";       SUFFIX="";    LABEL="Standard XMRig" ;;
    moneroocean) REPO="https://github.com/MoneroOcean/xmrig.git"; SUFFIX="-mo"; LABEL="MoneroOcean XMRig" ;;
    *) echo "Unknown VARIANT '$1' (use upstream or moneroocean)" >&2; exit 1 ;;
  esac
  VARIANT="$1"
  INSTALL_DIR="$HOME/xmrig$SUFFIX"
  VERSION_FILE="$INSTALL_DIR/VERSION"
  START_SCRIPT="$HOME/startxmrig$SUFFIX.sh"
  STOP_SCRIPT="$HOME/stopxmrig.sh"
  BOOT_DIR="$HOME/.termux/boot"
  BOOT_SCRIPT="$BOOT_DIR/start-xmrig$SUFFIX"
}

is_installed() { [[ -x "$INSTALL_DIR/xmrig" ]]; }

# Version recorded at build time; older installs fall back to asking the binary
installed_version() {
  if [[ -s "$VERSION_FILE" ]]; then
    head -n1 "$VERSION_FILE"
  else
    local v; v="$("$INSTALL_DIR/xmrig" --version 2>/dev/null | head -n1 | awk '{print $2}')"
    [[ -n "$v" ]] && echo "v${v#v}" || echo "unknown"
  fi
}

# Newest release tag of $REPO (empty if none / offline)
latest_tag() {
  git ls-remote --tags --sort=-v:refname "$REPO" 'v*' 2>>"$LOG" \
    | grep -v '\^{}' | head -n1 | sed 's#.*refs/tags/##' || true
}

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  run_step "Installing git" apt-get -y install git || fail "Couldn't install git"
}

miner_running() { pgrep -f "startxmrig$SUFFIX\.sh" >/dev/null 2>&1; }

install_packages() {
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confnew" upgrade
  apt-get -y install git cmake clang make binutils libuv openssl
}

clone_source() {
  if [[ -n "$BUILD_REF" ]]; then
    git clone --depth 1 --branch "$BUILD_REF" "$REPO" "$BUILD_ROOT/xmrig"
  else
    git clone --depth 1 "$REPO" "$BUILD_ROOT/xmrig"
  fi
}

configure_source() {
  # hwloc OFF: Android doesn't expose the CPU topology it needs.
  cmake -S "$BUILD_ROOT/xmrig" -B "$BUILD_ROOT/xmrig/build" \
    -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=OFF
}

compile_source() {
  if (( USE_TUI )); then
    term_size
    # Turn cmake's "[ 42%]" lines into a progress bar
    { cmake --build "$BUILD_ROOT/xmrig/build" -j"$JOBS" 2>&1 | tee -a "$LOG" \
        | sed -un 's/^\[ *\([0-9]\{1,3\}\)%\].*/\1/p'; } \
      | dialog --backtitle "$BACKTITLE" --title "Compiling" --gauge \
          "Building $LABEL ${BUILD_REF:-(default branch)} with $JOBS jobs.\n\nThis can take 10+ minutes on a phone.\nLog: $LOG_SHOW" \
          11 $(( TERM_W - 6 )) 0
  else
    section "Compiling with $JOBS jobs"
    cmake --build "$BUILD_ROOT/xmrig/build" -j"$JOBS" 2>&1 | tee -a "$LOG"
  fi
}

# Builds $BUILD_REF (or the latest release) and replaces ONLY the binary.
# Settings in the start script are never touched here.
build_and_install() {
  : > "$LOG"
  run_step "Installing packages" install_packages || fail "Package install failed"

  BUILD_REF="${XMRIG_VERSION:-${BUILD_REF:-}}"
  [[ -n "$BUILD_REF" ]] || BUILD_REF="$(latest_tag)"

  BUILD_ROOT="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/xmrig-build.XXXXXX")"
  trap 'rm -rf "$BUILD_ROOT"' EXIT

  run_step "Downloading $LABEL ${BUILD_REF:-(default branch)}" clone_source || fail "Download failed"
  run_step "Configuring build" configure_source || fail "Build configuration failed"

  # Jobs scale with free RAM (~1 GB each), capped at 4 to avoid OOM/overheating
  JOBS=$(( MEM_AVAIL_MB / 1024 ))
  (( JOBS > CORES )) && JOBS=$CORES
  (( JOBS > 4 )) && JOBS=4
  (( JOBS < 1 )) && JOBS=1
  compile_source || fail "Compile failed"
  [[ -x "$BUILD_ROOT/xmrig/build/xmrig" ]] || fail "Compile finished but no xmrig binary was produced"

  # Install to a temp name then rename, so a running miner is never left
  # pointing at a half-written file
  mkdir -p "$INSTALL_DIR"
  install -m 755 "$BUILD_ROOT/xmrig/build/xmrig" "$INSTALL_DIR/xmrig.new"
  mv -f "$INSTALL_DIR/xmrig.new" "$INSTALL_DIR/xmrig"
  local ver="$BUILD_REF"
  [[ -n "$ver" ]] || ver="$(git -C "$BUILD_ROOT/xmrig" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "$ver" > "$VERSION_FILE"
  rm -rf "$BUILD_ROOT"
}

# Update the current variant's binary only. Returns after showing the result.
do_update() {
  local old new running_note=""
  ensure_git
  old="$(installed_version)"
  new="${XMRIG_VERSION:-$(latest_tag)}"
  [[ -n "$new" ]] || fail "Couldn't find the latest $LABEL release (are you online?)"

  if [[ "$old" == "$new" && "${FORCE:-0}" != 1 ]]; then
    ui_msg "Up to date" "$LABEL is already on the latest release ($new).\n\nNothing to do. Use FORCE=1 to rebuild anyway."
    return 0
  fi

  BUILD_REF="$new"
  build_and_install

  miner_running && running_note="\n\nThe miner is running - restart it to use the new version:\n${STOP_SCRIPT/#"$HOME"/\~} then ${START_SCRIPT/#"$HOME"/\~}"
  ui_msg "Updated" "$LABEL updated: $old -> $new\n\nYour pool, wallet and other settings were not changed.$running_note"
  if (( USE_TUI )); then
    clear
    echo -e "$LABEL updated: $old -> $new (settings unchanged)${running_note}"
  fi
  return 0
}

# ---------- --update: update installed miners, no questions ----------
if [[ "$ACTION" == "update" ]]; then
  updated_any=0
  REQUESTED_VARIANT="${VARIANT:-}"
  for v in ${REQUESTED_VARIANT:-upstream moneroocean}; do
    set_variant "$v"
    if is_installed; then
      do_update
      updated_any=1
    elif [[ -n "$REQUESTED_VARIANT" ]]; then
      fail "$LABEL isn't installed yet - run ./build_xmrig.sh without --update first"
    fi
  done
  (( updated_any )) || fail "No miner is installed yet - run ./build_xmrig.sh without --update first"
  exit 0
fi

# =====================================================================
#  QUESTIONS (all up front - the build then runs unattended)
# =====================================================================

# ---------- 1. Miner ----------
if [[ -z "${VARIANT:-}" ]]; then
  ui_menu choice "Miner" \
    "$DEVICE_LINE$ARCH_NOTE\n\nWhich miner do you want to build?\n\nStandard: works with any Monero pool.\nMoneroOcean: auto algo-switching on\nthe MoneroOcean pool.\n\nEach screen picks its default after ${PROMPT_TIMEOUT}s." "1" \
    1 "Standard XMRig" \
    2 "MoneroOcean XMRig"
  case "$choice" in
    1|upstream|standard|s|u) VARIANT="upstream" ;;
    2|moneroocean|mo|m)      VARIANT="moneroocean" ;;
    *) fail "Invalid miner choice '$choice'" ;;
  esac
fi

set_variant "$VARIANT"

DO_BUILD=1
if is_installed; then
  INSTALLED_VER="$(installed_version)"
  ui_menu action "Already installed" \
    "$LABEL ${INSTALLED_VER} is already installed in\n${INSTALL_DIR/#"$HOME"/\~}\n\nWhat do you want to do?" "1" \
    1 "Update miner (keeps settings)" \
    2 "Change settings only" \
    3 "Rebuild + change settings"
  case "$action" in
    1) do_update; exit 0 ;;
    2) DO_BUILD=0 ;;
    3) DO_BUILD=1 ;;
    *) fail "Invalid choice '$action'" ;;
  esac
fi

# ---------- 2. Pool ----------
if [[ -z "${POOL:-}" ]]; then
  if [[ "$VARIANT" == "moneroocean" ]]; then default_pool=2; else default_pool=1; fi
  while [[ -z "${POOL:-}" ]]; do
    ui_menu pchoice "Pool" "Which pool do you want to mine on?\n\nTheMule:     ${THEMULE_POOL%%:*}\nMoneroOcean: ${MONEROOCEAN_POOL%%:*}\nSupportXMR:  ${SUPPORTXMR_POOL%%:*}" "$default_pool" \
      1 "TheMule" \
      2 "MoneroOcean" \
      3 "SupportXMR" \
      4 "Custom pool address"
    case "$pchoice" in
      1) POOL="$THEMULE_POOL" ;;
      2) POOL="$MONEROOCEAN_POOL" ;;
      3) POOL="$SUPPORTXMR_POOL" ;;
      4)
        ui_input raw_pool "Custom pool" \
          "Pool address:\n\nhost:port, stratum+tcp://host:port\nor stratum+ssl://host:port" ""
        if valid_pool "$(normalize_pool "$raw_pool")"; then
          is_ssl_url "$raw_pool" && POOL_IS_SSL=1
          POOL="$(normalize_pool "$raw_pool")"
        else
          ui_msg "Custom pool" "'${raw_pool}' doesn't look like host:port.\n\nPick the pool again."
          [[ -t 0 ]] || fail "No valid pool given"
        fi
        ;;
      *) fail "Invalid pool choice '$pchoice'" ;;
    esac
  done
else
  is_ssl_url "$POOL" && POOL_IS_SSL=1
  POOL="$(normalize_pool "$POOL")"
fi

if [[ -z "${TLS:-}" ]]; then
  if (( POOL_IS_SSL )); then
    TLS="y"
  elif ui_yesno "TLS" "Use TLS (encrypted connection) for\n$POOL ?\n\nOnly say yes if this port supports TLS." n; then
    TLS="y"
  else
    TLS="n"
  fi
fi
yes_no "$TLS" && TLS_FLAG="--tls" || TLS_FLAG=""

if [[ "$VARIANT" == "moneroocean" && "$POOL" != *moneroocean* ]]; then
  ui_msg "Heads up" "Algo switching only works on the MoneroOcean pool.\n\nOn $POOL the MoneroOcean build will mine like standard XMRig."
fi

# ---------- 3. Wallet ----------
if [[ -z "${WALLET:-}" ]]; then
  while :; do
    ui_input WALLET "Wallet" \
      "Monero wallet address (or pool username).\n\nThe worker name is added next as wallet.workername." \
      "$DEFAULT_ADDRESS"
    # Standard (95) or integrated (106) address, optionally with .workername
    if [[ "$WALLET" =~ ^([48][1-9A-HJ-NP-Za-km-z]{94}|4[1-9A-HJ-NP-Za-km-z]{105})(\.[A-Za-z0-9_-]+)?$ ]]; then
      break
    fi
    ui_yesno "Wallet" "That isn't a standard Monero address:\n\n$WALLET\n\nUse it anyway? (fine for pools with usernames)" n && break
    [[ -t 0 ]] || fail "Invalid wallet"
  done
fi

if [[ -z "${WORKER:-}" ]]; then
  default_worker="$(echo "${MODEL:-android}" | tr -c 'A-Za-z0-9_-' '_' | sed 's/_*$//')"
  ui_input WORKER "Worker name" "Worker name shown on the pool dashboard:" "${default_worker:-x}"
  WORKER="$(echo "$WORKER" | tr -c 'A-Za-z0-9_-' '_' | sed 's/_*$//')"
  WORKER="${WORKER:-x}"
fi

# Login is wallet.workername; left as typed if it already has a suffix
[[ "$WALLET" != *.* ]] && WALLET="$WALLET.$WORKER"

if [[ -z "${PASSWORD:-}" ]]; then
  ui_input PASSWORD "Pool password" \
    "Pool password.\n\nLeave as x unless your pool uses it for\nsettings such as a custom difficulty." "x"
fi

# ---------- 4. Performance ----------
ui_menu THREADS "Threads" \
  "Mining threads (phone has $CORES cores).\n\nauto = all cores, leaving one free on phones with more than 4.\nChecked fresh every time the miner starts." "auto" \
  auto "Detect at every start" \
  $(for ((i = 1; i <= CORES; i++)); do echo "$i"; echo "thread$([[ $i -gt 1 ]] && echo s)"; done)
if [[ "$THREADS" != "auto" ]] && { ! [[ "$THREADS" =~ ^[0-9]+$ ]] || (( THREADS < 1 )); }; then
  THREADS="auto"
fi

ui_menu MODE "RandomX mode" \
  "RandomX mode (${MEM_AVAIL_MB} MB RAM free right now).\n\nauto = fast with 3 GB+ free, light otherwise." "auto" \
  auto  "Detect at every start" \
  fast  "Faster, needs ~2.5 GB RAM" \
  light "Slower, low memory"
case "$MODE" in auto|fast|light) ;; *) MODE="auto" ;; esac

# ---------- 5. Autostart ----------
BOOT_YES=0
ui_yesno "Start on boot" \
  "Start this miner automatically when the phone boots?\n\nNeeds the Termux:Boot app." n && BOOT_YES=1

# ---------- Summary ----------
if (( ${#WALLET} > 30 )); then SHOW_WALLET="${WALLET:0:12}...${WALLET: -16}"; else SHOW_WALLET="$WALLET"; fi
SUMMARY="Miner:     $LABEL $([[ $DO_BUILD == 1 ]] && echo '(will build)' || echo '(keep build)')
Pool:      $POOL ${TLS_FLAG:+(TLS)}
Login:     $SHOW_WALLET
Password:  $PASSWORD
Threads:   $THREADS
Mode:      $MODE
Autostart: $( (( BOOT_YES )) && echo yes || echo no)"

if (( USE_TUI )); then
  ui_yesno "Summary" "$SUMMARY\n\nContinue?" y || cancel_setup
else
  section "Summary"; echo "$SUMMARY"
  yes_no "$(ask "Continue? (y/n)" "y")" || cancel_setup
fi

# =====================================================================
#  BUILD
# =====================================================================
if (( DO_BUILD )); then
  build_and_install
fi

# =====================================================================
#  WRITE LAUNCHER, STOP SCRIPT, AUTOSTART
# =====================================================================

# Part 1: saved settings (values safely quoted)
cat > "$START_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# $LABEL launcher - re-run build_xmrig.sh to change these settings
# Override per run:  THREADS=4 MODE=light $START_SCRIPT
INSTALL_DIR=$(printf %q "$INSTALL_DIR")
POOL=$(printf %q "$POOL")
TLS_FLAG=$(printf %q "$TLS_FLAG")
WALLET=$(printf %q "$WALLET")
PASS=$(printf %q "$PASSWORD")
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
BOOT_NOTE=""
if (( BOOT_YES )); then
  mkdir -p "$BOOT_DIR"
  # Only one miner should autostart - they'd fight over the same cores
  for other in "$BOOT_DIR/start-xmrig" "$BOOT_DIR/start-xmrig-mo"; do
    [[ "$other" != "$BOOT_SCRIPT" && -e "$other" ]] && rm -f "$other"
  done
  cat > "$BOOT_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec $(printf %q "$START_SCRIPT") >> $(printf %q "$HOME/xmrig$SUFFIX.log") 2>&1
EOF
  chmod +x "$BOOT_SCRIPT"
  BOOT_NOTE="\n\nAutostart is on. Open the Termux:Boot app once so\nAndroid lets it run. Boot log: ~/xmrig$SUFFIX.log"
else
  rm -f "$BOOT_SCRIPT"
fi

DONE_TEXT="$LABEL is ready.

Start:  ${START_SCRIPT/#"$HOME"/\~}
Stop:   Ctrl+C, or ${STOP_SCRIPT/#"$HOME"/\~}

The wake lock is released automatically when the miner stops.
Run this setup again to change pool or wallet without rebuilding.$BOOT_NOTE"

if (( USE_TUI )); then
  ui_msg "Done" "$DONE_TEXT"
  clear
fi
section "Done"
echo -e "$DONE_TEXT"
