#!/bin/bash
# Tiny Tapeout CMOS5L flow for tt_um_protocol_emulator, run inside WSL in LibreLane's Nix shell.
# Same steps as `tt_tool.py --create-user-config` + `--harden --no-docker` (tt-support-tools, branch ihp-sg13cmos5l),
# but without tt_tool's Python dependencies: the user config is written here exactly as tt_tool does it.
# Needs (once): ~/librelane-dev, ~/IHP-Open-PDK (dev), ~/tt-support-tools (branch ihp-sg13cmos5l).
# Usage: RUN_TAG=tt1 bash librelane/run_tt_wsl.sh      (results: $WORK/runs/$RUN_TAG)
set -e
SRC=${SRC:-/mnt/c/Data/protocol_emulator}
WORK=${WORK:-$HOME/pe_tt}
TAG=${RUN_TAG:-tt1}
mkdir -p "$WORK/src" "$WORK/tt"
rsync -a --delete "$SRC/src/" "$WORK/src/" --exclude fpga --exclude user_config.json --exclude config_merged.json
rsync -a --delete "$SRC/macro/" "$WORK/macro/"
rsync -a --delete "$SRC/info.yaml" "$WORK/info.yaml"
rsync -a --delete --exclude .git "$HOME/tt-support-tools/" "$WORK/tt/"
# optional per-run overrides: EXTRA_CFG='{"PL_TARGET_DENSITY_PCT": 70}'  DROP_CFG="PDN_CFG"
python3 - "$WORK" <<'EOF'
import json, os, re, sys, yaml
w = sys.argv[1]
info = yaml.safe_load(open(f"{w}/info.yaml"))["project"]
tiles = info["tiles"]
sizes = yaml.safe_load(open(f"{w}/tt/tech/ihp-sg13cmos5l/tile_sizes.yaml"))
die = [float(x) for x in sizes[tiles].split()]
user = {
    "DESIGN_NAME": info["top_module"],
    "VERILOG_FILES": [f"dir::{s}" for s in info["source_files"]],
    "DIE_AREA": die,
    "FP_DEF_TEMPLATE": f"dir::../tt/tech/ihp-sg13cmos5l/def/tt_block_{tiles}_pgvdd.def",
    "VDD_PIN": "VPWR",
    "GND_PIN": "VGND",
    "RT_MAX_LAYER": "Metal4",
}
json.dump(user, open(f"{w}/src/user_config.json", "w"), indent=2)
cfg = json.load(open(f"{w}/src/config.json"))
cfg.update(user)
cfg.update(json.loads(os.environ.get("EXTRA_CFG", "{}")))
for k in os.environ.get("DROP_CFG", "").split():
    cfg.pop(k, None)
json.dump(cfg, open(f"{w}/src/config_merged.json", "w"), indent=2)
print("tiles", tiles, "die", die)
EOF
rm -rf "$WORK/librelane_plugin_project"
cp -r "$SRC"/librelane_plugin_project "$WORK/"   # project plugin package (stripe bridge, engine fences, netgen JSON fix): found because we start with python -m from $WORK, like tt_tool.py does from the repo root
mkdir -p "$WORK/runs/$TAG"
cd "${LLDIR:-$HOME/librelane-dev}"
# RESUME=1: continue the last run in $WORK/runs (e.g. RESUME=1 bash run_tt_wsl.sh --from Netgen.LVS) instead of starting $TAG
if [ -n "$RESUME" ]; then RUNARGS="--last-run"; else RUNARGS="--run-tag $TAG --force-run-dir runs/$TAG"; fi
nix-shell --pure --run "cd $WORK && python3 -m librelane --pdk ihp-sg13cmos5l --manual-pdk --pdk-root $HOME/IHP-Open-PDK $RUNARGS src/config_merged.json $*"
