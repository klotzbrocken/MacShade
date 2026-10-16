import CoreGraphics
import Foundation
// usage: winid2 <owner-name-substring> [pid]  -> id of the largest on-screen window
let want = CommandLine.arguments[1].lowercased().replacingOccurrences(of: " ", with: "")
let pidFilter = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) : nil
var best: (Int, CGFloat) = (0, 0)
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] where (w[kCGWindowOwnerName as String] as? String)?.lowercased().replacingOccurrences(of: " ", with: "").contains(want) == true {
    if let p = pidFilter, (w[kCGWindowOwnerPID as String] as? Int) != p { continue }
    let b = w[kCGWindowBounds as String] as! [String: CGFloat]
    let area = b["Width"]! * b["Height"]!
    if area > best.1 { best = (w[kCGWindowNumber as String] as! Int, area) }
}
if best.0 != 0 { print(best.0) }
