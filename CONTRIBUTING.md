# Contributing

Issues and pull requests are welcome. Keep pull requests to one topic each.

## Building

```bash
brew install xcodegen
./install.sh
```

`project.yml` is the source of truth: the Xcode project is generated and not committed. UI strings are
written in English in the code and translated in `Sources/Localizable.xcstrings`.

## Help wanted: DDC brightness over HDMI on Apple Silicon

Lumac should set the real backlight of the external display (DDC/CI, VCP code `0x10`), not dim the
picture in software. The question is how to do it when the display is connected over HDMI.

### What has been tried

Setup: MacBook Pro 14" (M1 Pro), LG HDR 4K, [m1ddc](https://github.com/waydabber/m1ddc) 1.2.0.

| Connection | `m1ddc display 2 get luminance` | `m1ddc display 2 set luminance 20` |
|---|---|---|
| USB-C hub with an HDMI output | `DDC communication failure` | `DDC communication failure` |
| Built-in HDMI port of the Mac | returns `110` for every code (luminance, contrast, volume, input) | returns success, the display doesn't change |

On both, IOKit reports the link as `"Transport" = {"Upstream"="DP","Downstream"="HDMI"}`: the signal
leaves the Mac as DisplayPort and is converted to HDMI by a chip, in the Mac or in the hub.

[MonitorControl](https://github.com/MonitorControl/MonitorControl) lists the built-in HDMI port of M1
Macs as unsupported for DDC. [BetterDisplay](https://github.com/waydabber/BetterDisplay) says it supports
DDC over HDMI on these Macs, so it seems possible.

### Leads, unverified

- The writes may reach the DP-to-HDMI converter and stop there. The converter might need a different
  I2C address or a different `IOAVService` than the one m1ddc picks.
- The `110` read back looks like a fixed reply, not a value from the display.

### What would help

- A way to send VCP `0x10` to an HDMI display from the built-in HDMI port of an M1, M1 Pro or M1 Max Mac,
  ideally as a small Swift or C function using public or documented private APIs.
- Results from other Macs, hubs and displays: run the two m1ddc commands above and post the output, the
  Mac model, the connection and the display in the issue.

Code that ends up in Lumac must be compatible with the MIT license.
