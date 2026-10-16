import Cocoa
import CoreGraphics
// usage: post_events <pid> <script...>   script items: key:<mac keycode> | click:<x>:<y> (window-relative points) | move:<x>:<y> | wait:<sec> | scroll:<n>
let args = CommandLine.arguments
let pid = pid_t(Int(args[1])!)
func windowOrigin() -> CGPoint {
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in l where (w[kCGWindowOwnerPID as String] as? Int) == Int(pid) && (w[kCGWindowLayer as String] as? Int) == 0 {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        return CGPoint(x: b["X"]!, y: b["Y"]!)
    }
    return .zero
}
for item in args.dropFirst(2) {
    let p = item.split(separator: ":").map(String.init)
    switch p[0] {
    case "key":
        let code = CGKeyCode(Int(p[1])!)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
        down.postToPid(pid); usleep(80_000); up.postToPid(pid)
    case "move", "click":
        let o = windowOrigin()
        let pt = CGPoint(x: o.x + CGFloat(Double(p[1])!), y: o.y + CGFloat(Double(p[2])!))
        let type: CGEventType = p[0] == "move" ? .mouseMoved : .leftMouseDown
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)!
        e.postToPid(pid)
        if p[0] == "click" { usleep(60_000); CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)!.postToPid(pid) }
    case "wait": usleep(UInt32(Double(p[1])! * 1_000_000))
    default: break
    }
    usleep(150_000)
}
