"""LibreLane plugin: step Project.BridgeMacroStripes (see odb_bridge_macro_stripes.py).

Wired in through src/config.json: "meta": {"substituting_steps": {"+OpenROAD.GeneratePDN": "Project.BridgeMacroStripes"}}
(the leading + inserts the step after GeneratePDN). Found by LibreLane because run_tt_wsl.sh starts it with `python -m librelane`
from the directory that holds this file.
"""
import os
from typing import List

from librelane.steps import Step
from librelane.steps.odb import OdbpyStep


@Step.factory.register()
class BridgeMacroStripes(OdbpyStep):
    id = "Project.BridgeMacroStripes"
    name = "Bridge Metal4 power stripes across SRAM macros"

    def get_script_path(self):
        return os.path.join(os.path.dirname(os.path.abspath(__file__)), "odb_bridge_macro_stripes.py")

    def get_command(self) -> List[str]:
        return super().get_command()
