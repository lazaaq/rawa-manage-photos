import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// RAW file -> JPEG file. No Flutter or Photos dependency, so it also runs on macOS:
/// `tool/test_ios_encoder.sh` compiles this file together with `ios/EncoderTests/main.swift`.
enum RawJpegEncoder {
  struct EncodeError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
  }

  /// Decodes the RAW at `rawURL` (orientation applied), downsizes so the long side is at most
  /// `maxSide` (0 = original size, never upscaled) and writes a JPEG with the original
  /// EXIF/GPS/TIFF/IPTC metadata to `jpgURL`. Returns the JPEG size in bytes.
  @discardableResult
  static func encode(
    rawURL: URL, to jpgURL: URL, quality: Int, maxSide: Int, context: CIContext
  ) throws -> Int {
    var props: [String: Any] = [:]
    if let src = CGImageSourceCreateWithURL(rawURL as CFURL, nil),
      let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
    {
      props = p
    }

    // CIRAWFilter applies the file's orientation to its output.
    var image: CIImage?
    if let f = CIRAWFilter(imageURL: rawURL) {
      let native = f.nativeSize
      let long = max(native.width, native.height)
      if maxSide > 0, long > CGFloat(maxSide) {
        f.scaleFactor = Float(CGFloat(maxSide) / long)
      }
      image = f.outputImage
    }
    if image == nil, let ci = CIImage(contentsOf: rawURL, options: [.applyOrientationProperty: true]) {
      image = scaled(ci, maxSide: maxSide)
    }
    guard let img = image, !img.extent.isInfinite, !img.extent.isEmpty else {
      throw EncodeError("Format RAW tidak didukung perangkat")
    }

    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let cg = context.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: srgb)
    else { throw EncodeError("Gagal merender gambar") }

    guard let dest = CGImageDestinationCreateWithURL(
      jpgURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw EncodeError("Gagal membuat JPEG") }
    CGImageDestinationAddImage(dest, cg, jpegProperties(from: props, quality: quality) as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw EncodeError("Gagal menulis JPEG") }
    return (try? jpgURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  static func scaled(_ img: CIImage, maxSide: Int) -> CIImage {
    let long = max(img.extent.width, img.extent.height)
    guard maxSide > 0, long > CGFloat(maxSide) else { return img }
    let f = CIFilter(name: "CILanczosScaleTransform")!
    f.setValue(img, forKey: kCIInputImageKey)
    f.setValue(CGFloat(maxSide) / long, forKey: kCIInputScaleKey)
    f.setValue(1.0, forKey: kCIInputAspectRatioKey)
    return f.outputImage ?? img
  }

  static func jpegProperties(from src: [String: Any], quality: Int) -> [String: Any] {
    var out: [String: Any] = [:]
    let keep: [CFString] = [
      kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
      kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
      kCGImagePropertyIPTCDictionary,
    ]
    for k in keep {
      if let v = src[k as String] { out[k as String] = v }
    }
    // Pixels are already upright.
    out[kCGImagePropertyOrientation as String] = 1
    if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
      tiff[kCGImagePropertyTIFFOrientation as String] = 1
      out[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    if var exif = out[kCGImagePropertyExifDictionary as String] as? [String: Any] {
      exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
      exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
      // Newer cameras (e.g. Canon R6 II) only write ISOSpeed (0x8833); many viewers read
      // ISOSpeedRatings (0x8827).
      if exif[kCGImagePropertyExifISOSpeedRatings as String] == nil,
        let iso = exif[kCGImagePropertyExifISOSpeed as String]
      {
        exif[kCGImagePropertyExifISOSpeedRatings as String] = [iso]
      }
      out[kCGImagePropertyExifDictionary as String] = exif
    }
    out[kCGImageDestinationLossyCompressionQuality as String] =
      Double(min(max(quality, 1), 100)) / 100.0
    return out
  }
}
