#!/usr/bin/env bash
# Point DeepSeek Harness Desktop (the GUI app) at the CLI/chezmoi-managed
# DSH_HOME (~/.config/dsh) by copying the state the app accumulated under its
# own default home (~/.dsh).
#
# Why a copy: the desktop app and `dsh` share one home by design ("Harness home
# shared with npm-installed dsh"), but the packaged app resolves
# <configured> > $DSH_HOME > ~/.dsh and a macOS GUI process inherits no shell
# env — so the app needs DSH_HOME set for the launch (or GUI domain).
#
# Safety: this script only ADDS to the destination. The source home is never
# modified or deleted, so it doubles as the rollback copy. Credential and LTM
# memory stores are never overwritten: a conflicting destination wins and the
# incoming copy is parked beside it for manual review.
#
# Usage:
#   scripts/dsh-migrate-desktop-home.sh [--force] [--dry-run]
#
#   --force    proceed while the Desktop app is running: best-effort live copy.
#              The session executing the script is skipped (its log is still
#              being appended); re-run after quitting to pick it up flushed.
#   --dry-run  print the plan, change nothing.
#
# Typical sequence:
#   1. scripts/dsh-migrate-desktop-home.sh --force   # pre-stage while app runs
#   2. Cmd-Q the app completely
#   3. scripts/dsh-migrate-desktop-home.sh           # final, consistent copy
#   4. open -a "DeepSeek Harness" --env DSH_HOME="$HOME/.config/dsh"
set -euo pipefail

SRC="${DSH_MIGRATE_SRC:-${HOME}/.dsh}"
DST="${DSH_MIGRATE_DST:-${HOME}/.config/dsh}"
PARK="${DST}/.desktop-migration"
FORCE=0
DRY=0

for arg in "$@"; do
    case "${arg}" in
        --force) FORCE=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

note() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

run() {
    if [ "${DRY}" -eq 1 ]; then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# rsync -a minus owner/group: a non-root copy must not try to preserve them.
RSYNC=(rsync -rlptD)

step "plan"
note "source home : ${SRC}"
note "target home : ${DST}"
note "mode        : $([ "${DRY}" -eq 1 ] && echo dry-run || echo copy) $([ "${FORCE}" -eq 1 ] && echo '(force/live)')"

[ "${SRC}" != "${DST}" ] || { echo "source and target are the same directory" >&2; exit 1; }
[ -d "${SRC}" ] || { echo "source home not found: ${SRC}" >&2; exit 1; }

if [ "${FORCE}" -eq 1 ]; then
    note "app running : check skipped (--force)"
elif pgrep -f "DeepSeek Harness" >/dev/null 2>&1; then
    echo "the Desktop app appears to be running; quit it (Cmd-Q) or pass --force" >&2
    exit 1
else
    note "app running : no"
fi

[ "${DRY}" -eq 1 ] || mkdir -p "${DST}"

# ---------------------------------------------------------------- identity --
step "identity and credentials"
if [ -e "${DST}/.anonymous-user-id" ]; then
    note "keep existing .anonymous-user-id"
else
    run cp -p "${SRC}/.anonymous-user-id" "${DST}/.anonymous-user-id"
fi

if [ -e "${DST}/.credentials.yaml" ]; then
    # The CLI store is normally the richer one (pi-ai keys, oauth routes); never
    # clobber it. Park the app's store in .desktop-migration/ for a manual merge.
    run mkdir -p "${PARK}"
    run cp -p "${SRC}/.credentials.yaml" "${PARK}/.credentials.yaml"
    note "destination .credentials.yaml kept; app copy parked in ${PARK}/.credentials.yaml"
    note "top-level keys, CLI (kept):        $(grep -oE '^[A-Za-z0-9_-]+:' "${DST}/.credentials.yaml" | tr -d ':' | paste -sd, -)"
    note "top-level keys, desktop (parked):  $(grep -oE '^[A-Za-z0-9_-]+:' "${SRC}/.credentials.yaml" | tr -d ':' | paste -sd, -)"
else
    run cp -p "${SRC}/.credentials.yaml" "${DST}/.credentials.yaml"
    note "copied .credentials.yaml"
fi

# ------------------------------------------------------------- session state -
step "sessions (merge, destination-only files kept)"
EXCLUDES=(--exclude '.DS_Store' --exclude 'session.lock')
if [ "${FORCE}" -eq 1 ] && [ -n "${DSH_SESSION_ID:-}" ]; then
    EXCLUDES+=(--exclude "*/${DSH_SESSION_ID}")
    note "skipping the live session ${DSH_SESSION_ID}"
fi
if [ -d "${SRC}/sessions" ]; then
    run "${RSYNC[@]}" "${EXCLUDES[@]}" "${SRC}/sessions/" "${DST}/sessions/"
    note "sessions: $(find "${SRC}/sessions" -name '*.zstd' 2>/dev/null | wc -l | tr -d ' ') logs in source"
else
    note "no sessions/ in source"
fi

step "storages (merge)"
if [ -d "${SRC}/storages" ]; then
    run "${RSYNC[@]}" "${SRC}/storages/" "${DST}/storages/"
else
    note "no storages/ in source"
fi

step "LTM memory"
# Two independent SQLite stores cannot be merged automatically. The CLI home's
# store is normally the substantial one; park the app's instead of replacing it.
if [ -e "${DST}/memory/ltm.db" ]; then
    run mkdir -p "${PARK}/memory"
    run "${RSYNC[@]}" "${SRC}/memory/" "${PARK}/memory/"
    note "destination memory/ kept; app memory parked in ${PARK}/memory/"
    note "to adopt it: stop both apps, then swap the directories yourself"
else
    run mkdir -p "${DST}/memory"
    run "${RSYNC[@]}" "${SRC}/memory/" "${DST}/memory/"
    note "copied memory/"
fi

# ------------------------------------------------------------ app profile ---
step "desktop profile (bundles + installed plugins)"
note "the app writes profiles/desktop itself; 'lock' is a runtime lock and is skipped"
if [ -d "${SRC}/profiles/desktop" ]; then
    run "${RSYNC[@]}" --exclude 'lock' "${SRC}/profiles/desktop/" "${DST}/profiles/desktop/"
else
    note "no profiles/desktop in source (the app will create one)"
fi

# ------------------------------------------------------------- what is left --
step "intentionally NOT copied"
note "dsh-runtimes/     — 359MB payload the host re-syncs from the app bundle on first boot"
note "settings.yaml     — this desktop build mounts no dsh-settings-file (0 refs in app.asar), so it is never read"

step "next"
cat <<EOF
  1. quit the Desktop app completely (Cmd-Q)
  2. re-run this script WITHOUT --force to capture the final session logs
  3. relaunch pointed at the shared home:
       open -a "DeepSeek Harness" --env DSH_HOME="${DST}"
     or persistently, for Dock/Finder launches (survives until reboot):
       launchctl setenv DSH_HOME "${DST}"
     or a LaunchAgent running that launchctl line at login.
  4. verify inside a new session:  env | grep -E 'DSH_HOME|DSH_PROFILE_DIR'
  5. rollback: quit the app, then relaunch without DSH_HOME (its default is ${SRC}).
EOF
