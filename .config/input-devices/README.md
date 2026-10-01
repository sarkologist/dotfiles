# Input device configuration

This directory documents the Wacom Bamboo CTL-470 and Kensington SlimBlade Pro
configuration. The live text configuration is tracked at its native path; the
SteerMouse presets are exported snapshots because SteerMouse stores its live
database in an opaque, machine-specific format.

## Tracked files

- `~/.hammerspoon/init.lua` — pen scrolling and display switching, plus the
  existing Hammerspoon window-management configuration.
- `~/.hammerspoon/wacom-display.lua` — fast display switching over a persistent
  OpenTabletDriver CLI connection.
- `~/.hammerspoon/slimblade.lua` — switches the SlimBlade's `Default` setting
  between the left- and right-hand presets.
- `~/.local/bin/toggle-wacom-display` and `toggle-wacom-display.py` — standalone
  fallback for switching displays while preserving rotation and aspect ratio.
- `~/Library/Application Support/OpenTabletDriver/settings.json` — live
  OpenTabletDriver settings.
- `~/.config/input-devices/steermouse/*.smsetting_app` — importable SlimBlade
  presets.

The complete SteerMouse `Device.smsetting` database is deliberately not tracked.
It contains application security bookmarks, local paths, and machine-specific
identifiers.

## Wacom Bamboo CTL-470

- Absolute positioning, clipped to the selected display with aspect ratio
  locked.
- Tablet rotation: 180 degrees.
- Pen tip: left click; keep the tip touching the tablet while moving to drag or
  select text.
- Lower pen button: right click.
- Upper pen button, held while moving the pen: pixel scrolling; pointer movement
  is suppressed during the gesture.
- Upper pen button, double-tapped within 0.65 seconds: switch the tablet to the
  other display.

The Hammerspoon event filter accepts only events emitted by OpenTabletDriver, so
the pen gesture does not consume SlimBlade button chords.

Hammerspoon preserves the tip's click count through drag and release events.
OpenTabletDriver 0.6.7 creates a fresh macOS event for each movement without
restoring that count, and clears it on release after movement. The correction
applies only to OpenTabletDriver events, including double-click-and-drag
selection. Other pointing devices pass through unchanged.

The display shortcut keeps one OpenTabletDriver console process running and
reads the live mapping and rotation before each switch. Display geometry is
cached and refreshed when the connected screens change. Measured switching
time is about 35–75 ms in warmed-up tests, around 100 ms after idling, and
160–220 ms for the first switch after a Hammerspoon reload. These are measured
times, not a hard latency guarantee. A driver restart requires a new connection
and can take longer. If a connection fails, the shortcut reports the error; retry after
OpenTabletDriver is running. The standalone fallback still starts a new process
each time and is slower.

## SlimBlade Pro presets

### Right hand

| Physical button | Action |
| --- | --- |
| Bottom left | Primary click |
| Bottom right | Secondary click |
| Upper left | Back |
| Upper right | Forward |

| Chord | Action |
| --- | --- |
| Bottom left + bottom right | Undefined |
| Bottom left + upper left | Command-Shift-4 |
| Bottom right + upper left | Move right a Space |
| Bottom left + upper right | Move left a Space |
| Bottom right + upper right | Undefined |
| Upper left + upper right | Mission Control |

### Left hand

This is the geometric mirror of the right-hand preset.

| Physical button | Action |
| --- | --- |
| Bottom left | Secondary click |
| Bottom right | Primary click |
| Upper left | Forward |
| Upper right | Back |

| Chord | Action |
| --- | --- |
| Bottom left + bottom right | Undefined |
| Bottom left + upper left | Undefined |
| Bottom right + upper left | Move left a Space |
| Bottom left + upper right | Move right a Space |
| Bottom right + upper right | Command-Shift-4 |
| Upper left + upper right | Mission Control |

### Switching handedness

- Press **Control-Option-Command-H** to toggle between the left- and
  right-hand presets.
- Connecting the Wacom switches the SlimBlade to left-hand mode; disconnecting
  it switches back to right-hand mode.

The Hammerspoon automation imports only SteerMouse's `Default` application
setting, so settings for Anki, Chrome, and other individual applications are
left alone. SteerMouse briefly opens during a switch, then focus returns to the
application you were using.

## Restore

1. Install OpenTabletDriver, Hammerspoon, and SteerMouse.
2. Restore the tracked files into the paths above.
3. Restart OpenTabletDriver so it reloads `settings.json`.
4. Give Hammerspoon Accessibility permission, start it, and reload its config.
5. Connect or disconnect the Wacom, or press **Control-Option-Command-H**, to
   import the appropriate SlimBlade preset automatically.

SteerMouse does not provide general-purpose named presets. Importing one of these
exports replaces the selected application setting; keep both exports current
after changing button or chord assignments.
