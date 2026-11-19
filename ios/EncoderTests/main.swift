// macOS test harness for ios/Runner/RawJpegEncoder.swift (same Core Image / ImageIO code path
// as the iOS app). Run via tool/test_ios_encoder.sh.
//
// usage: encoder-tests <fixtures-dir> [cr3-samples-dir]
//   fixtures-dir must contain land.dng (landscape, orientation 1) and port.dng (orientation 6).

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let fixtures = URL(fileURLWithPath: args[1])
let samples = args.count > 2 && !args[2].isEmpty ? URL(fileURLWithPath: args[2]) : nil
let context = CIContext(options: [.cacheIntermediates: false])
let out = fixtures.appendingPathComponent("out", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var passed = 0
var failed = 0

func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
  if !cond {
    failed += 1
    print("    FAIL: \(msg())")
  }
}

func test(_ name: String, _ body: () throws -> Void) {
  let before = failed
  do { try body() } catch {
    failed += 1
    print("    FAIL: threw \(error.localizedDescription)")
  }
  if failed == before { passed += 1; print("  ok   \(name)") } else { print("  FAIL \(name)") }
}

struct Info {
  let width: Int
  let height: Int
  let orientation: Int
  let type: String
  let props: [String: Any]
  var exif: [String: Any] { props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:] }
  var tiff: [String: Any] { props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:] }
  var longSide: Int { max(width, height) }
}

func info(_ url: URL) -> Info? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
  else { return nil }
  return Info(
    width: p[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
    height: p[kCGImagePropertyPixelHeight as String] as? Int ?? 0,
    orientation: p[kCGImagePropertyOrientation as String] as? Int ?? 1,
    type: CGImageSourceGetType(src) as String? ?? "",
    props: p)
}

func encode(_ name: String, quality: Int = 85, maxSide: Int = 0, as outName: String? = nil) throws -> (Info, Int) {
  let dst = out.appendingPathComponent(outName ?? "\(name)-q\(quality)-m\(maxSide).jpg")
  try? FileManager.default.removeItem(at: dst)
  let src = name.hasPrefix("/") ? URL(fileURLWithPath: name) : fixtures.appendingPathComponent(name)
  let bytes = try RawJpegEncoder.encode(rawURL: src, to: dst, quality: quality, maxSide: maxSide, context: context)
  guard let i = info(dst) else { throw RawJpegEncoder.EncodeError("output unreadable") }
  return (i, bytes)
}

print("RawJpegEncoder (macOS)")

test("landscape DNG at original size is a JPEG with same dimensions") {
  let (i, bytes) = try encode("land.dng")
  check(i.type == UTType.jpeg.identifier, "type \(i.type)")
  check(i.width == 1200 && i.height == 800, "size \(i.width)x\(i.height)")
  check(i.orientation == 1, "orientation \(i.orientation)")
  check(bytes > 0, "bytes \(bytes)")
}

test("metadata is copied (TIFF Make/Model/DateTime)") {
  let (i, _) = try encode("land.dng")
  check(i.tiff[kCGImagePropertyTIFFMake as String] as? String == "TestCam", "make \(i.tiff)")
  check(i.tiff[kCGImagePropertyTIFFModel as String] as? String == "Synth DNG", "model")
  check(i.tiff[kCGImagePropertyTIFFDateTime as String] as? String == "2025:06:01 10:00:00", "datetime")
  check(i.tiff[kCGImagePropertyTIFFOrientation as String] as? Int ?? 1 == 1, "tiff orientation")
}

test("maxSide downsizes long side, keeps aspect ratio") {
  let (i, _) = try encode("land.dng", maxSide: 600)
  check(abs(i.longSide - 600) <= 1, "long side \(i.longSide)")
  check(abs(Double(i.width) / Double(i.height) - 1.5) < 0.01, "aspect \(i.width)x\(i.height)")
}

test("maxSide larger than image never upscales") {
  let (i, _) = try encode("land.dng", maxSide: 5000)
  check(i.width == 1200 && i.height == 800, "size \(i.width)x\(i.height)")
}

test("orientation 6 is applied to pixels, output orientation is 1") {
  let (i, _) = try encode("port.dng")
  check(i.width == 800 && i.height == 1200, "size \(i.width)x\(i.height)")
  check(i.orientation == 1, "orientation \(i.orientation)")
}

test("orientation + maxSide together") {
  let (i, _) = try encode("port.dng", maxSide: 600)
  check(i.height > i.width, "portrait \(i.width)x\(i.height)")
  check(abs(i.longSide - 600) <= 1, "long side \(i.longSide)")
}

test("lower quality gives a smaller file") {
  let (_, q50) = try encode("land.dng", quality: 50)
  let (_, q95) = try encode("land.dng", quality: 95)
  check(q50 < q95, "q50 \(q50) !< q95 \(q95)")
}

test("out-of-range quality is clamped, not rejected") {
  _ = try encode("land.dng", quality: 0)
  _ = try encode("land.dng", quality: 150)
}

test("non-image file throws a readable error") {
  let junk = fixtures.appendingPathComponent("junk.dng")
  try Data("this is not a raw file".utf8).write(to: junk)
  do {
    _ = try encode("junk.dng")
    check(false, "expected error")
  } catch {
    check(!error.localizedDescription.isEmpty, "empty message")
  }
}

if let samples {
  let files = (try? FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension.lowercased() == "cr3" }.sorted { $0.path < $1.path } ?? []
  for f in files {
    test("real \(f.lastPathComponent): orientation, size, EXIF") {
      guard let src = info(f) else { return check(false, "source unreadable") }
      let rotated = [5, 6, 7, 8].contains(src.orientation)
      let (full, fullBytes) = try encode(f.path, maxSide: 0, as: "\(f.lastPathComponent)-full.jpg")
      check(full.orientation == 1, "orientation \(full.orientation)")
      check(rotated ? full.height > full.width : full.width >= full.height,
            "src orientation \(src.orientation) -> \(full.width)x\(full.height)")
      check(full.longSide == src.longSide, "long side \(full.longSide) vs \(src.longSide)")

      let (small, smallBytes) = try encode(f.path, maxSide: 4096, as: "\(f.lastPathComponent)-4096.jpg")
      check(abs(small.longSide - 4096) <= 1, "4096 long side \(small.longSide)")
      check(smallBytes < fullBytes, "4096 \(smallBytes) !< full \(fullBytes)")

      let iso = src.exif[kCGImagePropertyExifISOSpeed as String].map { "\($0)" }
      let isoRatings = (small.exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first.map { "\($0)" }
      check(iso != nil && isoRatings == iso, "ISOSpeedRatings fallback: \(iso ?? "nil") -> \(isoRatings ?? "nil")")
      for key in [kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureTime,
                  kCGImagePropertyExifISOSpeed, kCGImagePropertyExifDateTimeOriginal,
                  kCGImagePropertyExifLensModel, kCGImagePropertyExifFocalLength] {
        let a = src.exif[key as String].map { "\($0)" }
        let b = small.exif[key as String].map { "\($0)" }
        check(a != nil && a == b, "\(key): \(a ?? "nil") -> \(b ?? "nil")")
      }
      check(small.tiff[kCGImagePropertyTIFFModel as String] as? String == src.tiff[kCGImagePropertyTIFFModel as String] as? String,
            "model")
      let inBytes = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      print(String(format: "         %@ %dx%d  RAW %.1f MB -> full %.1f MB, 4096 %.1f MB",
                   "o\(src.orientation)", small.width, small.height,
                   Double(inBytes) / 1e6, Double(fullBytes) / 1e6, Double(smallBytes) / 1e6))
    }
  }
}


// MARK: - ImageEncoder (regular photos)

print("ImageEncoder (macOS)")

/// Synthetic photo: gradient pixels, given EXIF orientation, GPS + TIFF metadata.
func makePhoto(_ url: URL, type: UTType, width: Int, height: Int, orientation: Int) {
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  for y in stride(from: 0, to: height, by: 8) {
    for x in stride(from: 0, to: width, by: 8) {
      ctx.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                       blue: CGFloat((x * y) % 255) / 255, alpha: 1)
      ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
    }
  }
  let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
  let props: [String: Any] = [
    kCGImagePropertyOrientation as String: orientation,
    kCGImagePropertyTIFFDictionary as String: [
      kCGImagePropertyTIFFMake as String: "Apple", kCGImagePropertyTIFFModel as String: "iPhone 11",
    ],
    kCGImagePropertyGPSDictionary as String: [
      kCGImagePropertyGPSLatitude as String: 8.65, kCGImagePropertyGPSLatitudeRef as String: "S",
      kCGImagePropertyGPSLongitude as String: 115.2, kCGImagePropertyGPSLongitudeRef as String: "E",
    ],
    kCGImagePropertyExifDictionary as String: [
      kCGImagePropertyExifDateTimeOriginal as String: "2023:03:30 10:11:12",
    ],
  ]
  CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
  CGImageDestinationFinalize(dest)
}

let photoJpg = fixtures.appendingPathComponent("photo.jpg")
let photoRot = fixtures.appendingPathComponent("photo-rot.jpg")
let photoPng = fixtures.appendingPathComponent("photo.png")
makePhoto(photoJpg, type: .jpeg, width: 1200, height: 800, orientation: 1)
makePhoto(photoRot, type: .jpeg, width: 1200, height: 800, orientation: 6)
makePhoto(photoPng, type: .png, width: 640, height: 480, orientation: 1)
let heicWritable = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)

func encodePhoto(_ src: URL, _ name: String, _ f: ImageFormat, quality: Int = 85, maxSide: Int = 0) throws
  -> (URL, Int)
{
  let dst = out.appendingPathComponent(name)
  try? FileManager.default.removeItem(at: dst)
  let n = try ImageEncoder.encode(source: src, to: dst, format: f, quality: quality, maxSide: maxSide)
  return (dst, n)
}

test("JPEG -> JPEG keeps size, GPS, TIFF and date") {
  let (u, n) = try encodePhoto(photoJpg, "p1.jpg", .jpeg)
  let i = info(u)!
  check(i.type == UTType.jpeg.identifier, "type \(i.type)")
  check(i.width == 1200 && i.height == 800, "size \(i.width)x\(i.height)")
  check(n > 0 && n == ((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1), "byte count")
  let gps = i.props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
  check(gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "S", "GPS kept")
  check(i.tiff[kCGImagePropertyTIFFModel as String] as? String == "iPhone 11", "model kept")
  check(i.exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2023:03:30 10:11:12", "date kept")
}

test("orientation 6 applied to pixels, output orientation 1") {
  let (u, _) = try encodePhoto(photoRot, "p2.jpg", .jpeg)
  let i = info(u)!
  check(i.width == 800 && i.height == 1200, "size \(i.width)x\(i.height)")
  check(i.orientation == 1, "orientation \(i.orientation)")
}

test("maxSide downsizes, never upscales") {
  let (a, _) = try encodePhoto(photoRot, "p3.jpg", .jpeg, maxSide: 600)
  let ia = info(a)!
  check(ia.longSide == 600 && ia.width == 400, "downsized \(ia.width)x\(ia.height)")
  let (b, _) = try encodePhoto(photoJpg, "p4.jpg", .jpeg, maxSide: 5000)
  check(info(b)!.longSide == 1200, "no upscale")
}

test("lower JPEG quality gives a smaller file") {
  let (_, hi) = try encodePhoto(photoJpg, "q95.jpg", .jpeg, quality: 95)
  let (_, lo) = try encodePhoto(photoJpg, "q50.jpg", .jpeg, quality: 50)
  check(lo < hi, "q50 \(lo) < q95 \(hi)")
}

test("JPEG -> PNG, quality ignored") {
  let (u, a) = try encodePhoto(photoJpg, "p5.png", .png, quality: 50)
  let (_, b) = try encodePhoto(photoJpg, "p6.png", .png, quality: 100)
  check(info(u)!.type == UTType.png.identifier, "type")
  check(a == b, "PNG size independent of quality: \(a) vs \(b)")
}

test("PNG -> JPEG") {
  let (u, _) = try encodePhoto(photoPng, "p7.jpg", .jpeg)
  let i = info(u)!
  check(i.type == UTType.jpeg.identifier && i.width == 640 && i.height == 480, "\(i.type) \(i.width)x\(i.height)")
}

test("JPEG -> HEIC (when this Mac can write HEIC)") {
  guard heicWritable else { print("         skipped: no HEIC encoder"); return }
  let (u, n) = try encodePhoto(photoRot, "p8.heic", .heic, maxSide: 1000)
  let i = info(u)!
  check(i.type == UTType.heic.identifier, "type \(i.type)")
  check(i.width == 667 && i.height == 1000, "size \(i.width)x\(i.height)")
  let (_, jpg) = try encodePhoto(photoRot, "p8.jpg", .jpeg, maxSide: 1000)
  check(n < jpg, "HEIC \(n) smaller than JPEG \(jpg)")
  // and back: HEIC -> JPEG
  let (back, _) = try encodePhoto(u, "p9.jpg", .jpeg)
  check(info(back)!.width == 667, "HEIC decodes")
}

test("format rules for 'same' and explicit formats") {
  check(ImageFormat.parse("same", sourceExtension: "HEIC") == .heic, "HEIC stays HEIC")
  check(ImageFormat.parse(nil, sourceExtension: "heif") == .heic, "heif")
  check(ImageFormat.parse("same", sourceExtension: "PNG") == .png, "png")
  check(ImageFormat.parse("same", sourceExtension: "JPG") == .jpeg, "jpg")
  check(ImageFormat.parse("same", sourceExtension: "webp") == .jpeg, "webp -> jpeg on iOS")
  check(ImageFormat.parse("same", sourceExtension: "") == .jpeg, "no extension")
  check(ImageFormat.parse("png", sourceExtension: "HEIC") == .png, "explicit wins")
  check(ImageFormat.parse("webp", sourceExtension: "PNG") == .png, "unknown explicit -> same as source")
  check(ImageFormat.heic.fileExtension == "HEIC" && ImageFormat.jpeg.fileExtension == "JPG", "extensions")
}

test("unreadable file throws a readable error") {
  let bad = fixtures.appendingPathComponent("bad.jpg")
  try Data("not an image".utf8).write(to: bad)
  do {
    _ = try encodePhoto(bad, "bad-out.jpg", .jpeg)
    check(false, "should throw")
  } catch {
    check(!error.localizedDescription.isEmpty, "message")
  }
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
