//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

// 0.0.7: the virtual-window mode is gone — MultitaskMode and
// the native/virtual fork are deleted. Every multitask launch is a
// native fullscreen scene now (see LCUtils.launchMultitaskGuestApp
// and MultitaskAppWindow).

@objc class MultitaskManager : NSObject {
    static private var usingMultitaskContainers : [String] = []
    
    @objc class func registerMultitaskContainer(container: String) {
        usingMultitaskContainers.append(container)
    }
    
    @objc class func unregisterMultitaskContainer(container: String) {
        usingMultitaskContainers.removeAll(where: { c in
            return c == container
        })
    }
    
    @objc class func isUsing(container: String) -> Bool {
        return usingMultitaskContainers.contains { c in
            return c == container
        }
    }
    
    @objc class func isMultitasking() -> Bool {
        return usingMultitaskContainers.count > 0
    }
}
