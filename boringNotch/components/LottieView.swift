//
//  LottieView.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-14.
//

import SwiftUI
import Lottie
import ObjectiveC

// Lottie 动画容器视图。
//
// 关键实现说明（勿改回 Auto Layout）：
// LottieAnimationView 覆写了 intrinsicContentSize，返回动画自身的像素尺寸；
// 且动画是异步加载的——加载完成前该值为 .zero，加载完成后才变成动画尺寸。
// 如果像通常做法那样用四边约束把动画视图钉在容器上，固有尺寸会向上传播，
// 使整个 NSViewRepresentable 的 fitting size 变成动画尺寸，外层 SwiftUI 的
// .frame(width:height:) 会完全失效，动画直接撑满父容器。
// 因此这里不使用 Auto Layout，改为在 layout() 中手动同步子视图 frame。
final class LottieContainerView: NSView {
    let animationView = LottieAnimationView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        addSubview(animationView)
    }

    override func layout() {
        super.layout()
        // 让动画视图始终跟随容器尺寸（容器尺寸由外层 SwiftUI 布局决定）
        animationView.frame = bounds
    }
}

struct LottieView: NSViewRepresentable {
    let url: URL
    let speed: Double
    let loopMode: LottieLoopMode

    private static var associatedURLKey: UInt8 = 0

    func makeNSView(context: Context) -> NSView {
        let container = LottieContainerView(frame: .zero)
        // 保持动画宽高比，避免默认（scaleToFill）把动画拉伸变形、视觉上"撑满"容器
        container.animationView.contentMode = .scaleAspectFit
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? LottieContainerView else { return }
        let animationView = container.animationView
        let lastURL = objc_getAssociatedObject(animationView, &Self.associatedURLKey) as? URL
        if lastURL != url {
            LottieAnimation.loadedFrom(url: url) { animation in
                animationView.animation = animation
                animationView.loopMode = loopMode
                animationView.animationSpeed = CGFloat(speed)
                animationView.play()
                objc_setAssociatedObject(animationView, &Self.associatedURLKey, url, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        } else {
            animationView.loopMode = loopMode
            animationView.animationSpeed = CGFloat(speed)
            if !animationView.isAnimationPlaying {
                animationView.play()
            }
        }
    }
}
