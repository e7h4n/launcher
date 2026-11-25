#!/usr/bin/python3 -I
"""Apply the two measured standby settings to the Cardputer Zero."""

import ctypes
import errno
import re
import sys
import time
from pathlib import Path


BRIGHTNESS = Path("/sys/class/backlight/backlight/actual_brightness")
CPUFREQ = Path("/sys/devices/system/cpu/cpufreq")
SPI = Path("/sys/bus/spi/devices/spi0.0")
DEBUGFS = Path("/sys/kernel/debug/dri/spi0.0")
DRI = Path("/dev/dri")
STATE = Path("/run/okou-cardputer-standby")
PANEL_DELAY = 0.120


def panel_bound():
    return (SPI / "driver").resolve().name == "panel-mipi-dbi-spi"


def redraw():
    """Retransmit the SPI panel's live scanout, including frames drawn during SLPOUT."""
    card = next((p for p in (SPI / "drm").glob("card*") if re.fullmatch(r"card\d+", p.name)), None)
    if card is None:
        raise OSError(errno.ENODEV, "no DRM card on spi0.0")
    drm = ctypes.CDLL("libdrm.so.2", use_errno=True)
    dirty = drm.drmModeDirtyFB
    dirty.argtypes = (ctypes.c_int, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32)
    with (DRI / card.name).open("rb+", buffering=0) as device:
        # A modeset can replace the framebuffer between the state read and DIRTYFB.
        for attempt in range(2):
            match = re.search(r"^\s*fb=([1-9]\d*)\b", (DEBUGFS / "state").read_text(), re.MULTILINE)
            if not match:
                return False  # The next modeset supplies its own initial frame.
            if dirty(device.fileno(), int(match[1]), None, 0) == 0:
                return True
            error = ctypes.get_errno()
            if attempt or error not in (errno.ENOENT, errno.EINVAL):
                raise OSError(error, "could not refresh the SPI framebuffer")


def enter():
    # A new unit activation can inherit records from a failed stop.
    restore()
    if BRIGHTNESS.read_text().strip() != "0":
        return
    factor = CPUFREQ / "ondemand/sampling_down_factor"
    governor = CPUFREQ / "policy0/scaling_governor"
    try:
        if governor.read_text().strip() == "ondemand" and factor.read_text().strip() == "50":
            (STATE / "factor").touch()
            factor.write_text("5\n")
    except FileNotFoundError:
        pass  # Other governors and kernels may have no ondemand tunable.
    except OSError as exc:
        print(f"Could not tune ondemand: {exc}", file=sys.stderr)

    asleep = STATE / "panel"
    command = DEBUGFS / "command"
    if not panel_bound() or not command.is_file():
        return
    try:
        # Only put the panel to sleep if this driver can redraw the active frame on wake.
        if not redraw() or BRIGHTNESS.read_text().strip() != "0":
            return
        with command.open("w") as device:
            # Record ownership first so ExecStopPost can recover an interrupted write.
            asleep.touch()
            device.write("10\n")  # MIPI DCS Enter Sleep Mode
        asleep.write_text(str(time.monotonic() + PANEL_DELAY))
    except OSError as exc:
        if asleep.exists():
            raise  # Entry may have reached the hardware. Let ExecStopPost undo it.
        print(f"Skipping LCD sleep: {exc}", file=sys.stderr)


def wake_panel(asleep):
    # Unbinding the driver discards its scanout. A later probe initializes the panel.
    if panel_bound():
        # A wake can interrupt entry immediately after SLPIN.
        deadline = asleep.read_text()
        delay = max(0, float(deadline) - time.monotonic()) if deadline else PANEL_DELAY
        time.sleep(min(PANEL_DELAY, delay))
        command = DEBUGFS / "command"
        command.write_text("11\n")  # MIPI DCS Exit Sleep Mode
        time.sleep(PANEL_DELAY)
        command.write_text("29\n")  # MIPI DCS Set Display On
        redraw()
    asleep.unlink()


def restore():
    asleep = STATE / "panel"
    owned_factor = STATE / "factor"
    try:
        if asleep.exists():
            try:
                wake_panel(asleep)
            except OSError as exc:
                print(f"Retrying LCD wake: {exc}", file=sys.stderr)
                time.sleep(PANEL_DELAY)
                wake_panel(asleep)
    finally:
        if owned_factor.exists():
            factor = CPUFREQ / "ondemand/sampling_down_factor"
            if factor.is_file() and factor.read_text().strip() == "5":
                factor.write_text("50\n")
            owned_factor.unlink()


if __name__ == "__main__":
    if sys.argv[1:] == ["enter"]:
        enter()
    elif sys.argv[1:] == ["restore"]:
        restore()
    else:
        sys.exit("usage: okou-cardputer-standby enter|restore")
