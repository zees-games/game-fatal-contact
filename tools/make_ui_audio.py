#!/usr/bin/env python3
"""Generate Fatal Contact's own feedback and announcer audio into assets/audio/ (original, no samples).

    FLITE=/path/to/flite python3 -I tools/make_ui_audio.py [--slice hit|announcer|all]

Everything is synthesised: hit sounds from the shared dot-audio foley primitives (noise bursts and
low thuds); announcer lines from the flite `rms` text-to-speech voice (BSD-style licence) pitched
down, band-limited, saturated and layered over a synthesised low sub hit. Nothing is taken from any
recorded game. Needs numpy, scipy, ffmpeg; foley.py comes from dot-audio (FOLEY_DIR or ~/godot).
"""
import argparse, os, subprocess, sys, tempfile, zlib
from pathlib import Path
import numpy as np

FOLEY = os.environ.get("FOLEY_DIR") or str(Path.home().parent / "gamedev/godot/dot-audio/tools")
sys.path.insert(0, FOLEY)
import foley as F  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "assets/audio"
RATE = F.RATE

LINES = {  # file stem -> spoken text
    "first_blood": "first blood", "double_kill": "double kill", "multi_kill": "multi kill",
    "mega_kill": "mega kill", "ultra_kill": "ultra kill", "monster_kill": "monster kill",
    "killing_spree": "killing spree", "rampage": "rampage", "dominating": "dominating",
    "unstoppable": "unstoppable", "godlike": "god like", "headshot": "head shot",
    "humiliation": "humiliation", "flawless_victory": "flawless victory",
    "prepare_to_fight": "prepare to fight", "last_man_standing": "last man standing",
}


def hits():
    rng = np.random.default_rng(7)
    out = {}
    for i in range(3):
        body = F.thud(rng, 150 - 12 * i, 62, 0.16, 0.035, 1.0, 0.2)
        crack = F.noise_burst(rng, 0.03, 700, 2600, 0.008, 0.55)
        out["hit_body_%d" % i] = F.mix([(0, body, 0), (0, crack, -4)], 0.16)
    body = F.thud(rng, 110, 52, 0.2, 0.05, 1.0, 0.25)
    crack = F.noise_burst(rng, 0.05, 900, 3200, 0.012, 0.8)
    out["hit_head"] = F.mix([(0, body, 0), (0, crack, -1), (0.012, F.noise_burst(rng, 0.04, 400, 1500, 0.015, 0.5), -6)], 0.2)
    clank = F.noise_burst(rng, 0.07, 500, 3400, 0.02, 0.8)
    out["hit_armor"] = F.mix([(0, F.thud(rng, 130, 70, 0.12, 0.03, 0.9, 0.3), 0), (0, clank, -3),
                              (0.018, F.noise_burst(rng, 0.05, 800, 2800, 0.014, 0.5), -8)], 0.14)
    big = F.thud(rng, 95, 40, 0.34, 0.09, 1.0, 0.3)
    out["hit_kill"] = F.mix([(0, big, 0), (0, F.noise_burst(rng, 0.06, 300, 2200, 0.02, 0.9), -2),
                             (0.02, F.thud(rng, 70, 38, 0.3, 0.1, 0.8, 0.2), -4)], 0.36)
    return {k: F.finish(F.lowpass(v, 5200), -3.0, 12.0) for k, v in out.items()}


def speak(text):
    flite = os.environ.get("FLITE", "flite")
    with tempfile.TemporaryDirectory() as d:
        w = Path(d) / "s.wav"
        subprocess.run([flite, "-voice", "rms", "-t", text, "-o", str(w)], check=True, capture_output=True)
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(w), "-af",
                              "asetrate=%d,aresample=%d,highpass=f=90,lowpass=f=4800" % (int(RATE * 0.84), RATE),
                              "-f", "f32le", "-ac", "1", "-ar", str(RATE), "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def announcer(stem, text):
    v = speak(text)
    v = v / max(np.max(np.abs(v)), 1e-9)
    v = np.tanh(2.2 * v) / np.tanh(2.2)                       # arena-PA saturation
    v = v + 0.35 * np.concatenate([np.zeros(int(0.045 * RATE)), v[:-int(0.045 * RATE)]]) * 0.6   # short slap
    v = F.lowpass(v, 4200)
    n = len(v) + int(0.25 * RATE)
    rng = np.random.default_rng(zlib.crc32(stem.encode()))
    sub = F.thud(rng, 85, 42, 0.45, 0.12, 1.0, 0.1)
    x = F.mix([(0, sub, -6), (0.03, v / np.max(np.abs(v)), 0)], n / RATE)
    return F.finish(x, -3.0, 40.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slice", default="all")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if a.slice in ("hit", "all"):
        for k, x in hits().items():
            F.to_ogg(x, OUT / (k + ".ogg"), 4)
    if a.slice in ("announcer", "all"):
        for k, t in LINES.items():
            F.to_ogg(announcer(k, t), OUT / (k + ".ogg"), 4)


if __name__ == "__main__":
    main()
