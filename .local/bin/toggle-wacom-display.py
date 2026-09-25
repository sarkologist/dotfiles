#!/opt/homebrew/bin/python3

"""Switch the Wacom tablet between two displays with one persistent driver session."""

import math
import os
import re
import select
import subprocess
import sys
import time


OTD = "/Applications/OpenTabletDriver.app/Contents/MacOS/OpenTabletDriver.Console"
TABLET = "Wacom CTL-470"
MAX_WIDTH = 147.2
MAX_HEIGHT = 92.0
CENTER_X = 73.6
CENTER_Y = 46.0


class ToggleError(Exception):
    pass


def notify(message, title="Wacom display toggle"):
    # Notifications need not hold up the shortcut after the mapping is verified.
    subprocess.Popen(
        ["/usr/bin/osascript", "-e", f'display notification "{message}" with title "{title}"'],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def send(process, commands):
    process.stdin.write(("\n".join(commands) + "\n").encode())
    process.stdin.flush()


def read_through_tablet_area(process, pending):
    lines = []
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if b"\n" not in pending:
            ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            pending += chunk
            continue

        raw_line, pending = pending.split(b"\n", 1)
        line = raw_line.decode(errors="replace").rstrip("\r")
        if "Daemon not running" in line or "Unhandled exception" in line:
            raise ToggleError("Cannot connect to OpenTabletDriver; restart the app")
        lines.append(line)
        if line.startswith("Tablet area:"):
            return lines, pending

    raise ToggleError("Could not query the tablet settings")


def area(lines, kind):
    for line in lines:
        if line.startswith(f"{kind} area:"):
            match = re.search(r"\[([0-9.]+)x([0-9.]+)@<\s*([-0-9.]+),\s*([-0-9.]+)>:([-0-9.]+)°\]", line)
            if match:
                return tuple(float(value) for value in match.groups())
    raise ToggleError(f"Could not read the current {kind.lower()} area")


def displays_from(lines):
    displays = {}
    for line in lines:
        match = re.match(r"^(\d+): Display .* \(([0-9.]+)x([0-9.]+)@<\s*([-0-9.]+),\s*([-0-9.]+)>\)", line)
        if match:
            index = int(match.group(1))
            displays[index] = tuple(float(value) for value in match.groups()[1:])
    return displays


def same_mapping(display_area, display):
    width, height, center_x, center_y, _ = display_area
    screen_width, screen_height, x, y = display
    return all(
        math.isclose(actual, expected, abs_tol=0.01)
        for actual, expected in zip(
            (width, height, center_x, center_y),
            (screen_width, screen_height, x + screen_width / 2, y + screen_height / 2),
        )
    )


def toggle():
    if not os.access(OTD, os.X_OK):
        raise ToggleError("OpenTabletDriver is not installed")

    # The direct command reliably lists displays; stdio's listdisplays is flaky.
    for attempt in range(2):
        listing = subprocess.run([OTD, "listdisplays"], capture_output=True, text=True, timeout=5)
        if "Sequence contains no elements" not in listing.stdout + listing.stderr:
            break
    if "Unhandled exception" in listing.stdout + listing.stderr:
        raise ToggleError("Could not list connected displays")
    displays = displays_from(listing.stdout.splitlines())
    if 0 not in displays or 1 not in displays:
        raise ToggleError("A second display is not connected")

    process = subprocess.Popen(
        [OTD, "stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    try:
        send(process, [f'getareas "{TABLET}"'])
        current_lines, pending = read_through_tablet_area(process, b"")
        current_display = area(current_lines, "Display")
        rotation = area(current_lines, "Tablet")[4]
        current_index = next(
            (index for index in (0, 1) if same_mapping(current_display, displays[index])), None
        )
        target_index = 1 if current_index == 0 else 0
        screen_width, screen_height, _, _ = displays[target_index]
        screen_ratio = screen_width / screen_height
        tablet_ratio = MAX_WIDTH / MAX_HEIGHT
        if screen_ratio > tablet_ratio:
            tablet_width, tablet_height = MAX_WIDTH, MAX_WIDTH / screen_ratio
        else:
            tablet_width, tablet_height = MAX_HEIGHT * screen_ratio, MAX_HEIGHT

        send(process, [
            f'maptodisplayindex "{TABLET}" {target_index}',
            f'settabletarea "{TABLET}" {tablet_width:.3f} {tablet_height:.3f} {CENTER_X} {CENTER_Y} {rotation:g}',
            f'setlockaspectratio "{TABLET}" true',
            f'setenableclipping "{TABLET}" true',
            "savedefaultsettings",
            f'getareas "{TABLET}"',
        ])
        verified_lines, _ = read_through_tablet_area(process, pending)
        verified_display = area(verified_lines, "Display")
        verified_rotation = area(verified_lines, "Tablet")[4]
        if not same_mapping(verified_display, displays[target_index]) or not math.isclose(
            verified_rotation, rotation, abs_tol=0.001
        ):
            raise ToggleError("Tablet mapping did not match the requested display")

        return f"Mapped to display {target_index + 1} ({screen_width:g}x{screen_height:g})"
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=1)


if __name__ == "__main__":
    try:
        message = toggle()
    except (ToggleError, OSError, ValueError, ZeroDivisionError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        notify(str(error))
        sys.exit(1)
    notify(message, "Wacom tablet")
