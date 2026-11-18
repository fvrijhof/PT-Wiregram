import Cocoa
let sizes = [16,32,64,128,256,512,1024]
let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
func draw(_ s: CGFloat) -> NSImage {
  let img = NSImage(size: NSSize(width: s, height: s)); img.lockFocus()
  let r = NSRect(x: s*0.1, y: s*0.1, width: s*0.8, height: s*0.8)
  let bg = NSBezierPath(roundedRect: r, xRadius: s*0.18, yRadius: s*0.18)
  NSGradient(colors:[NSColor(calibratedRed:0.10,green:0.12,blue:0.18,alpha:1),NSColor(calibratedRed:0.18,green:0.22,blue:0.32,alpha:1)])!.draw(in: bg, angle: 90)
  let cols:[NSColor] = [.systemTeal,.systemOrange,.systemPink]
  let left = [0.30,0.5,0.70].map{ CGFloat($0)*s }
  let mid = CGPoint(x: s*0.52, y: s*0.5); let out = CGPoint(x: s*0.75, y: s*0.5)
  for (i,y) in left.enumerated() {
    let p = NSBezierPath(); p.move(to: CGPoint(x:s*0.26,y:y)); p.curve(to: mid, controlPoint1: CGPoint(x:s*0.42,y:y), controlPoint2: CGPoint(x:s*0.38,y:mid.y))
    p.lineWidth = s*0.035; p.lineCapStyle = .round; cols[i].setStroke(); p.stroke()
    let d = NSBezierPath(ovalIn: NSRect(x:s*0.22,y:y-s*0.04,width:s*0.08,height:s*0.08)); cols[i].setFill(); d.fill()
  }
  let l = NSBezierPath(); l.move(to: mid); l.line(to: out); l.lineWidth = s*0.05; l.lineCapStyle = .round; NSColor.white.setStroke(); l.stroke()
  NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x:mid.x-s*0.05,y:mid.y-s*0.05,width:s*0.1,height:s*0.1)).fill()
  NSBezierPath(roundedRect: NSRect(x:out.x-s*0.02,y:out.y-s*0.09,width:s*0.07,height:s*0.18), xRadius:s*0.02,yRadius:s*0.02).fill()
  img.unlockFocus(); return img
}
for sz in sizes {
  for scale in [1,2] where !(sz == 1024 && scale == 1) || true {
    let px = sz*scale; if px > 1024 { continue }
    let name = scale == 1 ? "icon_\(sz)x\(sz).png" : "icon_\(sz)x\(sz)@2x.png"
    if sz == 1024 { continue }
    let rep = NSBitmapImageRep(data: draw(CGFloat(px)).tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir+"/"+name))
  }
}
