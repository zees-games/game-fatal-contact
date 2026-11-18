#!/usr/bin/env bash
# Applies the FC rename (fc-rename-1, phase 1) to the checkout it runs in: moves
# the old-name files to their fc_ names (with their .uid sidecars) and rewrites
# class consts, res:// and relative paths, suite names and prose to match.
# Idempotent: a second run, or a run on a branch that already has it, changes
# nothing. Run it after a rebase over a branch that still uses the old names:
#   tools/fc_rename_apply.sh            # apply
#   tools/fc_rename_apply.sh --check    # list what it would change, exit 1 if anything
#
# Kept on purpose (phase 2, see docs/fc-rename-plan.md): the cfg game id dir,
# content/pack ids, stat/award/leaderboard keys, input actions, effect and prop
# ids, user:// settings, env vars, argv,
# RPC-visible node names, and the entry-point shims dot-server-deploy loads.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec python3 - "$@" <<'PY'
import os, re, subprocess, sys

CHECK = "--check" in sys.argv[1:]
O = "ar" + "ena"            # the old name, split so this file never matches itself
OC = O.capitalize()
OU = O.upper()
SELF = {"tools/fc_rename_apply.sh", "docs/fc-rename-plan.md"}

# Old entry paths dot-server-deploy loads: they stay as thin shims over the new files.
SHIMS = {
    f"game/{O}_module.gd": ("game/fc_module.gd", None),
    f"game/{O}.tscn": ("game/fc.tscn", OC + "Client"),
    f"scenes/{O}_server.tscn": ("scenes/fc_server.tscn", OC + "Server"),
}
# Paths whose names are data (ids built into file names) or other repos' ids:
# never moved. Inside the cfg game dir only identifiers change (its templates are
# generated from code).
KEEP_CONTENT = [re.compile(rf"^cfg/game/game-{O}/")]
KEEP_PATH = KEEP_CONTENT
# Node names RPCs address by path: wire-visible, never renamed.
NODE_NAMES = {OC + "Server", OC + "Client", OC + "SimServer"}

changed = []

def git(*a):
    return subprocess.run(["git", *a], check=True, capture_output=True, text=True).stdout

def new_base(base):
    if base.startswith(O + "_"):
        return "fc_" + base[len(O) + 1:]
    if base.startswith(O + "."):
        return "fc" + base[len(O):]
    if base.startswith(f"headless_{O}16"):
        return base.replace(f"headless_{O}16", "headless_fc16", 1)
    return None

# 1. Paths.
files = [f for f in git("ls-files", "-z").split("\0") if f]
stems = {}
moves = []
for f in files:
    d, base = os.path.split(f)
    nb = new_base(base)
    if nb is None or any(k.search(f) for k in KEEP_PATH):
        continue
    stem, nstem = base.split(".")[0], nb.split(".")[0]
    stems[stem] = nstem
    if f in SHIMS:
        continue  # written below
    moves.append((f, os.path.join(d, nb)))
# Files already moved (by an earlier run or on main): a branch may still name their old stems.
for f in files:
    base = os.path.basename(f)
    if base.startswith("fc_") and not base.endswith(".uid"):
        nstem = base.split(".")[0]
        ostem = O + nstem[2:]
        if not any(k.search(os.path.join(os.path.dirname(f), ostem + ".x")) for k in KEEP_PATH):
            stems.setdefault(ostem, nstem)
for old, new in SHIMS.items():
    stems[old.rsplit("/", 1)[1].split(".")[0]] = new[0].rsplit("/", 1)[1].split(".")[0]

for src, dst in moves:
    if os.path.exists(dst):
        continue
    changed.append(f"mv {src} -> {dst}")
    if not CHECK:
        git("mv", src, dst)

for old, (new, root) in SHIMS.items():
    if os.path.exists(new) or not os.path.exists(old):
        continue
    changed.append(f"shim {old} -> {new}")
    if CHECK:
        continue
    git("mv", old, new)
    if os.path.exists(old + ".uid"):
        git("mv", old + ".uid", new + ".uid")
    with open(old, "w") as fh:
        if old.endswith(".gd"):
            fh.write(f'## Old entry path, kept for dot-server-deploy\'s game.yml `module:` until it\n'
                     f'## names res://{new}. Remove after that change is deployed.\n'
                     f'extends "{os.path.basename(new)}"\n')
        else:
            fh.write(f'[gd_scene load_steps=2 format=3]\n\n'
                     f'[ext_resource type="PackedScene" path="res://{new}" id="1"]\n\n'
                     f'[node name="{root}" instance=ExtResource("1")]\n')
    git("add", old)

# 2. Contents.
EXT = r"(?=\.(?:gd|tscn|tres|gdshader|gdshaderinc|uid|res|scn)\b)"
stem_re = re.compile(r"(?<![A-Za-z0-9_\-])(" + "|".join(sorted(map(re.escape, stems), key=len, reverse=True)) + ")" + EXT)
glob_re = re.compile(rf"(?<=/){O}_(?=[a-z_]*\*)")
suite_re = re.compile(rf"\b(headless_){O}16\b")
cls_re = re.compile(rf"(?<![A-Za-z0-9_])(Headless)?{OC}([A-Z0-9][A-Za-z0-9]*)")

# Internal lowercase names: meta keys, groups, helpers, test scratch dirs, screenshot names.
WORDS = [f"{O}_tunables", f"{O}_tun", f"{O}_names", f"not_{O}_key", f"not_{O}",
         f"DELIVERED_NOT_{OU}", f"{OU}_CLIENT_EXTRAS", f"{O}_base_speed", f"{O}_watched",
         f"{O}_bot_heard", f"{O}_attach_wrap", f"{O}_replay_camera", f"{O}_break_fx",
         f"{O}_drops_pooled", f"{O}_bot_world", f"{O}_other", f"{O}_profile_a", f"{O}_groups",
         f"{O}_delivered", f"{O}_delivered_stage", f"{O}_delivered_check_", f"{O}_pack_maps_check_",
         f"{O}_map_groups_check_", f"{O}_world_mount", f"{O}_specflow", f"{O}_schema_check",
         f"{O}_net_probe", f"{O}_net_self_mute", f"{O}_lossy", f"{O}_feel", f"{O}_dedicated",
         f"{O}_botcap", f"{O}_admin", f"{O}_cfgtest_", f"cfgtest_{O}_export_", f"{O}_map_picker",
         f"{O}_view_third", f"{O}_view_first", f"{O}_view_forced_first",
         f"{O}_ads_scoped", f"{O}_ads_raising", f"{O}_ads_hip", f"{O}_ads_aimed",
         f"{O}_loadout_persist", f"{O}_loadout_primary", f"{O}_loadout_over_budget",
         f"{O}_loadout_locked", f"{O}_loadout_grenades", f"{O}_loadout_every_spawn_on",
         f"{O}_loadout_every_spawn_off", f"{O}_loadout_equipped", f"{O}_stats_report_dir"]
words_re = re.compile(r"(?<![A-Za-z0-9_])(" + "|".join(sorted(map(re.escape, WORDS), key=len, reverse=True)) + r")(?![A-Za-z0-9_])")

def word_new(m):
    w = m.group(1)
    return w.replace(OU, "FC").replace(O, "fc")

REPO_URL = re.compile(rf"github\.com/gamemann/game-{O}(?:\.git)?")
PACKS = re.compile(rf"(?<![A-Za-z0-9_\-/`]){O}-(surf-dm-maps|dm-maps|weapons)(?![A-Za-z0-9_\-])")
LOG = re.compile(rf'((?:print|printerr|push_warning|push_error)\("|_line\(")game-{O}(?=[: —])')

# Prose (docs and comment lines), outside backticks and quotes.
def prose(seg):
    seg = re.sub(rf"(?<![A-Za-z0-9_\-/.:`'\"])game-{O}(?![A-Za-z0-9_\-/.]| folder)", "game-fatal-contact", seg)
    seg = re.sub(rf"(?<![A-Za-z0-9_\-/.:`'\"<>])([Tt]he |[Aa]n )?({O}|{OC})('s)?(?![A-Za-z0-9_\-/.:`'\"<>])",
                 lambda m: "Fatal Contact" + (m.group(3) or ""), seg)
    return seg

GENERIC = re.compile(rf"(memory|bump|frame|scratch) {O}|{O} (map|maps|allocator|kind)|KIND_{OU}|{OC} map|{O}s\b", re.I)
# Log, check and error text in GDScript strings: only "the/an <old name>", never a bare id.
TEXT = re.compile(rf"\b([Tt]he|[Aa]n) {O}('s)?(?![A-Za-z0-9_\-.:/])")
PLACE = re.compile(rf"\b(in|populates) the {O}\b")

def text_line(line):
    if GENERIC.search(line) or PLACE.search(line):
        return line
    parts = re.split(r'("(?:[^"\\]|\\.)*")', line)
    return "".join(TEXT.sub(lambda m: "Fatal Contact" + (m.group(2) or ""), p) if i % 2 else p
                   for i, p in enumerate(parts))

def prose_line(line):
    if GENERIC.search(line):
        return line
    parts = re.split(r"(`[^`]*`|\"[^\"]*\")", line)
    return "".join(p if i % 2 else prose(p) for i, p in enumerate(parts))

def code_line(line, path):
    def cls(m):
        tok = OC + m.group(2)
        if not m.group(1) and tok in NODE_NAMES:
            before = line[:m.start()]
            if before.endswith(('"', "/", "'")) or "node names" in line:
                return m.group(0)
        return ("HeadlessFc" if m.group(1) else "Fc") + m.group(2)
    line = cls_re.sub(cls, line)
    line = stem_re.sub(lambda m: stems[m.group(1)], line)
    line = glob_re.sub("fc_", line)
    line = suite_re.sub(r"\1fc16", line)
    line = words_re.sub(word_new, line)
    line = REPO_URL.sub("github.com/zees-games/game-fatal-contact", line)
    line = PACKS.sub(lambda m: "fc-" + m.group(1), line)
    line = LOG.sub(lambda m: m.group(1) + "FC", line)
    return line

COMMENT = {".gd": "#", ".sh": "#", ".conf": "#", ".yml": "#", ".yaml": "#", ".py": "#", ".cfg": ";", ".gdshader": "//", ".toml": "#"}

def rewrite(path, text):
    ext = os.path.splitext(path)[1]
    out = []
    for line in text.split("\n"):
        line = code_line(line, path)
        if ext == ".gd":
            line = text_line(line)
        if any(k.search(path) for k in KEEP_CONTENT):
            pass  # generated from code: class names follow it, the game id header stays
        elif ext == ".md":
            line = prose_line(line)
        elif ext in COMMENT:
            c = COMMENT[ext]
            i = line.find(c)
            # Only whole-line comments and "  # ..." tails: a '#' inside a string is left alone.
            if i >= 0 and (line[:i].strip() == "" or line[:i].endswith(" ") and line[:i].count('"') % 2 == 0):
                line = line[:i] + prose_line(line[i:])
        out.append(line)
    return "\n".join(out)

for f in git("ls-files", "-z").split("\0"):
    if not f or f in SELF or f in SHIMS or not os.path.isfile(f):
        continue
    if f.endswith((".uid", ".import")) or f.startswith(("assets/", "addons/")):
        continue
    try:
        with open(f, encoding="utf-8") as fh:
            text = fh.read()
    except (UnicodeDecodeError, OSError):
        continue
    if O not in text.lower():
        continue
    new = rewrite(f, text)
    if f == "licence.json":
        new = new.replace(f'"game-{O} contributors"', '"Fatal Contact contributors"')
    if f == "export_presets.example.cfg":
        new = re.sub(rf"build/(\w+)/game-{O}\.", r"build/\1/game-fatal-contact.", new)
    if new != text:
        changed.append(f"edit {f}")
        if not CHECK:
            with open(f, "w", encoding="utf-8") as fh:
                fh.write(new)

print("\n".join(changed) if changed else "fc_rename_apply: nothing to change")
print(f"fc_rename_apply: {len(changed)} change(s){' (check only)' if CHECK else ''}", file=sys.stderr)
sys.exit(1 if CHECK and changed else 0)
PY
