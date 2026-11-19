import CoreImage
import Flutter
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RawConverterPlugin") {
      RawConverterPlugin.register(with: registrar)
    }
  }
}

/// Native RAW -> JPEG converter.
///
/// Channel `raw_compressor/native`:
/// - `scanRaw`  -> [{id, name, size}]  semua foto RAW di library.
/// - `convert`  {id, quality, maxSide} -> {newId, inBytes, outBytes}
///   Decode RAW, encode JPEG (metadata EXIF/GPS disalin), simpan sebagai asset baru
///   dengan tanggal & lokasi yang sama. Asset RAW asli TIDAK dihapus di sini.
final class RawConverterPlugin: NSObject, FlutterPlugin {
  private static let rawExts: Set<String> = [
    "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
    "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "kdc", "mrw", "raw", "rwl",
  ]

  private let queue = DispatchQueue(label: "raw_compressor.convert", qos: .userInitiated)
  private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "raw_compressor/native", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(RawConverterPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "scanRaw":
      queue.async {
        let list = self.scanRaw()
        DispatchQueue.main.async { result(list) }
      }
    case "convert":
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? String else {
        result(FlutterError(code: "bad_args", message: "id wajib diisi", details: nil))
        return
      }
      let quality = args["quality"] as? Int ?? 85
      let maxSide = args["maxSide"] as? Int ?? 0
      queue.async {
        do {
          let r = try autoreleasepool { try self.convert(id: id, quality: quality, maxSide: maxSide) }
          DispatchQueue.main.async { result(r) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "convert_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Scan

  private func rawResource(for asset: PHAsset) -> PHAssetResource? {
    PHAssetResource.assetResources(for: asset).first { r in
      guard r.type == .photo || r.type == .alternatePhoto || r.type == .fullSizePhoto else {
        return false
      }
      if let t = UTType(r.uniformTypeIdentifier), t.conforms(to: .rawImage) { return true }
      return Self.rawExts.contains((r.originalFilename as NSString).pathExtension.lowercased())
    }
  }

  private func resourceSize(_ r: PHAssetResource) -> Int64 {
    guard r.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
    return (r.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
  }

  private func scanRaw() -> [[String: Any]] {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

    // Album pintar "RAW" jauh lebih cepat daripada memeriksa seluruh library.
    let assets: PHFetchResult<PHAsset>
    if let rawAlbum = PHAssetCollection.fetchAssetCollections(
      with: .smartAlbum, subtype: .smartAlbumRAW, options: nil
    ).firstObject {
      assets = PHAsset.fetchAssets(in: rawAlbum, options: opts)
    } else {
      assets = PHAsset.fetchAssets(with: opts)
    }

    var out: [[String: Any]] = []
    assets.enumerateObjects { asset, _, _ in
      guard let r = self.rawResource(for: asset) else { return }
      out.append([
        "id": asset.localIdentifier,
        "name": r.originalFilename,
        "size": self.resourceSize(r),
      ])
    }
    return out
  }

  // MARK: - Convert

  private struct ConvertError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
  }

  private func writeResource(_ res: PHAssetResource, to url: URL) throws {
    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = true  // unduh dari iCloud bila perlu
    let sem = DispatchSemaphore(value: 0)
    var failure: Error?
    PHAssetResourceManager.default().writeData(for: res, toFile: url, options: opts) { err in
      failure = err
      sem.signal()
    }
    sem.wait()
    if let failure { throw failure }
  }

  private func convert(id: String, quality: Int, maxSide: Int) throws -> [String: Any] {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    else { throw ConvertError("Foto tidak ditemukan") }
    guard let res = rawResource(for: asset) else { throw ConvertError("Bukan file RAW") }

    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("rawconv", isDirectory: true)
    try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let ext = (res.originalFilename as NSString).pathExtension
    let rawURL = tmpDir.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(ext.isEmpty ? "dng" : ext)
    let jpgURL = tmpDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
    defer {
      try? fm.removeItem(at: rawURL)
      try? fm.removeItem(at: jpgURL)
    }

    try writeResource(res, to: rawURL)
    let inBytes = (try? rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

    let outBytes = try RawJpegEncoder.encode(
      rawURL: rawURL, to: jpgURL, quality: quality, maxSide: maxSide, context: ciContext)

    // Simpan ke Photos dengan tanggal, lokasi, favorit yang sama.
    let base = (res.originalFilename as NSString).deletingPathExtension
    var newId: String?
    try PHPhotoLibrary.shared().performChangesAndWait {
      let req = PHAssetCreationRequest.forAsset()
      let o = PHAssetResourceCreationOptions()
      o.originalFilename = base + ".JPG"
      req.addResource(with: .photo, fileURL: jpgURL, options: o)
      req.creationDate = asset.creationDate
      req.location = asset.location
      req.isFavorite = asset.isFavorite
      newId = req.placeholderForCreatedAsset?.localIdentifier
    }

    return ["newId": newId ?? "", "inBytes": inBytes, "outBytes": outBytes]
  }
}
