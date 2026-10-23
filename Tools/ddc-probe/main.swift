import Foundation

// Command-line probe for DDC/CI on external displays, used to diagnose paths that fail
// (such as the built-in HDMI port of M1 Macs). Build: Tools/ddc-probe/build.sh
//
//   ddc-probe list                      displays, converter flag, EDID size
//   ddc-probe scan [code]               Get VCP with each automatic addressing, raw bytes
//   ddc-probe get [code] [--host 50|51] [--chip 37|b7]
//   ddc-probe set <value> [code] [--host 50|51] [--chip 37|b7] [--repeats n]

let arguments = Array(CommandLine.arguments.dropFirst())
let displays = DDCDisplay.externalDisplays()

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

func code(at index: Int) -> UInt8 {
    guard arguments.count > index, let value = UInt8(arguments[index].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
        return VCP.brightness.rawValue
    }
    return value
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard let display = displays.first else {
    print("No external DCPAVServiceProxy found.")
    exit(1)
}

if let host = option("--host").flatMap({ UInt8($0, radix: 16) }) { display.addressing.host = host }
if let chip = option("--chip").flatMap({ UInt8($0, radix: 16) }) { display.addressing.chip = chip }
if let repeats = option("--repeats").flatMap(Int.init) { display.timing.repeats = repeats }

switch arguments.first ?? "list" {
case "list":
    for (index, display) in displays.enumerated() {
        let id = display.displayID.map(String.init) ?? "unmatched"
        let edid = display.edid().map { "\($0.count) bytes" } ?? "unavailable"
        print("[\(index + 1)] \(display.name)  display ID \(id)  HDMI converter: \(display.throughHDMIConverter)  EDID: \(edid)")
    }

case "scan":
    let vcp = code(at: 1)
    for addressing in DDCDisplay.Addressing.all {
        display.addressing = addressing
        do {
            let bytes = try display.rawRead(vcp)
            let parsed = (try? display.read(vcp)).map { "current \($0.current), max \($0.maximum)" } ?? "no valid reply"
            print("\(addressing): \(parsed)\n  \(hex(bytes))")
        } catch {
            print("\(addressing): \(error)")
        }
    }

case "get":
    do {
        let vcp = arguments.count > 1 && !arguments[1].hasPrefix("--") ? code(at: 1) : VCP.brightness.rawValue
        let reading = try display.read(vcp)
        print("current \(reading.current), max \(reading.maximum)")
    } catch {
        print(error)
        exit(1)
    }

case "set":
    guard arguments.count > 1, let value = UInt16(arguments[1]) else {
        print("usage: ddc-probe set <value> [code] [--host 50|51] [--chip 37|b7] [--repeats n]")
        exit(2)
    }
    let vcp = arguments.count > 2 && !arguments[2].hasPrefix("--") ? code(at: 2) : VCP.brightness.rawValue
    do {
        try display.write(vcp, value: value)
        print("sent VCP 0x\(String(format: "%02x", vcp)) = \(value) (\(display.addressing), \(display.timing.repeats) repeats)")
    } catch {
        print(error)
        exit(1)
    }

default:
    print("usage: ddc-probe list | scan [code] | get [code] | set <value> [code] [--host 50|51] [--chip 37|b7] [--repeats n]")
    exit(2)
}
