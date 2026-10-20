//
//  ShelfItemViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreServices
import ObjectiveC

@MainActor
final class ShelfItemViewModel: ObservableObject {
    @Published private(set) var item: ShelfItem
    @Published var thumbnail: NSImage?
    @Published var isDropTargeted: Bool = false
    @Published var isRenaming: Bool = false
    @Published var draftTitle: String = ""
    private var sharingLifecycle: SharingLifecycleDelegate?
    private var quickShareLifecycle: SharingLifecycleDelegate?
    private var sharingAccessingURLs: [URL] = []
    private static var copiedURLs: [URL] = []

    private let selection = ShelfSelectionModel.shared

    init(item: ShelfItem) {
        self.item = item
        self.draftTitle = item.displayName
        Task { await loadThumbnail() }
    }

    var isSelected: Bool { selection.isSelected(item.id) }

    func loadThumbnail() async {
        guard let url = item.fileURL else { return }
        if let image = await ThumbnailService.shared.thumbnail(for: url, size: CGSize(width: 56, height: 56)) {
            self.thumbnail = image
        }
    }

    // MARK: - 拖放辅助方法
    func dragItemProvider() -> NSItemProvider {
    let selectedItems = selection.selectedItems(in: ShelfStateViewModel.shared.items)
        if selectedItems.count > 1 && selectedItems.contains(where: { $0.id == item.id }) {
            return createMultiItemProvider(for: selectedItems)
        }
        return createItemProvider(for: item)
    }

    private func createItemProvider(for item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file:
            let provider = NSItemProvider()
            if let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) {
                provider.registerObject(url as NSURL, visibility: .all)
            } else {
                provider.registerObject(item.displayName as NSString, visibility: .all)
            }
            return provider
        case .text(let string):
            return NSItemProvider(object: string as NSString)
        case .link(let url):
            return NSItemProvider(object: url as NSURL)
        }
    }

    private func createMultiItemProvider(for items: [ShelfItem]) -> NSItemProvider {
        let provider = NSItemProvider()
        var urls: [URL] = []
        var textItems: [String] = []
        for item in items {
            switch item.kind {
            case .file:
                if let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) {
                    urls.append(url)
                } else {
                    textItems.append(item.displayName)
                }
            case .text(let string):
                textItems.append(string)
            case .link:
                break
            }
        }
        if !urls.isEmpty {
            for url in urls {
                provider.registerObject(url as NSURL, visibility: .all)
            }
        }
        if !textItems.isEmpty {
            provider.registerObject(textItems.joined(separator: "\n") as NSString, visibility: .all)
        }
        return provider
    }

    // MARK: - 操作
    func handleClick(event: NSEvent, view: NSView) {
        let flags = event.modifierFlags
        if flags.contains(.shift) {
            selection.shiftSelect(to: item, in: ShelfStateViewModel.shared.items)
        } else if flags.contains(.command) {
            selection.toggle(item)
        } else if flags.contains(.control) {
            handleRightClick(event: event, view: view)
        } else {
            if !selection.isSelected(item.id) { selection.selectSingle(item) }
        }
        if event.clickCount == 2 { handleDoubleClick() }
    }

    func handleRightClick(event: NSEvent, view: NSView) {
        if !selection.isSelected(item.id) { selection.selectSingle(item) }
        presentContextMenu(event: event, in: view)
    }

    func handleDoubleClick() {
    let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
        for it in selected { ShelfActionService.open(it) }
    }

    func shareItem(from view: NSView?) {
        Task {
            var itemsToShare: [Any] = []
            var fileURLs: [URL] = []
            if case .text(let text) = item.kind {
                itemsToShare.append(text)
            } else {
                for item in ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items) {
                    switch item.kind {
                    case .file:
                        // 用户主动触发的分享操作，使用即时更新来刷新书签
                        if let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) {
                            itemsToShare.append(url)
                            fileURLs.append(url)
                        }
                    case .text(let string):
                        itemsToShare.append(string)
                    case .link(let url):
                        itemsToShare.append(url)
                    }
                }
            }
            
            guard !itemsToShare.isEmpty else { return }
             
            stopSharingAccessingURLs()
            // 为所有文件 URL 开启安全作用域访问，并在整个分享期间保持激活
            sharingAccessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
            
            // 为整个分享操作创建并持有生命周期委托
            let lifecycle = SharingStateManager.shared.makeDelegate { [weak self] in
                self?.sharingLifecycle = nil
                self?.stopSharingAccessingURLs()
            }
            self.sharingLifecycle = lifecycle
            
            let picker = NSSharingServicePicker(items: itemsToShare)
            picker.delegate = lifecycle
            lifecycle.markPickerBegan()
            if let view {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        }
    }
    
    private func stopSharingAccessingURLs() {
        for url in sharingAccessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        sharingAccessingURLs.removeAll()
    }

    /// 调用此闭包以请求对给定 URL 集合进行 Quick Look 预览
    var onQuickLookRequest: (([URL]) -> Void)?

    // MARK: - 上下文菜单辅助方法（从视图中抽取）
    func loadOpenWithApps() -> [URL] {
        // 同时支持文件项和链接项。对于链接项，向 NSWorkspace 询问能打开该 URL 的应用（通常是浏览器）。
        if let fileURL = item.fileURL {
            var results: [URL] = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
            if results.isEmpty {
                if let uti = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType {
                    results = NSWorkspace.shared.urlsForApplications(toOpen: uti)
                }
            }
            let unique = Array(Set(results))
            let sorted = unique.sorted { appDisplayName(for: $0) < appDisplayName(for: $1) }
            return sorted
        } else if case .link(let url) = item.kind {
            var results: [URL] = NSWorkspace.shared.urlsForApplications(toOpen: url)
            if results.isEmpty {
                if let uti = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                    results = NSWorkspace.shared.urlsForApplications(toOpen: uti)
                }
            }
            let unique = Array(Set(results))
            let sorted = unique.sorted { appDisplayName(for: $0) < appDisplayName(for: $1) }
            return sorted
        }
        return []
    }

    private func ensureContextMenuSelection() {
        if !selection.isSelected(item.id) { selection.selectSingle(item) }
    }

    func presentContextMenu(event: NSEvent, in view: NSView) {
        ensureContextMenuSelection()
        let menu = NSMenu()

        func addMenuItem(title: String) {
            let localizedText = String(localized: String.LocalizationValue(title))
            let mi = NSMenuItem(title: localizedText, action: nil, keyEquivalent: "")
            menu.addItem(mi)
        }

        let selectedItems = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
        let selectedFileURLs = selectedItems.compactMap { $0.fileURL }
        let selectedLinkURLs: [URL] = selectedItems.compactMap { itm in
            if case .link(let url) = itm.kind { return url }
            return nil
        }
        let selectedFolderURLs = selectedFileURLs.filter { isDirectory($0) }
        // 用于「打开 / 打开方式」的有效 URL（排除文件夹）
        let selectedOpenableURLs = selectedItems.compactMap { itm -> URL? in
            if let u = itm.fileURL { return isDirectory(u) ? nil : u }
            if case .link(let url) = itm.kind { return url }
            return nil
        }

        if !selectedOpenableURLs.isEmpty {
            addMenuItem(title: "Open")
        }

        if !selectedOpenableURLs.isEmpty {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            // 选择一个代表性 URL 来计算可用应用（若非文件夹，优先使用当前项）
            let baseURLForApps: URL? = {
                if let u = item.fileURL, !isDirectory(u) { return u }
                if case .link(let u) = item.kind { return u }
                return selectedOpenableURLs.first
            }()

            let openWithApps: [URL] = {
                guard let u = baseURLForApps else { return [] }
                if u.isFileURL {
                    var results = NSWorkspace.shared.urlsForApplications(toOpen: u)
                    if results.isEmpty, let uti = try? u.resourceValues(forKeys: [.contentTypeKey]).contentType {
                        results = NSWorkspace.shared.urlsForApplications(toOpen: uti)
                    }
                    return Array(Set(results))
                } else {
                    return Array(Set(NSWorkspace.shared.urlsForApplications(toOpen: u)))
                }
            }()
            let defaultApp = defaultAppURL()

            if openWithApps.isEmpty {
                let noApps = NSMenuItem(title: "No Compatible Apps Found", action: nil, keyEquivalent: "")
                noApps.isEnabled = false
                submenu.addItem(noApps)
            } else {
                if let defaultApp = defaultApp {
                    let appName = appDisplayName(for: defaultApp)
                    let def = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
                    def.representedObject = defaultApp
                    def.image = nsAppIcon(for: defaultApp, size: 16)

                    let title = NSMutableAttributedString(string: appName, attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: NSColor.labelColor
                    ])
                    let defaultPart = NSAttributedString(string: " (default)", attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ])
                    title.append(defaultPart)
                    def.attributedTitle = title
                    submenu.addItem(def)

                    if openWithApps.count > 1 || !openWithApps.contains(defaultApp) {
                        submenu.addItem(NSMenuItem.separator())
                    }
                }
                for appURL in openWithApps where appURL != defaultApp {
                    let mi = NSMenuItem(title: appDisplayName(for: appURL), action: nil, keyEquivalent: "")
                    mi.representedObject = appURL
                    mi.image = nsAppIcon(for: appURL, size: 16)
                    submenu.addItem(mi)
                }
            }

            submenu.addItem(NSMenuItem.separator())
            let other = NSMenuItem(title: "Other…", action: nil, keyEquivalent: "")
            other.representedObject = "__OTHER__"
            submenu.addItem(other)

            openWith.submenu = submenu
            menu.addItem(openWith)
        }

        if !selectedFileURLs.isEmpty { addMenuItem(title: "Show in Finder") }
        // 允许对文件和链接 URL 使用 Quick Look
        if !selectedFileURLs.isEmpty || !selectedLinkURLs.isEmpty {
            let localizedQL = String(localized: "Quick Look")
            // 添加 Quick Look 菜单项
            let quickLookItem = NSMenuItem(title: localizedQL, action: nil, keyEquivalent: "")
            menu.addItem(quickLookItem)
            
            // 添加幻灯片放映作为备选菜单项（按住 Option 键时显示）
            let slideshowItem = NSMenuItem(title: localizedQL, action: nil, keyEquivalent: "")
            slideshowItem.isAlternate = true
            slideshowItem.keyEquivalentModifierMask = [.option]
            menu.addItem(slideshowItem)
        }

        menu.addItem(NSMenuItem.separator())
        addMenuItem(title: "Share")
        
        // 为图片文件添加「图片操作」分组
        let imageURLs = selectedFileURLs.filter { ImageProcessingService.shared.isImageFile($0) }
        if !imageURLs.isEmpty {
            menu.addItem(NSMenuItem.separator())

            let imageActions = NSMenuItem(title: "Image Actions", action: nil, keyEquivalent: "")
            let imageSubmenu = NSMenu()

            // 移除背景 - 仅支持单张图片
            if imageURLs.count == 1 {
                let removeBg = NSMenuItem(title: "Remove Background", action: nil, keyEquivalent: "")
                imageSubmenu.addItem(removeBg)
            }

            // 转换图片 - 仅支持单张图片
            if imageURLs.count == 1 {
                let convertItem = NSMenuItem(title: "Convert Image…", action: nil, keyEquivalent: "")
                imageSubmenu.addItem(convertItem)
            }

            // 创建 PDF - 支持一张或多张图片
            let createPDF = NSMenuItem(title: "Create PDF", action: nil, keyEquivalent: "")
            imageSubmenu.addItem(createPDF)

            imageActions.submenu = imageSubmenu
            menu.addItem(imageActions)
            menu.addItem(NSMenuItem.separator())
        }

        // 为文件/文件夹添加压缩选项（支持单个或多个）
        if !selectedFileURLs.isEmpty {
            let compressItem = NSMenuItem(title: String(localized: "Compress"), action: nil, keyEquivalent: "")
            menu.addItem(compressItem)
        }

        if selectedItems.count == 1, case .file(_) = item.kind { addMenuItem(title: "Rename") }

        // 始终为所有项类型显示「复制」
        addMenuItem(title: "Copy")
        // 如果有文件 URL，则添加「复制路径」作为备选菜单项（Option 键）
        if !selectedFileURLs.isEmpty {
            let copyPathItem = NSMenuItem(title: String(localized: "Copy Path"), action: nil, keyEquivalent: "")
            copyPathItem.isAlternate = true
            copyPathItem.keyEquivalentModifierMask = [.option]
            menu.addItem(copyPathItem)
        }

        menu.addItem(NSMenuItem.separator())
        addMenuItem(title: "Remove")

        let actionTarget = MenuActionTarget(item: item, view: view, viewModel: self)

        for menuItem in menu.items {
            if menuItem.isSeparatorItem { continue }
            menuItem.target = actionTarget
            menuItem.action = #selector(MenuActionTarget.handle(_:))

            if let submenu = menuItem.submenu {
                for subItem in submenu.items {
                    if !subItem.isSeparatorItem {
                        subItem.target = actionTarget
                        subItem.action = #selector(MenuActionTarget.handle(_:))
                    }
                }
            }
        }
        
        menu.retainActionTarget(actionTarget)
        
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func isDirectory(_ url: URL) -> Bool {
        return url.accessSecurityScopedResource { scoped in
            (try? scoped.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
    }

    private final class MenuActionTarget: NSObject {
        let item: ShelfItem
        weak var view: NSView?
        unowned let viewModel: ShelfItemViewModel

        // 保留关联对象（如附属视图处理器），避免使用魔法字符串键
        private static var sliderHandlerAssoc = AssociatedObject<AnyObject>()

        init(item: ShelfItem, view: NSView, viewModel: ShelfItemViewModel) {
            self.item = item
            self.view = view
            self.viewModel = viewModel
        }

        @MainActor @objc func handle(_ sender: NSMenuItem) {
            let title = sender.title

            if let marker = sender.representedObject as? String, marker == "__OTHER__" {
                openWithPanel()
                return
            }

            if let appURL = sender.representedObject as? URL {
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                
                Task {
                        var allSelectedURLs: [URL] = []

                        for itm in selected {
                            if let fileURL = itm.fileURL {
                                allSelectedURLs.append(fileURL)
                            } else if case .link(let url) = itm.kind {
                                allSelectedURLs.append(url)
                            }
                        }

                        guard !allSelectedURLs.isEmpty else { return }

                        let config = NSWorkspace.OpenConfiguration()

                        let fileURLs = allSelectedURLs.filter { $0.isFileURL }
                        do {
                            if !fileURLs.isEmpty {
                                _ = try await fileURLs.accessSecurityScopedResources { _ in
                                    try await NSWorkspace.shared.open(allSelectedURLs, withApplicationAt: appURL, configuration: config)
                                }
                            } else {
                                try await NSWorkspace.shared.open(allSelectedURLs, withApplicationAt: appURL, configuration: config)
                            }
                        } catch {
                            print("❌ Failed to open with application: \(error.localizedDescription)")
                        }
                }
                return
            }

            switch title {
            case "Quick Look":
                // 对所有选中项执行 Quick Look，而非仅被点击的那一项
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                let urls: [URL] = selected.compactMap { item in
                    if let fileURL = item.fileURL {
                        return fileURL
                    }
                    if case .link(let url) = item.kind {
                        return url
                    }
                    return nil
                }
                if !urls.isEmpty {
                    viewModel.onQuickLookRequest?(urls)
                }

            case "Open":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                for it in selected { ShelfActionService.open(it) }

            case "Share":
                viewModel.shareItem(from: view)

            case "Rename":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                if selected.count == 1, let single = selected.first { showRenameDialog(for: single) }

            case "Show in Finder":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                Task {
                    let urls = await selected.asyncCompactMap { item -> URL? in
                        if case .file = item.kind {
                            // 用户主动触发的菜单操作，使用即时更新来刷新书签
                            return await ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item)
                        }
                        return nil
                    }
                    if !urls.isEmpty {
                        await urls.accessSecurityScopedResources { accessibleURLs in
                            NSWorkspace.shared.activateFileViewerSelecting(accessibleURLs)
                        }
                    }
                }

            case "Copy Path":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                let paths = selected.compactMap { $0.fileURL?.path }
                if !paths.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                }

            case "Copy":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                let pb = NSPasteboard.general
                
                // 停止访问之前复制的 URL
                for url in ShelfItemViewModel.copiedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
                ShelfItemViewModel.copiedURLs.removeAll()
                
                pb.clearContents()
                Task {
                    let fileURLs = await selected.asyncCompactMap { item -> URL? in
                        if case .file = item.kind {
                            return ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item)
                        }
                        return nil
                    }
                    if !fileURLs.isEmpty {
                        // 为所有 URL 开启安全作用域访问并保持激活
                        ShelfItemViewModel.copiedURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
                        NSLog("🔐 Started security-scoped access for \(ShelfItemViewModel.copiedURLs.count) copied files")
                        
                        // 写入剪贴板
                        pb.writeObjects(fileURLs as [NSURL])
                    } else {
                        let strings = selected.map { $0.displayName }
                        if !strings.isEmpty {
                            pb.setString(strings.joined(separator: "\n"), forType: .string)
                        }
                    }
                }

            case "Remove":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                for it in selected { ShelfActionService.remove(it) }
                
            case "Remove Background":
                handleRemoveBackground()
                
            case "Convert Image…":
                showConvertImageDialog()
                
            case "Create PDF":
                handleCreatePDF()
            
            case "Compress":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                let fileURLs = selected.compactMap { $0.fileURL }
                guard !fileURLs.isEmpty else { break }

                Task {
                    do {
                        // 在临时位置创建 ZIP，同时保持对所选资源的安全访问
                        if let zipTempURL = try await fileURLs.accessSecurityScopedResources(accessor: { urls in
                            await TemporaryFileStorageService.shared.createZip(from: urls)
                        }) {
                            if let bookmark = try? Bookmark(url: zipTempURL) {
                                let newItem = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                                ShelfStateViewModel.shared.add([newItem])
                            } else {
                                // 回退：在 Finder 中显示临时文件
                                NSWorkspace.shared.activateFileViewerSelecting([zipTempURL])
                            }
                        }
                    } catch {
                        print("❌ Compress failed: \(error)")
                    }
                }
                
            default:
                break
            }
        }

        @MainActor
        private func openWithPanel() {
            // 同时支持文件项和链接项
            let targetURL: URL?
            let needsSecurityScope: Bool
            
            if let fileURL = item.fileURL {
                targetURL = fileURL
                needsSecurityScope = true
            } else if case .link(let url) = item.kind {
                targetURL = url
                needsSecurityScope = false
            } else {
                targetURL = nil
                needsSecurityScope = false
            }
            guard let fileURL = targetURL else { return }

            let panel = NSOpenPanel()
            panel.title = "Choose Application"
            panel.message = "Choose an application to open the document \"\(item.displayName)\"."
            panel.prompt = "Open"
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.resolvesAliases = true
            if #available(macOS 12.0, *) {
                panel.allowedContentTypes = [.application]
            }
            panel.directoryURL = URL(fileURLWithPath: "/Applications")

            // 计算所选目标的推荐应用
            let recommendedApps: Set<URL> = {
                let apps: [URL]
                if let uti = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
                    apps = NSWorkspace.shared.urlsForApplications(toOpen: uti)
                } else {
                    apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
                }
                return Set(apps.map { $0.standardizedFileURL })
            }()

            // 委托用于在「推荐应用」模式下过滤条目
            final class AppChooserDelegate: NSObject, NSOpenSavePanelDelegate {
                enum Mode { case recommended, all }
                var mode: Mode = .recommended
                let recommended: Set<URL>
                init(recommended: Set<URL>) { self.recommended = recommended }
                
                func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
                    let ext = url.pathExtension.lowercased()
                    if ext == "app" {
                        switch mode {
                        case .all:
                            return true
                        case .recommended:
                            // 标准化 URL 以便可靠比较
                            let std = url.standardizedFileURL
                            return recommended.contains(std)
                        }
                    }

                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        return true
                    }
                    
                    return false
                }
            }

            let chooserDelegate = AppChooserDelegate(recommended: recommendedApps)
            panel.delegate = chooserDelegate

            let enableLabel = NSTextField(labelWithString: "Enable:")
            enableLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
            enableLabel.alignment = .natural
            enableLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ["Recommended Applications", "All Applications"])
            popup.font = .systemFont(ofSize: NSFont.systemFontSize)
            popup.selectItem(at: 0)
            
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            
            let alwaysCheckbox = NSButton(checkboxWithTitle: "Always Open With", target: nil, action: nil)
            alwaysCheckbox.font = .systemFont(ofSize: NSFont.systemFontSize)
            alwaysCheckbox.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [enableLabel, popup])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            row.distribution = .fill
            
            let column = NSStackView(views: [row, alwaysCheckbox])
            column.orientation = .vertical
            column.spacing = 12
            column.alignment = .centerX
            column.distribution = .fill
            column.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
            
            panel.accessoryView = column
            panel.isAccessoryViewDisclosed = true

            // 连接弹出菜单以切换过滤模式
            class PopupBinder: NSObject {
                weak var popup: NSPopUpButton?
                weak var chooserDelegate: AppChooserDelegate?
                weak var panel: NSOpenPanel?
                init(popup: NSPopUpButton, chooserDelegate: AppChooserDelegate, panel: NSOpenPanel) {
                    self.popup = popup
                    self.chooserDelegate = chooserDelegate
                    self.panel = panel
                }
                @objc func changed(_ sender: Any?) {
                    if popup?.indexOfSelectedItem == 1 {
                        chooserDelegate?.mode = .all
                    } else {
                        chooserDelegate?.mode = .recommended
                    }
                    if let panel = panel {
                        panel.validateVisibleColumns()
                        let currentDir = panel.directoryURL
                        panel.directoryURL = currentDir
                    }
                }
            }
            let binder = PopupBinder(popup: popup, chooserDelegate: chooserDelegate, panel: panel)
            popup.target = binder
            popup.action = #selector(PopupBinder.changed(_:))

            panel.begin { response in
                if response == .OK, let appURL = panel.url {
                    Task {
                        do {
                            let config = NSWorkspace.OpenConfiguration()
                            if alwaysCheckbox.state == .on, let bundleID = Bundle(url: appURL)?.bundleIdentifier {
                                if let contentType = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
                                    let status = LSSetDefaultRoleHandlerForContentType(contentType.identifier as CFString, LSRolesMask.all, bundleID as CFString)
                                    if status != noErr { print("⚠️ Failed to set default handler for \(contentType.identifier): \(status)") }
                                } else if let scheme = fileURL.scheme {
                                    let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
                                    if status != noErr { print("⚠️ Failed to set default handler for scheme \(scheme): \(status)") }
                                }
                            }

                            if needsSecurityScope {
                                _ = try await fileURL.accessSecurityScopedResource { accessibleURL in
                                    try await NSWorkspace.shared.open([accessibleURL], withApplicationAt: appURL, configuration: config)
                                }
                            } else {
                                try await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config)
                            }
                        } catch {
                            print("❌ Failed to open with application: \(error.localizedDescription)")
                        }
                    }
                }
                // 保持 binder/delegate 存活直到面板结束
                _ = binder
                _ = chooserDelegate
            }
        }
        
        @MainActor
        private func showRenameDialog(for item: ShelfItem) {
            guard case let .file(bookmarkData) = item.kind else { return }
            Task {
                let bookmark = Bookmark(data: bookmarkData)
                if let fileURL = bookmark.resolveURL() {
                    // 开启安全作用域访问，并保持激活直到重命名完成。
                    let didStart = fileURL.startAccessingSecurityScopedResource()

                    let savePanel = NSSavePanel()
                    savePanel.title = "Rename File"
                    savePanel.prompt = "Rename"
                    savePanel.nameFieldStringValue = fileURL.lastPathComponent
                    savePanel.directoryURL = fileURL.deletingLastPathComponent()
                    savePanel.begin { response in
                        if response == .OK, let newURL = savePanel.url {
                            Task {
                                do {
                                    NSLog("🔐 Rename: moving from \(fileURL.path) to \(newURL.path) (securityScope=\(didStart))")

                                    try FileManager.default.moveItem(at: fileURL, to: newURL)

                                    if let newBookmark = try? Bookmark(url: newURL) {
                                        ShelfStateViewModel.shared.updateBookmark(for: item, bookmark: newBookmark.data)
                                    }
                                } catch {
                                    print("❌ Failed to rename file: \(error.localizedDescription)")
                                }
                                if didStart { fileURL.stopAccessingSecurityScopedResource() }
                            }
                        } else {
                            if didStart { fileURL.stopAccessingSecurityScopedResource() }
                        }
                    }
                }
            }
        }
        
        @MainActor
        private func handleRemoveBackground() {
            let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            let imageURLs = selected.compactMap { $0.fileURL }.filter { ImageProcessingService.shared.isImageFile($0) }
            
            guard let imageURL = imageURLs.first else { return }
            
            Task {
                do {
                    let resultURL = try await imageURL.accessSecurityScopedResource { url in
                        try await ImageProcessingService.shared.removeBackground(from: url)
                    }
                    
                    if let resultURL = resultURL {
                        // 创建书签并作为临时项添加到货架
                        if let bookmark = try? Bookmark(url: resultURL) {
                            let newItem = ShelfItem(
                                kind: .file(bookmark: bookmark.data),
                                isTemporary: true
                            )
                            ShelfStateViewModel.shared.add([newItem])
                        }
                    }
                } catch {
                    print("❌ Failed to remove background: \(error.localizedDescription)")
                    await showErrorAlert(title: "Background Removal Failed", message: error.localizedDescription)
                }
            }
        }
        
        @MainActor
        private func handleCreatePDF() {
            let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            let imageURLs = selected.compactMap { $0.fileURL }.filter { ImageProcessingService.shared.isImageFile($0) }
            
            guard !imageURLs.isEmpty else { return }
            
            Task {
                do {
                    let resultURL = try await imageURLs.accessSecurityScopedResources { urls in
                        try await ImageProcessingService.shared.createPDF(from: urls)
                    }
                    
                    if let resultURL = resultURL {
                        // 创建书签并作为临时项添加到货架
                        if let bookmark = try? Bookmark(url: resultURL) {
                            let newItem = ShelfItem(
                                kind: .file(bookmark: bookmark.data),
                                isTemporary: true
                            )
                            ShelfStateViewModel.shared.add([newItem])
                        }
                    }
                } catch {
                    print("❌ Failed to create PDF: \(error.localizedDescription)")
                    await showErrorAlert(title: "PDF Creation Failed", message: error.localizedDescription)
                }
            }
        }
        
        @MainActor
        private func showConvertImageDialog() {
            let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            let imageURLs = selected.compactMap { $0.fileURL }.filter { ImageProcessingService.shared.isImageFile($0) }
            
            guard let imageURL = imageURLs.first else { return }
            
            // 创建并显示布局更优的转换选项对话框
            let alert = NSAlert()
            alert.messageText = "Convert Image"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Convert")
            alert.addButton(withTitle: "Cancel")
            
            // 创建附属视图，具有更好的间距与组织
            let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
            accessoryView.wantsLayer = true
            
            // MARK: 格式行
            let formatLabel = NSTextField(labelWithString: "Format:")
            formatLabel.frame = NSRect(x: 0, y: 145, width: 100, height: 20)
            formatLabel.font = .systemFont(ofSize: 12, weight: .medium)
            accessoryView.addSubview(formatLabel)
            
            let formatPopup = NSPopUpButton(frame: NSRect(x: 120, y: 140, width: 250, height: 28))
            formatPopup.addItems(withTitles: ["PNG", "JPEG", "HEIC", "TIFF", "BMP"])
            formatPopup.selectItem(at: 0)
            formatPopup.font = .systemFont(ofSize: 12)
            accessoryView.addSubview(formatPopup)
            
            // MARK: 图片尺寸行
            let imageSizeLabel = NSTextField(labelWithString: "Image Size:")
            imageSizeLabel.frame = NSRect(x: 0, y: 105, width: 100, height: 20)
            imageSizeLabel.font = .systemFont(ofSize: 12, weight: .medium)
            accessoryView.addSubview(imageSizeLabel)
            
            let imageSizePopup = NSPopUpButton(frame: NSRect(x: 120, y: 100, width: 160, height: 28))
            imageSizePopup.addItems(withTitles: ["Actual Size", "Large", "Medium", "Small", "Custom..."])
            imageSizePopup.selectItem(at: 0)
            imageSizePopup.font = .systemFont(ofSize: 12)
            accessoryView.addSubview(imageSizePopup)
            
            // 自定义尺寸输入框（初始隐藏）
            let customSizeField = NSTextField(frame: NSRect(x: 285, y: 103, width: 85, height: 22))
            customSizeField.placeholderString = "e.g., 1920"
            customSizeField.font = .systemFont(ofSize: 12)
            customSizeField.isHidden = true
            accessoryView.addSubview(customSizeField)
            
            // MARK: 保留元数据复选框
            let metadataCheckbox = NSButton(checkboxWithTitle: "Preserve Metadata", target: nil, action: nil)
            metadataCheckbox.frame = NSRect(x: 120, y: 65, width: 200, height: 20)
            metadataCheckbox.font = .systemFont(ofSize: 12)
            metadataCheckbox.state = .on
            accessoryView.addSubview(metadataCheckbox)
            
            // MARK: 分隔线
            let separatorLine = NSView(frame: NSRect(x: 0, y: 50, width: 380, height: 1))
            separatorLine.wantsLayer = true
            separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
            accessoryView.addSubview(separatorLine)
            
            // MARK: 格式相关选项（根据所选格式显示/隐藏）
            let qualityRow = NSView(frame: NSRect(x: 0, y: 15, width: 380, height: 30))
            qualityRow.wantsLayer = true
            
            let qualityLabel = NSTextField(labelWithString: "Compression:")
            qualityLabel.frame = NSRect(x: 0, y: 7, width: 100, height: 20)
            qualityLabel.font = .systemFont(ofSize: 12, weight: .medium)
            qualityRow.addSubview(qualityLabel)
            
            let qualitySlider = NSSlider(frame: NSRect(x: 120, y: 12, width: 200, height: 20))
            qualitySlider.minValue = 0.0
            qualitySlider.maxValue = 1.0
            qualitySlider.doubleValue = 0.85
            accessoryView.addSubview(qualitySlider)
            
            let qualityValueLabel = NSTextField(labelWithString: "85%")
            qualityValueLabel.frame = NSRect(x: 325, y: 7, width: 55, height: 20)
            qualityValueLabel.font = .systemFont(ofSize: 12)
            qualityValueLabel.alignment = .left
            accessoryView.addSubview(qualityValueLabel)
            
            // 根据格式更新质量标签并显示/隐藏压缩行
            let updateQualityLabel = {
                let value = Int(qualitySlider.doubleValue * 100)
                qualityValueLabel.stringValue = "\(value)%"
            }
            
            let updateCompressionVisibility = {
                let formatIndex = formatPopup.indexOfSelectedItem
                let showCompression = formatIndex == 1 || formatIndex == 2 // JPEG 或 HEIC
                qualitySlider.isHidden = !showCompression
                qualityValueLabel.isHidden = !showCompression
                qualityLabel.isHidden = !showCompression
            }
            
            let updateCustomSizeVisibility = {
                let sizeIndex = imageSizePopup.indexOfSelectedItem
                customSizeField.isHidden = sizeIndex != 4 // 仅在选择「自定义...」时显示
            }
            
            // 创建目标对象以处理滑块值变化
            class SliderHandler: NSObject {
                let updateLabel: () -> Void
                let updateVisibility: () -> Void
                let updateCustomSize: () -> Void
                init(updateLabel: @escaping () -> Void, updateVisibility: @escaping () -> Void, updateCustomSize: @escaping () -> Void) {
                    self.updateLabel = updateLabel
                    self.updateVisibility = updateVisibility
                    self.updateCustomSize = updateCustomSize
                }
                @objc func sliderChanged(_ sender: NSSlider) {
                    updateLabel()
                }
                @objc func formatChanged(_ sender: NSPopUpButton) {
                    updateVisibility()
                }
                @objc func sizeChanged(_ sender: NSPopUpButton) {
                    updateCustomSize()
                }
            }
            
            let handler = SliderHandler(updateLabel: updateQualityLabel, updateVisibility: updateCompressionVisibility, updateCustomSize: updateCustomSizeVisibility)
            qualitySlider.target = handler
            qualitySlider.action = #selector(SliderHandler.sliderChanged(_:))
            qualitySlider.isContinuous = true
            
            formatPopup.target = handler
            formatPopup.action = #selector(SliderHandler.formatChanged(_:))
            
            imageSizePopup.target = handler
            imageSizePopup.action = #selector(SliderHandler.sizeChanged(_:))
            
            updateCompressionVisibility()
            updateQualityLabel()
            updateCustomSizeVisibility()
            
            // 使用 `AssociatedObject` 辅助对象保持 handler 存活，而非魔法字符串键
            MenuActionTarget.sliderHandlerAssoc[accessoryView] = handler
            
            alert.accessoryView = accessoryView
            
            let response = alert.runModal()
            
            if response == .alertFirstButtonReturn {
                // 获取所选选项
                let formatIndex = formatPopup.indexOfSelectedItem
                let format: ImageConversionOptions.ImageFormat
                switch formatIndex {
                case 0: format = .png
                case 1: format = .jpeg
                case 2: format = .heic
                case 3: format = .tiff
                case 4: format = .bmp
                default: format = .png
                }
                
                let quality = qualitySlider.doubleValue
                
                // 根据图片尺寸选择获取最大尺寸
                let maxDimension: CGFloat? = {
                    let sizeIndex = imageSizePopup.indexOfSelectedItem
                    switch sizeIndex {
                    case 0: return nil // 实际尺寸
                    case 1: return 1280 // 大
                    case 2: return 640  // 中
                    case 3: return 320  // 小
                    case 4: // 自定义（用户指定）
                        let text = customSizeField.stringValue.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty, let value = Double(text), value > 0 else { return nil }
                        return CGFloat(value)
                    default: return nil
                    }
                }()
                
                let removeMetadata = metadataCheckbox.state == .off // 注意：这里做了取反
                
                let options = ImageConversionOptions(
                    format: format,
                    compressionQuality: quality,
                    maxDimension: maxDimension,
                    removeMetadata: removeMetadata
                )
                
                Task {
                    do {
                        let resultURL = try await imageURL.accessSecurityScopedResource { url in
                            try await ImageProcessingService.shared.convertImage(from: url, options: options)
                        }
                        
                        if let resultURL = resultURL {
                            // 创建书签并作为临时项添加到货架
                            if let bookmark = try? Bookmark(url: resultURL) {
                                let newItem = ShelfItem(
                                    kind: .file(bookmark: bookmark.data),
                                    isTemporary: true
                                )
                                ShelfStateViewModel.shared.add([newItem])
                            }
                        }
                    } catch {
                        print("❌ Failed to convert image: \(error.localizedDescription)")
                        showErrorAlert(title: "Image Conversion Failed", message: error.localizedDescription)
                    }
                }
            }
        }
        
        @MainActor
        private func showErrorAlert(title: String, message: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - 私有辅助方法
    private func appDisplayName(for appURL: URL) -> String {
        (try? appURL.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? appURL.lastPathComponent
    }

    private func nsAppIcon(for appURL: URL, size: CGFloat) -> NSImage? {
        let baseIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        baseIcon.isTemplate = false

        let targetSize = NSSize(width: size, height: size)
        let rendered = NSImage(size: targetSize, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            baseIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: [
                .interpolation: NSImageInterpolation.high.rawValue
            ])
            return true
        }

        rendered.size = targetSize
        return rendered
    }

    private func defaultAppURL() -> URL? {
        if let fileURL = item.fileURL {
            return NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        } else if case .link(let url) = item.kind {
            return NSWorkspace.shared.urlForApplication(toOpen: url)
        }
        return nil
    }
}

fileprivate extension Sequence {
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var result: [T] = []
        for element in self {
            if let transformed = await transform(element) {
                result.append(transformed)
            }
        }
        return result
    }
}
