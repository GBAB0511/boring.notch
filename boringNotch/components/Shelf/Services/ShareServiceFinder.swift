//
//  ShareServiceFinder.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-06.
//

import Cocoa

class ShareServiceFinder: NSObject, NSSharingServicePickerDelegate {

    @MainActor
    private var onServicesCaptured: (([NSSharingService]) -> Void)?

    /// 异步返回可用的分享服务，不阻塞 UI
    @MainActor
    func findApplicableServices(for items: [Any], timeout: TimeInterval = 2.0) async -> [NSSharingService] {

        let dummyView = NSView(frame: .zero)
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self

        return await withCheckedContinuation { continuation in
            var didResume = false

            // 捕获分享服务回调
            Task { @MainActor in
                self.onServicesCaptured = { services in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: services)
                }
            }

            picker.show(relativeTo: dummyView.bounds, of: dummyView, preferredEdge: .minY)


            // 超时任务：避免长时间等待分享服务枚举
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !didResume else { return }
                didResume = true
                print("Warning: timed out waiting for sharing services")
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: NSSharingServicePickerDelegate

    func sharingServicePicker(_ picker: NSSharingServicePicker,
                              sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        Task { @MainActor in
            self.onServicesCaptured?(proposed)
        }
        return proposed
    }
}
