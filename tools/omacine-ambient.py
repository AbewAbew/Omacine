#!/usr/bin/env python3
"""Ambient lighting: drive the ASUS Aura LEDs from what mpv is showing.

Why it works the way it does, on a ROG Strix G512LW:

  * The light bar is NOT colour-addressable. The firmware declares only four
    keyboard zones (SupportedBasicZones 1-4); BarLeft/BarRight/Logo are
    rejected outright. Direct/per-key addressing therefore lights the keys
    only.
  * But the bar DOES follow the firmware's own effect modes. Setting the
    Static effect (mode 0) colours the keyboard and the underglow together.
    So this drives one colour for the whole machine rather than a left-to-right
    gradient - a gradient would light the keys and leave the bar dark.

  * Capture is full-resolution grim. `grim -s` scales in software and measured
    5x SLOWER than capturing full frames and reducing them here.
  * Every pixel of a sampled row is averaged, not a sparse grid. A grid lands on
    different content each frame, so the average jitters by ~19 levels even on a
    completely static screen - visible flicker that no amount of temporal
    smoothing can remove, because it is noise rather than signal. Averaging
    whole rows drops that to ~1. Rows may still be skipped: each sampled row is
    itself a complete average, so coverage stays even.

Run it while something is playing. Ctrl-C restores the previous colour.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time

AURA_PATH = "/xyz/ljones/aura/1866_3_8"
AURA_SERVICE = "xyz.ljones.Asusd"
AURA_IFACE = "xyz.ljones.Aura"


def busctl(args):
    return subprocess.run(["busctl", "--system"] + args, capture_output=True, text=True)


def read_mode():
    out = busctl(["get-property", AURA_SERVICE, AURA_PATH, AURA_IFACE, "LedModeData"]).stdout
    parts = out.split()
    try:  # (uu(yyy)(yyy)ss)  mode zone r g b r2 g2 b2 speed dir
        return [int(parts[i]) for i in range(1, 9)]
    except (IndexError, ValueError):
        return None


def set_colour(r, g, b):
    busctl(["set-property", AURA_SERVICE, AURA_PATH, AURA_IFACE, "LedModeData",
            "(uu(yyy)(yyy)ss)", "0", "0", str(r), str(g), str(b),
            "0", "0", "0", "Med", "Right"])


def mpv_geometry():
    """Region of the mpv window, or None to capture the whole output."""
    try:
        clients = json.loads(subprocess.run(["hyprctl", "clients", "-j"],
                                            capture_output=True, text=True, timeout=3).stdout)
    except Exception:
        return None
    for win in clients:
        if "mpv" in str(win.get("class", "")).lower():
            if win.get("fullscreen"):
                return None                     # whole screen is the video
            x, y = win.get("at", [0, 0])
            w, h = win.get("size", [0, 0])
            if w > 32 and h > 32:
                return f"{x},{y} {w}x{h}"
    return None


def capture(region):
    cmd = ["grim", "-t", "ppm"]
    if region:
        cmd += ["-g", region]
    cmd.append("-")
    out = subprocess.run(cmd, capture_output=True).stdout
    return out if out.startswith(b"P6") else None


def frame_colour(raw, row_step=8, dark=24):
    """One representative colour, averaging every pixel of the sampled rows.

    Whole-row sums via slice arithmetic; a sparse x-grid is what caused the
    flicker. Letterbox rows are dropped wholesale rather than per pixel, which
    is both faster and more correct: a bar is a property of the row.
    """
    head = raw.split(b"\n", 3)
    try:
        w, h = map(int, head[1].split())
        body = head[3]
    except (IndexError, ValueError):
        return None
    rowb = w * 3
    rs = gs = bs = n = 0
    floor = dark * w          # a row this dark overall is letterboxing
    for y in range(0, h, row_step):
        start = y * rowb
        row = body[start:start + rowb]
        if len(row) < rowb:
            break
        r = sum(row[0::3]); g = sum(row[1::3]); b = sum(row[2::3])
        if r + g + b < floor * 3:
            continue
        rs += r; gs += g; bs += b; n += w
    if not n:
        return (0, 0, 0)
    return (rs // n, gs // n, bs // n)


def punch(rgb, saturation=1.7, floor=28, ceiling=255):
    """A frame average is muddy; push it toward the colour the eye reads."""
    r, g, b = rgb
    grey = (r + g + b) / 3 or 1
    r = grey + (r - grey) * saturation
    g = grey + (g - grey) * saturation
    b = grey + (b - grey) * saturation
    peak = max(r, g, b, 1)
    if peak > ceiling:                      # rescale rather than clip to white
        r, g, b = (c * ceiling / peak for c in (r, g, b))
    if peak < floor:                        # keep very dark scenes visible
        boost = floor / peak
        r, g, b = r * boost, g * boost, b * boost
    return tuple(max(0, min(255, int(c))) for c in (r, g, b))


def main():
    ap = argparse.ArgumentParser(description="Ambient lighting from the video on screen")
    ap.add_argument("--fps", type=float, default=12.0)
    ap.add_argument("--smooth", type=float, default=0.18,
                    help="0..1; lower is calmer. Stops cuts strobing.")
    ap.add_argument("--deadzone", type=int, default=6,
                    help="ignore colour changes smaller than this per channel")
    ap.add_argument("--min-interval", type=float, default=0.12,
                    help="seconds between hardware writes; every write re-applies "
                         "the Static mode and the firmware can flash doing it")
    ap.add_argument("--saturation", type=float, default=1.7)
    ap.add_argument("--step", type=int, default=8, help="row sampling stride")
    ap.add_argument("--follow-mpv", action="store_true",
                    help="only light up while an mpv window exists")
    ap.add_argument("--once", action="store_true", help="one frame, then exit")
    args = ap.parse_args()

    previous = read_mode()
    if previous is None:
        print("could not read the current Aura state - is asusd running?", file=sys.stderr)
        return 1

    def restore(*_):
        if previous:
            set_colour(previous[2], previous[3], previous[4])
        print("\nrestored the previous colour")
        sys.exit(0)

    signal.signal(signal.SIGINT, restore)
    signal.signal(signal.SIGTERM, restore)

    smoothed = None
    last_sent = (-99, -99, -99)
    last_write = 0.0
    interval = 1.0 / max(0.5, args.fps)
    print(f"ambient: {args.fps:g} fps, smoothing {args.smooth}, Ctrl-C to stop")
    while True:
        start = time.time()
        region = mpv_geometry()
        if args.follow_mpv and region is None:
            found = subprocess.run(["pgrep", "-x", "mpv"], capture_output=True).returncode == 0
            if not found:
                time.sleep(0.5)
                continue
        raw = capture(region)
        if raw:
            target = punch(frame_colour(raw, args.step) or (0, 0, 0), args.saturation)
            if smoothed is None:
                smoothed = target
                set_colour(*smoothed)
                last_sent, last_write = smoothed, time.time()
            else:
                a = args.smooth
                smoothed = tuple(int(s + (t - s) * a) for s, t in zip(smoothed, target))
                # Two gates before touching the hardware. Sampling is stable now,
                # so the remaining flicker comes from the writes themselves: each
                # one re-applies the Static effect mode, and the firmware can
                # blink as it does. Write only on a visible change, and never
                # faster than min-interval.
                moved = max(abs(c - p) for c, p in zip(smoothed, last_sent))
                due = (time.time() - last_write) >= args.min_interval
                if moved >= args.deadzone and due:
                    set_colour(*smoothed)
                    last_sent, last_write = smoothed, time.time()
        if args.once:
            print("colour:", smoothed)
            return 0
        rest = interval - (time.time() - start)
        if rest > 0:
            time.sleep(rest)


if __name__ == "__main__":
    sys.exit(main())
