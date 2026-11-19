import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Output format for re-encoding regular (non-RAW) photos.
enum ImageFormat: String {
  case jpeg, heic, png

  var type: UTType {
    switch self {
    case .jpeg: return .jpeg
    case .heic: return .heic
    case .png: return .png
    }
  }

  /// Extension for the saved file, upper case like the iPhone camera ("IMG_0001.HEIC").
  var fileExtension: String {
    switch self {
    case .jpeg: return "JPG"
    case .heic: return "HEIC"
    case .png: return "PNG"
    }
  }

  /// Same-format output for a source file extension; formats iOS cannot write fall back to JPEG.
  static func matching(extension ext: String) -> ImageFormat {
    switch ext.lowercased() {
    case "heic", "heif", "hif": return .heic
    case "png": return .png
    default: return .jpeg
    }
  }

  /// "jpeg" / "heic" / "png", or "same" -> format of the source file.
  static func parse(_ name: String?, sourceExtension ext: String) -> ImageFormat {
    if let name, let f = ImageFormat(rawValue: name) { return f }
    return matching(extension: ext)
  }
}

/// Re-encodes any ImageIO-readable photo (JPEG, HEIC, PNG, …): orientation is applied to the
/// pixels, long side is limited to `maxSide` (0 = original, never upscaled), and EXIF/GPS/TIFF/IPTC
/// metadata is kept.
enum ImageEncoder {
  @discardableResult
  static func encode(
    source: URL, to dest: URL, format: ImageFormat, quality: Int, maxSide: Int
  ) throws -> Int {
    guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
      CGImageSourceGetCount(src) > 0
    else { throw RawJpegEncoder.EncodeError("File foto tidak bisa dibaca") }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
    let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
    let long = max(w, h)
    guard long > 0 else { throw RawJpegEncoder.EncodeError("Ukuran foto tidak diketahui") }

    let target = maxSide > 0 && long > maxSide ? maxSide : long
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,  // apply EXIF orientation
      kCGImageSourceThumbnailMaxPixelSize: target,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
      throw RawJpegEncoder.EncodeError("Gagal membaca foto")
    }

    guard let out = CGImageDestinationCreateWithURL(
      dest as CFURL, format.type.identifier as CFString, 1, nil)
    else { throw RawJpegEncoder.EncodeError("Format \(format.fileExtension) tidak didukung perangkat ini") }
    var meta = RawJpegEncoder.jpegProperties(from: props, quality: quality)
    if format == .png { meta.removeValue(forKey: kCGImageDestinationLossyCompressionQuality as String) }
    CGImageDestinationAddImage(out, image, meta as CFDictionary)
    guard CGImageDestinationFinalize(out) else {
      throw RawJpegEncoder.EncodeError("Gagal menulis \(format.fileExtension)")
    }
    return (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }
}
