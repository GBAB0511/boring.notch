//
//  NSScreen+UUID.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-21.
//

import AppKit
import CoreGraphics

extension NSScreen {
    /// 返回此显示器的持久化 UUID
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        let uuidString = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
        return uuidString
    }
    
    /// 通过 UUID 查找屏幕
    @MainActor static func screen(withUUID uuid: String) -> NSScreen? {
        return NSScreenUUIDCache.shared.screen(forUUID: uuid)
    }
    
    /// 获取所有屏幕的 UUID → NSScreen 映射
    @MainActor static var screensByUUID: [String: NSScreen] {
        return NSScreenUUIDCache.shared.allScreens
    }
}

/// UUID → NSScreen 映射的缓存，避免重复查找
@MainActor
final class NSScreenUUIDCache {
    static let shared = NSScreenUUIDCache()
    
    private var cache: [String: NSScreen] = [:]
    private var observer: Any?
    
    private init() {
        rebuildCache()
        setupObserver()
    }
    
    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupObserver() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildCache()
        }
    }
    
    private func rebuildCache() {
        var newCache: [String: NSScreen] = [:]
        
        for screen in NSScreen.screens {
            if let uuid = screen.displayUUID {
                newCache[uuid] = screen
            }
        }
        
        cache = newCache
    }
    
    func screen(forUUID uuid: String) -> NSScreen? {
        return cache[uuid]
    }
    
    var allScreens: [String: NSScreen] {
        return cache
    }
}
