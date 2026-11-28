#!/usr/bin/env python3
"""Objective gates for Fatal Contact's gameplay audio, per category, plus spectrogram PNGs.

    python3 -I tools/audio_check.py [--spec DIR] [--compare OLD_DIR] [paths...]

Default path: assets/audio. A file's category comes from its name (hit_*, announcer lines, ...).
Gates: LUFS window per category, true peak under -1 dBFS, no clipping, head silence <= 10 ms,
spectral centroid ceiling, tonal-peak ratio (rejects pure-tone blips), tail length (time to -40 dB).
Measuring reuses dot-audio's tools/audit_weapon_audio.py (decode, K-weighting, true peak).
Exit 1 when any file fails. Needs numpy, scipy, ffmpeg.
"""
import argparse, os, subprocess, sys
from pathlib import Path
import numpy as np

AUD = os.environ.get("FOLEY_DIR") or str(Path.home().parent / "gamedev/godot/dot-audio/tools")
sys.path.insert(0, AUD)
import audit_weapon_audio as A  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
# category: (lufs_min, lufs_max, centroid_max_hz, tonal_max, tail_max_s)
CATS = {
    "hit": (-26, -16, 2600, 0.40, 0.45),
    "announcer": (-24, -12, 2200, 0.60, 2.5),
    "move": (-36, -20, 2800, 0.30, 0.8),
    "impact": (-30, -14, 3000, 0.30, 1.5),
    "ui": (-34, -18, 2800, 0.35, 0.8),
    "pickup": (-32, -16, 2800, 0.35, 0.8),
    "ambience": (-42, -26, 2400, 0.50, 99),
}
ANNOUNCER = ("first_blood double_kill multi_kill mega_kill ultra_kill monster_kill killing_spree rampage dominating "
             "unstoppable godlike headshot humiliation flawless_victory prepare_to_fight last_man_standing").split()


def category(p):
    s = p.stem
    if s.startswith("hit_"): return "hit"
    if s in ANNOUNCER: return "announcer"
    for pre, c in (("step", "move"), ("jump", "move"), ("land", "move"), ("slide", "move"), ("wall", "move"), ("dash", "move"),
                   ("pain", "move"), ("death", "move"), ("impact", "impact"), ("ricochet", "impact"), ("explo", "impact"),
                   ("pickup", "pickup"), ("amb", "ambience")):
        if s.startswith(pre): return c
    return "ui"


def extra(x):
    n = len(x)
    spec = np.abs(np.fft.rfft(x * np.hanning(n))) ** 2
    fr = np.fft.rfftfreq(n, 1 / A.RATE)
    # tonal ratio: above 400 Hz, the energy within +-8% of the strongest peak over all energy there.
    # A pure-tone blip is close to 1, noise and thuds are well under 0.4.
    hi = fr > 400
    sp, fh = spec[hi], fr[hi]
    tonal = 0.0
    if len(sp) and sp.sum() > 0:
        f0 = fh[int(np.argmax(sp))]
        tonal = float(sp[np.abs(fh - f0) <= 0.08 * f0].sum() / sp.sum())
    env = np.abs(x)
    k = int(0.005 * A.RATE)
    sm = np.convolve(env, np.ones(k) / k, "same")
    pk = sm.max()
    idx = np.nonzero(sm > pk * 10 ** (-40 / 20))[0]
    tail = float(idx[-1] / A.RATE) if len(idx) else 0.0
    return {"tonal": round(tonal, 3), "tail_s": round(tail, 3)}


def check(p):
    x = A.decode(p)
    m = A.measure(x)
    m.update(extra(x))
    cat = category(p)
    lo, hi, cen, ton, tail = CATS[cat]
    f = []
    if m["tp_db"] > -1.0: f.append("true peak %.1f" % m["tp_db"])
    if m["clipped"] > 0: f.append("clipped %d" % m["clipped"])
    if m["head_s"] > 0.010: f.append("head silence %.0f ms" % (m["head_s"] * 1000))
    if not lo <= m["lufs_active"] <= hi: f.append("LUFS %.1f outside %d..%d" % (m["lufs_active"], lo, hi))
    if m["centroid_hz"] > cen: f.append("centroid %d > %d" % (m["centroid_hz"], cen))
    if m["tonal"] > ton: f.append("tonal %.2f > %.2f" % (m["tonal"], ton))
    if m["tail_s"] > tail: f.append("tail %.2f s > %.2f" % (m["tail_s"], tail))
    m["cat"], m["flags"] = cat, f
    return m


def spectrogram(p, out):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(p), "-lavfi",
                    "showspectrumpic=s=640x320:legend=1:scale=log:fscale=log", str(out)], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--spec")
    ap.add_argument("--compare", help="also print the same measures for old files, no gating")
    a = ap.parse_args()
    files = []
    for s in a.paths or [str(ROOT / "assets/audio")]:
        sp = Path(s)
        files += sorted(sp.rglob("*.ogg")) if sp.is_dir() else [sp]
    bad = 0
    print("%-28s %-9s %6s %6s %6s %6s %6s %6s %6s" % ("file", "cat", "dur", "LUFS", "tp", "head", "cent", "tonal", "tail"))
    for p in files:
        m = check(p)
        print("%-28s %-9s %6.2f %6.1f %6.1f %6.3f %6d %6.2f %6.2f  %s" % (p.name[:28], m["cat"], m["dur"], m["lufs_active"],
              m["tp_db"], m["head_s"], m["centroid_hz"], m["tonal"], m["tail_s"], "; ".join(m["flags"])))
        bad += bool(m["flags"])
        if a.spec:
            Path(a.spec).mkdir(parents=True, exist_ok=True)
            spectrogram(p, Path(a.spec) / (p.stem + ".png"))
    print("files %d, failing %d" % (len(files), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
