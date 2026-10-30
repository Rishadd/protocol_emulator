"""Project LibreLane plugin (package name must start with librelane_plugin_).

LibreLane imports every module or package on the Python path whose name starts with `librelane_plugin_`. Tiny Tapeout's flow
(tt_tool.py --harden, also in the GitHub gds workflow) runs `python -m librelane` from the repository root, so this package at the
root is found there without any copying; librelane/run_tt_wsl.sh does the same in WSL.

  bridge_stripes  step Project.BridgeMacroStripes: Metal4 power stripes across the SRAM macros (odb_bridge_macro_stripes.py)
  module_regions  steps Project.ModuleRegions / Project.RemoveModuleRegions: engine placement fences (odb_module_regions.py)
  netgen_json     tolerate netgen's invalid JSON escapes for the SRAM pin names (VDD! / VSS!)
The steps are wired in through src/config.json ("meta": {"substituting_steps": ...}).
"""
from . import bridge_stripes, module_regions, netgen_json  # noqa: F401  (importing registers the steps)
