import CoreGraphics
import Foundation
import IOKit

// Private IOKit functions for I2C on Apple silicon display outputs. They have no public header.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(
    _ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
    _ buffer: UnsafeMutableRawPointer, _ size: UInt32
) -> IOReturn

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(
    _ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
    _ buffer: UnsafeMutableRawPointer, _ size: UInt32
) -> IOReturn

@_silgen_name("IOAVServiceCopyEDID")
private func IOAVServiceCopyEDID(_ service: CFTypeRef, _ edid: UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn

/// VCP codes from the VESA MCCS standard.
enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
    case input = 0x60
}

struct VCPReading: Equatable {
    let current: UInt16
    let maximum: UInt16
}

enum DDCError: Error, CustomStringConvertible {
    case io(IOReturn)
    case malformedReply([UInt8])
    case unsupported(VCP.RawValue)

    var description: String {
        switch self {
        case .io(let code): return String(format: "I2C error 0x%08x", code)
        case .malformedReply(let bytes): return "malformed reply: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        case .unsupported(let code): return String(format: "display does not support VCP 0x%02x", code)
        }
    }
}

/// DDC/CI (VESA MCCS) over the I2C bus carried by the video cable, through `IOAVService`.
///
/// Implemented from the DDC/CI standard and from a functional description of the
/// exchange (addresses, frame layout, retries); no third-party code was used.
///
/// I2C exchanges are serialized by a lock; `addressing` and `timing` must be set from the
/// queue that performs the exchanges.
final class DDCDisplay: @unchecked Sendable {
    /// Some displays and adapters only answer with these non-standard addresses.
    struct Addressing: Hashable, CustomStringConvertible {
        /// 0x51 per the standard, 0x50 for some non-conforming devices (manual use only).
        var host: UInt8 = 0x51
        /// 0x37 per the standard; 0xB7 is the same address with the high bit set.
        var chip: UInt8 = 0x37

        static let standard = Addressing()
        static let highChip = Addressing(host: 0x51, chip: 0xB7)
        /// Variants tried automatically. Host 0x50 is left out: through the built-in HDMI
        /// converter, a Get VCP request sent with it set the brightness to 0.
        static let all: [Addressing] = [.standard, .highChip]

        var description: String { String(format: "host 0x%02x, chip 0x%02x", host, chip) }
    }

    struct Timing {
        /// Pause before each write: many displays drop frames sent back to back.
        var writeDelay: TimeInterval = 0.01
        /// Each frame is sent this many times, since displays often ignore one.
        var repeats = 2
        /// Attempts when the I2C call itself fails.
        var attempts = 3
        /// Time the display needs to prepare a reply after a Get VCP request.
        var replyDelay: TimeInterval = 0.05
    }

    let name: String
    let displayID: CGDirectDisplayID?
    /// True when the output goes through the DisplayPort-to-HDMI converter of the built-in HDMI port.
    let throughHDMIConverter: Bool
    var addressing = Addressing.standard
    var timing = Timing()

    private let service: CFTypeRef
    private let lock = NSLock()
    /// The DDC/CI destination address of the display, part of every checksum.
    private static let displayAddress: UInt8 = 0x6E
    /// Long enough for the 11-byte reply plus whatever chatty displays add.
    private static let readSize = 37

    private init(service: CFTypeRef, name: String, displayID: CGDirectDisplayID?, throughHDMIConverter: Bool) {
        self.service = service
        self.name = name
        self.displayID = displayID
        self.throughHDMIConverter = throughHDMIConverter
    }

    // MARK: - VCP

    func write(_ code: VCP.RawValue, value: UInt16) throws {
        var payload: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        payload.append(checksum(payload))
        try locked {
            for _ in 0..<timing.repeats { try send(payload) }
        }
    }

    func read(_ code: VCP.RawValue) throws -> VCPReading {
        try locked {
            var payload: [UInt8] = [0x82, 0x01, code]
            payload.append(checksum(payload))
            try send(payload)
            Thread.sleep(forTimeInterval: timing.replyDelay)
            return try parseReply(receive(), code: code)
        }
    }

    func write(_ code: VCP, value: UInt16) throws { try write(code.rawValue, value: value) }
    func read(_ code: VCP) throws -> VCPReading { try read(code.rawValue) }

    /// Raw bytes returned after a Get VCP request, for diagnosis.
    func rawRead(_ code: VCP.RawValue) throws -> [UInt8] {
        try locked {
            var payload: [UInt8] = [0x82, 0x01, code]
            payload.append(checksum(payload))
            try send(payload)
            Thread.sleep(forTimeInterval: timing.replyDelay)
            return try receive()
        }
    }

    /// Picks the first addressing that gets a valid brightness reply, standard first.
    /// Through the built-in HDMI converter of M1 Macs, only chip address 0xB7 answers:
    /// 0x37 returns the DDC/CI null message (`6E 80 BE`) and writes are ignored.
    @discardableResult
    func detectAddressing() -> Bool {
        let preferred = throughHDMIConverter ? Addressing.highChip : .standard
        for candidate in [preferred] + Addressing.all.filter({ $0 != preferred }) {
            addressing = candidate
            if (try? read(.brightness)) != nil { return true }
        }
        addressing = preferred
        return false
    }

    func edid() -> Data? {
        var edid: Unmanaged<CFData>?
        guard IOAVServiceCopyEDID(service, &edid) == kIOReturnSuccess, let edid else { return nil }
        return edid.takeRetainedValue() as Data
    }

    // MARK: - Frames

    /// XOR of the display address, the host address and every payload byte.
    private func checksum(_ payload: [UInt8]) -> UInt8 {
        payload.reduce(Self.displayAddress ^ addressing.host, ^)
    }

    private func send(_ payload: [UInt8]) throws {
        var buffer = payload
        var result = kIOReturnSuccess
        for _ in 0..<timing.attempts {
            Thread.sleep(forTimeInterval: timing.writeDelay)
            result = IOAVServiceWriteI2C(service, UInt32(addressing.chip), UInt32(addressing.host), &buffer, UInt32(buffer.count))
            if result == kIOReturnSuccess { return }
        }
        throw DDCError.io(result)
    }

    private func receive() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        var result = kIOReturnSuccess
        for _ in 0..<timing.attempts {
            result = IOAVServiceReadI2C(service, UInt32(addressing.chip), 0, &buffer, UInt32(buffer.count))
            if result == kIOReturnSuccess { return buffer }
            Thread.sleep(forTimeInterval: timing.writeDelay)
        }
        throw DDCError.io(result)
    }

    /// Finds the Get VCP reply (`6E 88 02 result code type maxHi maxLo curHi curLo checksum`)
    /// anywhere in the buffer, since some paths prepend or append bytes.
    private func parseReply(_ bytes: [UInt8], code: UInt8) throws -> VCPReading {
        for start in bytes.indices where start + 11 <= bytes.count {
            let frame = Array(bytes[start..<start + 11])
            guard frame[0] == Self.displayAddress, frame[1] == 0x88, frame[2] == 0x02, frame[4] == code else { continue }
            // Replies are checksummed with the virtual host address 0x50.
            guard frame[0..<10].reduce(0x50, ^) == frame[10] else { continue }
            guard frame[3] == 0 else { throw DDCError.unsupported(code) }
            return VCPReading(
                current: UInt16(frame[8]) << 8 | UInt16(frame[9]),
                maximum: UInt16(frame[6]) << 8 | UInt16(frame[7])
            )
        }
        throw DDCError.malformedReply(bytes)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Discovery

    /// External displays reachable over DDC, in IORegistry order.
    ///
    /// Each `DCPAVServiceProxy` with Location = External is paired with the last external
    /// framebuffer met before it while walking the IOService plane, which identifies the display.
    static func externalDisplays() -> [DDCDisplay] {
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var framebuffer: (name: String, vendor: UInt32?, product: UInt32?, serial: UInt32?)?
        var converter = false
        var displays: [DDCDisplay] = []

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if property(entry, "EPICProviderClass") as? String == "AppleDCPMCDP29XX" { converter = true }

            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                guard property(entry, "external") as? Bool == true,
                      let attributes = property(entry, "DisplayAttributes") as? [String: Any],
                      let product = attributes["ProductAttributes"] as? [String: Any]
                else { continue }
                framebuffer = (
                    name: product["ProductName"] as? String ?? "External display",
                    vendor: (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                    product: (product["ProductID"] as? NSNumber)?.uint32Value,
                    serial: (product["SerialNumber"] as? NSNumber)?.uint32Value
                )
                converter = false
                continue
            }

            guard IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0,
                  property(entry, "Location") as? String == "External",
                  let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
            else { continue }

            let id = framebuffer.flatMap { fb in
                onlineDisplays().first {
                    CGDisplayIsBuiltin($0) == 0
                        && (fb.vendor == nil || CGDisplayVendorNumber($0) == fb.vendor)
                        && (fb.product == nil || CGDisplayModelNumber($0) == fb.product)
                        && (fb.serial == nil || CGDisplaySerialNumber($0) == fb.serial)
                }
            }
            displays.append(DDCDisplay(
                service: service,
                name: framebuffer?.name ?? "External display",
                displayID: id,
                throughHDMIConverter: converter
            ))
            framebuffer = nil
            converter = false
        }
        return displays
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
