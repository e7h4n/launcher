import ctypes
import errno
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import standby


class StandbyTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        paths = patch.multiple(
            standby, BRIGHTNESS=root / "brightness", CPUFREQ=root / "cpu", SPI=root / "spi0.0",
            DEBUGFS=root / "debug", DRI=root / "dri", STATE=root / "run",
        )
        paths.start()
        self.addCleanup(paths.stop)
        self.factor = standby.CPUFREQ / "ondemand/sampling_down_factor"
        self.governor = standby.CPUFREQ / "policy0/scaling_governor"
        self.command = standby.DEBUGFS / "command"
        self.scanout = standby.DEBUGFS / "state"
        for path in (self.factor.parent, self.governor.parent, standby.SPI / "drm/card7",
                     standby.DEBUGFS, standby.DRI, standby.STATE, root / "panel-mipi-dbi-spi"):
            path.mkdir(parents=True)
        (standby.SPI / "driver").symlink_to(root / "panel-mipi-dbi-spi")
        os.mkfifo(standby.DRI / "card7")  # Like the device fd, this need not be seekable.
        self.command.touch()
        self.factor.write_text("50")
        self.governor.write_text("ondemand")
        self.scanout.write_text("plane[18]: plane-0\n\tfb=31\n")
        standby.BRIGHTNESS.write_text("0")
        self.dirty = Mock(return_value=0)
        library = Mock(drmModeDirtyFB=self.dirty)
        drm = patch.object(standby.ctypes, "CDLL", return_value=library)
        drm.start()
        self.addCleanup(drm.stop)
        self.delays = []
        sleep = patch.object(standby.time, "sleep",
                             side_effect=lambda t: self.delays.append((self.command.read_text(), t)))
        sleep.start()
        self.addCleanup(sleep.stop)

    def test_wake_redraws_the_current_frame_after_sleep_out_and_restores_factor(self):
        standby.BRIGHTNESS.write_text("100")
        standby.enter()
        self.dirty.assert_not_called()
        self.assertEqual(self.factor.read_text(), "50")

        standby.BRIGHTNESS.write_text("0")
        standby.enter()
        self.assertEqual(self.command.read_text(), "10\n")
        self.assertEqual(self.factor.read_text().strip(), "5")
        self.scanout.write_text("plane[18]: plane-0\n\tfb=47\n")
        standby.BRIGHTNESS.write_text("80")
        standby.restore()
        self.assertIn(("11\n", 0.120), self.delays)
        self.assertEqual(self.command.read_text(), "29\n")
        self.assertEqual([call.args[1:] for call in self.dirty.call_args_list], [(31, None, 0), (47, None, 0)])
        self.assertEqual(self.factor.read_text().strip(), "50")
        self.assertEqual(list(standby.STATE.iterdir()), [])
        standby.restore()
        self.assertEqual(self.dirty.call_count, 2)

    def test_wake_during_preflight_cancels_panel_sleep(self):
        def wake(*args):
            standby.BRIGHTNESS.write_text("80")
            return 0
        self.dirty.side_effect = wake
        standby.enter()
        self.assertEqual(self.command.read_text(), "")
        standby.restore()
        self.assertEqual(self.factor.read_text().strip(), "50")

    def test_modeset_during_refresh_uses_the_replacement_framebuffer(self):
        def modeset(fd, fb, clips, count):
            if fb == 31:
                self.scanout.write_text("plane[18]: plane-0\n\tfb=52\n")
                ctypes.set_errno(errno.ENOENT)
                return -1
            return 0
        self.dirty.side_effect = modeset
        standby.enter()
        self.assertEqual([call.args[1] for call in self.dirty.call_args_list], [31, 52])
        self.assertEqual(self.command.read_text(), "10\n")

    def test_unrefreshable_panel_and_changed_governor_settings(self):
        ctypes.set_errno(errno.EACCES)
        self.dirty.return_value = -1
        standby.enter()
        self.assertEqual(self.command.read_text(), "")
        self.assertEqual(self.factor.read_text().strip(), "5")
        self.factor.write_text("12")  # Another owner changed the tunable during standby.
        standby.restore()
        self.assertEqual(self.factor.read_text(), "12")
        self.scanout.write_text("plane[18]: plane-0\n\tfb=(null)\n")
        standby.enter()
        self.assertEqual(list(standby.STATE.iterdir()), [])

    def test_interrupted_sleep_still_wakes_and_keeps_a_failed_redraw_retryable(self):
        (standby.STATE / "panel").touch()
        (standby.STATE / "factor").touch()
        self.factor.write_text("5")
        ctypes.set_errno(errno.EIO)
        self.dirty.return_value = -1
        with self.assertRaises(OSError):
            standby.restore()
        self.assertEqual(self.delays[:2], [("", 0.120), ("11\n", 0.120)])
        self.assertEqual(self.factor.read_text().strip(), "50")
        self.assertTrue((standby.STATE / "panel").exists())
        self.dirty.return_value = 0
        standby.enter()  # A new dark interval recovers the outstanding stop first.
        self.assertEqual(self.command.read_text(), "10\n")
        standby.restore()
        self.assertEqual(list(standby.STATE.iterdir()), [])

    def test_no_commands_to_another_driver_and_no_change_to_another_governor(self):
        self.governor.write_text("performance")
        (standby.SPI / "driver").unlink()
        standby.enter()
        self.assertEqual(list(standby.STATE.iterdir()), [])
        self.dirty.assert_not_called()
        (standby.STATE / "panel").touch()  # The original driver was unbound while asleep.
        standby.restore()
        self.assertEqual(self.command.read_text(), "")
        self.assertEqual(self.factor.read_text(), "50")


if __name__ == "__main__":
    unittest.main()
