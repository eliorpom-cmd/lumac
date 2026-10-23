<img src="docs/icon.png" width="96" height="96" alt="Lumac icon">

# Lumac

A menu bar app that puts a MacBook to sleep when its lid is closed with an external display connected.
Without it, macOS switches to clamshell mode and keeps running on the external display.

## Why not noclamshell

[noclamshell](https://github.com/pirj/noclamshell) does it by checking the lid every 5 seconds. Right
after a wake, it often reads the lid as still closed and puts the Mac back to sleep: you open the lid,
the screen turns on, off, then on again. Lumac reacts to the lid event sent by macOS instead of checking
on a timer, so this doesn't happen.

## Features

- **Sleep when the lid closes**, only when an external display is connected. Without one, macOS
  already sleeps on its own.
- **Back to sleep after a wake with the lid closed**, for example when you touch an external keyboard.
- **Brightness and contrast sliders** that change the display's own settings over DDC/CI, not a gamma
  overlay. Works over USB-C and DisplayPort, and through the built-in HDMI port of M1 MacBook Pros.
- **Software dimming** when the display doesn't accept DDC commands (many USB-C hubs with an HDMI
  output): the slider darkens the picture through the gamma table instead, and says so.
- **Brightness keys** of the keyboard change the external display when the pointer is on it, or when
  the lid is closed; on the built-in display they work as usual. Needs the Accessibility permission.
- **Follow the built-in display**: the external display follows the MacBook's brightness, which macOS
  sets from the ambient light sensor. Adjust the external display by hand while following and Lumac
  keeps that gap.
- **Brightness calibration** (`Tools/brightness-calibration/calibrate.sh`): matches the two displays
  level by level, by eye with the arrow keys (`--manual`) or with a camera that sees both screens, such
  as an iPhone through Continuity Camera. Following then uses the measured curve.
- **Built-in display brightness** slider in the panel, next to the external display's.
- **Volume slider** for displays with speakers.
- **Input switch** (DisplayPort, HDMI, USB-C), with a confirmation since the picture leaves the Mac.
- Shows the name of the connected display and the time of the last sleep.
- Open at login, from the menu.
- English and French.

## Requirements

- macOS 14 or later. Tested on a MacBook Pro with M1 Pro.
- To build: Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Installation

There's no signed download yet: build Lumac from source.

```bash
brew install xcodegen
git clone https://github.com/eliorpom-cmd/lumac.git && cd lumac
./install.sh
```

The script builds the app, installs it in `/Applications` and opens it. Lumac then appears in the
menu bar. Builds are signed ad hoc; set `LUMAC_SIGN_IDENTITY` to your own codesigning identity to keep
"Open at login" working across rebuilds.

If you used noclamshell, stop it first so the two don't both act on the lid:

```bash
brew services stop noclamshell
```

## How it works

Lumac subscribes to the lid notification of `IOPMrootDomain` (IOKit). When the lid closes and macOS
doesn't plan to sleep (because an external display keeps it awake), Lumac waits one second, then runs
`pmset sleepnow` only if three things agree: the lid sensor says closed, the built-in display is off,
and an external display is on. After a wake, the same check runs 8 seconds later; opening the lid in
the meantime cancels it.

All the logic is in [`Sources/LidMonitor.swift`](Sources/LidMonitor.swift). Logs:

```bash
log stream --predicate 'subsystem == "dev.byelior.lumac"'
```

## Brightness over HDMI

On the built-in HDMI port of M1 MacBook Pros, the signal goes through a DisplayPort-to-HDMI converter
(`AppleDCPMCDP29XX` in IOKit). With the standard DDC/CI chip address `0x37`, the display only returns the
DDC/CI null message (`6E 80 BE`) and ignores writes: this is why tools that use `0x37` read `110` (`0x6E`)
for every value. With chip address `0xB7`, the same frames go through and the display answers normally.
Lumac tries the standard addressing first, then `0xB7`, and keeps the first that gets a valid reply.
It never tries the host address `0x50` on its own: through the HDMI converter, a read request sent
with it set the brightness to 0.

The DDC code is in [`Sources/DDC.swift`](Sources/DDC.swift). To test another Mac, hub or display:

```bash
./Tools/ddc-probe/build.sh
./build/ddc-probe list    # displays found, and whether they go through the HDMI converter
./build/ddc-probe scan    # Get VCP brightness with each addressing, raw reply bytes
```

USB-C hubs with an HDMI output have their own converter, which may block DDC whatever the address.
With the hub tested so far, every I2C call fails (`0xE0114000`) with both `0x37` and `0xB7`: connect the
display to the Mac's HDMI port or over USB-C to DisplayPort instead.

## License

[MIT](LICENSE)
