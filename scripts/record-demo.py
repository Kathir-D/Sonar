#!/usr/bin/env python3
"""Record the README's demo video from a real run of Sonar.

Nothing in the video is mocked. A scripted scenario runs against the real
Sonar.app and the real Spotify while four things are recorded on one clock
(`time.monotonic()`, which on macOS is the same mach_absolute_time Core Audio's
helper stamps with):

  - which processes are producing audio, started/stopped (a Core Audio watcher)
  - every line Sonar writes to its log (ducked / restored / candidate)
  - Spotify's player state, polled over AppleScript
  - the menu bar and the notification banner, grabbed with `screencapture -x`

`render` then draws those recordings into frames with PIL, follows them with a
short tour of the app from the window screenshots in docs/images (see TOUR),
and encodes an MP4 and a GIF with ffmpeg. Long waits (a Reminders alarm can
take a minute) are cut out, so the video is short while every event in it keeps
its real timing.

    python3 scripts/record-demo.py record --app dist/Sonar.app --work /tmp/sonar-demo
    python3 scripts/record-demo.py render --work /tmp/sonar-demo --out docs/images/sonar-demo

Only two screen regions are ever kept: the Sonar menu-bar item and, on grabs
that match the demo's own banner, the banner. Everything else on the screen is
discarded.

DESTRUCTIVE IN THE SAME WAYS AS system-sounds-smoke.py: it relaunches Sonar on
the Instant preset (restoring the previous settings after), plays sounds out
loud and creates a reminder named "Sonar demo" (deleted after).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Shared with the smoke test: the Swift helper, Sonar's prefs/log paths and the
# relaunch-on-Instant logic. One copy of each, so the demo shows exactly what
# the test asserts.
_spec = importlib.util.spec_from_file_location("system_sounds_smoke", ROOT / "scripts/system-sounds-smoke.py")
smoke = importlib.util.module_from_spec(_spec)
sys.modules["system_sounds_smoke"] = smoke
_spec.loader.exec_module(smoke)

# Screen regions, in screen pixels of the main display (2560x1440 at 1x on the
# recording machine). Edit these to adapt to another layout.
GRAB = (1850, 0, 710, 240)  # x, y, w, h: covers both regions below in one shot
MENU_ITEM = (1892, 0, 136, 28)  # fallback; the live position is read at record time
BANNER = (2200, 46, 346, 76)

REMINDER = "Sonar demo"
SPEECH = "Quick clip from another app."

# After the live run, a short tour of the real app, from screenshots in
# docs/images (window captures, so nothing else on the screen is in them).
# `focus` is a rectangle in the screenshot's pixels to ring; with `scroll`, the
# view also scrolls down to it, continuing from where the previous stop left
# the same screenshot.
TOUR = [
    {"image": "menu-bar-player.png", "seconds": 2.0, "panel": True,
     "caption": "Your track, in the menu bar.", "sub": "Click Sonar for artwork and playback controls."},
    {"image": "auto-pause-pane.png", "seconds": 2.0, "focus": (221, 480, 760, 601),
     "caption": "Choose how it pauses.", "sub": "Fade eases the music down and back up. Instant cuts it in the moment."},
    {"image": "auto-pause-pane.png", "seconds": 2.8, "focus": (221, 1019, 760, 1091), "scroll": True,
     "caption": "One switch for system sounds.", "sub": "Auto-Pause › Ignore Apple system sounds. On by default."},
]
TOUR_SCALE = 0.78  # settings screenshots, shown at one scale so stops on the same image line up
XFADE = 0.25  # seconds of crossfade between scenes

W, H, FPS = 1280, 720, 30
FONT = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/Menlo.ttc"

BG_TOP, BG_BOTTOM = (12, 14, 20), (18, 22, 31)
PANEL = (24, 28, 38)
PANEL_EDGE = (40, 46, 60)
TEXT = (236, 239, 244)
DIM = (140, 148, 163)
FAINT = (78, 86, 102)
GREEN = (30, 215, 96)  # Spotify green
BLUE = (90, 170, 255)  # Apple system sounds
ORANGE = (255, 159, 67)  # other apps
AMBER = (255, 196, 61)
RED = (255, 95, 87)


# =============================================================== recording


class Recorder:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.work = Path(args.work)
        self.frames = self.work / "frames"
        self.t0 = time.monotonic()
        self.stop = threading.Event()
        self.audio: list[tuple[float, str, str]] = []
        self.log: list[tuple[float, str]] = []
        self.spotify: list[tuple[float, str]] = []
        self.grabs: list[tuple[float, str]] = []
        self.segments: list[dict] = []
        self.marks: dict[str, float] = {}

    def now(self) -> float:
        return time.monotonic()

    # -- background recorders

    def grab_loop(self) -> None:
        x, y, w, h = GRAB
        i = 0
        while not self.stop.is_set():
            path = self.frames / f"{i:05d}.png"
            t = self.now()
            subprocess.run(["screencapture", "-x", "-o", f"-R{x},{y},{w},{h}", str(path)])
            # Stamped at the middle of the grab: screencapture takes ~0.1 s.
            self.grabs.append(((t + self.now()) / 2, path.name))
            i += 1

    def log_loop(self) -> None:
        offset = smoke.log_size()
        while not self.stop.is_set():
            text = smoke.log_since(offset)
            if text:
                offset += len(text.encode())
                t = self.now()
                for line in text.splitlines():
                    if line.strip():
                        self.log.append((t, line.split("Z ", 1)[-1]))
            time.sleep(0.01)

    def spotify_loop(self) -> None:
        while not self.stop.is_set():
            self.spotify.append((self.now(), smoke.spotify_state()))
            time.sleep(0.15)

    def audio_loop(self) -> None:
        # Terminated from `run()`'s cleanup: this loop is parked in readline()
        # and would never get round to it, and an orphaned watcher keeps the
        # caller's pipes open forever.
        for line in self.watcher.stdout:
            t, what, path = line.rstrip("\n").split(" ", 2)
            self.audio.append((float(t), what, path))

    # -- scenario

    def segment(self, start: float, end: float, caption: str, sub: str = "") -> None:
        self.segments.append({"start": start, "end": end, "caption": caption, "sub": sub})

    def first_audio_after(self, t: float, suffixes: tuple[str, ...], timeout: float) -> float | None:
        deadline = self.now() + timeout
        while self.now() < deadline:
            for at, what, path in list(self.audio):
                if at >= t and what == "on" and path.endswith(suffixes):
                    return at
            time.sleep(0.02)
        return None

    def first_log_after(self, t: float, prefix: str, timeout: float) -> float | None:
        deadline = self.now() + timeout
        while self.now() < deadline:
            for at, line in list(self.log):
                if at >= t and line.startswith(prefix):
                    return at
            time.sleep(0.02)
        return None

    @staticmethod
    def menu_item_region() -> tuple[int, int, int, int]:
        """Sonar's menu-bar item, where it is right now: its width follows the
        track title, so a fixed rectangle would clip it or show a neighbour."""
        out = smoke.osa('tell application "System Events" to tell process "Sonar" to '
                        'get {position, size} of menu bar item 1 of menu bar 2')
        try:
            x, y, w, h = (int(v) for v in out.split(", "))
        except ValueError:
            return MENU_ITEM
        gx, _, gw, _ = GRAB
        if x < gx or x + w > gx + gw:
            return MENU_ITEM
        return (x, 0, w, 28)

    def run(self) -> None:
        run = smoke.Run(argparse.Namespace(app=self.args.app, trials=1))
        run.tmp = self.work / "tmp"
        run.tmp.mkdir(parents=True, exist_ok=True)
        run.helper = run.tmp / "helper"
        (run.tmp / "helper.swift").write_text(smoke.HELPER_SOURCE)
        subprocess.run(["swiftc", "-O", str(run.tmp / "helper.swift"), "-o", str(run.helper)], check=True)
        run.prefs_backup = smoke.PREFS.read_bytes() if smoke.PREFS.exists() else None
        run.sonar_was_running = smoke.sonar_running()

        info = smoke.osa('tell application "Spotify" to get {name, artist, album, artwork url} of current track')
        title, artist, album, art = (s.strip() for s in info.split(", ", 3)) if info.count(", ") >= 3 else ("", "", "", "")
        track = {"title": title, "artist": artist, "album": album}
        if art.startswith("https://"):
            urllib.request.urlretrieve(art, self.work / "artwork.jpg")

        settings = smoke.osa("get volume settings")
        vals = dict(kv.split(":") for kv in settings.split(", "))
        restore_volume = (f"output volume {vals['output volume']} alert volume {vals['alert volume']} "
                          + ("with" if vals["output muted"] == "true" else "without") + " output muted")
        smoke.osa("set volume output volume 20 alert volume 50 without output muted")
        try:
            run.ensure_playing()
            run.launch_sonar(ignore_system_sounds=True)
            self.watcher = subprocess.Popen([str(run.helper), "transitions"], stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, text=True)
            threads = [
                threading.Thread(target=self.grab_loop, daemon=True),
                threading.Thread(target=self.log_loop, daemon=True),
                threading.Thread(target=self.spotify_loop, daemon=True),
                threading.Thread(target=self.audio_loop, daemon=True),
            ]
            for t in threads:
                t.start()
            time.sleep(1.5)
            self.menu_item = self.menu_item_region()

            # 1. Baseline.
            t = self.now()
            time.sleep(1.6)
            self.segment(t, self.now(), "Spotify is playing.",
                         "Sonar pauses it whenever another app makes sound.")

            # 2. A real notification. Reminders alarms fire on the minute, so the
            # wait is cut out of the video; the sound is the anchor.
            smoke.osa('set d to (current date) + 65\nset seconds of d to 0\n'
                      f'tell application "Reminders" to make new reminder with properties '
                      f'{{name:"{REMINDER}", body:"Dinner at 7", remind me date:d}}')
            t = self.now()
            at = self.first_audio_after(t, smoke.SYSTEM_PLAYERS, 75)
            if at is None:
                raise SystemExit("The reminder never played a sound.")
            time.sleep(3.0)
            self.marks["notification"] = at
            self.segment(at - 0.6, at + 2.6, "A notification arrives.",
                         "It's an Apple system sound, so the music keeps playing.")

            # 3. A short clip from an ordinary app.
            run.ensure_playing()
            time.sleep(1.5)
            t = self.now()
            subprocess.run(["say", "-v", "Samantha", SPEECH])
            end = self.now()
            # Speech synthesis takes a second or more to start; anchor on the
            # moment the audio really began, not on the command.
            at = self.first_audio_after(t, ("/say",), 1) or t
            back = self.first_log_after(end, "restored", 5) or end + 1.0
            time.sleep(1.0)
            self.segment(at - 0.6, back + 0.9, "Another app plays a short clip.",
                         "Sonar pauses Spotify, then resumes it the moment it stops.")
        finally:
            self.stop.set()
            if getattr(self, "watcher", None) is not None:
                self.watcher.terminate()
                self.watcher.wait(timeout=5)
            time.sleep(0.5)
            smoke.osa(f'tell application "Reminders" to delete (every reminder whose name is "{REMINDER}")')
            smoke.clear_notifications()
            smoke.osa(f"set volume {restore_volume}")
            run.quit_sonar()
            if run.prefs_backup is not None:
                smoke.PREFS.write_bytes(run.prefs_backup)
            if run.sonar_was_running:
                subprocess.run(["open", self.args.app])

        (self.work / "events.json").write_text(json.dumps({
            "track": track, "audio": self.audio, "log": self.log, "spotify": self.spotify,
            "grabs": self.grabs, "segments": self.segments, "marks": self.marks,
            "grab_region": GRAB, "menu_item": getattr(self, "menu_item", MENU_ITEM), "banner": BANNER,
        }, indent=1))
        print(f"recorded {len(self.grabs)} grabs, {len(self.audio)} audio transitions, "
              f"{len(self.log)} log lines into {self.work}")


# =============================================================== rendering


def font(size: int, weight: str = "Regular"):
    from PIL import ImageFont

    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def mono(size: int):
    from PIL import ImageFont

    return ImageFont.truetype(MONO, size)


def ease(x: float) -> float:
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def mix(a, b, t: float):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Timeline:
    """Everything recorded, queryable at any instant of the recording."""

    def __init__(self, ev: dict):
        self.ev = ev
        self.duck = []  # (start, end) intervals Sonar held Spotify paused
        start = None
        for t, line in ev["log"]:
            if line.startswith("ducked:"):
                start = t
            elif line.startswith("restored") and start is not None:
                self.duck.append((start, t))
                start = None
        if start is not None:
            self.duck.append((start, math.inf))
        # Per-process output intervals.
        self.intervals: list[tuple[float, float, str]] = []
        open_at: dict[str, float] = {}
        for t, what, path in ev["audio"]:
            if "Spotify" in path:
                continue
            if what == "on":
                open_at[path] = t
            elif path in open_at:
                self.intervals.append((open_at.pop(path), t, path))
        for path, t in open_at.items():
            self.intervals.append((t, math.inf, path))
        self.grabs = ev["grabs"]

    def ducked(self, t: float) -> bool:
        return any(a <= t < b for a, b in self.duck)

    def grab_at(self, t: float) -> str | None:
        best = None
        for gt, name in self.grabs:
            if gt <= t:
                best = name
            else:
                break
        return best

    @staticmethod
    def is_system(path: str) -> bool:
        return path.endswith(smoke.SYSTEM_PLAYERS)


class Renderer:
    def __init__(self, work: Path):
        from PIL import Image

        self.work = work
        self.ev = json.loads((work / "events.json").read_text())
        self.tl = Timeline(self.ev)
        self.Image = Image
        self.cache: dict[str, object] = {}
        self.art = None
        if (work / "artwork.jpg").exists():
            self.art = self.rounded(Image.open(work / "artwork.jpg").convert("RGB").resize((300, 300), Image.LANCZOS), 18)
        self.bg = self.gradient()
        self.f = {
            "h1": font(64, "Bold"), "h2": font(30, "Semibold"), "cap": font(34, "Semibold"),
            "sub": font(21), "title": font(28, "Bold"), "body": font(20), "small": font(15, "Medium"),
            "tiny": font(13, "Medium"), "pill": font(19, "Semibold"), "mono": mono(15), "mono_s": mono(13),
        }

    # -- helpers

    def gradient(self):
        img = self.Image.new("RGB", (W, H))
        px = img.load()
        for y in range(H):
            c = mix(BG_TOP, BG_BOTTOM, y / H)
            for x in range(W):
                px[x, y] = c
        return img

    def rounded(self, img, r: int):
        from PIL import ImageDraw

        mask = self.Image.new("L", img.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, *img.size), r, fill=255)
        out = self.Image.new("RGBA", img.size)
        out.paste(img, (0, 0), mask)
        return out

    def grab(self, name: str | None, region):
        if name is None:
            return None
        key = f"{name}:{region}"
        if key not in self.cache:
            gx, gy, _, _ = self.ev["grab_region"]
            x, y, w, h = region
            img = self.Image.open(self.work / "frames" / name).convert("RGB")
            self.cache[key] = img.crop((x - gx, y - gy, x - gx + w, y - gy + h))
            if len(self.cache) > 400:
                self.cache.pop(next(iter(self.cache)))
        return self.cache[key]

    # -- scenes

    def caption(self, d, seg: dict, seg_t: float, length: float) -> None:
        a = ease(seg_t * 5) * ease((length - seg_t) * 5 + 0.3)
        d.text((W // 2, 636), seg["caption"], font=self.f["cap"], fill=mix(BG_BOTTOM, TEXT, a), anchor="mm")
        d.text((W // 2, 680), seg["sub"], font=self.f["sub"], fill=mix(BG_BOTTOM, DIM, a), anchor="mm")
        total = len(self.ev["segments"]) + len(TOUR)
        for i in range(total):
            cx = W // 2 - (total - 1) * 9 + i * 18
            d.ellipse((cx - 3, 704, cx + 3, 710), fill=TEXT if i == self.seg_index else FAINT)

    def shot(self, name: str):
        key = f"tour:{name}"
        if key not in self.cache:
            self.cache[key] = self.Image.open(ROOT / "docs/images" / name).convert("RGB")
        return self.cache[key]

    def card(self, img, src, x: int, y: int, radius: int = 12) -> None:
        """Paste `src` with rounded corners and a soft shadow at (x, y)."""
        from PIL import ImageDraw, ImageFilter

        shadow = self.Image.new("RGBA", (src.width + 60, src.height + 60), (0, 0, 0, 0))
        mask = self.Image.new("L", shadow.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((30, 36, 30 + src.width, 36 + src.height), radius, fill=150)
        shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(14)))
        img.paste(shadow, (x - 30, y - 30), shadow)
        r = self.rounded(src, radius)
        img.paste(r, (x, y), r)

    def tour_frame(self, stop: dict, p: float, seg_t: float, length: float):
        from PIL import ImageDraw

        img = self.bg.copy()
        src = self.shot(stop["image"])
        if stop.get("panel"):
            # The real menu-bar item, with the player hanging under it.
            last = self.tl.grabs[-1][1] if self.tl.grabs else None
            item = self.grab(last, self.ev["menu_item"])
            strip = item.getpixel((item.width - 1, item.height // 2)) if item is not None else (8, 9, 12)
            d = ImageDraw.Draw(img, "RGBA")
            d.rectangle((0, 0, W, 52), fill=strip)
            if item is not None:
                big = item.resize((item.width * 3 // 2, item.height * 3 // 2), self.Image.LANCZOS)
                img.paste(big, (W // 2 - big.width // 2, 5))
            k = 1.45 + 0.05 * ease(p)
            panel = src.resize((int(src.width * k), int(src.height * k)), self.Image.LANCZOS)
            drop = int(18 * (1 - ease(seg_t * 4)))
            self.card(img, panel, W // 2 - panel.width // 2, 70 - drop, 18)
        else:
            area_h = 540
            view_h = int(area_h / TOUR_SCALE)
            top = stop["_from"]
            fx0, fy0, fx1, fy1 = stop["focus"]
            if stop.get("scroll"):
                target = min(max((fy0 + fy1) // 2 - view_h // 2, 0), src.height - view_h)
                top = int(top + (target - top) * ease(p * 1.8))
            stop["_to"] = top
            crop = src.crop((0, top, src.width, min(top + view_h, src.height)))
            out = crop.resize((int(crop.width * TOUR_SCALE), int(crop.height * TOUR_SCALE)), self.Image.LANCZOS)
            x, y = W // 2 - out.width // 2, 62 + (area_h - out.height) // 2
            self.card(img, out, x, y)
            ring = ease((p - (0.55 if stop.get("scroll") else 0.25)) * 4)
            if ring > 0:
                d = ImageDraw.Draw(img, "RGBA")
                pad = 6
                d.rounded_rectangle((x + fx0 * TOUR_SCALE - pad, y + (fy0 - top) * TOUR_SCALE - pad,
                                     x + fx1 * TOUR_SCALE + pad, y + (fy1 - top) * TOUR_SCALE + pad),
                                    12, outline=(*BLUE, int(255 * ring)), width=3)
        d = ImageDraw.Draw(img, "RGBA")
        self.caption(d, stop, seg_t, length)
        return img

    def frame(self, t: float, seg: dict, seg_p: float, seg_t: float):
        from PIL import ImageDraw

        img = self.bg.copy()
        d = ImageDraw.Draw(img, "RGBA")

        # Menu bar strip with the real Sonar item.
        item = self.grab(self.tl.grab_at(t), self.ev["menu_item"])
        strip = item.getpixel((item.width - 1, item.height // 2)) if item is not None else (8, 9, 12)
        d.rectangle((0, 0, W, 52), fill=strip)
        d.text((24, 26), "Your menu bar, live", font=self.f["tiny"], fill=DIM, anchor="lm")
        if item is not None:
            big = item.resize((item.width * 3 // 2, item.height * 3 // 2), self.Image.LANCZOS)
            img.paste(big, (W // 2 - big.width // 2, 5))
            d.text((W // 2 + big.width // 2 + 14, 26), "← Sonar", font=self.f["tiny"], fill=DIM, anchor="lm")

        ducked = self.tl.ducked(t)

        # Now-playing card.
        d.rounded_rectangle((40, 78, 440, 590), 22, fill=PANEL, outline=PANEL_EDGE)
        if ducked:
            d.rounded_rectangle((40, 78, 440, 590), 22, outline=(*AMBER, 140), width=2)
        if self.art is not None:
            art = self.art
            if ducked:
                from PIL import ImageEnhance

                art = ImageEnhance.Brightness(art).enhance(0.45)
            img.paste(art, (90, 122), art)
        tr = self.ev["track"]
        d.text((90, 440), tr["title"], font=self.f["title"], fill=TEXT)
        d.text((90, 476), tr["artist"], font=self.f["body"], fill=DIM)
        pill_col = AMBER if ducked else GREEN
        label = "Paused by Sonar" if ducked else "Playing"
        pw = int(d.textlength(label, font=self.f["pill"])) + 52
        py = 524
        d.rounded_rectangle((90, py, 90 + pw, py + 38), 19, fill=(*pill_col, 40), outline=(*pill_col, 160))
        if ducked:
            d.rectangle((106, py + 11, 111, py + 27), fill=pill_col)
            d.rectangle((116, py + 11, 121, py + 27), fill=pill_col)
        else:
            d.polygon([(107, py + 10), (107, py + 28), (122, py + 19)], fill=pill_col)
        d.text((132, py + 19), label, font=self.f["pill"], fill=pill_col, anchor="lm")
        d.text((64, 100), "SPOTIFY", font=self.f["tiny"], fill=FAINT)

        # Timeline of who is making sound.
        x0, x1, top = 480, 1240, 78
        d.rounded_rectangle((x0, top, x1, 590), 22, fill=PANEL, outline=PANEL_EDGE)
        d.text((x0 + 24, top + 22), "WHO IS MAKING SOUND", font=self.f["tiny"], fill=FAINT)
        span = 5.0
        lx0, lx1 = x0 + 222, x1 - 30

        def tx(at: float) -> float:
            return lx1 - (t - at) / span * (lx1 - lx0)

        lanes = [("Spotify", GREEN, 130), ("Apple system sounds", BLUE, 215), ("Other apps", ORANGE, 300)]
        for name, colour, y in lanes:
            d.text((x0 + 24, y), name, font=self.f["body"], fill=TEXT, anchor="lm")
            d.line((lx0, y, lx1, y), fill=(*FAINT, 120), width=1)
        # Seconds ticks.
        for k in range(int(span) + 1):
            at = math.floor(t) - k
            xx = tx(at)
            if lx0 <= xx <= lx1:
                d.line((xx, 108, xx, 330), fill=(255, 255, 255, 10), width=1)
        # Spotify lane: playing unless Sonar had it ducked.
        y = lanes[0][2]
        segs = [(lx0, lx1)]
        for a, b in self.tl.duck:
            ca, cb = max(tx(a), lx0), min(tx(b), lx1)
            if cb <= lx0 or ca >= lx1:
                continue
            new = []
            for s, e in segs:
                if cb <= s or ca >= e:
                    new.append((s, e))
                else:
                    if ca > s:
                        new.append((s, ca))
                    if cb < e:
                        new.append((cb, e))
            segs = new
            half = d.textlength("paused", font=self.f["tiny"]) / 2
            px = min(max((ca + cb) / 2, lx0 + half), lx1 - half - 6)
            d.text((px, y - 26), "paused", font=self.f["tiny"], fill=AMBER, anchor="mm")
        for s, e in segs:
            if e - s > 1:
                d.rounded_rectangle((s, y - 9, e, y + 9), 9, fill=GREEN)
        # Sound lanes.
        for a, b, path in self.tl.intervals:
            system = Timeline.is_system(path)
            y = lanes[1][2] if system else lanes[2][2]
            colour = BLUE if system else ORANGE
            ca, cb = max(tx(a), lx0), min(tx(min(b, t)), lx1)
            if a > t or cb <= lx0 or ca >= lx1:
                continue
            d.rounded_rectangle((ca, y - 11, max(cb, ca + 6), y + 11), 11, fill=colour)
            label = Path(path).name
            lw = d.textlength(label, font=self.f["mono_s"])
            d.text((min(max(ca, lx0) + 2, lx1 - lw), y + 26), label, font=self.f["mono_s"], fill=colour, anchor="lm")
        d.line((lx1, 100, lx1, 340), fill=(255, 255, 255, 70), width=2)
        d.text((lx1, 345), "now", font=self.f["tiny"], fill=DIM, anchor="mt")

        # Sonar's log, live.
        d.text((x0 + 24, 382), "SONAR'S LOG", font=self.f["tiny"], fill=FAINT)
        shown = []
        for a, b, path in self.tl.intervals:
            if a <= t and t - a < 30:
                system = Timeline.is_system(path)
                verdict = "Apple system sound, ignored" if system else "app audio, counts"
                shown.append((a, f"{Path(path).name:<19} {verdict}", BLUE if system else ORANGE))
        for at, line in self.ev["log"]:
            if at <= t and t - at < 30 and line.startswith(("ducked:", "restored")):
                if line.startswith("ducked"):
                    src = max((a for a, _, p in self.tl.intervals if a <= at and not Timeline.is_system(p)), default=None)
                    note = f"  {at - src:.2f} s after it started" if src is not None else ""
                    shown.append((at, f"  → paused Spotify{note}", AMBER))
                else:
                    src = max((b for _, b, p in self.tl.intervals if b <= at and not Timeline.is_system(p)), default=None)
                    note = f" {at - src:.2f} s after it stopped" if src is not None else ""
                    shown.append((at, f"  → resumed Spotify{note}", GREEN))
        shown.sort()
        for i, (at, text, colour) in enumerate(shown[-6:]):
            alpha = int(255 * ease((t - at) * 4))
            d.text((x0 + 24, 414 + i * 30), text, font=self.f["mono"], fill=(*colour, alpha))

        # The real notification banner, only on grabs that show *our* banner:
        # anything else in that region (the desktop, another app's banner) is
        # not this video's to show.
        n = self.ev["marks"].get("notification")
        shown_at = self.banner_from
        name = self.tl.grab_at(t)
        if n is not None and shown_at is not None and shown_at <= t <= n + 3.8 and self.is_banner(name):
            banner = self.grab(name, self.ev["banner"])
            if banner is not None:
                k = ease((t - shown_at) * 4) * ease((n + 3.8 - t) * 3)
                b = self.rounded(banner, 14)
                x = int(W - b.width - 20 + (1 - k) * 60)
                shadow = self.Image.new("RGBA", (b.width + 8, b.height + 8), (0, 0, 0, int(110 * k)))
                img.paste(shadow, (x - 4, 64), self.rounded(shadow, 18))
                b.putalpha(b.getchannel("A").point(lambda v: int(v * k)))
                img.paste(b, (x, 60), b)

        self.caption(d, seg, seg_t, seg["end"] - seg["start"])
        return img

    def is_banner(self, name: str | None) -> bool:
        """Whether this grab shows the demo's banner: it must closely match the
        grab taken 1.5 s after the sound, when the banner has settled."""
        from PIL import ImageChops, ImageStat

        if name is None or self.banner_ref is None:
            return False
        key = f"is_banner:{name}"
        if key not in self.cache:
            diff = ImageStat.Stat(ImageChops.difference(self.banner_ref, self.grab(name, self.ev["banner"]))).mean
            self.cache[key] = sum(diff) / 3 < 8
        return self.cache[key]

    def find_banner(self) -> float | None:
        """When the banner first appears: the first grab after the sound that
        matches the settled banner."""
        n = self.ev["marks"].get("notification")
        self.banner_ref = None
        if n is None:
            return None
        settled = self.tl.grab_at(n + 1.5)
        if settled is None:
            return None
        self.banner_ref = self.grab(settled, self.ev["banner"]).copy()
        for gt, name in self.tl.grabs:
            if n <= gt <= n + 3 and self.is_banner(name):
                return gt
        return None

    def render(self, out: Path, gif_width: int) -> None:
        frames_dir = self.work / "render"
        shutil.rmtree(frames_dir, ignore_errors=True)
        frames_dir.mkdir(parents=True)
        self.banner_from = self.find_banner()
        # Segments never overlap: a timeline that jumps back half a second
        # between two of them reads as a glitch.
        segs = self.ev["segments"]
        for prev, seg in zip(segs, segs[1:]):
            if seg["start"] < prev["end"]:
                seg["start"] = prev["end"]
        n = 0
        last = None

        def emit(img, fade_from=None, k: float = 1.0) -> None:
            nonlocal n, last
            img = img.convert("RGB")
            if fade_from is not None and k < 1.0:
                img = self.Image.blend(fade_from, img, ease(k))
            img.save(frames_dir / f"{n:05d}.png", compress_level=1)
            last = img
            n += 1

        # Every scene crossfades in from the last frame of the one before; the
        # first from the background and the end back to it, so the GIF loops.
        for idx, seg in enumerate(self.ev["segments"]):
            self.seg_index = idx
            length = seg["end"] - seg["start"]
            prev = last if last is not None else self.bg
            for i in range(int(length * FPS)):
                st = i / FPS
                emit(self.frame(seg["start"] + st, seg, st / length, st), prev, st / XFADE)
        for j, stop in enumerate(TOUR):
            self.seg_index = len(self.ev["segments"]) + j
            before = TOUR[j - 1] if j else None
            stop["_from"] = before["_to"] if before and before["image"] == stop["image"] else 0
            length = stop["seconds"]
            prev = last
            for i in range(int(length * FPS)):
                st = i / FPS
                emit(self.tour_frame(stop, st / length, st, length), prev, st / XFADE)
        tail = last
        for i in range(int(0.4 * FPS)):
            emit(self.bg, tail, i / (0.4 * FPS))

        out.parent.mkdir(parents=True, exist_ok=True)
        mp4 = out.with_suffix(".mp4")
        gif = out.with_suffix(".gif")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", str(FPS),
                        "-i", str(frames_dir / "%05d.png"), "-c:v", "libx264", "-preset", "slow", "-crf", "20",
                        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4)], check=True)
        palette = self.work / "palette.png"
        scale = f"fps=12,scale={gif_width}:-1:flags=lanczos"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(mp4),
                        "-vf", f"{scale},palettegen=max_colors=128:stats_mode=diff", str(palette)], check=True)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(mp4), "-i", str(palette),
                        "-lavfi", f"{scale}[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                        str(gif)], check=True)
        print(f"{n} frames → {mp4} ({mp4.stat().st_size // 1024} KB), {gif} ({gif.stat().st_size // 1024} KB)")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("--app", default="/Applications/Sonar.app")
    r.add_argument("--work", default="/tmp/sonar-demo")
    v = sub.add_parser("render")
    v.add_argument("--work", default="/tmp/sonar-demo")
    v.add_argument("--out", default=str(ROOT / "docs/images/sonar-demo"))
    v.add_argument("--gif-width", type=int, default=800)
    args = p.parse_args()

    if args.cmd == "record":
        args.app = str(Path(args.app).resolve())
        work = Path(args.work)
        shutil.rmtree(work, ignore_errors=True)
        (work / "frames").mkdir(parents=True)
        if smoke.spotify_state() != "playing":
            raise SystemExit("Press play in Spotify first.")
        Recorder(args).run()
    else:
        Renderer(Path(args.work)).render(Path(args.out), args.gif_width)
    return 0


if __name__ == "__main__":
    sys.exit(main())
