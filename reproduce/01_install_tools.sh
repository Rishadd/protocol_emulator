#!/bin/bash
# Install every tool the results were made with, on Ubuntu 22.04 (x86-64, 16 cores / 16 GB RAM / 100 GB free disk is comfortable).
# This is exactly the environment of the runs in results/ from 2026-10-20 on; versions are listed in reproduce/versions.txt and checked at the end.
# Run it step by step (each step says what it needs); it is safe to run again, finished steps are skipped.
#   bash reproduce/01_install_tools.sh            everything
#   bash reproduce/01_install_tools.sh nix        only the Nix step (also: profile librelane pdk tt venvs check)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
STEPS=${*:-nix profile librelane pdk tt venvs check}
has() { [[ " $STEPS " == *" $1 "* ]]; }

if has nix; then
  echo "== Nix (Determinate installer, multi-user). The apt package nix-bin must NOT be installed: it blocks this installer."
  if dpkg -l nix-bin 2>/dev/null | grep -q '^ii'; then echo "remove it first: sudo apt remove nix-bin"; exit 1; fi
  sudo apt-get update && sudo apt-get install -y git rsync curl build-essential python3-venv xz-utils
  if ! command -v nix >/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm
  fi
  # the per-user profile directory must exist before the first `nix profile` call
  sudo mkdir -p /nix/var/nix/profiles/per-user/$USER && sudo chown $USER /nix/var/nix/profiles/per-user/$USER
  echo "open a NEW shell now (so nix is on PATH), then run the next steps"
fi

if has profile; then
  echo "== simulator, formal tools, waveform viewer, KLayout, Python 3.12 into the Nix profile"
  # versions of the results: iverilog 13.0, sby 0.69, yices 2.7.0, boolector 3.2.4, klayout 0.30.12, gtkwave 3.3.128, python 3.12.15
  nix profile add nixpkgs#iverilog nixpkgs#python312 nixpkgs#sby nixpkgs#yices nixpkgs#boolector nixpkgs#klayout nixpkgs#gtkwave
  # the formal runner finds yosys itself in /nix/store (sby pulls in yosys 0.69 as a dependency)
fi

if has librelane; then
  echo "== LibreLane 3.1.0.dev3 (the release Tiny Tapeout's GitHub 'gds' action installs), commit ca6adb1, with its own Nix shell (several GB)"
  [ -d ~/librelane-dev ] || git clone https://github.com/librelane/librelane.git ~/librelane-dev
  bash "$R/librelane/install_tt_librelane_wsl.sh" 3.1.0.dev3 ~/librelane-3.1.0.dev3
  # expected last lines: "librelane 3.1.0.dev3" and "Yosys 0.66 (git sha1 86f2ddebce7e98ce7cacc27e8a5c14cb53b51b51 ..."
fi

if has pdk; then
  echo "== IHP-Open-PDK revision 2bbec755dc67ca3db0261c3d6163e15735d66710 (2026-09-08) into ~/pdk_tt, the one Tiny Tapeout's gds action uses"
  bash "$R/librelane/install_tt_pdk_wsl.sh" 2bbec755dc67ca3db0261c3d6163e15735d66710 ~/pdk_tt
fi

if has tt; then
  echo "== tt-support-tools, branch ihp-sg13cmos5l, commit d66cf179e7bc4d296362ab7e2e3b344dc3c4f665 (2026-09-21)"
  [ -d ~/tt-support-tools ] || git clone -b ihp-sg13cmos5l https://github.com/TinyTapeout/tt-support-tools.git ~/tt-support-tools
  git -C ~/tt-support-tools checkout -q d66cf179e7bc4d296362ab7e2e3b344dc3c4f665
fi

if has venvs; then
  echo "== Python venvs. ttvenv: precheck + flow helpers (Nix Python 3.12.15); pictvenv: pictures (system Python 3.10.12)"
  [ -d ~/ttvenv ] || python3 -m venv ~/ttvenv
  ~/ttvenv/bin/pip install -r "$R/reproduce/requirements_ttvenv.txt"
  [ -d ~/pictvenv ] || /usr/bin/python3 -m venv ~/pictvenv
  ~/pictvenv/bin/pip install -r "$R/reproduce/requirements_pictvenv.txt"
fi

if has check; then
  echo "== versions found (compare with reproduce/versions.txt)"
  for c in "iverilog -V" "sby --help"; do :; done
  iverilog -V 2>&1 | head -1
  python3 --version
  ls -d /nix/store/*-sby-* /nix/store/*-yices-2* /nix/store/*-boolector-* /nix/store/*-klayout-0* /nix/store/*-gtkwave-* 2>/dev/null | grep -v '\.drv' | sed 's#/nix/store/[a-z0-9]*-##'
  git -C ~/librelane-3.1.0.dev3 log -1 --format='librelane %h %ad' --date=short
  git -C ~/pdk_tt log -1 --format='pdk %H %ad' --date=short
  git -C ~/tt-support-tools log -1 --format='tt-support-tools %H %ad' --date=short
fi
