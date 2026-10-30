"""LibreLane plugin: tolerate the invalid JSON escapes netgen writes for the IHP SRAM pin names.

netgen's LVS JSON contains pin names such as `VDD!` / `VDDARRAY!` / `VSS!` preceded by a lone backslash, which is not a valid
JSON escape, so `json.loads` in librelane.steps.netgen raises "Invalid \\escape" and the flow dies before the LVS checker runs.
This plugin parses normally first and, only if that fails, doubles every backslash that is not part of a valid escape.
Discovered automatically by LibreLane when this file is on the Python path (run_tt_wsl.sh starts it with `python -m librelane`
from the directory that holds this file). The same bug and workaround appear in WilliamZhang20/protocol-emulator.
"""
import json as _json
import re
import types

import librelane.steps.netgen as _netgen

# a valid escape pair is kept as is; any other backslash is doubled
_ESC = re.compile(r'(\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})|\\')


def _repair(text: str) -> str:
    return _ESC.sub(lambda m: m.group(1) if m.group(1) else "\\\\", text)


def _loads(s, *args, **kwargs):
    try:
        return _json.loads(s, *args, **kwargs)
    except _json.JSONDecodeError:
        return _json.loads(_repair(s), *args, **kwargs)


# only the netgen step sees the tolerant loader; the global json module is untouched
_netgen.json = types.SimpleNamespace(**{k: getattr(_json, k) for k in dir(_json) if not k.startswith("__")}, )
_netgen.json.loads = _loads
