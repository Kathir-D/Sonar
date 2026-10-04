#!/usr/bin/env python3
"""system-sounds-smoke.py — end-to-end proof that Auto-Pause ignores Apple's
system sounds and still pauses for short sounds from apps.

Runs the real Sonar.app against the real Spotify on the Instant preset (the
most trigger-happy one: 0.1 s of sound is enough to pause), then:

  ignored  Apple system sounds must NOT pause Spotify. Every trial also proves
           the sound really played, by watching systemsoundserverd (or
           PowerChime) go active in Core Audio while it ran. A trial where the
           daemon never made a sound is reported as INVALID, never as a pass,
           so a muted Mac cannot make this script pass by accident.
  counted  Short sounds from apps MUST pause and then resume. This includes an
           Apple sound *file* played by an ordinary process (afplay), which is
           the case a duration- or file-based rule would get wrong.
  control  The same system sound with "Ignore Apple system sounds" switched
           off MUST pause, which shows the ignored trials are not passing
           because nothing could have paused at all.

Usage:
  python3 scripts/system-sounds-smoke.py                   # installed app
  python3 scripts/system-sounds-smoke.py --app dist/Sonar.app --trials 5
  python3 scripts/system-sounds-smoke.py --set-volumes     # unmute for the run

DESTRUCTIVE BY DESIGN, and only in these ways: it quits and relaunches Sonar,
rewrites its autopause.* defaults (restored byte for byte at the end), plays
sounds out loud, takes screenshots into a temp folder, and creates (then
deletes) Reminders named "Sonar system-sound smoke". Spotify must already be
playing unless --allow-playback is given.

Needs: osascript automation for Spotify, System Events and Reminders, swiftc.
Standard library only.
"""

from __future__ import annotations

import argparse
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.KathirD.sonar"
CONTAINER = Path.home() / "Library/Containers" / BUNDLE_ID / "Data/Library"
PREFS = CONTAINER / "Preferences" / f"{BUNDLE_ID}.plist"
LOG = CONTAINER / "Logs/Sonar/sonar.log"
REMINDER_NAME = "Sonar system-sound smoke"
SOUNDS = Path("/System/Library/Sounds")

# Instant preset, exactly as AutoPausePreset.instant defines it.
INSTANT = {
    "autopause.enabled": ("-bool", "true"),
    "autopause.mode": ("-string", "instant"),
    "autopause.activeDuration": ("-float", "0.1"),
    "autopause.quietDuration": ("-float", "0.3"),
    "autopause.fadeOut": ("-float", "0"),
    "autopause.fadeIn": ("-float", "0"),
    "autopause.threshold": ("-float", "0.01"),
    "autopause.filterMode": ("-string", "allExcept"),
}

# A tiny helper, compiled once, so every sound is played the way an app or the
# OS really plays it rather than approximated from the shell.
HELPER_SOURCE = r"""
import AppKit
import AudioToolbox
import CoreAudio
import Darwin

func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    .init(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func processObjects() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func u32(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(s); var v: UInt32 = 0; var sz: UInt32 = 4
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
}
func path(_ pid: pid_t) -> String {
    var b = [CChar](repeating: 0, count: 4096); proc_pidpath(pid, &b, 4096); return String(cString: b)
}

let args = CommandLine.arguments
switch args[1] {
case "beep":
    NSSound.beep()
case "alert":
    AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
case "systemsound":
    var id: SystemSoundID = 0
    AudioServicesCreateSystemSoundID(URL(fileURLWithPath: args[2]) as CFURL, &id)
    AudioServicesPlaySystemSound(id)
case "nssound":
    NSSound(contentsOfFile: args[2], byReference: true)?.play()
case "watch":
    // Print every non-Spotify process that starts producing output, with its
    // executable path, until killed or the deadline passes.
    let end = Date().addingTimeInterval(Double(args[2])!)
    var seen = Set<String>()
    setvbuf(stdout, nil, _IOLBF, 0)
    while Date() < end {
        for id in processObjects() where u32(id, kAudioProcessPropertyIsRunningOutput) != 0 {
            let p = path(pid_t(bitPattern: u32(id, kAudioProcessPropertyPID)))
            if !seen.contains(p) { seen.insert(p); print(p) }
        }
        usleep(5_000)
    }
    exit(0)
case "transitions":
    // Every output start/stop of every process, stamped with the same clock as
    // Python's time.monotonic() (mach_absolute_time), until killed.
    var running = Set<String>()
    setvbuf(stdout, nil, _IOLBF, 0)
    while true {
        var now = Set<String>()
        for id in processObjects() where u32(id, kAudioProcessPropertyIsRunningOutput) != 0 {
            now.insert(path(pid_t(bitPattern: u32(id, kAudioProcessPropertyPID))))
        }
        let t = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
        for p in now.subtracting(running) { print(t, "on", p) }
        for p in running.subtracting(now) { print(t, "off", p) }
        running = now
        usleep(5_000)
    }
default:
    exit(2)
}
RunLoop.main.run(until: Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["HOLD"] ?? "1.5")!))
"""

SYSTEM_PLAYERS = ("/usr/sbin/systemsoundserverd", "/PowerChime")

if sys.stdout.isatty():
    GREEN, RED, YELLOW, DIM, BOLD, RESET = (f"\033[{c}m" for c in ("32", "31", "33", "2", "1", "0"))
else:
    GREEN = RED = YELLOW = DIM = BOLD = RESET = ""


def say(msg: str = "") -> None:
    print(msg, flush=True)


def osa(script: str, timeout: float = 10) -> str:
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()


def spotify_state() -> str:
    return osa('tell application "Spotify" to if it is running then return player state as string')


def sonar_running() -> bool:
    return subprocess.run(["pgrep", "-x", "Sonar"], capture_output=True).returncode == 0


def log_size() -> int:
    return LOG.stat().st_size if LOG.exists() else 0


def log_since(offset: int) -> str:
    if not LOG.exists():
        return ""
    with LOG.open("rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


@dataclass
class Trial:
    group: str
    name: str
    ok: bool
    detail: str
    pause_ms: int | None = None
    resume_ms: int | None = None
    invalid: bool = False


@dataclass
class Run:
    args: argparse.Namespace
    helper: Path = Path()
    tmp: Path = Path()
    trials: list[Trial] = field(default_factory=list)
    prefs_backup: bytes | None = None
    sonar_was_running: bool = False
    volumes: str | None = None

    # ------------------------------------------------------------- lifecycle

    def quit_sonar(self) -> None:
        if not sonar_running():
            return
        osa(f'tell application id "{BUNDLE_ID}" to quit')
        for _ in range(50):
            if not sonar_running():
                return
            time.sleep(0.1)
        subprocess.run(["pkill", "-TERM", "-x", "Sonar"])
        time.sleep(1)

    def launch_sonar(self, ignore_system_sounds: bool) -> None:
        self.quit_sonar()
        for key, (kind, value) in INSTANT.items():
            subprocess.run(["defaults", "write", str(PREFS), key, kind, value], check=True)
        subprocess.run(
            ["defaults", "write", str(PREFS), "autopause.ignoreSystemSounds", "-bool",
             "true" if ignore_system_sounds else "false"], check=True)
        offset = log_size()
        subprocess.run(["open", "-n", self.args.app], check=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            text = log_since(offset)
            if "tap verified" in text:
                break
            if "tap unavailable" in text:
                raise SystemExit(f"{RED}Sonar's tap is unavailable; grant audio capture and re-run.{RESET}")
            time.sleep(0.2)
        else:
            raise SystemExit(f"{RED}Sonar never logged 'tap verified' (log: {LOG}).{RESET}")
        targets = [l for l in log_since(offset).splitlines() if "targets:" in l]
        say(f"{DIM}  {targets[-1].split('tap: ', 1)[-1] if targets else 'no targets line'}{RESET}")
        # Let the first rebuilds and the process-change churn of a fresh launch settle.
        time.sleep(3)

    def ensure_playing(self) -> None:
        if spotify_state() == "playing":
            return
        osa('tell application "Spotify" to play')
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and spotify_state() != "playing":
            time.sleep(0.2)

    # ----------------------------------------------------------------- trials

    def watch(self, seconds: float) -> subprocess.Popen:
        return subprocess.Popen([str(self.helper), "watch", str(seconds)], stdout=subprocess.PIPE, text=True)

    def ignored(self, name: str, trigger, window: float = 3.0, wait_for_sound: float = 0.0) -> None:
        """A system sound: it must play, and Spotify must never be ducked."""
        self.ensure_playing()
        time.sleep(0.8)
        offset = log_size()
        watcher = self.watch(window + wait_for_sound)
        time.sleep(0.15)
        trigger()
        states = set()
        lines: list[str] = []
        deadline = time.monotonic() + window + wait_for_sound
        heard = False
        while time.monotonic() < deadline:
            ready, _, _ = select.select([watcher.stdout], [], [], 0.1)
            if ready:
                line = watcher.stdout.readline().strip()
                if line:
                    lines.append(line)
                if not heard and line.endswith(SYSTEM_PLAYERS):
                    # Watch for `window` seconds after the sound, not after the trigger.
                    heard = True
                    deadline = time.monotonic() + window
            states.add(spotify_state())
        watcher.send_signal(signal.SIGTERM)
        rest, _ = watcher.communicate(timeout=10)
        players = [p for p in lines + rest.splitlines() if p and "Spotify" not in p]
        system_played = any(p.endswith(SYSTEM_PLAYERS) or p == SYSTEM_PLAYERS[0] for p in players)
        text = log_since(offset)
        ducked = "ducked:" in text or "candidate:" in text
        if not system_played:
            self.record(Trial("ignored", name, False, f"no system sound was produced (saw: {players or 'nothing'})",
                              invalid=True))
        elif ducked or "paused" in states:
            line = next((l for l in text.splitlines() if "ducked:" in l or "candidate:" in l), "spotify paused")
            self.record(Trial("ignored", name, False, f"paused: {line.split('Z ', 1)[-1]}"))
        else:
            others = [p for p in players if not p.endswith(SYSTEM_PLAYERS)]
            self.record(Trial("ignored", name, True,
                              "played by " + ", ".join(sorted({Path(p).name for p in players if p not in others}))
                              + ("; also " + ", ".join(Path(p).name for p in others) if others else "")))

    def counted(self, group: str, name: str, trigger, expect_system: bool = False) -> None:
        """Audio that counts: it must pause Spotify, and the music must come back.

        Times are measured from the moment the sound was started: how long
        until Sonar paused, and how long the music was paused for in total.
        """
        self.ensure_playing()
        time.sleep(0.8)
        offset = log_size()
        watcher = self.watch(6.0)
        time.sleep(0.15)
        start = time.monotonic()
        proc = trigger()
        pause_ms = back_ms = None
        deadline = start + 6.0
        while time.monotonic() < deadline:
            text = log_since(offset)
            if pause_ms is None and "ducked:" in text:
                pause_ms = int((time.monotonic() - start) * 1000)
            if pause_ms is not None and "restored" in text.split("ducked:", 1)[-1]:
                back_ms = int((time.monotonic() - start) * 1000) - pause_ms
                break
            time.sleep(0.02)
        if proc is not None:
            proc.wait(timeout=15)
        watcher.send_signal(signal.SIGTERM)
        players, _ = watcher.communicate(timeout=10)
        players = [p for p in players.splitlines() if p and "Spotify" not in p]
        system_played = any(p.endswith(SYSTEM_PLAYERS) for p in players)
        ok = pause_ms is not None and back_ms is not None
        if expect_system and not system_played:
            self.record(Trial(group, name, False, f"no system sound was produced (saw: {players or 'nothing'})",
                              invalid=True))
        elif not expect_system and system_played and not ok:
            self.record(Trial(group, name, False, "the sound came from a system daemon, not the app",
                              invalid=True))
        else:
            detail = ("paused, then resumed" if ok else
                      "never paused" if pause_ms is None else "paused but never resumed")
            detail += " (played by " + ", ".join(sorted({Path(p).name for p in players})) + ")"
            self.record(Trial(group, name, ok, detail, pause_ms, back_ms))
        self.ensure_playing()

    def record(self, t: Trial) -> None:
        self.trials.append(t)
        tag = f"{YELLOW}INVALID{RESET}" if t.invalid else (f"{GREEN}PASS{RESET}" if t.ok else f"{RED}FAIL{RESET}")
        timing = ""
        if t.pause_ms is not None:
            timing = f"  paused after {t.pause_ms} ms"
            if t.resume_ms is not None:
                timing += f", music back {t.resume_ms} ms later"
        say(f"  {tag}  {t.name:<38} {DIM}{t.detail}{timing}{RESET}")

    # ------------------------------------------------------------- the sounds

    def helper_cmd(self, *args: str, hold: float = 1.5) -> None:
        subprocess.run([str(self.helper), *args], env={**os.environ, "HOLD": str(hold)}, check=False)

    def reminder(self) -> None:
        # Reminders alarms fire on the minute, whatever seconds the date
        # carries, so the alarm is set for the next whole minute that is at
        # least 5 s away and the trial waits up to 70 s for it.
        osa(f'set d to (current date) + 65\nset seconds of d to 0\n'
            f'tell application "Reminders" to make new reminder with properties '
            f'{{name:"{REMINDER_NAME}", remind me date:d}}')

    def screenshot(self) -> None:
        subprocess.run(["screencapture", str(self.tmp / f"shot-{time.time_ns()}.png")], check=False)

    def run_ignored(self) -> None:
        say(f"\n{BOLD}Apple system sounds — must NOT pause{RESET}")
        sounds = sorted(SOUNDS.glob("*.aiff"))
        for i in range(self.args.trials):
            self.ignored(f"NSBeep #{i + 1}", lambda: self.helper_cmd("beep"))
        for i in range(self.args.trials):
            self.ignored(f"alert sound #{i + 1}", lambda: self.helper_cmd("alert"))
        for s in sounds:
            self.ignored(f"system sound {s.stem}", lambda s=s: self.helper_cmd("systemsound", str(s)))
        self.ignored("burst of 6 beeps", lambda: [self.helper_cmd("beep", hold=0.25) for _ in range(6)])
        for i in range(max(1, self.args.trials // 2)):
            self.ignored(f"screenshot shutter #{i + 1}", self.screenshot)
        if not self.args.skip_notifications:
            for i in range(max(1, self.args.trials // 2)):
                # The alarm is up to a minute away (see `reminder`); the trial
                # still has to see the daemon play before it can pass.
                self.ignored(f"notification (Reminders) #{i + 1}", self.reminder, window=3.0, wait_for_sound=70.0)

    def run_counted(self) -> None:
        say(f"\n{BOLD}Short sounds from apps — MUST pause{RESET}")
        tone = self.tmp / "tone-0.4s.wav"
        make_tone(tone, 0.4)
        glass = str(SOUNDS / "Glass.aiff")
        for i in range(self.args.trials):
            self.counted("counted", f"0.4 s tone via afplay #{i + 1}",
                         lambda: subprocess.Popen(["afplay", str(tone)]))
        for i in range(self.args.trials):
            # An Apple sound *file*, but played by an ordinary process: that is
            # app audio, not a system sound, and it has to pause.
            self.counted("counted", f"Glass.aiff via afplay #{i + 1}",
                         lambda: subprocess.Popen(["afplay", glass]))
        for i in range(self.args.trials):
            self.counted("counted", f"Ping.aiff via NSSound in-app #{i + 1}",
                         lambda: subprocess.Popen([str(self.helper), "nssound", str(SOUNDS / "Ping.aiff")],
                                                  env={**os.environ, "HOLD": "1.2"}))

    def run_control(self) -> None:
        say(f"\n{BOLD}Control — the switch OFF, system sounds MUST pause{RESET}")
        self.launch_sonar(ignore_system_sounds=False)
        # Glass.aiff, the same file the counted group plays through afplay, so the only thing that
        # differs is the player. (A bare NSBeep is too short and quiet at a modest alert volume to
        # cross the Instant threshold reliably, which would test the threshold, not the switch.)
        glass = "/System/Library/Sounds/Glass.aiff"
        for i in range(max(2, self.args.trials // 2)):
            self.counted("control", f"Glass via systemsoundserverd, switch off #{i + 1}",
                         lambda: subprocess.Popen([str(self.helper), "systemsound", glass]),
                         expect_system=True)

    # ---------------------------------------------------------------- summary

    def summary(self) -> int:
        say(f"\n{BOLD}SUMMARY{RESET}")
        failed = 0
        for group in ("ignored", "counted", "control"):
            ts = [t for t in self.trials if t.group == group]
            if not ts:
                continue
            passed = sum(t.ok for t in ts)
            invalid = sum(t.invalid for t in ts)
            failed += len(ts) - passed - invalid
            pauses = [t.pause_ms for t in ts if t.pause_ms is not None]
            resumes = [t.resume_ms for t in ts if t.resume_ms is not None]
            timing = ""
            if pauses:
                timing = f"  pause median {sorted(pauses)[len(pauses) // 2]} ms"
            if resumes:
                timing += f", paused-for median {sorted(resumes)[len(resumes) // 2]} ms"
            colour = GREEN if passed == len(ts) else RED
            say(f"  {colour}{group:<8} {passed}/{len(ts)} passed{RESET}"
                + (f"  {YELLOW}{invalid} invalid{RESET}" if invalid else "") + timing)
        invalid_total = sum(t.invalid for t in self.trials)
        if failed == 0 and invalid_total == 0:
            say(f"\n{GREEN}{BOLD}All {len(self.trials)} trials passed.{RESET}")
            return 0
        if failed == 0:
            say(f"\n{YELLOW}No failures, but {invalid_total} trial(s) could not prove a sound played.{RESET}")
            return 2
        say(f"\n{RED}{BOLD}{failed} trial(s) failed.{RESET}")
        return 1

    def cleanup(self) -> None:
        self.quit_sonar()
        if self.prefs_backup is not None:
            PREFS.write_bytes(self.prefs_backup)
            subprocess.run(["defaults", "read", str(PREFS)], capture_output=True)
        osa(f'tell application "Reminders" to delete (every reminder whose name is "{REMINDER_NAME}")', timeout=20)
        clear_notifications()
        if self.volumes:
            osa(f"set volume {self.volumes}")
        if self.sonar_was_running:
            subprocess.run(["open", self.args.app])
        shutil.rmtree(self.tmp, ignore_errors=True)


def clear_notifications() -> None:
    """Dismiss the Reminders alerts the trials left on screen (they persist).

    Best effort, through Notification Center's own "Clear All" accessibility
    action, which needs nothing beyond the Accessibility grant osascript has.
    """
    for _ in range(10):
        r = subprocess.run(["osascript", "-e", '''
tell application "System Events" to tell process "NotificationCenter" to tell window "Notification Center"
    perform (first action of (group 1 of group 1 of scroll area 1 of group 1 of group 1) whose name contains "Clear All")
end tell'''], capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            return
        time.sleep(0.8)


def make_tone(path: Path, seconds: float) -> None:
    import math
    import struct
    import wave

    rate = 44100
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(
            struct.pack("<h", int(0.5 * 32767 * math.sin(2 * math.pi * 1000 * i / rate)))
            for i in range(int(rate * seconds))))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", default="/Applications/Sonar.app", help="Sonar.app to test")
    p.add_argument("--trials", type=int, default=5, help="repeats per sound (default 5)")
    p.add_argument("--allow-playback", action="store_true", help="press play in Spotify if it is not playing")
    p.add_argument("--set-volumes", action="store_true",
                   help="unmute and raise output/alert volume for the run, restore after")
    p.add_argument("--skip-notifications", action="store_true", help="skip the Reminders notification trials")
    p.add_argument("--skip-control", action="store_true", help="skip the switch-off control run")
    p.add_argument("--notifications-only", action="store_true", help="run only the Reminders notification trials")
    p.add_argument("--control-only", action="store_true", help="run only the switch-off control trials")
    args = p.parse_args()
    args.app = str(Path(args.app).resolve())

    run = Run(args)
    run.tmp = Path(tempfile.mkdtemp(prefix="sonar-syssound-"))
    run.helper = run.tmp / "helper"
    src = run.tmp / "helper.swift"
    src.write_text(HELPER_SOURCE)
    say(f"{DIM}Compiling the sound helper…{RESET}")
    subprocess.run(["swiftc", "-O", str(src), "-o", str(run.helper)], check=True, capture_output=True)

    state = spotify_state()
    if state != "playing":
        if not args.allow_playback:
            raise SystemExit(f"Spotify is '{state or 'not running'}'. Press play, or pass --allow-playback.")
        run.ensure_playing()

    settings = osa("get volume settings")
    say(f"{DIM}Volume: {settings}{RESET}")
    if args.set_volumes:
        vals = dict(kv.split(":") for kv in settings.split(", "))
        run.volumes = (f"output volume {vals['output volume']} alert volume {vals['alert volume']} "
                       + ("with" if vals["output muted"] == "true" else "without") + " output muted")
        osa("set volume output volume 20 alert volume 50 without output muted")
    elif "output muted:true" in settings or "alert volume:0" in settings:
        say(f"{YELLOW}Output is muted or the alert volume is 0. System sounds may not play;"
            f" trials that cannot prove a sound will be INVALID. Use --set-volumes.{RESET}")

    run.prefs_backup = PREFS.read_bytes() if PREFS.exists() else None
    run.sonar_was_running = sonar_running()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(130))
    try:
        say(f"\n{BOLD}Launching {args.app} on the Instant preset, ignoring system sounds{RESET}")
        run.launch_sonar(ignore_system_sounds=True)
        if args.notifications_only:
            say(f"\n{BOLD}Notification sounds — must NOT pause{RESET}")
            for i in range(args.trials):
                run.ignored(f"notification (Reminders) #{i + 1}", run.reminder, window=3.0, wait_for_sound=70.0)
            return run.summary()
        if args.control_only:
            run.run_control()
            return run.summary()
        run.run_ignored()
        run.run_counted()
        if not args.skip_control:
            run.run_control()
        return run.summary()
    finally:
        run.cleanup()


if __name__ == "__main__":
    sys.exit(main())
