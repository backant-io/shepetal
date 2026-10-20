import CoreAudio
import IOKit
import ShepetalCore

/// CoreAudio input devices, the system default input, hot-plug events and the lid state.
enum AudioDevices {
    static func inputs() -> [MicDevice] {
        var size: UInt32 = 0
        var address = Self.address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device)
    }

    static var defaultInputUID: String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    static func id(forUID uid: String) -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Calls `change` on the main queue whenever a device comes or goes.
    static func watch(_ change: @escaping () -> Void) {
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in change() }
    }

    /// IOKit's AppleClamshellState: true while a laptop lid is closed. Desktops have no such property.
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    // MARK: -

    private static func device(_ id: AudioDeviceID) -> MicDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        var transport: UInt32 = 0
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        var taddress = Self.address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(id, &taddress, 0, nil, &tsize, &transport)
        let kind: MicTransport = switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .virtual
        default: .other
        }
        return MicDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, transport: kind)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
