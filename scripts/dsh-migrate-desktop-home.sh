#!/usr/bin/env bash
# Merge Desktop's old ~/.dsh state into the shared ~/.config/dsh home.
# Existing destination files ALWAYS win: credentials, memory, session logs,
# storage and profile configuration are never replaced. The old home is kept
# intact for manual conflict review; missing files are copied with rsync.
# An existing desktop profile is kept as a unit (do not mix dependency trees).
#
# Usage: scripts/dsh-migrate-desktop-home.sh [--force] [--dry-run] [--link]
#   --force    allow a best-effort live COPY (never allowed with --link).
#   --dry-run  print the plan without modifying either home.
#   --link     after copying, rename ~/.dsh to a private timestamped backup and
#              use chezmoi to deploy ~/.dsh -> ~/.config/dsh. Quit Desktop first.
#              This option only accepts the default source/target paths.
#
# Typical sequence (run from a separate terminal, after Cmd-Q):
#   bash scripts/dsh-migrate-desktop-home.sh --dry-run --link
#   bash scripts/dsh-migrate-desktop-home.sh --link
# Conflicting files remain in the backup. Independent SQLite memory databases
# are NOT merged; the old store is retained for manual review.
set -euo pipefail

SRC="${DSH_MIGRATE_SRC:-${HOME:?}/.dsh}"
DST="${DSH_MIGRATE_DST:-${HOME:?}/.config/dsh}"
FORCE=0
DRY=0
LINK=0

for arg in "$@"; do
    case "${arg}" in
        --force) FORCE=1 ;;
        --dry-run) DRY=1 ;;
        --link) LINK=1 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

note() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
run() {
    if [ "${DRY}" -eq 1 ]; then
        printf '  [dry-run]'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}
fail() { echo "$*" >&2; exit 1; }

step "plan"
note "source home : ${SRC}"
note "target home : ${DST}"
if [ "${LINK}" -eq 1 ]; then
    [ "${FORCE}" -eq 0 ] || fail "--link cannot be combined with --force; quit Desktop first"
    [ "${SRC}" = "${HOME:?}/.dsh" ] && [ "${DST}" = "${HOME:?}/.config/dsh" ] ||
        fail "--link only supports the default ~/.dsh and ~/.config/dsh paths"
fi
[ -d "${SRC}" ] || fail "source home not found: ${SRC}"
SRC_REAL=$(cd "${SRC}" && pwd -P)
if [ -d "${DST}" ]; then
    DST_REAL=$(cd "${DST}" && pwd -P)
    if [ "${SRC_REAL}" = "${DST_REAL}" ]; then
        if [ "${LINK}" -eq 1 ]; then
            [ -L "${SRC}" ] && [ "$(readlink "${SRC}")" = "${DST}" ] ||
                fail "same-home alias is not the intended ~/.dsh -> ~/.config/dsh link"
        fi
        note "already using the same physical home; nothing to migrate"
        exit 0
    fi
else
    [ ! -e "${DST}" ] && [ ! -L "${DST}" ] || fail "target is not a directory: ${DST}"
    DST_PARENT=$(cd "$(dirname "${DST}")" && pwd -P)
    DST_REAL="${DST_PARENT}/$(basename "${DST}")"
fi
case "${DST_REAL}/" in "${SRC_REAL}/"*) fail "target must not be inside source" ;; esac
case "${SRC_REAL}/" in "${DST_REAL}/"*) fail "source must not be inside target" ;; esac

if [ "${DRY}" -eq 1 ]; then
    note "preview only; process check deferred until actual migration"
elif [ "${FORCE}" -eq 1 ]; then
    note "app running : check skipped (--force, copy only)"
else
    # A denied process query must not be mistaken for 'Desktop is stopped'.
    PROCESSES=$(ps -axo comm=) || fail "cannot inspect processes; migration aborted"
    case "${PROCESSES}" in
        *"DeepSeek Harness"*) fail "Desktop is running; quit it (Cmd-Q) before migrating" ;;
    esac
    note "app running : no Desktop process found"
fi

if [ "${LINK}" -eq 1 ]; then
    HOME_REAL=$(cd "${HOME:?}" && pwd -P)
    [ ! -L "${SRC}" ] && [ "${SRC_REAL}" = "${HOME_REAL}/.dsh" ] ||
        fail "refusing to rename a nonstandard or symlinked source home"
    # Validate the managed target BEFORE moving anything.
    EXPECTED_LINK=$(chezmoi cat "${SRC}") || fail "cannot read chezmoi's symlink rule"
    [ "${EXPECTED_LINK}" = "${DST}" ] || fail "chezmoi's ~/.dsh rule must target ${DST}"
    BACKUP="${HOME_REAL}/.dsh.backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    [ ! -e "${BACKUP}" ] && [ ! -L "${BACKUP}" ] || fail "backup already exists: ${BACKUP}"
    note "backup home : ${BACKUP}"
fi

run mkdir -p "${DST}"
# Do not change permissions or timestamps of existing destination directories.
RSYNC=(rsync -rlD --ignore-existing)
# Publish whole trees only after rsync succeeds. An interrupted copy must not
# leave memory/ or profiles/desktop/ looking like a complete destination.
copy_tree() {
    local source="$1" target="$2" park stage stage_real park_real target_parent
    shift 2
    park="${DST}/.desktop-migration"
    run mkdir -p "${park}" "$(dirname "${target}")"
    if [ "${DRY}" -eq 1 ]; then
        stage="${park}/tree.dry-run-$$"
    else
        stage=$(mktemp -d "${park}/tree.XXXXXX")
    fi
    run "${RSYNC[@]}" "$@" "${source}/" "${stage}/tree/"
    [ ! -e "${target}" ] && [ ! -L "${target}" ] || fail "target appeared during copy: ${target}"
    if [ "${DRY}" -eq 0 ]; then
        park_real=$(cd "${park}" && pwd -P)
        stage_real=$(cd "${stage}" && pwd -P)
        target_parent=$(cd "$(dirname "${target}")" && pwd -P)
        [ "${stage_real}" = "${park_real}/$(basename "${stage}")" ] &&
            [ ! -L "${stage}/tree" ] && [ -d "${stage}/tree" ] || fail "unexpected staging path"
        case "${target_parent}/" in
            "$(cd "${DST}" && pwd -P)/"*) ;;
            *) fail "copy target escaped the destination home" ;;
        esac
    fi
    # Resolved staging and target-parent paths were checked before this move.
    run mv "${stage}/tree" "${target}"
}
step "identity and credentials (destination wins)"
for name in .anonymous-user-id .credentials.yaml; do
    if [ -e "${DST}/${name}" ] || [ -L "${DST}/${name}" ]; then
        note "keep existing ${name}; old copy stays in source/backup"
    elif [ -f "${SRC}/${name}" ]; then
        run cp -p "${SRC}/${name}" "${DST}/${name}"
    fi
done

step "sessions and storages (missing files only)"
EXCLUDES=(--exclude '.DS_Store' --exclude 'session.lock')
if [ "${FORCE}" -eq 1 ] && [ -n "${DSH_SESSION_ID:-}" ]; then
    EXCLUDES+=(--exclude "*${DSH_SESSION_ID}*")
    note "skip live session ${DSH_SESSION_ID}"
fi
for name in sessions storages; do
    if [ -d "${SRC}/${name}" ]; then
        run "${RSYNC[@]}" "${EXCLUDES[@]}" "${SRC}/${name}/" "${DST}/${name}/"
    fi
done

step "LTM memory"
if [ -e "${DST}/memory" ] || [ -L "${DST}/memory" ]; then
    note "keep entire destination memory/; old store stays in source/backup"
elif [ -d "${SRC}/memory" ]; then
    copy_tree "${SRC}/memory" "${DST}/memory"
fi

step "desktop profile (keep dependency tree together)"
if [ -e "${DST}/profiles/desktop" ] || [ -L "${DST}/profiles/desktop" ]; then
    note "keep entire destination profile; old configuration stays in source/backup"
elif [ -d "${SRC}/profiles/desktop" ]; then
    copy_tree "${SRC}/profiles/desktop" "${DST}/profiles/desktop" --exclude 'lock'
fi

step "intentionally NOT copied"
note "dsh-runtimes/ — Desktop re-syncs this payload from the app bundle"
note "settings.yaml — legacy import can consume it; use profile entry config"
note "conflicts and other old state — kept in the original home or backup"

if [ "${LINK}" -eq 1 ]; then
    step "backup and deploy managed link"
    # Both paths are checked absolute paths: SRC_REAL is exactly HOME_REAL/.dsh,
    # BACKUP is a nonexistent sibling, and the physical target is not nested.
    # Recheck immediately before the move; never rename an unexpected symlink.
    [ ! -L "${SRC}" ] && [ "$(cd "${SRC}" && pwd -P)" = "${SRC_REAL}" ] ||
        fail "source home changed during migration"
    [ ! -e "${BACKUP}" ] && [ ! -L "${BACKUP}" ] || fail "backup path changed"
    run mv "${SRC}" "${BACKUP}"
    if ! run chezmoi apply --exclude scripts "${SRC}"; then
        fail "link deployment failed; old home is safe at ${BACKUP}. Restore it before restarting Desktop."
    fi
    if [ "${DRY}" -eq 0 ]; then
        [ -L "${SRC}" ] && [ "$(cd "${SRC}" && pwd -P)" = "$(cd "${DST}" && pwd -P)" ] ||
            fail "link verification failed; old home is safe at ${BACKUP}"
    fi
    note "old home retained at ${BACKUP}; review conflicts there (contains secrets)"
    note "rollback: quit Desktop; move the link aside, restore the backup, and disable the chezmoi link rule"
else
    step "next"
    note "quit Desktop, then run this script with --link to back up the old home and deploy the symlink"
    note "do NOT run chezmoi apply on ~/.dsh while it is still a real directory"
fi
