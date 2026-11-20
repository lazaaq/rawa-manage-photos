package com.lazaaq.raw_compressor;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.function.Predicate;

/** Output format rules for re-encoding regular photos (pure Java, unit-tested). */
public final class ImageFormats {
    private ImageFormats() {}

    public static final String JPEG = "jpeg";
    public static final String PNG = "png";
    public static final String WEBP = "webp";

    private static String ext(String name) {
        int dot = name == null ? -1 : name.lastIndexOf('.');
        return dot < 0 ? "" : name.substring(dot + 1).toLowerCase(Locale.ROOT);
    }

    /**
     * {@code format} "jpeg" / "png" / "webp" is used as is; "same" (or anything else) keeps the
     * source format when Android can write it. HEIC/HEIF and others become JPEG.
     */
    public static String resolve(String format, String sourceName) {
        if (JPEG.equals(format) || PNG.equals(format) || WEBP.equals(format)) return format;
        switch (ext(sourceName)) {
            case "png": return PNG;
            case "webp": return WEBP;
            default: return JPEG;
        }
    }

    public static String extension(String format) {
        switch (format) {
            case PNG: return "png";
            case WEBP: return "webp";
            default: return "jpg";
        }
    }

    public static String mime(String format) {
        switch (format) {
            case PNG: return "image/png";
            case WEBP: return "image/webp";
            default: return "image/jpeg";
        }
    }

    /** Output name: source base name + new extension ("IMG_1.HEIC" -> "IMG_1.jpg"). */
    public static String outputName(String sourceName, String format) {
        String name = sourceName == null || sourceName.isEmpty() ? "photo" : sourceName;
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name;
        return base + "." + extension(format);
    }

    /** Camera RAW extensions (lower case). */
    public static final Set<String> RAW_EXTS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
            "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
            "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "kdc", "mrw", "raw", "rwl")));

    public static boolean isRaw(String name) {
        return RAW_EXTS.contains(ext(name));
    }

    /**
     * File path for an ExternalStorageProvider document id: "primary:Pictures/a.jpg" ->
     * {@code primaryRoot}/Pictures/a.jpg, "1A2B-3C4D:DCIM/a.jpg" -> /storage/1A2B-3C4D/DCIM/a.jpg.
     * null when the id has no volume part.
     */
    public static String documentPath(String documentId, String primaryRoot) {
        if (documentId == null) return null;
        int colon = documentId.indexOf(':');
        if (colon <= 0) return null;
        String volume = documentId.substring(0, colon);
        String rel = documentId.substring(colon + 1);
        String root = volume.equalsIgnoreCase("primary") ? primaryRoot : "/storage/" + volume;
        return rel.isEmpty() ? root : root + "/" + rel;
    }

    /** {@code first} if free, else "base (1).ext", "base (2).ext", … */
    public static String uniqueName(String first, Predicate<String> exists) {
        if (!exists.test(first)) return first;
        int dot = first.lastIndexOf('.');
        String base = dot > 0 ? first.substring(0, dot) : first;
        String ext = dot > 0 ? first.substring(dot) : "";
        for (int n = 1; ; n++) {
            String candidate = base + " (" + n + ")" + ext;
            if (!exists.test(candidate)) return candidate;
        }
    }

    /** User-facing message for a conversion failure. */
    public static String errorMessage(Throwable t) {
        if (t instanceof OutOfMemoryError) {
            return "Foto terlalu besar untuk memori perangkat. Pilih ukuran yang lebih kecil.";
        }
        String m = t.getMessage();
        return m == null || m.isEmpty() ? t.getClass().getSimpleName() : m;
    }
}
