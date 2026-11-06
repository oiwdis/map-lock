// Checks MapZoomState: clamp, pan bounds, map<->view point round-trip.
// Run ./check-zoom.sh from the project folder.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated(unsafe) var fails: [String] = []
func expect(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { fails.append(name) }
}
func near(_ a: CGFloat, _ b: CGFloat, eps: CGFloat = 0.02) -> Bool { abs(a - b) < eps }
func nearPt(_ a: CGPoint, _ b: CGPoint, eps: CGFloat = 0.05) -> Bool {
    near(a.x, b.x, eps: eps) && near(a.y, b.y, eps: eps)
}

let size = CGSize(width: 800, height: 400)
var z = MapZoomState()
expect("start at 1x", z.scale == 1 && !z.isZoomed)

z.zoomIn(anchor: CGPoint(x: 400, y: 200), in: size)
expect("zoomIn steps up", near(z.scale, MapZoomState.step))
expect("center zoom keeps offset near zero", near(z.offset.width, 0) && near(z.offset.height, 0))

let corner = CGPoint(x: 100, y: 50)
z.reset()
z.setScale(4, anchor: corner, in: size)
expect("clamp max not exceeded", z.scale <= MapZoomState.maxScale)
expect("setScale 4", near(z.scale, 4))
let back = z.mapPoint(from: corner, in: size)
expect("anchor stays fixed under zoom", nearPt(back, corner))

z.setScale(100, anchor: CGPoint(x: 400, y: 200), in: size)
expect("clamped to max", near(z.scale, MapZoomState.maxScale))

z.setScale(0.1, anchor: CGPoint(x: 400, y: 200), in: size)
expect("clamped to min / reset", near(z.scale, 1) && !z.isZoomed)

z.setScale(4, anchor: CGPoint(x: 400, y: 200), in: size)
z.pan(by: CGSize(width: 10_000, height: -10_000), in: size)
let maxX = size.width * (z.scale - 1) / 2
let maxY = size.height * (z.scale - 1) / 2
expect("pan clamped X", abs(z.offset.width) <= maxX + 0.01)
expect("pan clamped Y", abs(z.offset.height) <= maxY + 0.01)

z.reset()
z.pan(by: CGSize(width: 50, height: 50), in: size)
expect("no pan at 1x", z.offset == .zero)

z.setScale(2, anchor: CGPoint(x: 200, y: 100), in: size)
let view = CGPoint(x: 250, y: 120)
let map = z.mapPoint(from: view, in: size)
// Round-trip: map -> view via inverse of mapPoint
let c = CGPoint(x: size.width / 2, y: size.height / 2)
let view2 = CGPoint(
    x: (map.x - c.x) * z.scale + c.x + z.offset.width,
    y: (map.y - c.y) * z.scale + c.y + z.offset.height
)
expect("mapPoint inverse", nearPt(view2, view))

z.zoomOut(anchor: CGPoint(x: 400, y: 200), in: size)
expect("zoomOut reduces", z.scale < 2)

print(fails.isEmpty ? "\nAll zoom checks passed." : "\n\(fails.count) failed.")
if !fails.isEmpty { exit(1) }
