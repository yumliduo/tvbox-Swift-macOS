#if os(macOS)
import AppKit

enum MPVKeyboardAction {
    case togglePause, seekBackward, seekForward, volumeDown, volumeUp

    init?(event: NSEvent) {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch event.keyCode {
        case 49: self = .togglePause
        case 123: self = .seekBackward
        case 124: self = .seekForward
        case 125: self = .volumeDown
        case 126: self = .volumeUp
        default: return nil
        }
    }
}
#endif
