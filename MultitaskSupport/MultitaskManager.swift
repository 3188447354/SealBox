//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import Foundation

extension Notification.Name {
    /// Posted by `MultitaskDockManager.closeMultitaskWindow(uuid:)` to ask the
    /// native-window scene hosting the guest with `userInfo["dataUUID"]` to
    /// terminate its LiveProcess. The virtual-window path does not need it:
    /// there the dock owns the decorated view controller directly.
    static let lcMultitaskTerminateWindow = Notification.Name("LCMultitaskTerminateWindow")
}

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

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
