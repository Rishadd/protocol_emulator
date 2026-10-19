#!/bin/bash
# Flow run with a floorplan variant: per-run overrides from librelane/<variant>_cfg.json + the matching engine fences in src/.
# Usage: bash librelane/flow_variant_wsl.sh <tag> <variant: compact | symmetric> [extra JSON merged on top, e.g. '{"CLOCK_PERIOD": 20}']
TAG=$1; V=$2; MORE=${3:-'{}'}
P=/mnt/c/Data/protocol_emulator
[ -n "$(python3 -c "import json; print(json.load(open('$P/librelane/floorplan_${V}_cfg.json')).get('TILES',''))")" ] && export TILES=$(python3 -c "import json; print(json.load(open('$P/librelane/floorplan_${V}_cfg.json'))['TILES'])")
CFG_EXTRA=$(python3 -c "import json,sys; a=json.load(open('$P/librelane/floorplan_${V}_cfg.json')); a.pop('TILES', None); a.update(json.loads(sys.argv[1])); print(json.dumps(a))" "$MORE")
export CFG_EXTRA
bash $P/librelane/flow_run_wsl.sh $TAG boxed floorplan_engines_${V}.json
tail -n 3 ~/flow_$TAG.log
