#!/bin/bash
# After a flow (05_run_flow.sh / librelane/flow_variant_linux.sh): the Tiny Tapeout precheck, the module map pictures, the stage-by-stage images and the
# comparison table. All of these only read the finished run in ~/pe_<tag>.
#   bash reproduce/06_precheck_and_reports.sh <tag>
# precheck: KLayout DRC, zero-area, boundary, pins, layers against the 8x4 template named in the work folder's info.yaml (expected: PASS, about 5 minutes)
# pictures: results/shared_<date>/<tag>_images/ (index.html = gallery of every stage), module maps (librelane/module_map.py)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?tag}
bash "$R/librelane/precheck_linux.sh" "$TAG"
RES=${RES:-$R/results/repro_$(date +%F)} bash "$R/librelane/live_images_linux.sh" "$TAG=reproduced run $TAG"
