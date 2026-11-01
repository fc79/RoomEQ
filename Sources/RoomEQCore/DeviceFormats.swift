// Small helpers for the output-device menus (sample rates, transport type).

import CoreAudio
import Foundation

public enum SampleRates {
    /// Rates closer than this are the same rate (HAL values can carry
    /// tiny floating-point differences).
    public static let tolerance = 0.5

    public static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }

    /// `rate` is one of `rates` (within the tolerance).
    public static func contains(_ rates: [Double], _ rate: Double) -> Bool { rates.contains { same($0, rate) } }

    /// The standard rates offered when a device reports a continuous range.
    public static let standard: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    /// Rates to offer for `kAudioDevicePropertyAvailableNominalSampleRates`:
    /// a single value (min == max) is offered as is; a range offers every
    /// standard rate inside it. Sorted, without duplicates or junk.
    public static func expand(_ ranges: [(minimum: Double, maximum: Double)]) -> [Double] {
        var rates = Set<Double>()
        for range in ranges where range.minimum.isFinite && range.maximum.isFinite && range.minimum > 0 {
            let low = min(range.minimum, range.maximum), high = max(range.minimum, range.maximum)
            if high - low < 0.5 {
                rates.insert(low.rounded())
            } else {
                for rate in standard where rate >= low - 0.5 && rate <= high + 0.5 { rates.insert(rate) }
            }
        }
        return rates.sorted()
    }
}

public enum TransportType {
    /// Short (localized) name of a `kAudioDevicePropertyTransportType` value.
    public static func name(_ code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return String(localized: "Integrato")
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeVirtual: return String(localized: "Virtuale")
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return String(localized: "Aggregato")
        default: return String(localized: "Altro")
        }
    }

    /// Aggregate devices are not offered as outputs.
    public static func isAggregate(_ code: UInt32) -> Bool {
        code == kAudioDeviceTransportTypeAggregate || code == kAudioDeviceTransportTypeAutoAggregate
    }
}
