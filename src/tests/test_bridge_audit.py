#!/usr/bin/env python3
"""Audit tests for GE -> vehicle command names and pet audio wiring."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MODULES = REPO_ROOT / "src" / "lua" / "ge" / "extensions" / "soulPilot" / "modules"
VEHICLE_AUTO = REPO_ROOT / "src" / "lua" / "vehicle" / "extensions" / "auto"


class GeVehicleBridgeAuditTests(unittest.TestCase):
    def test_ge_modules_do_not_send_legacy_command_tables(self) -> None:
        legacy = re.compile(r"autopilotLive[A-Za-z]*Cmd")
        offenders = []
        for path in sorted(MODULES.glob("*.lua")):
            text = path.read_text(encoding="utf-8")
            if legacy.search(text):
                offenders.append(path.name)
        self.assertEqual(offenders, [])

    def test_ge_modules_use_soulpilot_command_tables(self) -> None:
        text = (MODULES / "commands.lua").read_text(encoding="utf-8")
        self.assertIn("soulPilotWheelCmd.on", text)
        self.assertIn("soulPilotPedalsCmd.on", text)
        self.assertIn("soulPilotWheelCmd.off", text)
        self.assertIn("soulPilotPedalsCmd.off", text)

        popup = (MODULES / "popup.lua").read_text(encoding="utf-8")
        self.assertIn("soulPilotPopupCmd.start", popup)

        pet = (MODULES / "pet.lua").read_text(encoding="utf-8")
        self.assertIn("Engine.Audio.playOnce", pet)

    def test_vehicle_modules_expose_soulpilot_tables_and_legacy_aliases(self) -> None:
        pairs = {
            "soulPilotWheel.lua": ("soulPilotWheelCmd", "autopilotLiveWheelCmd"),
            "soulPilotPedals.lua": ("soulPilotPedalsCmd", "autopilotLivePedalsCmd"),
            "soulPilotPopup.lua": ("soulPilotPopupCmd", "autopilotLivePopupCmd"),
            "soulPilotPet.lua": ("soulPilotPetCmd", "autopilotLivePetCmd"),
        }
        for filename, (new_name, old_name) in pairs.items():
            text = (VEHICLE_AUTO / filename).read_text(encoding="utf-8")
            self.assertIn(new_name + " = {}", text, filename)
            self.assertIn(
                old_name + " = " + new_name,
                text,
                filename,
            )


if __name__ == "__main__":
    unittest.main()
