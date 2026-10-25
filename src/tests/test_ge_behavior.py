#!/usr/bin/env python3
"""Golden behavior tests for the soulPilot GE layer.

The command tests load the real GE extension in a small Lua sandbox, so they
verify the actual apl_wheel()/apl_pedals() command strings instead of a Python
stub. Config assertions pin the master policy that existed before the refactor.

Run from the repository root:

    python -m unittest discover -s src/tests -v
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from typing import Any

try:
    import lupa
except ImportError:  # pragma: no cover - the project venv provides lupa
    lupa = None

REPO_ROOT = Path(__file__).resolve().parents[2]
GE_MAIN = REPO_ROOT / "src" / "lua" / "ge" / "extensions" / "soulPilot" / "main.lua"
CONFIG_DIR = REPO_ROOT / "src" / "config"


def load_json(name: str) -> dict[str, Any]:
    with (CONFIG_DIR / name).open(encoding="utf-8") as handle:
        return json.load(handle)


MASTER_CONFIG = load_json("master.json")

# ============================================================================
# GOLDEN VALUES — master policy and command routing at the start of Step 5.
# ============================================================================
GOLDEN_MASTER_FLAGS = {
    "enable_wheel": 1,
    "enable_pedals": 1,
    "enable_lights": 1,
    "enable_popup": 1,
    "enable_pain": 1,
    "enable_music": 0,
}
GOLDEN_WHEEL_CONFIG_SUFFIX = "mods/unpacked/soulPilot/src/config/wheel.json"
GOLDEN_PEDALS_CONFIG_SUFFIX = "mods/unpacked/soulPilot/src/config/pedals.json"


class MasterConfigGoldenTests(unittest.TestCase):
    def test_master_flags_are_locked(self) -> None:
        for key, value in GOLDEN_MASTER_FLAGS.items():
            self.assertEqual(MASTER_CONFIG[key], value, key)

    def test_master_has_no_parking_module(self) -> None:
        self.assertNotIn("enable_parking", MASTER_CONFIG)

    def test_master_ai_mode_is_traffic(self) -> None:
        self.assertEqual(MASTER_CONFIG["ai_mode"], "traffic")


@unittest.skipUnless(lupa is not None, "lupa is required for Lua command tests")
class GeCommandGoldenTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = lupa.LuaRuntime()
        self.lua.execute(
            """
            extensions = { load = function() end }
            _G.soulPilot_main = nil
            FS = {
              fileExists = function(self, path) return true end,
              directoryExists = function(self, path) return true end,
              directoryCreate = function(self, path, recursive) return true end,
              getUserPath = function(self) return "" end,
              getFileRealPath = function(self, path) return "" end,
            }
            commands = {}
            vehicle = {
              queueLuaCommand = function(self, command) table.insert(commands, command) end,
              getID = function(self) return 1001 end,
            }
            getPlayerVehicle = function(slot) return vehicle end
            getObjectByID = function(id) return vehicle end
            log = function() end
            """
        )
        self.master_source = GE_MAIN.read_text(encoding="utf-8")
        self.lua.execute("package.path = [[%s]] .. ';' .. package.path" % (
            str(REPO_ROOT / "src" / "lua" / "ge" / "?.lua").replace("\\", "/")
        ))
        self.lua.execute(self.master_source)

    def commands(self) -> list[str]:
        return [str(value) for value in self.lua.globals().commands.values()]

    def test_wheel_on_sends_vehicle_command(self) -> None:
        self.lua.globals().apl_wheel("on")
        commands = self.commands()
        self.assertTrue(
            any(
                GOLDEN_WHEEL_CONFIG_SUFFIX in command
                and "soulPilotWheelCmd.on" in command
                for command in commands
            ),
            commands,
        )

    def test_wheel_off_sends_vehicle_command(self) -> None:
        self.lua.globals().apl_wheel("off")
        commands = self.commands()
        self.assertTrue(
            any("soulPilotWheelCmd.off" in command for command in commands),
            commands,
        )

    def test_pedals_on_sends_vehicle_command(self) -> None:
        self.lua.globals().apl_pedals("on")
        commands = self.commands()
        self.assertTrue(
            any(
                GOLDEN_PEDALS_CONFIG_SUFFIX in command
                and "soulPilotPedalsCmd.on" in command
                for command in commands
            ),
            commands,
        )

    def test_public_commands_are_registered(self) -> None:
        for name in (
            "apl_autopilot",
            "apl_wheel",
            "apl_pedals",
            "apl_lights",
            "apl_pet",
            "apl_popup",
            "apl_pain",
            "apl_warmup",
            "apl_status",
            "apl_debug",
            "apl_lock",
        ):
            self.assertEqual(
                self.lua.globals()[name] is not None,
                True,
                name,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
