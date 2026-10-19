//
//  main.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// 此方法用于配置、接受并恢复一个新的传入 NSXPCConnection
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        
        // 配置连接。
        // 首先，设置被导出对象所实现的接口。
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
        
        // 接着，设置连接导出的对象。所有发往此服务的消息都会交给导出对象处理，连接会持有该对象。
        let exportedObject = BoringNotchXPCHelper()
        newConnection.exportedObject = exportedObject
        
        // 恢复连接以便系统投递更多传入消息。
        newConnection.resume()
        
        // 返回 true 表示已接受连接；若需拒绝，可对连接调用 invalidate() 并返回 false。
        return true
    }
}

// 创建服务的委托。
let delegate = ServiceDelegate()

// 为本服务设置唯一的 NSXPCListener，用于处理所有传入连接。
let listener = NSXPCListener.service()
listener.delegate = delegate

// 恢复 serviceListener 以启动本服务，此方法不会返回。
listener.resume()
