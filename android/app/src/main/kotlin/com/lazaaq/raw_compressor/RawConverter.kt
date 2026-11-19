package com.lazaaq.raw_compressor

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Native RAW -> JPEG converter.
 *
 * Channel `raw_compressor/native`:
 * - `scanRaw` -> [{id, name, size}]  semua file RAW yang terindeks MediaStore (termasuk
 *   folder Download, bukan hanya galeri). id = _ID tabel MediaStore.Files.
 * - `convert` {id, quality, maxSide} -> {newId, inBytes, outBytes}
 *   Decode RAW, encode JPEG (EXIF disalin), simpan ke folder yang sama bila diizinkan.
 *   File RAW asli TIDAK dihapus di sini.
 * - `thumbnail` {id, size} -> JPEG bytes, untuk file yang tidak dikenali galeri (mis. CR3).
 * - `deleteLegacy` {ids} -> id yang benar-benar terhapus (Android 9), atau null di Android 10+
 *   (Dart lalu memakai photo_manager yang menampilkan dialog konfirmasi sistem).
 */
class RawConverter(private val context: Context) : MethodChannel.MethodCallHandler {
    private val executor = Executors.newSingleThreadExecutor()
    private val thumbExecutor = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())

    private val isScopedStorage = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    private val filesUri: Uri = MediaStore.Files.getContentUri("external")

    companion object {
        private val RAW_EXTS = listOf(
            "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
            "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "kdc", "mrw", "raw", "rwl",
        )

        private val EXIF_TAGS = listOf(
            ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL,
            ExifInterface.TAG_DATETIME_DIGITIZED, ExifInterface.TAG_OFFSET_TIME,
            ExifInterface.TAG_OFFSET_TIME_ORIGINAL, ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
            ExifInterface.TAG_SUBSEC_TIME_ORIGINAL, ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL,
            ExifInterface.TAG_LENS_MAKE, ExifInterface.TAG_LENS_MODEL,
            ExifInterface.TAG_BODY_SERIAL_NUMBER, ExifInterface.TAG_F_NUMBER,
            ExifInterface.TAG_APERTURE_VALUE, ExifInterface.TAG_EXPOSURE_TIME,
            ExifInterface.TAG_SHUTTER_SPEED_VALUE, ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
            ExifInterface.TAG_FOCAL_LENGTH, ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
            ExifInterface.TAG_EXPOSURE_BIAS_VALUE, ExifInterface.TAG_EXPOSURE_PROGRAM,
            ExifInterface.TAG_EXPOSURE_MODE, ExifInterface.TAG_METERING_MODE,
            ExifInterface.TAG_FLASH, ExifInterface.TAG_WHITE_BALANCE, ExifInterface.TAG_ARTIST,
            ExifInterface.TAG_COPYRIGHT, ExifInterface.TAG_GPS_LATITUDE,
            ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE,
            ExifInterface.TAG_GPS_LONGITUDE_REF, ExifInterface.TAG_GPS_ALTITUDE,
            ExifInterface.TAG_GPS_ALTITUDE_REF, ExifInterface.TAG_GPS_TIMESTAMP,
            ExifInterface.TAG_GPS_DATESTAMP,
        )

        private fun isCr3(name: String) = name.lowercase().endsWith(".cr3")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scanRaw" -> run(result, executor) { scanRaw() }
            "convert" -> {
                val id = call.argument<String>("id")?.toLongOrNull()
                    ?: return result.error("bad_args", "id wajib diisi", null)
                val quality = call.argument<Int>("quality") ?: 85
                val maxSide = call.argument<Int>("maxSide") ?: 0
                run(result, executor) { convert(id, quality, maxSide) }
            }
            "thumbnail" -> {
                val id = call.argument<String>("id")?.toLongOrNull()
                    ?: return result.error("bad_args", "id wajib diisi", null)
                val size = call.argument<Int>("size") ?: 300
                run(result, thumbExecutor) { thumbnail(id, size) }
            }
            "deleteLegacy" -> {
                val ids = call.argument<List<String>>("ids") ?: emptyList()
                run(result, executor) { deleteLegacy(ids) }
            }
            else -> result.notImplemented()
        }
    }

    private fun run(result: MethodChannel.Result, pool: java.util.concurrent.Executor, block: () -> Any?) {
        pool.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (t: Throwable) {
                main.post { result.error("convert_failed", t.message ?: t.javaClass.simpleName, null) }
            }
        }
    }

    // ---------------------------------------------------------------- scan

    /**
     * Pakai tabel MediaStore.Files, bukan Images: file seperti CR3 di folder Download tidak
     * dikenali galeri sebagai foto, tapi tetap terindeks sebagai file.
     */
    @Suppress("DEPRECATION")
    private fun scanRaw(): List<Map<String, Any>> {
        // Android 9: _display_name bisa kosong untuk file non-media, jadi cocokkan path.
        val nameCol = if (isScopedStorage) MediaStore.MediaColumns.DISPLAY_NAME else MediaStore.MediaColumns.DATA
        val selection = RAW_EXTS.joinToString(" OR ") { "$nameCol LIKE ?" }
        val args = RAW_EXTS.map { "%.$it" }.toTypedArray()
        val projection = arrayOf(MediaStore.MediaColumns._ID, nameCol, MediaStore.MediaColumns.SIZE)

        val out = mutableListOf<Map<String, Any>>()
        context.contentResolver.query(
            filesUri, projection, "($selection)", args,
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                val raw = c.getString(1) ?: continue
                out.add(
                    mapOf(
                        "id" to c.getLong(0).toString(),
                        "name" to raw.substringAfterLast('/'),
                        "size" to c.getLong(2),
                    )
                )
            }
        }
        return out
    }

    // ------------------------------------------------------------- source

    private data class Source(
        val uri: Uri,
        val name: String,
        val size: Long,
        /** Android 10+: folder relatif (mis. "DCIM/Camera/"). */
        val relativePath: String?,
        /** Android 9: path file absolut. */
        val dataPath: String?,
        val dateTaken: Long?,
    )

    @Suppress("DEPRECATION")
    private fun querySource(id: Long): Source {
        val uri = ContentUris.withAppendedId(filesUri, id)
        val location = if (isScopedStorage) MediaStore.MediaColumns.RELATIVE_PATH else MediaStore.MediaColumns.DATA
        val projection = arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            location,
            MediaStore.Images.ImageColumns.DATE_TAKEN,
        )
        context.contentResolver.query(uri, projection, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val loc = c.getString(2)
                val name = c.getString(0) ?: loc?.substringAfterLast('/') ?: "photo"
                return Source(
                    uri = uri,
                    name = name,
                    size = c.getLong(1),
                    relativePath = if (isScopedStorage) loc else null,
                    dataPath = if (isScopedStorage) null else loc,
                    dateTaken = if (c.isNull(3)) null else c.getLong(3),
                )
            }
        }
        throw IllegalStateException("File tidak ditemukan")
    }

    /** Uri untuk membaca file: Android 10+ minta data GPS asli (butuh ACCESS_MEDIA_LOCATION). */
    private fun readUri(src: Source): Uri = if (isScopedStorage) {
        try { MediaStore.setRequireOriginal(src.uri) } catch (_: Throwable) { src.uri }
    } else src.uri

    private fun openFd(src: Source): ParcelFileDescriptor {
        // Android 9: buka path langsung (READ_EXTERNAL_STORAGE), lebih andal untuk file non-media.
        src.dataPath?.let { path ->
            val f = File(path)
            if (f.canRead()) return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        return context.contentResolver.openFileDescriptor(readUri(src), "r")
            ?: throw IllegalStateException("Tidak bisa membuka file")
    }

    private fun readCr3(src: Source): Pair<Cr3Parser.Result, ByteArray> =
        openFd(src).use { pfd ->
            FileInputStream(pfd.fileDescriptor).channel.use { ch ->
                val r = Cr3Parser.parse(ch)
                Pair(r, Cr3Parser.readJpeg(ch, r))
            }
        }

    // ------------------------------------------------------------- convert

    private fun convert(id: Long, quality: Int, maxSide: Int): Map<String, Any> {
        val src = querySource(id)
        val tmp = File(context.cacheDir, "${UUID.randomUUID()}.jpg")
        try {
            val exif: Map<String, String>?
            var bitmap: Bitmap
            if (isCr3(src.name)) {
                // CR3 tidak didukung decoder Android: pakai JPG resolusi penuh di dalamnya.
                val (meta, jpeg) = readCr3(src)
                bitmap = decodeBytes(jpeg, maxSide) ?: throw IllegalStateException("Gagal membaca JPG di dalam CR3")
                bitmap = applyOrientation(bitmap, meta.exif[ExifInterface.TAG_ORIENTATION]?.toIntOrNull() ?: 1)
                exif = meta.exif + (ExifInterface.TAG_ORIENTATION to "1")
            } else {
                val (bmp, rotated) = decode(src, maxSide)
                bitmap = if (rotated) bmp else applyOrientation(bmp, sourceOrientation(src))
                exif = null
            }
            // Pixel sudah tegak: semua galeri menampilkan benar walau mengabaikan tag EXIF.

            tmp.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), it) }
            val width = bitmap.width
            val height = bitmap.height
            bitmap.recycle()

            if (exif != null) {
                writeExif(tmp, exif, width, height)
            } else {
                copyExif(src, tmp, width, height)
            }
            val newId = insertJpeg(tmp, src)
            return mapOf("newId" to newId, "inBytes" to src.size, "outBytes" to tmp.length())
        } finally {
            tmp.delete()
        }
    }

    private fun sampleFor(long: Int, maxSide: Int): Int {
        var sample = 1
        if (maxSide > 0) while (long / (sample * 2) >= maxSide) sample *= 2
        return sample
    }

    private fun decodeBytes(bytes: ByteArray, maxSide: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sampleFor(max(bounds.outWidth, bounds.outHeight), maxSide)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)?.let { fit(it, maxSide) }
    }

    /** @return bitmap + apakah decoder sudah memutar pixel sesuai EXIF. */
    private fun decode(src: Source, maxSide: Int): Pair<Bitmap, Boolean> {
        // 1) BitmapFactory (Skia raw codec: DNG, CR2, NEF, ARW, RAF, ORF, RW2, PEF, SRW, ...).
        //    Tidak menerapkan orientasi EXIF -> tag orientasi disalin ke JPEG.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        openFd(src).use { BitmapFactory.decodeFileDescriptor(it.fileDescriptor, null, bounds) }
        if (bounds.outWidth > 0 && bounds.outHeight > 0) {
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sampleFor(max(bounds.outWidth, bounds.outHeight), maxSide)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            val bmp = openFd(src).use { BitmapFactory.decodeFileDescriptor(it.fileDescriptor, null, opts) }
            if (bmp != null) return Pair(fit(bmp, maxSide), false)
        }

        // 2) ImageDecoder (menerapkan orientasi sendiri).
        val source = src.dataPath?.let { ImageDecoder.createSource(File(it)) }
            ?: ImageDecoder.createSource(context.contentResolver, readUri(src))
        val bmp = try {
            ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val w = info.size.width
                val h = info.size.height
                val long = max(w, h)
                if (maxSide in 1 until long) {
                    val s = maxSide.toFloat() / long
                    decoder.setTargetSize((w * s).roundToInt(), (h * s).roundToInt())
                }
            }
        } catch (t: Throwable) {
            throw IllegalStateException("Format RAW ini tidak didukung di perangkat ini")
        }
        return Pair(bmp, true)
    }

    private fun fit(bmp: Bitmap, maxSide: Int): Bitmap {
        val long = max(bmp.width, bmp.height)
        if (maxSide <= 0 || long <= maxSide) return bmp
        val s = maxSide.toFloat() / long
        val scaled = Bitmap.createScaledBitmap(bmp, (bmp.width * s).roundToInt(), (bmp.height * s).roundToInt(), true)
        if (scaled != bmp) bmp.recycle()
        return scaled
    }

    private fun sourceOrientation(src: Source): Int = try {
        openFd(src).use {
            ExifInterface(it.fileDescriptor)
                .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }
    } catch (_: Throwable) {
        ExifInterface.ORIENTATION_NORMAL
    }

    /** Putar/cerminkan pixel sesuai tag EXIF Orientation (1..8). */
    private fun applyOrientation(bmp: Bitmap, orientation: Int): Bitmap {
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { m.setRotate(90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> m.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { m.setRotate(-90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> m.setRotate(-90f)
            else -> return bmp
        }
        val out = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        if (out != bmp) bmp.recycle()
        return out
    }

    private fun copyExif(src: Source, jpg: File, width: Int, height: Int) {
        try {
            val srcExif = openFd(src).use { ExifInterface(it.fileDescriptor) }
            val map = mutableMapOf<String, String>()
            for (tag in EXIF_TAGS) srcExif.getAttribute(tag)?.let { map[tag] = it }
            map[ExifInterface.TAG_ORIENTATION] = "1" // pixel sudah diputar
            writeExif(jpg, map, width, height)
        } catch (_: Throwable) {
            // Metadata opsional; gambar tetap tersimpan.
        }
    }

    private fun writeExif(jpg: File, tags: Map<String, String>, width: Int, height: Int) {
        try {
            val dst = ExifInterface(jpg.absolutePath)
            for ((k, v) in tags) {
                try { dst.setAttribute(k, v) } catch (_: Throwable) {}
            }
            if (tags[ExifInterface.TAG_ORIENTATION] == null) dst.setAttribute(ExifInterface.TAG_ORIENTATION, "1")
            dst.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
            dst.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
            dst.setAttribute(ExifInterface.TAG_SOFTWARE, "rawa")
            dst.saveAttributes()
        } catch (_: Throwable) {
            // Metadata opsional; gambar tetap tersimpan.
        }
    }

    // ------------------------------------------------------------ thumbnail

    private fun thumbnail(id: Long, size: Int): ByteArray? {
        val src = querySource(id)
        val bmp: Bitmap = if (isCr3(src.name)) {
            val (meta, jpeg) = readCr3(src)
            decodeBytes(jpeg, size)?.let {
                applyOrientation(it, meta.exif[ExifInterface.TAG_ORIENTATION]?.toIntOrNull() ?: 1)
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            openFd(src).use { BitmapFactory.decodeFileDescriptor(it.fileDescriptor, null, bounds) }
            if (bounds.outWidth <= 0) return null
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sampleFor(max(bounds.outWidth, bounds.outHeight), size)
            }
            openFd(src).use { BitmapFactory.decodeFileDescriptor(it.fileDescriptor, null, opts) }
                ?.let { applyOrientation(fit(it, size), sourceOrientation(src)) }
        } ?: return null
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
        bmp.recycle()
        return out.toByteArray()
    }

    // --------------------------------------------------------------- delete

    /**
     * Android 9: hapus file langsung lalu bersihkan barisnya di MediaStore. Hanya id yang
     * filenya benar-benar sudah tidak ada yang dikembalikan.
     * Android 10+: null -> Dart memakai photo_manager (dialog konfirmasi sistem).
     */
    @Suppress("DEPRECATION")
    private fun deleteLegacy(ids: List<String>): List<String>? {
        if (isScopedStorage) return null
        val cr = context.contentResolver
        val done = mutableListOf<String>()
        for (id in ids) {
            val rowId = id.toLongOrNull() ?: continue
            val uri = ContentUris.withAppendedId(filesUri, rowId)
            val path = cr.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
            val file = path?.let(::File)
            if (file != null && file.exists() && !file.delete()) continue
            try { cr.delete(uri, null, null) } catch (_: Throwable) {}
            if (file == null || !file.exists()) done.add(id)
        }
        return done
    }

    // --------------------------------------------------------------- insert

    private fun insertJpeg(file: File, src: Source): String =
        if (isScopedStorage) insertJpegScoped(file, src) else insertJpegLegacy(file, src)

    /** Android 9: tulis file langsung di samping RAW asli, lalu daftarkan ke MediaStore. */
    @Suppress("DEPRECATION")
    private fun insertJpegLegacy(file: File, src: Source): String {
        val dir = src.dataPath?.let { File(it).parentFile }?.takeIf { it.canWrite() }
            ?: File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "rawa")
                .apply { mkdirs() }
        val base = src.name.substringBeforeLast('.')
        var target = File(dir, "$base.jpg")
        var n = 1
        while (target.exists()) target = File(dir, "$base (${n++}).jpg")
        file.copyTo(target)

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DATA, target.absolutePath)
            put(MediaStore.Images.Media.DISPLAY_NAME, target.name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.SIZE, target.length())
            src.dateTaken?.let { put(MediaStore.Images.Media.DATE_TAKEN, it) }
            put(MediaStore.Images.Media.DATE_ADDED, System.currentTimeMillis() / 1000)
            put(MediaStore.Images.Media.DATE_MODIFIED, target.lastModified() / 1000)
        }
        val newUri = try {
            context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        } catch (_: Throwable) { null }
        if (newUri == null) {
            target.delete()
            throw IllegalStateException("Gagal mendaftarkan JPG ke galeri")
        }
        // Lengkapi metadata (lebar/tinggi, tanggal dari EXIF, dll.) di MediaStore.
        MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), arrayOf("image/jpeg"), null)
        return ContentUris.parseId(newUri).toString()
    }

    /** Android 10+: scoped storage via MediaStore. */
    private fun insertJpegScoped(file: File, src: Source): String {
        val cr = context.contentResolver
        // MediaStore hanya mengizinkan gambar baru di DCIM/ atau Pictures/.
        val rel = src.relativePath?.takeIf { it.startsWith("DCIM/") || it.startsWith("Pictures/") }
            ?: "Pictures/rawa/"
        val base = src.name.substringBeforeLast('.')
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$base.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, rel)
            src.dateTaken?.let { put(MediaStore.Images.Media.DATE_TAKEN, it) }
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val newUri = cr.insert(collection, values) ?: throw IllegalStateException("Gagal menyimpan JPG")
        try {
            cr.openOutputStream(newUri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
                ?: throw IllegalStateException("Gagal menulis JPG")
            cr.update(newUri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        } catch (t: Throwable) {
            cr.delete(newUri, null, null)
            throw t
        }
        return ContentUris.parseId(newUri).toString()
    }
}
