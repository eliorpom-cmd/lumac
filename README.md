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

## Help wanted: real brightness over HDMI

The next feature is a brightness slider that changes the display's backlight through DDC/CI, not a
gamma overlay. It works over USB-C and DisplayPort with tools like [m1ddc](https://github.com/waydabber/m1ddc),
but not through the built-in HDMI port of M1 MacBook Pros, nor through most USB-C hubs with an HDMI
output. BetterDisplay manages it on these Macs, but its code is closed.

If you know how to send a DDC command to an HDMI display from these ports, see
[CONTRIBUTING.md](CONTRIBUTING.md) for what has been tried so far.

## License

[MIT](LICENSE)
