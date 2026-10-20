#!/bin/bash
# Rebuild the user guide pictures and the HTML from the markdown (nothing else in docs/ is generated).
#   bash reproduce/07_docs.sh        needs ~/pictvenv (matplotlib) for the capture example; the shared worktree for la_model.py (02_sources.sh)
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
export LA_MODEL_DIR=${LA_MODEL_DIR:-${SHARED:-$HOME/pe_shared_v2}/host}
(cd "$R/docs/images" && "$HOME/pictvenv/bin/python" make_images.py)
python3 "$R/docs/build_user_guide.py"
