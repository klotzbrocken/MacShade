import AppKit
import SwiftUI

/// A ReShade shortcut: Windows virtual-key code plus modifiers (ReShade.ini notation "vk,ctrl,shift,alt").
struct KeyBinding: Codable, Hashable {
    var vk: Int
    var ctrl = false, shift = false, alt = false

    var iniValue: String { "\(vk),\(ctrl ? 1 : 0),\(shift ? 1 : 0),\(alt ? 1 : 0)" }
    var label: String {
        (ctrl ? "Ctrl + " : "") + (shift ? "Shift + " : "") + (alt ? "Option + " : "") + (KeyNames.name(vk) ?? L("Key %d", vk))
    }

    static let home = KeyBinding(vk: 0x24)
    static let f12 = KeyBinding(vk: 0x7B)
    static let end = KeyBinding(vk: 0x23)
}

enum KeyNames {
    /// macOS key code -> Windows virtual key (same table MacShade's input layer uses).
    static let macToVK: [UInt16: Int] = [
        0: 0x41, 1: 0x53, 2: 0x44, 3: 0x46, 4: 0x48, 5: 0x47, 6: 0x5A, 7: 0x58, 8: 0x43, 9: 0x56, 11: 0x42, 12: 0x51, 13: 0x57, 14: 0x45, 15: 0x52,
        16: 0x59, 17: 0x54, 18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34, 22: 0x36, 23: 0x35, 24: 0xBB, 25: 0x39, 26: 0x37, 27: 0xBD, 28: 0x38, 29: 0x30, 30: 0xDD, 31: 0x4F,
        32: 0x55, 33: 0xDB, 34: 0x49, 35: 0x50, 36: 0x0D, 37: 0x4C, 38: 0x4A, 39: 0xDE, 40: 0x4B, 41: 0xBA, 42: 0xDC, 43: 0xBC, 44: 0xBF, 45: 0x4E, 46: 0x4D, 47: 0xBE,
        48: 0x09, 49: 0x20, 50: 0xC0, 51: 0x08, 53: 0x1B,
        65: 0x6E, 67: 0x6A, 69: 0x6B, 71: 0x90, 75: 0x6F, 76: 0x0D, 78: 0x6D,
        82: 0x60, 83: 0x61, 84: 0x62, 85: 0x63, 86: 0x64, 87: 0x65, 88: 0x66, 89: 0x67, 91: 0x68, 92: 0x69,
        96: 0x74, 97: 0x75, 98: 0x76, 99: 0x72, 100: 0x77, 101: 0x78, 103: 0x7A, 105: 0x2C, 107: 0x91, 109: 0x79, 111: 0x7B, 113: 0x13,
        114: 0x2D, 115: 0x24, 116: 0x21, 117: 0x2E, 118: 0x73, 119: 0x23, 120: 0x71, 121: 0x22, 122: 0x70, 123: 0x25, 124: 0x27, 125: 0x28, 126: 0x26,
    ]
    static let special: [Int: String] = [
        0x24: "Home", 0x23: "End", 0x21: "PgUp", 0x22: "PgDn", 0x2D: "Ins", 0x2E: "Del", 0x08: "Backspace", 0x09: "Tab", 0x0D: "Return", 0x1B: "Esc", 0x20: "Space",
        0x25: "←", 0x26: "↑", 0x27: "→", 0x28: "↓", 0x2C: "F13", 0x91: "F14", 0x13: "F15",
        0xBB: "=", 0xBD: "-", 0xBC: ",", 0xBE: ".", 0xBA: ";", 0xBF: "/", 0xC0: "`", 0xDB: "[", 0xDD: "]", 0xDC: "\\", 0xDE: "'",
    ]
    static func name(_ vk: Int) -> String? {
        if let s = special[vk] { return s }
        if (0x41...0x5A).contains(vk) || (0x30...0x39).contains(vk) { return String(UnicodeScalar(UInt8(vk))) }
        if (0x70...0x7B).contains(vk) { return "F\(vk - 0x6F)" }
        if (0x60...0x69).contains(vk) { return "Num \(vk - 0x60)" }
        return nil
    }
}

/// Button that records the next key combination (with Ctrl/Shift/Option) the user presses.
struct KeyRecorder: View {
    let title: String
    @Binding var binding: KeyBinding
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .bold))
            Spacer()
            Button { recording ? stop() : start() } label: { Text(recording ? L("Press a key … (Esc cancels)") : binding.label).font(.system(size: 13, design: .monospaced)).frame(minWidth: 180) }.buttonStyle(SoftButton(tint: recording ? Theme.accent : Theme.text))
        }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }   // Esc cancels
            if let vk = KeyNames.macToVK[event.keyCode] {
                let f = event.modifierFlags
                binding = KeyBinding(vk: vk, ctrl: f.contains(.control), shift: f.contains(.shift), alt: f.contains(.option))
                stop()
            }
            return nil
        }
    }
    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
