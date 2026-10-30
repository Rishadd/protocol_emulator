#!/bin/bash
# Live images while flow runs are going: after every new step of each run, render the new stage (render_stages.py, incremental),
# draw the module maps once global / detailed placement exist (module_map.py), and rewrite the run's index.html (reloads itself every
# 60 s, shows the current step and the routing progress). Also writes <results>/index.html with one line per run.
# Usage (in WSL): bash librelane/live_images_wsl.sh "<tag>=<title>" ...      e.g. "tt9b=pipelined CRC, fixed floorplan"
# Stops when every listed run has finished and its last images are made.
P=${P:-$(cd "$(dirname "$0")/.." && pwd)}
RES=${RES:-$P/results/shared_2026-10-20}
PDK=${TT_PDK_ROOT:-$HOME/pdk_tt}/ihp-sg13cmos5l
declare -A TITLE SEEN DONE
TAGS=()
for a in "$@"; do t=${a%%=*}; TAGS+=("$t"); TITLE[$t]=${a#*=}; done

status_of() {   # one line: current step (+ routing progress) or the result
  local t=$1 rd=$HOME/pe_$1/runs/$1 log=$HOME/flow_$1.log step f p it v
  if grep -q "exit code" $log 2>/dev/null; then
    echo "Finished: $(grep 'exit code' $log | tail -1) at $(date -r $log +%H:%M)"; return
  fi
  step=$(ls -d $rd/[0-9]*-* 2>/dev/null | sed 's#.*/##' | sort -n | tail -1)
  [ -z "$step" ] && { echo "Waiting to start"; return; }
  echo -n "Running: step $step"
  case $step in *-detailedrouting)
    f=$rd/$step/openroad-detailedrouting.log
    p=$(grep -c 'Start detail routing' $f 2>/dev/null)
    it=$(grep -oE 'Start [0-9]+(st|nd|rd|th) (optimization|stubborn tiles) iteration' $f 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1)
    v=$(grep -oE 'Number of violations = [0-9]+' $f 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    echo -n ", pass ${p:-0}, round ${it:-0} of 64, ${v:-?} violations";;
  esac
  echo " (updated $(date +%H:%M); this page reloads every 60 s)"
}

overview() {
  { echo "<!doctype html><meta charset=utf-8><meta http-equiv=refresh content=60><title>Flow runs</title>"
    echo "<style>body{background:#111;color:#ddd;font:15px system-ui;padding:16px}a{color:#9cf}td{border:1px solid #333;padding:4px 10px}table{border-collapse:collapse}</style>"
    echo "<h1>Flow runs (live)</h1><table><tr><td>run</td><td>what it is</td><td>status</td></tr>"
    for t in "${TAGS[@]}"; do
      echo "<tr><td><a href='${t}_images/index.html'>$t</a></td><td>${TITLE[$t]}</td><td>$(status_of $t)</td></tr>"
    done
    echo "</table><p>Each run's page shows the images of every finished stage and the module maps.</p>"; } > $RES/index.html
}

while true; do
  all=1
  for t in "${TAGS[@]}"; do
    rd=$HOME/pe_$t/runs/$t; out=$RES/${t}_images
    finished=0; grep -q "exit code" $HOME/flow_$t.log 2>/dev/null && finished=1
    [ "${DONE[$t]}" = 1 ] && continue
    [ $finished = 0 ] && all=0
    [ -d $rd ] || continue
    mkdir -p $out
    n=$(ls -d $rd/[0-9]*-* 2>/dev/null | wc -l)
    if [ "$n" != "${SEEN[$t]}" ] || [ $finished = 1 ]; then
      SEEN[$t]=$n
      (cd ~/librelane-3.1.0.dev3 && nix-shell --pure --run "klayout -b -r $P/librelane/render_stages.py -rd run=$rd -rd out=$out -rd pdk=$PDK \
          -rd macro_lef=$HOME/pe_$t/macro/RM_IHPSG13_2P_512x32_c2_bm_bist/RM_IHPSG13_2P_512x32_c2_bm_bist.lef -rd width=2000") 2>&1 \
          | grep -E '^wrote' | sed "s/^/[$t] /"
      for s in globalplacement detailedplacement; do
        if ls -d $rd/*-openroad-$s >/dev/null 2>&1 && [ ! -f $out/${s}__annotated.png ]; then
          bash $P/librelane/module_map_shared_linux.sh $t $out $s "$t ${TITLE[$t]}: ${s/placement/ placement}" 2>&1 | grep -E '^wrote' | sed "s/^/[$t] /"
        fi
      done
    fi
    if [ $finished = 1 ]; then
      $HOME/pictvenv/bin/python $P/librelane/make_gallery.py $out "$t: ${TITLE[$t]}" $rd/final/metrics.json --status "$(status_of $t)" >/dev/null
      DONE[$t]=1
      echo "[$t] finished, final images and gallery written"
    else
      $HOME/pictvenv/bin/python $P/librelane/make_gallery.py $out "$t: ${TITLE[$t]}" --status "$(status_of $t)" --refresh 60 >/dev/null
    fi
  done
  overview
  [ $all = 1 ] && { echo "all runs finished"; exit 0; }
  sleep 60
done
