import Foundation
import CoreGraphics

// ---- Display brightness via DisplayServices (Apple Silicon internal panel) ----
typealias DSGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias DSSet = @convention(c) (UInt32, Float) -> Int32

let dsPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
if let ds = dlopen(dsPath, RTLD_NOW),
   let gs = dlsym(ds, "DisplayServicesGetBrightness"),
   let ss = dlsym(ds, "DisplayServicesSetBrightness") {
    let get = unsafeBitCast(gs, to: DSGet.self)
    let set = unsafeBitCast(ss, to: DSSet.self)
    let disp = CGMainDisplayID()
    var cur: Float = -1
    let rc = get(disp, &cur)
    print("DISPLAY: get rc=\(rc) brightness=\(cur)")
    if rc == 0 {
        // gentle proof it can move: dip ~10% for 250ms, then restore exactly
        let test = max(0, cur - 0.1)
        let sr = set(disp, test)
        usleep(250_000)
        let rr = set(disp, cur)
        print("DISPLAY: set->\(test) rc=\(sr), restored->\(cur) rc=\(rr)  (SET WORKS if both 0)")
    }
} else {
    print("DISPLAY: DisplayServices unavailable")
}

// ---- Keyboard backlight via CoreBrightness KeyboardBrightnessClient ----
// NOTE: methods take/return Float, not Double.
@objc protocol KBClient {
    func brightnessForKeyboard(_ k: Int64) -> Float
    func setBrightness(_ b: Float, forKeyboard k: Int64) -> Bool
}
_ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
if let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
    let kb = unsafeBitCast(cls.init(), to: KBClient.self)
    let kid: Int64 = 1
    let before = kb.brightnessForKeyboard(kid)
    print("KEYBOARD id=\(kid): current=\(before)")
    _ = kb.setBrightness(0.75, forKeyboard: kid); usleep(300_000)
    let mid = kb.brightnessForKeyboard(kid)
    _ = kb.setBrightness(0.0, forKeyboard: kid); usleep(300_000)
    let low = kb.brightnessForKeyboard(kid)
    _ = kb.setBrightness(before, forKeyboard: kid)
    print("KEYBOARD: after set 0.75 read=\(mid), after set 0 read=\(low)  (CONTROL WORKS if read tracks the set)")
} else {
    print("KEYBOARD: KeyboardBrightnessClient not found")
}
