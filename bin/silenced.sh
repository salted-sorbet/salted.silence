#!/bin/bash
# silenced - per-workspace audio daemon for the salted.silence Omarchy plugin.
#
# Applies PipeWire stream mute/volume according to a shared state file that
# the bar widget edits:
#
#   $XDG_RUNTIME_DIR/workspace-audio/state.json
#     {
#       "autoMute": bool,     # mute workspaces that are not in focus
#       "exclude": "regex",   # application names never touched (optional)
#       "workspaces": {
#         "<id>": { "muted": bool, "volume": 0-100 }   # volume key optional
#       }
#     }
#
# Streams whose windows sit on a configured workspace always follow that
# workspace's explicit settings; unconfigured ones follow autoMute (muted
# unless their workspace is the active one on some monitor). The original
# stream volume is remembered while a custom one is applied so it can be
# restored when the setting is cleared.
#
# Debug logging: run with SILENCE_DEBUG=1 to append decisions to daemon.log.
set -u

STATE_DIR="${XDG_RUNTIME_DIR}/workspace-audio"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/daemon.log"
SOCK="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

# Fail closed if the runtime dir or state dir exists but was not created by
# this user (pre-planted by another local user).
for d in "${XDG_RUNTIME_DIR}" "$STATE_DIR"; do
    if [[ -e $d ]] && [[ $(stat -c '%u' -- "$d") != "$(id -u)" ]]; then
        echo "silenced: refusing unsafe directory: $d" >&2
        exit 1
    fi
done

mkdir -p -m 700 "$STATE_DIR" || exit 1
chmod 700 -- "$STATE_DIR"

# Refuse to follow a symlinked state file planted over the real path.
if [[ -L $STATE_FILE ]]; then
    echo "silenced: refusing symlinked state file" >&2
    exit 1
fi
[[ -f $STATE_FILE ]] || printf '{"autoMute":true,"workspaces":{}}\n' > "$STATE_FILE"

# Lock file: create without clobbering or following an existing entry, then
# verify it is a plain regular file owned by us before binding the lock fd.
# Reopening uses read/write mode (no truncation) on the verified path.
LOCK="$STATE_DIR/daemon.lock"
if [[ -L $LOCK || (-e $LOCK && ! -f $LOCK) ]]; then
    echo "silenced: refusing unsafe lock file" >&2
    exit 1
fi
( set -o noclobber; : > "$LOCK" ) 2>/dev/null
if [[ -L $LOCK || ! -f $LOCK ]] || [[ $(stat -c '%u' -- "$LOCK") != "$(id -u)" ]]; then
    echo "silenced: lock file failed verification" >&2
    exit 1
fi
exec 9<>"$LOCK" || exit 1
flock -n 9 || exit 0

declare -A ORIG_VOL=()
# Private work directory: mktemp guarantees a fresh, owner-only, non-guessable
# path inside the user-private runtime dir; failure is fatal.
if ! TMPDIR_S=$(mktemp -d "$STATE_DIR/work.XXXXXXXX"); then
    echo "silenced: cannot create private work directory" >&2
    exit 1
fi
chmod 700 -- "$TMPDIR_S"
trap 'rm -rf -- "$TMPDIR_S"' EXIT

log() { [[ -n "${SILENCE_DEBUG:-}" ]] && echo "$(date +%H:%M:%S.%3N) $*" >> "$LOG_FILE"; return 0; }

tree_of() {
    ps -eo pid=,ppid= | awk -v seeds="$*" '
        BEGIN { n = split(seeds, s, /[[:space:]]+/); for (i = 1; i <= n; i++) want[s[i]] = 1 }
        { pp[$1] = $2 }
        END {
            changed = 1
            while (changed) {
                changed = 0
                for (pid in pp)
                    if (!(pid in want) && (pp[pid] in want)) { want[pid] = 1; changed = 1 }
            }
            for (pid in want) print pid
        }'
}

# Open state.json once and return the bounded bytes in STATE_JSON. The open
# itself uses O_NOFOLLOW|O_NONBLOCK so a planted symlink or FIFO can never
# be followed or block us; the owner, type, and size checks run against the
# very same descriptor (fstat), and parsing stays on the captured string.
read_state() {
    STATE_JSON=""
    local out rc
    out=$(python3 - "$STATE_FILE" <<'PY'
import os, stat, sys
path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
except OSError:
    sys.exit(2)
try:
    st = os.fstat(fd)
    if st.st_uid != os.getuid():
        sys.exit(3)
    if not stat.S_ISREG(st.st_mode):
        sys.exit(4)
    if st.st_size > 65536:
        sys.exit(5)
    data = os.read(fd, st.st_size + 1)
finally:
    os.close(fd)
if not data or len(data) != st.st_size:
    sys.exit(6)
sys.stdout.write(data.decode("utf-8", "replace"))
PY
)
    rc=$?
    (( rc == 0 )) || return 1
    STATE_JSON=$out
}

sync_audio() {
    local auto_mute ws_states exclude focused allowed
    # One descriptor-bound read, validated and bounded in read_state().
    read_state || { log "state file read failed, skipped"; return; }
    # jq's "//" alternative falls through on false, so booleans must be read
    # with has() to tell an explicit false from an absent key.
    auto_mute=$(jq -r 'if has("autoMute") and .autoMute != null then .autoMute else true end' <<<"$STATE_JSON" 2>/dev/null) || return
    ws_states=$(jq -c '.workspaces // {}' <<<"$STATE_JSON" 2>/dev/null) || return
    exclude=$(jq -r 'if has("exclude") then .exclude else "" end' <<<"$STATE_JSON" 2>/dev/null) || return
    # The regex is user-editable state: strip control characters and cap it.
    exclude=${exclude//[![:print:]]/}
    ((${#exclude} <= 256)) || { log "exclude too long, ignored"; exclude=""; }

    log "sync autoMute=$auto_mute ws_states=$ws_states"

    focused=",$(hyprctl monitors -j 2>/dev/null |
        jq -r '[.[].activeWorkspace.id] | unique | join(",")')," || return

    hyprctl clients -j 2>/dev/null |
        jq -r '.[] | "\(.pid)|\(.workspace.id)"' > "$TMPDIR_S/pidws" || return

    # Every window pid feeds the child-process expansion, so apps that play
    # audio from a helper process still map back to their window's workspace.
    local seeds
    seeds=$(awk -F'|' '{print $1}' "$TMPDIR_S/pidws" | tr '\n' ' ')
    mapfile -t allowed < <(tree_of "${seeds:- }")

    pactl list sink-inputs | awk '
        /^Sink Input #[0-9]+/ {
            if (idx != "" && pid != "") print idx "|" pid "|" name "|" vol
            idx = $3; sub(/#/, "", idx); pid = ""; name = ""; vol = ""
        }
        /^[\t ]+Volume:/          { if (vol == "") { match($0, /\/[ ]*[0-9]+%/); vol = substr($0, RSTART, RLENGTH); gsub(/[\/ %]/, "", vol) } }
        /application\.process\.id/{ if (pid == "") { pid = $NF; gsub(/"/, "", pid) } }
        /application\.name/       { if (name == "") { name = $NF; gsub(/"/, "", name) } }
        END { if (idx != "" && pid != "") print idx "|" pid "|" name "|" vol }
    ' > "$TMPDIR_S/streams"

    local idx spid appname curvol ws ws_state muted vol target
    while IFS='|' read -r idx spid appname curvol; do
        [[ -n "$idx" ]] || continue
        # Only touch well-formed stream indexes and pids.
        [[ "$idx" =~ ^[0-9]+$ && "$spid" =~ ^[0-9]+$ ]] || continue
        if [[ -n "$exclude" && "$appname" =~ $exclude ]]; then
            log "stream#$idx $appname: excluded, skip"
            continue
        fi

        ws=$(awk -F'|' -v p="$spid" '$1 == p { print $2; exit }' "$TMPDIR_S/pidws")
        if [[ -z "$ws" ]]; then
            log "stream#$idx $appname pid=$spid: no window, skip"
            continue
        fi

        ws_state=$(jq -c --arg w "$ws" '.[$w] // empty' <<<"$ws_states")

        if [[ -n "$ws_state" ]]; then
            muted=$(jq -r 'if has("muted") then .muted else false end' <<<"$ws_state")
            vol=$(jq -r 'if has("volume") and (.volume != null) then .volume else "" end' <<<"$ws_state")
            log "stream#$idx $appname ws=$ws explicit muted=$muted vol=$vol"
            pactl set-sink-input-mute "$idx" "$([[ $muted == "true" ]] && echo 1 || echo 0)"

            if [[ "$vol" =~ ^[0-9]+$ ]]; then
                (( vol > 150 )) && vol=150
                [[ -z "${ORIG_VOL[$idx]:-}" ]] && ORIG_VOL[$idx]="$([[ $curvol =~ ^[0-9]+$ ]] && echo "$curvol" || echo 100)"
                pactl set-sink-input-volume "$idx" "${vol}%"
            elif [[ -n "${ORIG_VOL[$idx]:-}" ]]; then
                pactl set-sink-input-volume "$idx" "${ORIG_VOL[$idx]}%"
                unset "ORIG_VOL[$idx]"
            fi
        else
            if [[ "$auto_mute" == "true" ]]; then
                [[ "$focused" == *,"$ws",* ]] && target=0 || target=1
                log "stream#$idx $appname ws=$ws auto target=$target"
                pactl set-sink-input-mute "$idx" "$target"
            else
                log "stream#$idx $appname ws=$ws automute-off unmute"
                pactl set-sink-input-mute "$idx" 0
            fi
            if [[ -n "${ORIG_VOL[$idx]:-}" ]]; then
                pactl set-sink-input-volume "$idx" "${ORIG_VOL[$idx]}%"
                unset "ORIG_VOL[$idx]"
            fi
        fi
    done < "$TMPDIR_S/streams"
}

mtime_now() { stat -c '%y' -- "$STATE_FILE" 2>/dev/null; }

last_mtime=$(mtime_now)
sync_audio

while :; do
    m=$(mtime_now)
    if [[ "$m" != "$last_mtime" ]]; then
        last_mtime=$m
        sync_audio
    fi
    if IFS= read -r -t 0.2 ev; then
        case "$ev" in
            workspace*|moveworkspace*|openwindow*|closewindow*|movewindow*) sync_audio ;;
        esac
    fi
done < <(socat -U - "$SOCK")
