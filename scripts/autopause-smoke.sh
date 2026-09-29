#!/bin/sh
# autopause-smoke.sh — end-to-end proof that Auto-Pause really pauses Spotify
# when another app makes sound and resumes it when that sound stops, using the
# INSTANT preset.
#
# Usage: scripts/autopause-smoke.sh [options]      (see --help)
#
#   sh scripts/autopause-smoke.sh --dry-run     print every command, touch nothing
#   sh scripts/autopause-smoke.sh               test the installed Sonar.app
#   sh scripts/autopause-smoke.sh --allow-playback
#
# DESTRUCTIVE BY DESIGN, and only in the ways named below:
#   - it quits Sonar, rewrites the Auto-Pause UserDefaults, and relaunches it
#     (--no-quit-sonar skips the quit; --keep-prefs skips the restore)
#   - it launches Spotify if it is not running, and never starts playback
#     without --allow-playback
#   - it plays a 1 kHz tone out loud through the default output device
#   - it only touches /Applications when you pass --install
#   - it never quits an app it did not start, and it never resets a TCC grant
#
# AUDIO IS A SHARED, GLOBAL RESOURCE: never run this while another test is
# running on this Mac.
#
# Env:
#   SONAR_APP            app bundle to test (default /Applications/Sonar.app)
#   SONAR_BUNDLE_ID      defaults domain (default com.KathirD.sonar)
#   SONAR_PREFS_DOMAIN   where to write defaults. Defaults to the sandboxed
#                        container plist, which is what the app actually reads.
#                        Set to a bare domain (e.g. com.KathirD.sonar) for an
#                        unsandboxed build.
#   SPOTIFY_BUNDLE       Spotify bundle id (default com.spotify.client)
#   TONE_WAV             path for the generated tone (default: mktemp, deleted
#                        at the end unless --keep-tone)
#   PRESET_THRESHOLD     loudness floor to write (default 0.02)
#   DEVELOPER_DIR        required for xcodebuild on this host
#   CODE_SIGN_IDENTITY   ad-hoc "-" by default
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------- configuration

SONAR_APP="${SONAR_APP:-/Applications/Sonar.app}"
SONAR_BUNDLE_ID="${SONAR_BUNDLE_ID:-com.KathirD.sonar}"
SPOTIFY_BUNDLE="${SPOTIFY_BUNDLE:-com.spotify.client}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/dist/autopause-smoke/DerivedData}"
STAGE_DIR="${STAGE_DIR:-$ROOT/dist/autopause-smoke/stage}"
LOG_MAX_LINES="${LOG_MAX_LINES:-25}"
# Remembered before the default is applied, so cleanup only deletes a tone it
# generated itself and never one the operator pointed TONE_WAV at.
TONE_WAV_ENV="${TONE_WAV:-}"

# Instant preset timings, in the values the model persists. Quoted in
# AutoPausePreferencesModel.Key and AutoPausePreset.instant.
#
# PRESET_THRESHOLD is the one to watch. AutoPausePreferencesModel.presetThreshold
# is AutoPausePreset.fade.threshold (0.02) for *every* preset, and that is what
# apply(_:) persists, so 0.02 is what keeps the pane labelling these values
# "Instant" — while AutoPausePreset.instant.threshold itself is 0.01 and is not
# used by the app. Override with PRESET_THRESHOLD=0.01 if the model starts
# asking the preset instead.
PRESET_MODE=instant
PRESET_ACTIVE=0.1
PRESET_QUIET=0.3
PRESET_FADEOUT=0.0
PRESET_FADEIN=0.0
PRESET_THRESHOLD="${PRESET_THRESHOLD:-0.02}"
PRESET_FILTER=allExcept

PAUSE_THRESHOLD_MS="${PAUSE_THRESHOLD_MS:-2000}"
RESUME_THRESHOLD_MS="${RESUME_THRESHOLD_MS:-3000}"
TONE_SECONDS="${TONE_SECONDS:-6}"
SETTLE_SECONDS="${SETTLE_SECONDS:-8}"
POLL_INTERVAL="${POLL_INTERVAL:-0.05}"
SPOTIFY_LAUNCH_TIMEOUT="${SPOTIFY_LAUNCH_TIMEOUT:-30}"

DO_BUILD=0
DO_INSTALL=0
ALLOW_PLAYBACK=0
DRY_RUN=0
KEEP_SONAR=0
QUIT_SONAR=1
KEEP_PREFS=0
KEEP_TONE=0
LAUNCH_SPOTIFY=1
SKIP_BUILD=0
SKIP_INSTALL=0
SKIP_SPOTIFY=0
SKIP_PREFS=0
SKIP_LAUNCH=0
SKIP_TONE=0
SKIP_ASSERT=0
SKIP_LOG=0

# ------------------------------------------------------------------------ output

if [ -t 1 ]; then
    C_RESET="$(printf '\033[0m')"
    C_BOLD="$(printf '\033[1m')"
    C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_BLUE="$(printf '\033[34m')"
    C_DIM="$(printf '\033[2m')"
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

say()  { printf '%s\n' "$*"; }
note() { printf '%s\n' "${C_DIM}$*${C_RESET}"; }
head1() { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}!! $*${C_RESET}" >&2; }

# A shell-quoted rendering of "$@" for --dry-run and for showing what ran.
sq() {
    case "$1" in
        '' | *[!A-Za-z0-9_./:=@,+*-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}
cmdline() {
    _cl_out=''
    for _cl_a in "$@"; do
        _cl_out="$_cl_out $(sq "$_cl_a")"
    done
    printf '%s' "${_cl_out# }"
}

# Run a command, echoing it first. Honours --dry-run.
run() {
    printf '%s\n' "${C_BLUE}\$ $(cmdline "$@")${C_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    "$@"
}

# Same, but the command's own output goes to a file instead of the terminal.
# The redirect has to sit on the invocation, not on `run`, or the echoed
# command line would be swallowed by it too.
run_logged() { # logfile cmd...
    _rl_log="$1"
    shift
    printf '%s\n' "${C_BLUE}\$ $(cmdline "$@")${C_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    "$@" > "$_rl_log" 2>&1
}

WORKDIR="$(mktemp -d -t sonar-autopause-smoke)"
RESULTS="$WORKDIR/results.tsv"
PREFS_BACKUP="$WORKDIR/prefs-backup.plist"
PREFS_HAD_FILE=0
PREFS_TOUCHED=0
TONE_WAV="${TONE_WAV:-$WORKDIR/tone-1khz.wav}"
: > "$RESULTS"

# ------------------------------------------------------------------ assertions

record() { # name status latency threshold detail
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "${4:--}" "$5" >> "$RESULTS"
}

note_result() { # name status latency threshold detail
    case "$2" in
        PASS) printf '%s\n' "${C_GREEN}PASS${C_RESET}  $1 ${C_DIM}$5${C_RESET}" ;;
        FAIL) printf '%s\n' "${C_RED}FAIL${C_RESET}  $1 ${C_DIM}$5${C_RESET}" ;;
        SKIP) printf '%s\n' "${C_YELLOW}SKIP${C_RESET}  $1 ${C_DIM}$5${C_RESET}" ;;
        *)    printf '%s\n' "????? $1 $5" ;;
    esac
    record "$@"
}

FAILURES=0
bump() { FAILURES=$((FAILURES + 1)); }

# ------------------------------------------------------------------ timestamps

# Milliseconds off the system-wide monotonic clock. `date +%s%N` is not
# portable to BSD date, and every poll is a separate process, so the clock has
# to be machine-wide, not per-process.
now_ms() {
    python3 -c 'import time; print(int(time.monotonic() * 1000))'
}

# -------------------------------------------------------------- app / Spotify

app_exists() {
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    [ -d "$SONAR_APP" ]
}

# The UserDefaults the app actually reads. A sandboxed app resolves
# UserDefaults.standard inside its container, so the plain domain would be a
# different file and the writes would silently do nothing.
prefs_domain() {
    if [ -n "${SONAR_PREFS_DOMAIN:-}" ]; then
        printf '%s' "$SONAR_PREFS_DOMAIN"
        return
    fi
    printf '%s' "$HOME/Library/Containers/$SONAR_BUNDLE_ID/Data/Library/Preferences/$SONAR_BUNDLE_ID.plist"
}

spotify_running() {
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    pgrep -x Spotify >/dev/null 2>&1
}

sonar_running() {
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    pgrep -x Sonar >/dev/null 2>&1
}

# `player state` via the same AppleScript idiom the engine uses: the `it is
# running` guard means this can never launch Spotify as a side effect. Prints
# one of playing/paused/stopped, or empty when the call itself failed.
spotify_state() {
    if [ "$DRY_RUN" -eq 1 ]; then printf 'playing'; return 0; fi
    osascript <<'APPLESCRIPT' 2>/dev/null | tr -d '\r\n'
with timeout of 4 seconds
    tell application "Spotify"
        if it is running then
            return player state as string
        else
            return "stopped"
        end if
    end tell
end timeout
APPLESCRIPT
}

spotify_volume() {
    if [ "$DRY_RUN" -eq 1 ]; then printf '100'; return 0; fi
    osascript <<'APPLESCRIPT' 2>/dev/null | tr -d '\r\n'
with timeout of 4 seconds
    tell application "Spotify"
        if it is running then
            return sound volume
        end if
    end tell
end timeout
APPLESCRIPT
}

spotify_play() {
    printf '%s\n' "${C_DIM}\$ osascript: tell application \"Spotify\" to play${C_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
with timeout of 4 seconds
    tell application "Spotify" to play
end timeout
APPLESCRIPT
}

spotify_pause() {
    printf '%s\n' "${C_DIM}\$ osascript: tell application \"Spotify\" to pause${C_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
with timeout of 4 seconds
    tell application "Spotify" to pause
end timeout
APPLESCRIPT
}

spotify_set_volume() {
    printf '%s\n' "${C_DIM}\$ osascript: tell application \"Spotify\" to set sound volume to $1${C_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
with timeout of 4 seconds
    tell application "Spotify" to set sound volume to $1
end timeout
APPLESCRIPT
}

# ------------------------------------------------------------- poll for state

# wait_for_state <wanted> <timeout_ms>
# Sets WF_MATCH_TS (ms when the wanted state was first seen) and
# WF_PREV_TS (ms of the last sample that was NOT the wanted state), so the
# caller can report an upper bound plus the sampling quantum instead of
# pretending the measurement is exact.
wait_for_state() {
    WF_MATCH_TS=''
    WF_PREV_TS=''
    _wf_prev_ms="$(now_ms)"
    _wf_deadline=$((_wf_prev_ms + $2))
    while :; do
        _wf_now="$(now_ms)"
        if [ "$_wf_now" -gt "$_wf_deadline" ]; then
            return 1
        fi
        _wf_state="$(spotify_state)"
        if [ "$_wf_state" = "$1" ]; then
            WF_MATCH_TS="$_wf_now"
            WF_PREV_TS="$_wf_prev_ms"
            return 0
        fi
        _wf_prev_ms="$_wf_now"
        sleep "$POLL_INTERVAL"
    done
}

# ------------------------------------------------------------------ UserDefaults

defaults_read() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '(dry-run)'
        return 0
    fi
    defaults read "$(prefs_domain)" "$1" 2>/dev/null || printf '<unset>'
}

defaults_write() { # key type value
    run defaults write "$(prefs_domain)" "$1" "$2" "$3"
}

# `-array` with no values, which `defaults` needs spelled this way.
defaults_write_empty_array() { # key
    run defaults write "$(prefs_domain)" "$1" -array
}

# Float comparison that tolerates plist text formatting.
float_is() { # got want
    awk -v a="${1:-x}" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d < 0.0005) }' 2>/dev/null
}

write_instant_preset() {
    if [ "$DRY_RUN" -eq 0 ]; then
        _pd="$(prefs_domain)"
        case "$_pd" in
            */*)
                _pdir="$(dirname "$_pd")"
                if [ ! -d "$_pdir" ]; then
                    warn "No container at $_pdir — creating it so defaults(1) can"
                    warn "create the plist. If the app has never run sandboxed,"
                    warn "delete it afterwards if you do not want it."
                    mkdir -p "$_pdir"
                fi
                if [ -f "$_pd" ] && [ ! -w "$_pd" ]; then
                    say ""
                    say "${C_RED}Cannot write $_pd${C_RESET}"
                    say "The file exists but is not writable by $(id -un) (it is"
                    say "usually left root-owned after Sonar was ever launched with"
                    say "sudo). Fix the ownership once, as a human:"
                    say ""
                    say "  sudo chown -R \"\$(id -un)\":staff \"$HOME/Library/Containers/$SONAR_BUNDLE_ID\""
                    say ""
                    say "or point the script somewhere else:"
                    say "  SONAR_PREFS_DOMAIN=$SONAR_BUNDLE_ID sh $0 $ARGS"
                    say ""
                    bump
                    note_result 'autopause-defaults-writable' FAIL '' '' "not writable: $_pd"
                    exit 1
                fi
                ;;
        esac
    fi

    PREFS_TOUCHED=1
    say "Writing the Instant preset into $(prefs_domain)"
    note "Keys come from AutoPausePreferencesModel.Key; values from AutoPausePreset.instant"
    defaults_write autopause.enabled  -bool  true
    defaults_write autopause.mode      -string "$PRESET_MODE"
    defaults_write autopause.activeDuration -float "$PRESET_ACTIVE"
    defaults_write autopause.quietDuration  -float "$PRESET_QUIET"
    defaults_write autopause.fadeOut   -float "$PRESET_FADEOUT"
    defaults_write autopause.fadeIn    -float "$PRESET_FADEIN"
    defaults_write autopause.threshold -float "$PRESET_THRESHOLD"
    defaults_write autopause.filterMode -string "$PRESET_FILTER"
    defaults_write_empty_array autopause.bundleIDs

    if [ "$DRY_RUN" -eq 1 ]; then
        note_result 'autopause-defaults-written' SKIP '' '' 'dry run'
        return 0
    fi

    _got_enabled="$(defaults_read autopause.enabled)"
    _got_mode="$(defaults_read autopause.mode)"
    _got_active="$(defaults_read autopause.activeDuration)"
    _got_quiet="$(defaults_read autopause.quietDuration)"
    _got_fadeout="$(defaults_read autopause.fadeOut)"
    _got_fadein="$(defaults_read autopause.fadeIn)"
    _got_threshold="$(defaults_read autopause.threshold)"
    _got_filter="$(defaults_read autopause.filterMode)"
    _got_ids="$(defaults_read autopause.bundleIDs)"

    say ""
    say "  ${C_BOLD}Read back from the plist${C_RESET}"
    say "    autopause.enabled         = $_got_enabled"
    say "    autopause.mode            = $_got_mode"
    say "    autopause.activeDuration  = $_got_active"
    say "    autopause.quietDuration   = $_got_quiet"
    say "    autopause.fadeOut         = $_got_fadeout"
    say "    autopause.fadeIn          = $_got_fadein"
    say "    autopause.threshold       = $_got_threshold"
    say "    autopause.filterMode      = $_got_filter"
    say "    autopause.bundleIDs       = $_got_ids"
    say ""

    _bad=''
    [ "$_got_enabled" = "1" ] || _bad="$_bad enabled(expected 1)"
    [ "$_got_mode" = "$PRESET_MODE" ] || _bad="$_bad mode(expected $PRESET_MODE)"
    float_is "$_got_active" "$PRESET_ACTIVE" || _bad="$_bad activeDuration(expected $PRESET_ACTIVE)"
    float_is "$_got_quiet" "$PRESET_QUIET" || _bad="$_bad quietDuration(expected $PRESET_QUIET)"
    float_is "$_got_fadeout" "$PRESET_FADEOUT" || _bad="$_bad fadeOut(expected $PRESET_FADEOUT)"
    float_is "$_got_fadein" "$PRESET_FADEIN" || _bad="$_bad fadeIn(expected $PRESET_FADEIN)"
    float_is "$_got_threshold" "$PRESET_THRESHOLD" || _bad="$_bad threshold(expected $PRESET_THRESHOLD)"
    [ "$_got_filter" = "$PRESET_FILTER" ] || _bad="$_bad filterMode(expected $PRESET_FILTER)"
    [ "$_got_ids" != "<unset>" ] || _bad="$_bad bundleIDs(expected an array)"

    if [ -n "$_bad" ]; then
        bump
        note_result 'autopause-defaults-written' FAIL '' '' "wrong values:$_bad"
        return 1
    fi
    note_result 'autopause-defaults-written' PASS '' '' "Instant preset in $(prefs_domain)"
    return 0
}

snapshot_prefs() {
    # A whole-file copy, so the restore puts back the exact plist — right types,
    # not strings. `defaults read/write` on a file path is the same mechanism
    # cfprefsd uses, which is why the read-back in write_instant_preset can be
    # trusted to mean the app will see these values too.
    _snap_dom="$(prefs_domain)"
    case "$_snap_dom" in
        */*) ;;
        *) note "SONAR_PREFS_DOMAIN is a bare domain, not a file: no file backup."; return 0 ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        run cp "$_snap_dom" "$PREFS_BACKUP"
        return 0
    fi
    if [ ! -f "$_snap_dom" ]; then
        note "No $_snap_dom yet; cleanup deletes the keys this run creates."
        return 0
    fi
    if cp "$_snap_dom" "$PREFS_BACKUP" 2>/dev/null; then
        PREFS_HAD_FILE=1
        note "Backed up $_snap_dom to $PREFS_BACKUP"
    else
        warn "Could not back up $_snap_dom (unreadable). Cleanup will only delete"
        warn "the keys this run writes; it cannot restore anything else."
    fi
    return 0
}

restore_prefs() {
    if [ "$DRY_RUN" -eq 1 ] || [ "$PREFS_TOUCHED" -eq 0 ]; then
        return 0
    fi
    _rp_dom="$(prefs_domain)"
    case "$_rp_dom" in
        */*)
            if [ ! -f "$_rp_dom" ]; then
                return 0
            fi
            ;;
        *)
            if ! defaults read "$_rp_dom" >/dev/null 2>&1; then
                return 0
            fi
            ;;
    esac
    say "Restoring the autopause.* values that were there before the test"
    if [ "$PREFS_HAD_FILE" -eq 1 ]; then
        run cp "$PREFS_BACKUP" "$_rp_dom"
        return 0
    fi
    for _k in autopause.enabled autopause.mode autopause.activeDuration \
        autopause.quietDuration autopause.fadeOut autopause.fadeIn \
        autopause.threshold autopause.filterMode autopause.bundleIDs; do
        run defaults delete "$_rp_dom" "$_k" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------- the log

log_path() {
    _lc="$HOME/Library/Containers/$SONAR_BUNDLE_ID/Data/Library/Logs/Sonar/sonar.log"
    if [ -f "$_lc" ] || [ "$DRY_RUN" -eq 1 ]; then
        printf '%s' "$_lc"
    else
        printf '%s' "$HOME/Library/Logs/Sonar/sonar.log"
    fi
}

log_size() {
    if [ "$DRY_RUN" -eq 1 ]; then printf '0'; return 0; fi
    _lp="$(log_path)"
    if [ -f "$_lp" ]; then
        wc -c < "$_lp" | tr -d ' '
    else
        printf '0'
    fi
}

# Everything the app logged after the byte offset we took before the tone.
log_since() {
    _lp="$(log_path)"
    _off="${1:-0}"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "(dry-run: no log read)"
        return 0
    fi
    if [ ! -f "$_lp" ]; then
        printf 'No log at %s\n' "$_lp" >&2
        return 0
    fi
    tail -c "+$((_off + 1))" "$_lp" 2>/dev/null || true
}

# ------------------------------------------------------------------- the tone

make_tone() {
    if [ "$DRY_RUN" -eq 1 ]; then
        run python3 -c 'generate 1 kHz mono 16-bit sine WAV' "$TONE_WAV" "$TONE_SECONDS"
        return 0
    fi
    say "Generating a ${TONE_SECONDS}s 1 kHz sine into $TONE_WAV (python3, stdlib only)"
    python3 - "$TONE_WAV" "$TONE_SECONDS" <<'PY' >/dev/null
import math, struct, sys, wave

path, seconds = sys.argv[1], float(sys.argv[2])
rate, freq, amplitude = 44100, 1000.0, 0.5
with wave.open(path, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    chunk = bytearray()
    for i in range(int(rate * seconds)):
        chunk += struct.pack("<h", int(amplitude * 32767 * math.sin(2 * math.pi * freq * i / rate)))
        if len(chunk) >= 65536:
            w.writeframes(bytes(chunk))
            chunk = bytearray()
    w.writeframes(bytes(chunk))
PY
    if [ ! -s "$TONE_WAV" ]; then
        say "${C_RED}python3 did not produce a tone at $TONE_WAV${C_RESET}" >&2
        return 1
    fi
    note "Tone is $(( $(wc -c < "$TONE_WAV" | tr -d ' ') )) bytes; RMS ~0.35, far above the $PRESET_THRESHOLD threshold"
    return 0
}

# --------------------------------------------------------------- app lifecycle

stop_sonar() {
    if [ "$DRY_RUN" -eq 1 ]; then
        run osascript -e "tell application id \"$SONAR_BUNDLE_ID\" to quit"
        return 0
    fi
    if ! sonar_running; then
        return 0
    fi
    say "Quitting the running Sonar so UserDefaults are not rewritten underneath it"
    warn "Sonar is quitting. Anything it is holding Spotify for is released."
    osascript -e "tell application id \"$SONAR_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    _n=0
    while sonar_running && [ "$_n" -lt 50 ]; do
        _n=$((_n + 1))
        sleep 0.1
    done
    if sonar_running; then
        say "Graceful quit did not take; sending SIGTERM"
        pkill -TERM -x Sonar >/dev/null 2>&1 || true
        _n=0
        while sonar_running && [ "$_n" -lt 30 ]; do
            _n=$((_n + 1))
            sleep 0.1
        done
    fi
    if sonar_running; then
        warn "Sonar is still running after SIGTERM. The defaults below may be"
        warn "overwritten the moment it saves. Stop it by hand and re-run."
        return 1
    fi
    return 0
}

start_sonar() {
    if sonar_running; then
        note "Sonar is already running; not launching a second copy."
        return 0
    fi
    run open "$SONAR_APP"
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    SONAR_LAUNCHED_BY_US=1
    _n=0
    while ! sonar_running && [ "$_n" -lt 100 ]; do
        _n=$((_n + 1))
        sleep 0.1
    done
    if ! sonar_running; then
        say "${C_RED}$SONAR_APP did not start${C_RESET}" >&2
        return 1
    fi
    return 0
}

# Wait for the engine to come up, and say whether the tap went live. Returns 0
# when "engine started" appeared within the timeout.
await_engine() {
    _lp="$(log_path)"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "Would poll the last $LOG_MAX_LINES lines of $_lp for 'engine started',"
        note "then for 'tap verified' or 'tap unavailable', for up to ${SETTLE_SECONDS}s."
        return 0
    fi
    _from="$1"
    _deadline=$(( $(now_ms) + SETTLE_SECONDS * 1000 ))
    _started=0
    while [ "$(now_ms)" -lt "$_deadline" ]; do
        if log_since "$_from" | grep -q 'engine started'; then
            _started=1
            break
        fi
        sleep 0.2
    done
    if [ "$_started" -eq 0 ]; then
        warn "No 'engine started' line in the log within ${SETTLE_SECONDS}s."
        warn "Is $_lp the log the running build writes to?"
        return 1
    fi
    # The tap only counts once it is carrying audio; that flips the log line.
    _deadline=$(( $(now_ms) + SETTLE_SECONDS * 1000 ))
    while [ "$(now_ms)" -lt "$_deadline" ]; do
        if log_since "$_from" | grep -q 'tap verified'; then
            note "Tap verified: RMS loudness is driving the decisions."
            return 0
        fi
        if log_since "$_from" | grep -q 'tap unavailable'; then
            warn "Log says 'tap unavailable' — detection is process-polling only,"
            warn "which cannot tell silence from sound. Expect a slow or missing resume."
            return 0
        fi
        sleep 0.25
    done
    note "No tap verdict in the log yet; assuming the tap is still starting."
    return 0
}

# ------------------------------------------------------------------ the report

print_summary() {
    head1 'SUMMARY'
    printf '%s\n' "${C_BOLD}STATUS  ASSERTION                        MEASURED   BUDGET    NOTES${C_RESET}"
    while IFS="$(printf '\t')" read -r _name _status _lat _budget _detail; do
        [ -n "${_name:-}" ] || continue
        _ms="${_lat:--}"
        if [ "$_ms" != "-" ]; then
            _ms="${_ms} ms"
        fi
        _bg="${_budget:--}"
        if [ "$_bg" != "-" ]; then
            _bg="${_bg} ms"
        fi
        case "$_status" in
            PASS) _c="$C_GREEN" ;;
            FAIL) _c="$C_RED" ;;
            *)    _c="$C_YELLOW" ;;
        esac
        printf '%s%-6s  %-30s  %-9s  %-8s  %s%s\n' \
            "$_c" "$_status" "$_name" "$_ms" "$_bg" "$C_RESET" "$_detail"
    done < "$RESULTS"
    if [ "$FAILURES" -eq 0 ]; then
        printf '\n%s\n' "${C_GREEN}All assertions passed.${C_RESET}"
    else
        printf '\n%s\n' "${C_RED}$FAILURES assertion(s) failed.${C_RESET}"
    fi
}

# -------------------------------------------------------------------- cleanup

CLEANED=0
SIGNALLED=0
AFPLAY_PID=''
SONAR_WAS_RUNNING=0
# Only ever set when THIS script took Sonar from not-running to running. An app
# that was already running when the script started is never quit at the end:
# it belongs to the operator, not to the test, and quitting it would destroy
# whatever it was in the middle of doing.
SONAR_LAUNCHED_BY_US=0
SPOTIFY_WAS_RUNNING=0
# Only set once the tone has actually been played, i.e. once the engine may have
# paused Spotify. Before that the script sends Spotify nothing at all, so an
# early failure cannot leave playback in a state it did not find.
SPOTIFY_TOUCHED=0
ORIG_STATE=''
ORIG_VOLUME=''
UNRESTORED=''

cleanup() {
    _rc=$?
    trap - EXIT HUP INT TERM
    if [ "$CLEANED" -eq 1 ]; then
        exit "$_rc"
    fi
    CLEANED=1
    if [ "$_rc" -ne 0 ] && [ "$SIGNALLED" -eq 1 ]; then
        printf '\n%s\n' "${C_RED}Interrupted (exit $_rc) — cleaning up.${C_RESET}"
    fi

    if [ -n "$AFPLAY_PID" ] && kill -0 "$AFPLAY_PID" 2>/dev/null; then
        say "Stopping afplay (pid $AFPLAY_PID)"
        kill "$AFPLAY_PID" 2>/dev/null || true
        wait "$AFPLAY_PID" 2>/dev/null || true
    fi

    if [ "$SPOTIFY_WAS_RUNNING" -eq 1 ] && [ "$SPOTIFY_TOUCHED" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && [ -n "$ORIG_STATE" ]; then
        say "Restoring Spotify: was $ORIG_STATE at volume ${ORIG_VOLUME:-?}"
        _now_state="$(spotify_state)"
        case "$ORIG_STATE" in
            playing) [ "$_now_state" = "playing" ] || spotify_play ;;
            *)      [ "$_now_state" = "$ORIG_STATE" ] || spotify_pause ;;
        esac
        if [ -n "${ORIG_VOLUME:-}" ] && [ "$ORIG_VOLUME" != "100" ]; then
            spotify_set_volume "$ORIG_VOLUME"
        fi
        _end_state="$(spotify_state)"
        if [ "$_end_state" != "$ORIG_STATE" ]; then
            UNRESTORED="${UNRESTORED}Spotify player state (wanted $ORIG_STATE, now $_end_state); "
        fi
    fi

    # Put Sonar back the way this script found it: running if it was running,
    # stopped if it was stopped. Either way, only ever quit a copy we started.
    if [ "$KEEP_SONAR" -eq 1 ]; then
        note "Leaving Sonar running (--keep-sonar-running)."
    elif [ "$SONAR_WAS_RUNNING" -eq 1 ]; then
        note "Leaving Sonar running: it was running when this script started."
    elif [ "$SONAR_LAUNCHED_BY_US" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        say "Quitting Sonar (this script started it)"
        stop_sonar
    fi

    if [ "$KEEP_PREFS" -eq 0 ]; then
        restore_prefs
    elif [ "$PREFS_TOUCHED" -eq 1 ]; then
        note "--keep-prefs: leaving the Instant preset in place."
    fi

    if [ -n "$UNRESTORED" ]; then
        printf '\n%s\n' "${C_YELLOW}Could not restore:$C_RESET"
        printf '  %s\n' "$UNRESTORED"
    fi
    print_summary

    if [ "$KEEP_TONE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ -z "${TONE_WAV_SET:-}" ]; then
        rm -f "$TONE_WAV"
    fi
    rm -rf "$WORKDIR" 2>/dev/null || true

    if [ "$FAILURES" -ne 0 ]; then
        exit 1
    fi
    exit "$_rc"
}
trap cleanup EXIT
trap 'SIGNALLED=1; exit 130' INT
trap 'SIGNALLED=1; exit 143' TERM HUP

# ------------------------------------------------------------------------ help

usage() {
    cat <<'USAGE'
autopause-smoke.sh — does Auto-Pause really pause Spotify when another app
makes sound, and resume it when that sound stops, on the INSTANT preset?

USAGE
    printf '  %s [options]\n' "$(basename "$0")"

    cat <<'USAGE'

STEPS (each can be skipped)
  --build                 Build Sonar Release first. OFF by default: it is slow,
                          and xcode-select points at CommandLineTools here, so
                          DEVELOPER_DIR is set for you.
  --install               Install the build to a staging path and codesign-verify
                          it. OFF by default. With --install this also copies to
                          $SONAR_APP, which QUITS the running Sonar and replaces
                          the installed bundle.
  --skip-build            Never build, even if --build was given.
  --skip-install          Never install, even if --install was given.
  --skip-spotify          Do not launch/inspect/start Spotify.
  --skip-prefs            Do not write the Instant preset to UserDefaults.
  --skip-launch           Do not launch Sonar.
  --skip-tone             Do not play the test tone (assertions then FAIL).
  --skip-assert           Play the tone but do not assert on Spotify.
  --skip-log              Do not read sonar.log.

BEHAVIOUR
  --allow-playback        Start Spotify playback if it is not already playing.
                          OFF by default: the script refuses to start your music
                          without being told to.
  --no-launch-spotify     Fail instead of launching Spotify when it is not running.
  --keep-sonar-running    Leave Sonar running at the end, even if this script
                          was the one that started it.
  --no-quit-sonar          Do not quit Sonar before writing the preset. Faster
                          and non-disruptive, but the running app may save its
                          own values straight back over what we write, and the
                          test will only be honest if the app was closed.
  --keep-prefs            Do not restore the previous autopause.* values.
  --keep-tone             Do not delete the generated WAV.
  --pause-threshold-ms N  Fail if the pause takes longer than N ms (default 2000).
  --resume-threshold-ms N Fail if the resume takes longer than N ms (default 3000).
  --tone-seconds N        Length of the tone (default 6).
  --settle-seconds N      How long to wait for the engine/tap to come up (default 8).
  --dry-run               Print every command that would run. Touches nothing:
                          no build, no audio, no defaults, no Spotify.
  --help                  This text.

ENV
  SONAR_APP=/Applications/Sonar.app     app bundle under test
  SONAR_BUNDLE_ID=com.KathirD.sonar     defaults domain
  SONAR_PREFS_DOMAIN=...                defaults target (default: the sandboxed
                                         container plist the app actually reads)
  SPOTIFY_BUNDLE=com.spotify.client     Spotify bundle id
  TONE_WAV=/tmp/tone.wav                where to put the generated tone
  PRESET_THRESHOLD=0.02                 the Instant loudness floor to write
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  CODE_SIGN_IDENTITY=-                  ad-hoc by default

WHAT IT NEEDS FROM YOU
  * One test at a time on this Mac. Audio, /Applications/Sonar.app and Spotify
    are all shared state.
  * The shell that runs this must itself be allowed to control Spotify:
    System Settings > Privacy & Security > Automation. The script talks to
    Spotify with osascript, so the grant belongs to Terminal/iTerm, not to
    Sonar.
  * Sonar needs Screen & System Audio Recording and Automation for Spotify
    before Auto-Pause can switch on at all. The script cannot grant those.
  * Polling `player state` over AppleScript costs ~50-100 ms, so a reported
    latency is an upper bound accurate to one poll interval plus one osascript
    round trip. The summary prints that quantum next to every number.
USAGE
}

ARGS="$*"
while [ $# -gt 0 ]; do
    case "$1" in
        --build)                DO_BUILD=1 ;;
        --install)              DO_INSTALL=1 ;;
        --skip-build)           SKIP_BUILD=1 ;;
        --skip-install)         SKIP_INSTALL=1 ;;
        --skip-spotify)         SKIP_SPOTIFY=1 ;;
        --skip-prefs)           SKIP_PREFS=1 ;;
        --skip-launch)          SKIP_LAUNCH=1 ;;
        --skip-tone)            SKIP_TONE=1 ;;
        --skip-assert)          SKIP_ASSERT=1 ;;
        --skip-log)             SKIP_LOG=1 ;;
        --allow-playback)       ALLOW_PLAYBACK=1 ;;
        --no-launch-spotify)    LAUNCH_SPOTIFY=0 ;;
        --keep-sonar-running)   KEEP_SONAR=1 ;;
        --no-quit-sonar)        QUIT_SONAR=0 ;;
        --keep-prefs)           KEEP_PREFS=1 ;;
        --keep-tone)            KEEP_TONE=1 ;;
        --dry-run)              DRY_RUN=1 ;;
        --pause-threshold-ms)   PAUSE_THRESHOLD_MS="$2"; shift ;;
        --resume-threshold-ms)  RESUME_THRESHOLD_MS="$2"; shift ;;
        --tone-seconds)         TONE_SECONDS="$2"; shift ;;
        --settle-seconds)       SETTLE_SECONDS="$2"; shift ;;
        -h|--help)              trap - EXIT HUP INT TERM; rm -rf "$WORKDIR"; usage; exit 0 ;;
        *)
            say "Unknown option: $1"
            case "$1" in
                *=*)
                    say "That looks like an environment variable, and it has to be set"
                    say "BEFORE the script name, not passed as an argument:"
                    say "  ${1%%=*}=... sh $(basename "$0") <options>"
                    ;;
            esac
            say ""
            usage
            exit 2
            ;;
    esac
    shift
done

if [ -n "${TONE_WAV_ENV+x}" ] && [ -n "$TONE_WAV_ENV" ]; then
    TONE_WAV_SET=1
else
    TONE_WAV_SET=''
fi

# =========================================================== 0. preflight

head1 'autopause-smoke — Auto-Pause end-to-end (Instant preset)'
say "Host: $(sw_vers -productName) $(sw_vers -productVersion)   $(uname -m)"
say "App under test: $SONAR_APP"
say "Defaults target: $(prefs_domain)"
say "Budgets: pause <= ${PAUSE_THRESHOLD_MS} ms, resume <= ${RESUME_THRESHOLD_MS} ms"
if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n%s\n' "${C_YELLOW}DRY RUN — nothing will be built, installed, launched, played, or written.${C_RESET}"
    note "Probes answer optimistically (Sonar and Spotify both already running,"
    note "Spotify playing), so the printed plan is the full happy path."
fi

for _tool in defaults osascript afplay python3 codesign; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        say "${C_RED}Missing required tool: $_tool${C_RESET}" >&2
        say "Install it, or re-run with the matching --skip-* flag." >&2
        exit 2
    fi
done

# =========================================================== 1. build

if [ "$DO_BUILD" -eq 1 ] && [ "$SKIP_BUILD" -eq 0 ]; then
    head1 'STEP 1  Build Sonar (Release)'
    note "DEVELOPER_DIR=$DEVELOPER_DIR  (xcode-select points at $(xcode-select -p))"
    note "Derived data goes to its own path: $DERIVED_DATA"
    if run_logged "$WORKDIR/xcodebuild.log" env DEVELOPER_DIR="$DEVELOPER_DIR" \
        xcodebuild \
        -project "$ROOT/SpotMenu.xcodeproj" \
        -scheme Sonar \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        MARKETING_VERSION="$(tr -d ' \n' < "$ROOT/VERSION")" \
        CURRENT_PROJECT_VERSION="$(git -C "$ROOT" rev-parse --short HEAD)" \
        CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
        build; then
        note "xcodebuild output: $WORKDIR/xcodebuild.log"
        if [ "$DRY_RUN" -eq 1 ]; then
            note_result 'build-release' SKIP '' '' 'dry run'
        else
            note_result 'build-release' PASS '' '' "Release build in $DERIVED_DATA"
        fi
    else
        bump
        note_result 'build-release' FAIL '' '' "xcodebuild failed, see $WORKDIR/xcodebuild.log"
        tail -n 30 "$WORKDIR/xcodebuild.log" || true
    fi
    BUILT_APP="$DERIVED_DATA/Build/Products/Release/Sonar.app"
else
    note "STEP 1  Build: skipped (pass --build to run it)"
    BUILT_APP=''
fi

# =========================================================== 2. install

if [ "$DO_INSTALL" -eq 1 ] && [ "$SKIP_INSTALL" -eq 0 ]; then
    head1 'STEP 2  Install to a staging path and verify the signature'
    if [ -z "$BUILT_APP" ] || { [ "$DRY_RUN" -eq 0 ] && [ ! -d "$BUILT_APP" ]; }; then
        bump
        note_result 'staged-app-codesign' FAIL '' '' "nothing to install; --install needs --build"
    else
        say "Staging to $STAGE_DIR/Sonar.app"
        run rm -rf "$STAGE_DIR/Sonar.app"
        run mkdir -p "$STAGE_DIR"
        run cp -R "$BUILT_APP" "$STAGE_DIR/Sonar.app"
        _cs=0
        run codesign -v "$STAGE_DIR/Sonar.app" || _cs=$?
        if [ "$DRY_RUN" -eq 1 ]; then
            note_result 'staged-app-codesign' SKIP '' '' 'dry run'
        elif [ "$_cs" -eq 0 ]; then
            note_result 'staged-app-codesign' PASS '' '' "codesign -v OK on $STAGE_DIR/Sonar.app"
        else
            bump
            note_result 'staged-app-codesign' FAIL '' '' "codesign -v rejected $STAGE_DIR/Sonar.app"
        fi
        if [ "$SONAR_APP" != "$STAGE_DIR/Sonar.app" ]; then
            warn "Replacing $SONAR_APP now."
            warn "This QUITS the running Sonar and overwrites the installed bundle."
            warn "A rebuild also invalidates the TCC grants, so macOS will re-prompt."
            stop_sonar
            run rm -rf "$SONAR_APP"
            run cp -R "$STAGE_DIR/Sonar.app" "$SONAR_APP"
            run codesign -v "$SONAR_APP"
        fi
    fi
else
    note "STEP 2  Install: skipped (pass --install to stage and verify; nothing"
    note "        under /Applications is touched otherwise)"
fi

if ! app_exists; then
    say ""
    say "${C_RED}No Sonar app bundle at $SONAR_APP${C_RESET}"
    say "Build one with --build, or point the script at an existing bundle:"
    say "  SONAR_APP=/path/to/Sonar.app sh $0 $ARGS"
    bump
    note_result 'app-present' FAIL '' '' "$SONAR_APP does not exist"
    exit 1
fi
if [ "$DRY_RUN" -eq 0 ]; then
    if codesign -v "$SONAR_APP" 2>/dev/null; then
        note_result 'app-present' PASS '' '' "$SONAR_APP (codesign -v OK)"
    else
        note_result 'app-present' PASS '' '' "$SONAR_APP (exists; codesign -v unhappy)"
    fi
else
    note_result 'app-present' SKIP '' '' 'dry run'
fi

# =========================================================== 3. Spotify

if [ "$SKIP_SPOTIFY" -eq 0 ]; then
    head1 'STEP 3  Spotify running and playing'
    if spotify_running; then
        SPOTIFY_WAS_RUNNING=1
        note "Spotify is already running (pgrep -x Spotify)"
        note_result 'spotify-running' PASS '' '' "already running ($SPOTIFY_BUNDLE)"
    else
        note "Spotify is not running."
        if [ "$LAUNCH_SPOTIFY" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
            warn "Launching Spotify ($SPOTIFY_BUNDLE) because the test needs it."
            run open -b "$SPOTIFY_BUNDLE"
            _n=0
            _deadline=$(( $(now_ms) + SPOTIFY_LAUNCH_TIMEOUT * 1000 ))
            while ! spotify_running && [ "$(now_ms)" -lt "$_deadline" ]; do
                _n=$((_n + 1))
                sleep 0.5
            done
        fi
        if spotify_running; then
            SPOTIFY_WAS_RUNNING=1
            note_result 'spotify-running' PASS '' '' "launched $SPOTIFY_BUNDLE"
        else
            say ""
            say "${C_RED}Spotify is not running.${C_RESET}"
            say "Start Spotify, wait for it to be ready, then re-run:"
            say "  sh $0 $ARGS"
            say "(--no-launch-spotify forbids this script from starting it.)"
            bump
            note_result 'spotify-running' FAIL '' '' "$SPOTIFY_BUNDLE is not running"
            exit 1
        fi
    fi

    # Automation check: this failure mode looks exactly like "Auto-Pause is
    # broken", so it has to be named.
    ORIG_STATE="$(spotify_state)"
    if [ -z "$ORIG_STATE" ]; then
        say ""
        say "${C_RED}Could not read Spotify's player state.${C_RESET}"
        say "That is almost always Automation: this shell (the terminal running"
        say "this script) is not allowed to control Spotify."
        say "Grant it at System Settings > Privacy & Security > Automation, or"
        say "re-run with --skip-spotify --skip-assert to check the app only."
        bump
        note_result 'spotify-readable' FAIL '' '' 'osascript player state returned nothing'
        exit 1
    fi
    ORIG_VOLUME="$(spotify_volume)"
    say "Spotify player state: ${C_BOLD}$ORIG_STATE${C_RESET}   volume: ${ORIG_VOLUME:-unknown}"
    note_result 'spotify-readable' PASS '' '' "state=$ORIG_STATE volume=${ORIG_VOLUME:-?}"

    if [ "$ORIG_STATE" = "playing" ]; then
        note_result 'spotify-playing-at-start' PASS '' '' 'already playing'
    elif [ "$ALLOW_PLAYBACK" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        warn "Starting playback because --allow-playback was given."
        spotify_play
        _n=0
        _deadline=$(( $(now_ms) + 20000 ))
        while [ "$(spotify_state)" != "playing" ] && [ "$(now_ms)" -lt "$_deadline" ]; do
            _n=$((_n + 1))
            sleep 0.5
        done
        note_result 'spotify-playing-at-start' PASS '' '' "started playback, now $(spotify_state)"
    else
        say ""
        say "${C_YELLOW}Spotify is '$ORIG_STATE', not playing.${C_RESET}"
        say "Auto-Pause can only prove a pause if something was playing. Either"
        say "press play in Spotify and re-run, or let the script do it:"
        say "  sh $0 $ARGS --allow-playback"
        bump
        note_result 'spotify-playing-at-start' FAIL '' '' "player state is $ORIG_STATE"
        exit 1
    fi
else
    note "STEP 3  Spotify: skipped"
    note_result 'spotify-running' SKIP '' '' '--skip-spotify'
fi

# =========================================================== 4. force Instant

if [ "$SKIP_PREFS" -eq 0 ]; then
    head1 'STEP 4  Force the Instant preset and launch Sonar'
    if sonar_running; then
        SONAR_WAS_RUNNING=1
        if [ "$DRY_RUN" -eq 1 ]; then
            note "Dry run: assuming Sonar is running, so the quit step is shown."
        else
            note "Sonar is running."
        fi
    else
        SONAR_WAS_RUNNING=0
        note "Sonar is not running."
    fi
    snapshot_prefs
    if [ "$QUIT_SONAR" -eq 0 ]; then
        warn "--no-quit-sonar: not closing the app before writing."
        warn "If Sonar is running it can save its own values back over these, and"
        warn "the run will only mean something if Sonar was already closed."
        note_result 'sonar-quit-for-prefs' SKIP '' '' '--no-quit-sonar'
    elif ! stop_sonar; then
        bump
        note_result 'sonar-quit-for-prefs' FAIL '' '' 'could not quit the running Sonar'
    else
        note_result 'sonar-quit-for-prefs' PASS '' '' 'Sonar is not running'
    fi
    write_instant_preset || true

    if [ "$SKIP_LAUNCH" -eq 0 ]; then
        LOG_BASE="$(log_size)"
        start_sonar || true
        await_engine "${LOG_BASE:-0}" || true
    else
        note "--skip-launch: not starting Sonar, so the tone assertions will fail."
        LOG_BASE=0
    fi
else
    note "STEP 4  Instant preset: skipped (--skip-prefs)"
    LOG_BASE="$(log_size)"
fi

# =========================================================== 5. the tone

if [ "$DRY_RUN" -eq 1 ]; then
    note "STEP 5  Tone: generated for the plan, not written"
    run python3 -c 'generate 1 kHz mono 16-bit sine WAV' "$TONE_WAV" "$TONE_SECONDS"
    run afplay "$TONE_WAV"
    run tail -c "+$(( $(log_size) + 1 ))" "$(log_path)"
    LOG_BASE=0
elif [ "$SKIP_TONE" -eq 0 ]; then
    head1 'STEP 5  Generate and play the test tone'
    make_tone || {
        bump
        note_result 'tone-generated' FAIL '' '' "python3 could not write $TONE_WAV"
        exit 1
    }
    note_result 'tone-generated' PASS '' '' "$TONE_WAV (${TONE_SECONDS}s, 1 kHz, mono 16-bit)"
    LOG_BASE="${LOG_BASE:-$(log_size)}"
else
    note "STEP 5  Tone: skipped (--skip-tone)"
fi

# =========================================================== 6. assertions

TONE_START_MS=0
TONE_STOP_MS=0
PAUSE_LATENCY_MS=''
RESUME_LATENCY_MS=''
PAUSE_QUANTUM_MS=''
RESUME_QUANTUM_MS=''

if [ "$DRY_RUN" -eq 0 ] && [ "$SKIP_ASSERT" -eq 0 ] && [ "$SKIP_TONE" -eq 0 ] && [ "$SKIP_LAUNCH" -eq 0 ]; then
    head1 'STEP 6  Assert the duck and the resume'
    if [ "$(spotify_state)" != "playing" ]; then
        bump
        note_result 'spotify-playing-before-tone' FAIL '' '' "state is $(spotify_state), expected playing"
    else
        note_result 'spotify-playing-before-tone' PASS '' '' 'playing'
    fi

    say "Playing the tone now; polling Spotify every ${POLL_INTERVAL}s."
    run afplay "$TONE_WAV"
    AFPLAY_PID=$!
    SPOTIFY_TOUCHED=1
    TONE_START_MS="$(now_ms)"
    note "Tone started at ${TONE_START_MS} ms (monotonic)."
    note_result 'tone-started' PASS '' '' "afplay pid $AFPLAY_PID at ${TONE_START_MS} ms"

    if wait_for_state paused "$((PAUSE_THRESHOLD_MS + 8000))"; then
        PAUSE_LATENCY_MS=$((WF_MATCH_TS - TONE_START_MS))
        PAUSE_QUANTUM_MS=$((WF_MATCH_TS - WF_PREV_TS))
        say "Spotify reported 'paused' at ${WF_MATCH_TS} ms."
        if [ "$PAUSE_LATENCY_MS" -le "$PAUSE_THRESHOLD_MS" ]; then
            note_result 'spotify-paused' PASS "$PAUSE_LATENCY_MS" "$PAUSE_THRESHOLD_MS" \
                "playing->paused, sampled every ${PAUSE_QUANTUM_MS} ms"
        else
            bump
            note_result 'spotify-paused' FAIL "$PAUSE_LATENCY_MS" "$PAUSE_THRESHOLD_MS" \
                "playing->paused took too long (sampled every ${PAUSE_QUANTUM_MS} ms)"
        fi
    else
        bump
        note_result 'spotify-paused' FAIL '' "$PAUSE_THRESHOLD_MS" \
            "still $(spotify_state) after the tone started"
    fi

    # The tone has a fixed length, so afplay ends by itself; if the pause
    # assertion burned the whole budget, stop it here instead.
    if kill -0 "$AFPLAY_PID" 2>/dev/null; then
        say "Stopping the tone early (the pause assertion already used its budget)"
        kill "$AFPLAY_PID" 2>/dev/null || true
    fi
    wait "$AFPLAY_PID" 2>/dev/null || true
    TONE_STOP_MS="$(now_ms)"
    AFPLAY_PID=''
    note "Tone stopped at ${TONE_STOP_MS} ms, ${PAUSE_LATENCY_MS:-?} ms after it started."
    note_result 'tone-stopped' PASS '' '' "afplay finished at ${TONE_STOP_MS} ms"

    if wait_for_state playing "$((RESUME_THRESHOLD_MS + 8000))"; then
        RESUME_LATENCY_MS=$((WF_MATCH_TS - TONE_STOP_MS))
        RESUME_QUANTUM_MS=$((WF_MATCH_TS - WF_PREV_TS))
        say "Spotify reported 'playing' at ${WF_MATCH_TS} ms."
        if [ "$RESUME_LATENCY_MS" -le "$RESUME_THRESHOLD_MS" ]; then
            note_result 'spotify-resumed' PASS "$RESUME_LATENCY_MS" "$RESUME_THRESHOLD_MS" \
                "paused->playing, sampled every ${RESUME_QUANTUM_MS} ms"
        else
            bump
            note_result 'spotify-resumed' FAIL "$RESUME_LATENCY_MS" "$RESUME_THRESHOLD_MS" \
                "paused->playing took too long (sampled every ${RESUME_QUANTUM_MS} ms)"
        fi
    else
        bump
        note_result 'spotify-resumed' FAIL '' "$RESUME_THRESHOLD_MS" \
            "still $(spotify_state) after the tone stopped"
    fi
else
    if [ "$DRY_RUN" -eq 1 ]; then
        note "STEP 6  Assertions: dry run, so nothing is played and nothing is timed."
    else
        note "STEP 6  Assertions: skipped (--skip-assert / --skip-tone / --skip-launch)"
    fi
    note_result 'spotify-playing-before-tone' SKIP '' '' 'skipped'
    note_result 'tone-started'               SKIP '' '' 'skipped'
    note_result 'spotify-paused'             SKIP '' "$PAUSE_THRESHOLD_MS" 'skipped'
    note_result 'tone-stopped'               SKIP '' '' 'skipped'
    note_result 'spotify-resumed'            SKIP '' "$RESUME_THRESHOLD_MS" 'skipped'
fi

# =========================================================== 7. the log

if [ "$SKIP_LOG" -eq 0 ]; then
    head1 'STEP 7  What the engine logged'
    if [ "$DRY_RUN" -eq 1 ]; then
        run tail -n "$LOG_MAX_LINES" "$(log_path)"
        note_result 'engine-log' SKIP '' '' 'dry run'
    else
        _lp="$(log_path)"
        say "Log: $_lp"
        say "Lines written by this run:"
        log_since "${LOG_BASE:-0}" | sed 's/^/    /' || true
        say ""
        say "Last $LOG_MAX_LINES engine lines (candidate/ducked/restored/relinquished/tap):"
        log_since 0 | grep -E 'candidate:|ducked:|restored|relinquished:|tap |engine started|permissions:' \
            | tail -n "$LOG_MAX_LINES" | sed 's/^/    /' || note "    (no engine lines in the log yet)"
        say ""
        if log_since "${LOG_BASE:-0}" | grep -q 'tap verified'; then
            say "Detector that drove this run: ${C_BOLD}the Core Audio tap${C_RESET} (RMS, real loudness)."
        elif log_since "${LOG_BASE:-0}" | grep -Eq 'tap unavailable|tap ready'; then
            say "Detector that drove this run: ${C_YELLOW}process polling only${C_RESET}."
            say "Polling cannot tell silence from sound, so the resume can only be"
            say "as fast as the app releases the output device."
        else
            say "Detector verdict: ${C_YELLOW}no tap line in this run's log${C_RESET}."
            say "Check Preferences > Auto-Pause > Diagnostics for the Detector row."
        fi
        if [ -f "$_lp" ]; then
            note_result 'engine-log' PASS '' '' "read $_lp"
        else
            note_result 'engine-log' FAIL '' '' "no log at $_lp"
        fi
    fi
else
    note "STEP 7  Log: skipped (--skip-log)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say ""
    say "${C_YELLOW}Dry run complete. Nothing was built, installed, launched, played, or written.${C_RESET}"
fi

# cleanup() runs on EXIT and prints the summary.
exit 0
