//
//  ImageProcessingService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-16.
//

import Foundation
import AppKit
import CoreImage
import CoreGraphics
import Vision
import PDFKit
import UniformTypeIdentifiers
import ImageIO

/// 图片转换选项
struct ImageConversionOptions {
    enum ImageFormat {
        case png, jpeg, heic, tiff, bmp
        
        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .tiff: return .tiff
            case .bmp: return .bmp
            }
        }
        
        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .tiff: return "tiff"
            case .bmp: return "bmp"
            }
        }
    }
    
    let format: ImageFormat
    let compressionQuality: Double // 0.0 到 1.0，仅对 JPEG/HEIC 生效
    let maxDimension: CGFloat? // 最大宽度或高度，nil 表示不缩放
    let removeMetadata: Bool
}

/// 图片处理服务（背景移除、格式转换、PDF 生成）
@MainActor
final class ImageProcessingService {
    static let shared = ImageProcessingService()
    
    private init() {}
    private let ciContext = CIContext(options: nil)
    
    // MARK: - 移除背景
    
    /// 使用 Vision 框架移除图片背景
    func removeBackground(from url: URL) async throws -> URL? {
        guard let inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }
        
        guard let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageProcessingError.invalidImage
        }
        
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        
        try handler.perform([request])
        
        guard let result = request.results?.first else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        
        let output = try await applyMask(mask, to: cgImage)
        
        let processedImage = NSImage(cgImage: output, size: inputImage.size)
        
        // 创建临时文件
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_no_bg.png"
        
        guard let pngData = processedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: pngData),
              let finalData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageProcessingError.saveFailed
        }
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(finalData, suggestedName: newName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    private func applyMask(_ mask: CVPixelBuffer, to image: CGImage) async throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: mask)
        
        let filter = CIFilter.blendWithMask()
        filter.inputImage = ciImage
        filter.maskImage = maskImage
        filter.backgroundImage = CIImage.empty()
        
        guard let output = filter.outputImage else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        let context = CIContext()
        guard let result = context.createCGImage(output, from: output.extent) else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        return result
    }
    
    // MARK: - 转换图片
    
    /// 按指定选项转换图片格式
    func convertImage(from url: URL, options: ImageConversionOptions) async throws -> URL? {
        guard var inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }
        
        // 如需缩放，先按最大尺寸缩放
        if let maxDim = options.maxDimension {
            inputImage = scaleImage(inputImage, maxDimension: maxDim)
        }
        
        // 根据目标格式获取图片数据
        let imageData: Data?
        
        if options.removeMetadata {
            // 创建不含元数据的新图片
            guard let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ImageProcessingError.invalidImage
            }
            
            let newImage = NSImage(cgImage: cgImage, size: inputImage.size)
            imageData = try convertToFormat(newImage, format: options.format, quality: options.compressionQuality)
        } else {
            imageData = try convertToFormat(inputImage, format: options.format, quality: options.compressionQuality)
        }
        
        guard let data = imageData else {
            throw ImageProcessingError.conversionFailed
        }
        
        // 创建临时文件
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_converted.\(options.format.fileExtension)"
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(data, suggestedName: newName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    private func convertToFormat(_ image: NSImage, format: ImageConversionOptions.ImageFormat, quality: Double) throws -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        switch format {
        case .png:
            return bitmap.representation(using: .png, properties: [:])
        case .jpeg:
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionFactor: quality
            ]
            return bitmap.representation(using: .jpeg, properties: properties)
        case .tiff:
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)
            ]
            return bitmap.representation(using: .tiff, properties: properties)
        case .bmp:
            return bitmap.representation(using: .bmp, properties: [:])
        case .heic:
            // HEIC 格式需借助 CIContext 编码
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let ciImage = CIImage(cgImage: cgImage)
            let context = CIContext()
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ]
            return try? context.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: options)
        }
    }
    
    private func scaleImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        guard maxDimension > 0 else { return image }

        guard let srcCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let srcMax = max(srcCG.width, srcCG.height)
        if CGFloat(srcMax) <= maxDimension {
            return image // 无需缩小
        }

        let scale = maxDimension / CGFloat(srcMax)

        let ciImage = CIImage(cgImage: srcCG)
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = ciImage
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1.0

        guard let output = lanczos.outputImage else {
            return image
        }

        // 保留源色彩空间以保证颜色精确匹配
        let colorSpace = srcCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = CIContext(options: [.workingColorSpace: colorSpace])

        // 使用匹配的色彩空间通过 CIContext 渲染
        guard let dstCG = ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return image
        }

        return NSImage(cgImage: dstCG, size: NSSize(width: dstCG.width, height: dstCG.height))
    }
    
    // MARK: - 创建 PDF
    
    /// 由多张图片 URL 生成一份 PDF
    func createPDF(from imageURLs: [URL], outputName: String? = nil) async throws -> URL? {
        guard !imageURLs.isEmpty else {
            throw ImageProcessingError.noImagesProvided
        }
        
        let pdfDocument = PDFDocument()
        
        for (index, url) in imageURLs.enumerated() {
            guard let image = NSImage(contentsOf: url) else {
                continue
            }
            
            let pdfPage = PDFPage(image: image)
            if let page = pdfPage {
                pdfDocument.insert(page, at: index)
            }
        }
        
        guard pdfDocument.pageCount > 0 else {
            throw ImageProcessingError.pdfCreationFailed
        }
        
        // 创建临时文件
        let name = outputName ?? "images_\(Date().timeIntervalSince1970).pdf"
        let pdfName = name.hasSuffix(".pdf") ? name : "\(name).pdf"
        
        guard let pdfData = pdfDocument.dataRepresentation() else {
            throw ImageProcessingError.pdfCreationFailed
        }
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(pdfData, suggestedName: pdfName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    // MARK: - 辅助方法
    
    /// 检查某个 URL 是否为图片文件
    func isImageFile(_ url: URL) -> Bool {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return contentType.conforms(to: .image)
    }
}

// MARK: - 错误类型

enum ImageProcessingError: LocalizedError {
    case invalidImage
    case backgroundRemovalFailed
    case conversionFailed
    case pdfCreationFailed
    case noImagesProvided
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The file is not a valid image"
        case .backgroundRemovalFailed:
            return "Failed to remove background from image"
        case .conversionFailed:
            return "Failed to convert image format"
        case .pdfCreationFailed:
            return "Failed to create PDF from images"
        case .noImagesProvided:
            return "No images were provided"
        case .saveFailed:
            return "Failed to save processed file"
        }
    }
}
