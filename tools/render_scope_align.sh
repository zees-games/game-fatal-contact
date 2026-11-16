#!/usr/bin/env bash
# The aimed view of every scoped weapon at several window sizes, to check the optic's ring, lens picture and reticle
# sit on the screen's middle: screenshots/scope_align/<role>_<W>x<H>.png and <W>x<H>.csv (see tools/render_scope_align.gd).
#   SCOPE_SIZES="1036x648 1920x1080" SCOPE_ROLES=marksman tools/render_scope_align.sh
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshots/scope_align
for size in ${SCOPE_SIZES:-1036x648 1280x720 1920x1080 2366x1022 1024x768 1440x900}; do
  xvfb-run -a -s "-screen 0 ${size}x24" timeout 600 godot --path . --resolution "$size" --script tools/render_scope_align.gd 2>&1 | grep -E 'ERROR|SCRIPT|no def|scope_align|^[a-z_]+,' | head -20 || true
done
