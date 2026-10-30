"""LibreLane plugin: step Project.ModuleRegions (see odb_module_regions.py).

Wired in through src/config.json (only for the boxed runs, see run_tt_wsl.sh EXTRA_CFG):
  "meta": {"substituting_steps": {"+OpenROAD.GeneratePDN": "Project.BridgeMacroStripes", "-OpenROAD.GlobalPlacementSkipIO": "Project.ModuleRegions"}}
  "MODULE_BOXES": "dir::floorplan_boxes.json"
The step is skipped when MODULE_BOXES is not set, so the flat reference run goes through the same flow definition.
"""
import os
from typing import List, Optional, Tuple

from librelane.common import Path
from librelane.config import Variable
from librelane.state import State
from librelane.steps import Step
from librelane.steps.odb import OdbpyStep
from librelane.logging import info


@Step.factory.register()
class ModuleRegions(OdbpyStep):
    id = "Project.ModuleRegions"
    name = "Create placement regions (fences) for the major modules"

    config_vars = OdbpyStep.config_vars + [
        Variable("MODULE_BOXES", Optional[Path], "JSON file with one rectangle and a list of instance-name prefixes per module box."),
        Variable("MODULE_BOXES_MAX_UTIL", float, "Refuse a box that needs a higher cell utilisation than this.", default=0.85),
    ]

    def get_script_path(self):
        return os.path.join(os.path.dirname(os.path.abspath(__file__)), "odb_module_regions.py")

    def get_command(self) -> List[str]:
        return super().get_command() + ["--boxes", str(self.config["MODULE_BOXES"]), "--max-util", str(self.config["MODULE_BOXES_MAX_UTIL"])]

    def run(self, state_in: State, **kwargs):
        if self.config["MODULE_BOXES"] is None:
            info(f"'MODULE_BOXES' not set. Skipping '{self.id}'…")
            return {}, {}
        return super().run(state_in, **kwargs)


@Step.factory.register()
class RemoveModuleRegions(OdbpyStep):
    id = "Project.RemoveModuleRegions"
    name = "Remove the module placement regions (fences) after global placement"

    config_vars = OdbpyStep.config_vars + [
        Variable("MODULE_BOXES", Optional[Path], "JSON file with one rectangle and a list of instance-name prefixes per module box."),
    ]

    def get_script_path(self):
        return os.path.join(os.path.dirname(os.path.abspath(__file__)), "odb_remove_module_regions.py")

    def run(self, state_in: State, **kwargs):
        if self.config["MODULE_BOXES"] is None:
            info(f"'MODULE_BOXES' not set. Skipping '{self.id}'…")
            return {}, {}
        return super().run(state_in, **kwargs)
