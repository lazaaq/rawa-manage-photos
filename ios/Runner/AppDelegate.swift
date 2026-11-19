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
/// - `scanImages` -> [{id, name, size}]  semua foto non-RAW (JPEG, HEIC, PNG, …), terbaru dulu.
/// - `convert`  {id, quality, maxSide, target, source, format, onlyIfSmaller}
///   -> {newId, inBytes, outBytes, skipped}
///   `source` "raw" (default): decode RAW -> JPEG. "image": foto biasa -> `format`
///   ("jpeg" / "heic" / "png" / "same"). `onlyIfSmaller`: hasil yang tidak lebih kecil tidak
///   disimpan (skipped = true). Metadata EXIF/GPS disalin, lalu simpan:
///   `gallery` = asset baru di Photos dengan tanggal & lokasi yang sama,
///   `folder` = file di folder pilihan pengguna (app Files, iCloud Drive, dll.; newId kosong).
///   Asset RAW asli TIDAK dihapus di sini.
/// - `pickFolder` -> nama folder, atau nil bila dibatalkan. Disimpan sebagai bookmark.
/// - `savedFolder` -> nama folder tersimpan yang masih bisa dibuka, atau nil.
final class RawConverterPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private static let folderKey = "saveFolderBookmark"
  private var pendingPick: FlutterResult?

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
    case "scanImages":
      queue.async {
        let list = self.scanImages()
        DispatchQueue.main.async { result(list) }
      }
    case "convert":
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? String else {
        result(FlutterError(code: "bad_args", message: "id wajib diisi", details: nil))
        return
      }
      let quality = args["quality"] as? Int ?? 85
      let maxSide = args["maxSide"] as? Int ?? 0
      let toFolder = (args["target"] as? String) == "folder"
      let fromRaw = (args["source"] as? String ?? "raw") == "raw"
      let format = args["format"] as? String
      let onlyIfSmaller = args["onlyIfSmaller"] as? Bool ?? false
      queue.async {
        do {
          let r = try autoreleasepool {
            fromRaw
              ? try self.convert(id: id, quality: quality, maxSide: maxSide, toFolder: toFolder)
              : try self.convertImage(
                id: id, quality: quality, maxSide: maxSide, toFolder: toFolder,
                format: format, onlyIfSmaller: onlyIfSmaller)
          }
          DispatchQueue.main.async { result(r) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "convert_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "pickFolder":
      pickFolder(result)
    case "savedFolder":
      result(savedFolderURL()?.lastPathComponent)
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

  /// Resource foto biasa (versi editan bila ada).
  private func photoResource(for asset: PHAsset) -> PHAssetResource? {
    let all = PHAssetResource.assetResources(for: asset)
    return all.first { $0.type == .fullSizePhoto } ?? all.first { $0.type == .photo }
  }

  /// Nama file asli (bukan "FullSizeRender.jpg" dari editan).
  private func originalName(for asset: PHAsset) -> String {
    let all = PHAssetResource.assetResources(for: asset)
    return (all.first { $0.type == .photo } ?? all.first)?.originalFilename ?? "IMG.JPG"
  }

  private func scanImages() -> [[String: Any]] {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let assets = PHAsset.fetchAssets(with: .image, options: opts)
    var out: [[String: Any]] = []
    out.reserveCapacity(assets.count)
    assets.enumerateObjects { asset, _, _ in
      autoreleasepool {
        guard self.rawResource(for: asset) == nil, let r = self.photoResource(for: asset) else { return }
        out.append([
          "id": asset.localIdentifier,
          "name": self.originalName(for: asset),
          "size": self.resourceSize(r),
        ])
      }
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

  private func convert(id: String, quality: Int, maxSide: Int, toFolder: Bool) throws -> [String: Any] {
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

    let base = (res.originalFilename as NSString).deletingPathExtension
    let newId = try save(jpgURL, like: asset, name: base, ext: "JPG", toFolder: toFolder)
    return ["newId": newId, "inBytes": inBytes, "outBytes": outBytes, "skipped": false]
  }

  private func convertImage(
    id: String, quality: Int, maxSide: Int, toFolder: Bool, format: String?, onlyIfSmaller: Bool
  ) throws -> [String: Any] {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    else { throw ConvertError("Foto tidak ditemukan") }
    guard let res = photoResource(for: asset) else { throw ConvertError("Bukan foto") }

    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("rawconv", isDirectory: true)
    try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let name = originalName(for: asset)
    let srcExt = (res.originalFilename as NSString).pathExtension
    let fmt = ImageFormat.parse(format, sourceExtension: srcExt)
    let inURL = tmpDir.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(srcExt.isEmpty ? "jpg" : srcExt)
    let outURL = tmpDir.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fmt.fileExtension.lowercased())
    defer {
      try? fm.removeItem(at: inURL)
      try? fm.removeItem(at: outURL)
    }

    try writeResource(res, to: inURL)
    let inBytes = (try? inURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let outBytes = try ImageEncoder.encode(
      source: inURL, to: outURL, format: fmt, quality: quality, maxSide: maxSide)
    if onlyIfSmaller && outBytes >= inBytes {
      return ["newId": "", "inBytes": inBytes, "outBytes": inBytes, "skipped": true]
    }
    let base = (name as NSString).deletingPathExtension
    let newId = try save(outURL, like: asset, name: base, ext: fmt.fileExtension, toFolder: toFolder)
    return ["newId": newId, "inBytes": inBytes, "outBytes": outBytes, "skipped": false]
  }

  /// Simpan ke folder pilihan, atau ke Photos dengan tanggal, lokasi, favorit yang sama.
  private func save(_ file: URL, like asset: PHAsset, name base: String, ext: String, toFolder: Bool) throws
    -> String
  {
    if toFolder {
      try saveToFolder(file, name: base, ext: ext.lowercased())
      return ""
    }
    var newId: String?
    try PHPhotoLibrary.shared().performChangesAndWait {
      let req = PHAssetCreationRequest.forAsset()
      let o = PHAssetResourceCreationOptions()
      o.originalFilename = base + "." + ext
      req.addResource(with: .photo, fileURL: file, options: o)
      req.creationDate = asset.creationDate
      req.location = asset.location
      req.isFavorite = asset.isFavorite
      newId = req.placeholderForCreatedAsset?.localIdentifier
    }
    return newId ?? ""
  }

  // MARK: - Custom folder

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }
      .first
    var vc = window?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }

  private func pickFolder(_ result: @escaping FlutterResult) {
    guard pendingPick == nil else {
      result(FlutterError(code: "busy", message: "Pemilih folder sudah terbuka", details: nil))
      return
    }
    guard let vc = topViewController() else {
      result(FlutterError(code: "no_ui", message: "Aplikasi tidak aktif", details: nil))
      return
    }
    pendingPick = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    vc.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingPick else { return }
    pendingPick = nil
    guard let url = urls.first else { return result(nil) }
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(data, forKey: Self.folderKey)
      result(url.lastPathComponent)
    } catch {
      result(FlutterError(code: "folder_denied", message: "Folder ini tidak bisa dipakai", details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPick?(nil)
    pendingPick = nil
  }

  /// Folder dari bookmark; bookmark diperbarui bila basi. nil bila tidak ada atau tidak bisa dibuka.
  private func savedFolderURL() -> URL? {
    guard let data = UserDefaults.standard.data(forKey: Self.folderKey) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }
    if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      UserDefaults.standard.set(fresh, forKey: Self.folderKey)
    }
    return url
  }

  /// Salin file ke folder pilihan; "Nama (1).jpg" bila nama sudah ada.
  private func saveToFolder(_ jpgURL: URL, name base: String, ext: String) throws {
    guard let dir = savedFolderURL() else {
      throw ConvertError("Folder tujuan tidak bisa diakses. Pilih ulang folder.")
    }
    let ok = dir.startAccessingSecurityScopedResource()
    defer { if ok { dir.stopAccessingSecurityScopedResource() } }

    let fm = FileManager.default
    var target = dir.appendingPathComponent("\(base).\(ext)")
    var n = 1
    while fm.fileExists(atPath: target.path) {
      target = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
      n += 1
    }

    var coordError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { url in
      do { try fm.copyItem(at: jpgURL, to: url) } catch { copyError = error }
    }
    if let e = coordError ?? copyError {
      throw ConvertError("Gagal menyimpan ke folder tujuan: \(e.localizedDescription)")
    }
  }
}
