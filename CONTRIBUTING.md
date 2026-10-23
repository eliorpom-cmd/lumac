# Contributing

Issues and pull requests are welcome. Keep pull requests to one topic each.

## Building

```bash
brew install xcodegen
./install.sh
```

`project.yml` is the source of truth: the Xcode project is generated and not committed. UI strings are
written in English in the code and translated in `Sources/Localizable.xcstrings`.

## Help wanted: DDC on other Macs, hubs and displays

Brightness works over USB-C, DisplayPort and the built-in HDMI port of an M1 Pro MacBook Pro with an
LG HDR 4K (chip address `0xB7` through the HDMI converter, see the README). Results from other setups
help: build the probe and post the output of `list` and `scan` with your Mac, display and cable or hub.

```bash
./Tools/ddc-probe/build.sh
./build/ddc-probe list
./build/ddc-probe scan
```
