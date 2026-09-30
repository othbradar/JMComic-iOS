import CommonCrypto
import CryptoKit
import Foundation
import ImageIO
import UIKit

enum JMCrypto {
    static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }

    static func signedHeaders(timestamp: String, version: String, contentRequest: Bool = false) -> [String: String] {
        let secret = contentRequest
            ? JMServiceProtocol.Signing.contentTokenSecret
            : JMServiceProtocol.Signing.tokenSecret
        return [
            JMServiceProtocol.Signing.tokenParameterHeader: "\(timestamp),\(version)",
            JMServiceProtocol.Signing.tokenHeader: md5(timestamp + secret),
            JMServiceProtocol.Signing.acceptEncodingHeader: JMServiceProtocol.Signing.acceptedEncoding,
            JMServiceProtocol.Signing.versionHeader: JMServiceProtocol.Signing.protocolVersion
        ]
    }

    static func decryptResponse(
        _ encoded: String,
        timestamp: String,
        secret: String = JMServiceProtocol.Signing.responseSecret
    ) throws -> Data {
        guard let encrypted = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CryptoError.invalidBase64
        }
        let key = Data(md5(timestamp + secret).utf8)
        let outputCapacity = encrypted.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            encrypted.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        key.count,
                        nil,
                        inputBuffer.baseAddress,
                        encrypted.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.decryptFailed(status) }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    enum CryptoError: LocalizedError {
        case invalidBase64
        case decryptFailed(CCCryptorStatus)

        var errorDescription: String? {
            switch self {
            case .invalidBase64: return "服务端返回了无效的加密数据"
            case .decryptFailed(let status): return "响应解密失败（\(status)）"
            }
        }
    }
}

enum ImageScrambler {
    struct EncodedPage: Sendable {
        let data: Data
        let fileExtension: String
    }

    static func segmentationCount(scrambleID: Int, photoID: Int, filename: String) -> Int {
        guard photoID >= scrambleID else { return 0 }
        guard let last = JMCrypto.md5("\(photoID)\(filename)").utf8.last else { return 0 }
        return JMServiceProtocol.ImageScrambling.segmentCount(
            photoID: photoID,
            digestLastByte: last
        )
    }

    static func decode(
        _ data: Data,
        scrambleID: Int,
        photoID: String,
        filename: String,
        processing: PageImageProcessing = .faithful,
        storage: PageImageStorage = .lossless
    ) throws -> EncodedPage {
        let count = segmentationCount(
            scrambleID: scrambleID,
            photoID: Int(photoID) ?? 0,
            filename: (filename as NSString).deletingPathExtension
        )
        let result = try decodeImage(
            data,
            scrambleID: scrambleID,
            photoID: photoID,
            filename: filename,
            processing: processing
        )
        // Validate/decode with the same ImageIO path used by the reader, then
        // keep supported original bytes when no pixel processing is needed.
        if count == 0, storage == .lossless,
           let fileExtension = originalFileExtension(data) {
            return EncodedPage(data: data, fileExtension: fileExtension)
        }
        let useJPEG = storage == .spaceSavingJPEG && !hasAlpha(result.cgImage)
        let encoded = useJPEG ? result.jpegData(compressionQuality: 0.96) : result.pngData()
        guard let encoded else {
            throw ImageError.encodeFailed
        }
        return EncodedPage(data: encoded, fileExtension: useJPEG ? "jpg" : "png")
    }

    /// 阅读器直接使用解扰后的像素图，避免先 JPEG 编码、随后又解码的两次 CPU 和内存峰值。
    static func decodeImage(
        _ data: Data,
        scrambleID: Int,
        photoID: String,
        filename: String,
        processing: PageImageProcessing = .faithful
    ) throws -> UIImage {
        let source = try rasterImage(from: data)
        guard let cgImage = source.cgImage else { throw ImageError.invalidImage }
        let count = segmentationCount(
            scrambleID: scrambleID,
            photoID: Int(photoID) ?? 0,
            filename: (filename as NSString).deletingPathExtension
        )
        guard count > 0 else { return source }

        return try decodeScrambledPixels(
            cgImage,
            segmentationCount: count,
            repairLossySeams: processing == .repairChroma && isLossyEncodedImage(data)
        )
    }

    /// Reverse complete scanlines without resampling. The optional legacy
    /// chroma interpolation can also alter legitimate coloured details: codec
    /// and dimensions are eligibility checks, not evidence of a damaged seam.
    private static func decodeScrambledPixels(
        _ source: CGImage,
        segmentationCount count: Int,
        repairLossySeams: Bool
    ) throws -> UIImage {
        let width = source.width
        let height = source.height
        guard width > 0, height > 0, count > 1 else {
            return UIImage(cgImage: source, scale: 1, orientation: .up)
        }

        let baseHeight = height / count
        let remainder = height % count

        let bytesPerPixel = 4
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        let (byteCount, imageOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !imageOverflow, byteCount > 0 else { throw ImageError.invalidImage }

        var pixels = Data(count: byteCount)
        var rowScratch = Data(count: bytesPerRow)
        let output: CGImage? = pixels.withUnsafeMutableBytes { pixelBytes in
            guard let baseAddress = pixelBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: source.colorSpace?.model == .rgb
                        ? source.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | (hasAlpha(source) ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
                  ) else { return nil }

            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.setAllowsAntialiasing(false)
            // Drawing a CGImage directly into a raw bitmap preserves its
            // provider's top-to-bottom scanline order.  Applying UIKit's usual
            // coordinate flip here would invert the page before descrambling.
            context.draw(source, in: bounds)

            rowScratch.withUnsafeMutableBytes { scratchBytes in
                guard let scratch = scratchBytes.baseAddress else { return }
                // Reverse all rows and then each reversed block.  This reverses
                // block order in-place while preserving the row order inside it,
                // including the taller remainder block.
                reverseRows(
                    baseAddress: baseAddress,
                    range: 0..<height,
                    bytesPerRow: bytesPerRow,
                    scratch: scratch
                )
                var blockStart = 0
                for blockIndex in 0..<count {
                    let blockHeight = baseHeight + (blockIndex == 0 ? remainder : 0)
                    reverseRows(
                        baseAddress: baseAddress,
                        range: blockStart..<(blockStart + blockHeight),
                        bytesPerRow: bytesPerRow,
                        scratch: scratch
                    )
                    blockStart += blockHeight
                }
            }

            // Four repaired rows need one untouched anchor on either side.
            // Tiny but otherwise valid images must still be descrambled; only
            // the optional seam repair is skipped when no safe anchors exist.
            if repairLossySeams, baseHeight >= 6 {
                repairChromaSeams(
                    baseAddress: baseAddress,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    segmentationCount: count,
                    baseHeight: baseHeight,
                    remainder: remainder,
                    hasAlpha: hasAlpha(source)
                )
            }
            return context.makeImage()
        }

        guard let output else { throw ImageError.invalidImage }
        return UIImage(cgImage: output, scale: 1, orientation: .up)
    }

    private static func reverseRows(
        baseAddress: UnsafeMutableRawPointer,
        range: Range<Int>,
        bytesPerRow: Int,
        scratch: UnsafeMutableRawPointer
    ) {
        var first = range.lowerBound
        var last = range.upperBound - 1
        while first < last {
            let firstRow = baseAddress.advanced(by: first * bytesPerRow)
            let lastRow = baseAddress.advanced(by: last * bytesPerRow)
            scratch.copyMemory(from: firstRow, byteCount: bytesPerRow)
            firstRow.copyMemory(from: lastRow, byteCount: bytesPerRow)
            lastRow.copyMemory(from: scratch, byteCount: bytesPerRow)
            first += 1
            last -= 1
        }
    }

    /// Radius two: anchors are join-3 and join+2, repaired rows are join-2...
    /// join+1.  RGB interpolation supplies clean chroma; adding a common delta
    /// to R/G/B restores the original BT.601 luminance because its coefficients
    /// sum to one.  Alpha/skip bytes are deliberately untouched.
    private static func repairChromaSeams(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        segmentationCount count: Int,
        baseHeight: Int,
        remainder: Int,
        hasAlpha: Bool
    ) {
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let anchorDistance = 5
        for index in 1..<count {
            let join = baseHeight * index + remainder
            let topY = join - 3
            let bottomY = join + 2
            guard topY >= 0, bottomY < height else { continue }

            let top = bytes.advanced(by: topY * bytesPerRow)
            let bottom = bytes.advanced(by: bottomY * bytesPerRow)
            for rowOffset in 1..<anchorDistance {
                let targetY = topY + rowOffset
                let target = bytes.advanced(by: targetY * bytesPerRow)
                let topWeight = Double(anchorDistance - rowOffset) / Double(anchorDistance)
                let bottomWeight = Double(rowOffset) / Double(anchorDistance)

                for x in 0..<width {
                    let offset = x * 4
                    // Interpolation expects opaque RGB; do not reconstruct
                    // premultiplied colours across a transparency boundary.
                    if hasAlpha, top[offset + 3] != 255 || bottom[offset + 3] != 255 || target[offset + 3] != 255 {
                        continue
                    }
                    let originalR = Double(target[offset])
                    let originalG = Double(target[offset + 1])
                    let originalB = Double(target[offset + 2])
                    let expectedR = Double(top[offset]) * topWeight
                        + Double(bottom[offset]) * bottomWeight
                    let expectedG = Double(top[offset + 1]) * topWeight
                        + Double(bottom[offset + 1]) * bottomWeight
                    let expectedB = Double(top[offset + 2]) * topWeight
                        + Double(bottom[offset + 2]) * bottomWeight
                    let originalY = originalR * 0.299 + originalG * 0.587 + originalB * 0.114
                    let expectedY = expectedR * 0.299 + expectedG * 0.587 + expectedB * 0.114
                    let luminanceDelta = originalY - expectedY

                    target[offset] = clampedByte(expectedR + luminanceDelta)
                    target[offset + 1] = clampedByte(expectedG + luminanceDelta)
                    target[offset + 2] = clampedByte(expectedB + luminanceDelta)
                }
            }
        }
    }

    private static func clampedByte(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, Int(value.rounded()))))
    }

    private static func hasAlpha(_ image: CGImage?) -> Bool {
        guard let image else { return false }
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
        default: return false
        }
    }

    private static func originalFileExtension(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        switch type {
        case "public.jpeg": return "jpg"
        case "public.png": return "png"
        case "org.webmproject.webp": return "webp"
        default: return nil // Other readable sources are stored as PNG.
        }
    }

    /// Lossless containers do not have cross-strip codec pollution and should
    /// remain byte-for-byte sharp. When explicitly enabled, limit repair to the two lossy page
    /// codecs observed from JM's CDN: JPEG and VP8 WebP.  Unknown formats stay
    /// untouched instead of risking a needless four-row colour modification.
    private static func isLossyEncodedImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(64))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return false
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return false }
        if bytes.starts(with: [0x42, 0x4D]) { return false }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return false
        }
        if bytes.count >= 16,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            var offset = 12
            while offset + 8 <= data.count {
                let fourCC = String(data: data[offset..<(offset + 4)], encoding: .ascii)
                if fourCC == "VP8L" { return false }
                if fourCC == "VP8 " { return true }
                let size = Int(data[offset + 4])
                    | (Int(data[offset + 5]) << 8)
                    | (Int(data[offset + 6]) << 16)
                    | (Int(data[offset + 7]) << 24)
                guard size >= 0, offset <= Int.max - 8 - size else { break }
                offset += 8 + size + (size & 1)
            }
            return false
        }
        return false
    }

    /// 强制在当前（后台）任务解码像素，避免 UIImage 在首次绘制时卡住主线程。
    static func rasterImage(from data: Data) throws -> UIImage {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw ImageError.invalidImage
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    enum ImageError: LocalizedError {
        case invalidImage
        case encodeFailed
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "图片数据损坏"
            case .encodeFailed: return "图片还原失败"
            }
        }
    }
}
