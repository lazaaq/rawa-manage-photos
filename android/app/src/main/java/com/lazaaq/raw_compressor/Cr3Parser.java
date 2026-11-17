package com.lazaaq.raw_compressor;

import java.io.EOFException;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Minimal Canon CR3 reader (ISO-BMFF container).
 *
 * <p>Android has no CR3 decoder, but every CR3 stores a full-size, camera-rendered JPEG in
 * track 1 plus EXIF data as TIFF blocks (CMT1 = IFD0, CMT2 = Exif IFD, CMT4 = GPS IFD) inside
 * Canon's moov/uuid box. This class finds both. Pure Java with no Android dependencies, so it
 * can be tested on a desktop JVM: {@code java Cr3Parser.java file.CR3}.
 *
 * <p>EXIF values are formatted the way {@code androidx.exifinterface.media.ExifInterface#setAttribute}
 * expects: rationals as "num/den", ExposureTime/FNumber as decimals, GPSTimeStamp as "hh:mm:ss".
 */
public final class Cr3Parser {
    public static final class Result {
        public long jpegOffset;
        public long jpegSize;
        /** ExifInterface tag name -> value. */
        public final Map<String, String> exif = new LinkedHashMap<>();
    }

    private static final String CANON_UUID = "85c0b687820f11e08111f4ce462b6a48";

    private static final Map<Integer, String> IFD0_TAGS = new HashMap<>();
    private static final Map<Integer, String> EXIF_TAGS = new HashMap<>();
    private static final Map<Integer, String> GPS_TAGS = new HashMap<>();
    private static final Set<String> DECIMAL_TAGS = new HashSet<>();

    static {
        IFD0_TAGS.put(0x010F, "Make");
        IFD0_TAGS.put(0x0110, "Model");
        IFD0_TAGS.put(0x0112, "Orientation");
        IFD0_TAGS.put(0x0132, "DateTime");
        IFD0_TAGS.put(0x013B, "Artist");
        IFD0_TAGS.put(0x8298, "Copyright");

        EXIF_TAGS.put(0x829A, "ExposureTime");
        EXIF_TAGS.put(0x829D, "FNumber");
        EXIF_TAGS.put(0x8822, "ExposureProgram");
        EXIF_TAGS.put(0x8827, "PhotographicSensitivity");
        EXIF_TAGS.put(0x9003, "DateTimeOriginal");
        EXIF_TAGS.put(0x9004, "DateTimeDigitized");
        EXIF_TAGS.put(0x9010, "OffsetTime");
        EXIF_TAGS.put(0x9011, "OffsetTimeOriginal");
        EXIF_TAGS.put(0x9012, "OffsetTimeDigitized");
        EXIF_TAGS.put(0x9201, "ShutterSpeedValue");
        EXIF_TAGS.put(0x9202, "ApertureValue");
        EXIF_TAGS.put(0x9204, "ExposureBiasValue");
        EXIF_TAGS.put(0x9207, "MeteringMode");
        EXIF_TAGS.put(0x9209, "Flash");
        EXIF_TAGS.put(0x920A, "FocalLength");
        EXIF_TAGS.put(0x9291, "SubSecTimeOriginal");
        EXIF_TAGS.put(0xA402, "ExposureMode");
        EXIF_TAGS.put(0xA403, "WhiteBalance");
        EXIF_TAGS.put(0xA405, "FocalLengthIn35mmFilm");
        EXIF_TAGS.put(0xA431, "BodySerialNumber");
        EXIF_TAGS.put(0xA432, "LensSpecification");
        EXIF_TAGS.put(0xA433, "LensMake");
        EXIF_TAGS.put(0xA434, "LensModel");

        GPS_TAGS.put(0x01, "GPSLatitudeRef");
        GPS_TAGS.put(0x02, "GPSLatitude");
        GPS_TAGS.put(0x03, "GPSLongitudeRef");
        GPS_TAGS.put(0x04, "GPSLongitude");
        GPS_TAGS.put(0x05, "GPSAltitudeRef");
        GPS_TAGS.put(0x06, "GPSAltitude");
        GPS_TAGS.put(0x07, "GPSTimeStamp");
        GPS_TAGS.put(0x1D, "GPSDateStamp");

        DECIMAL_TAGS.add("ExposureTime");
        DECIMAL_TAGS.add("FNumber");
    }

    private Cr3Parser() {}

    public static Result parse(FileChannel ch) throws IOException {
        Result r = new Result();
        long len = ch.size();
        Box moov = child(ch, 0, len, "moov");
        if (moov == null) throw new IOException("Bukan file CR3 yang valid");

        boolean firstTrak = true;
        long off = moov.body;
        while (off + 8 <= moov.end) {
            Box b = readBox(ch, off, moov.end);
            if ("uuid".equals(b.type) && CANON_UUID.equals(b.uuid)) {
                parseCanon(ch, b, r);
            } else if ("trak".equals(b.type) && firstTrak) {
                firstTrak = false;
                parseTrak(ch, b, r);
            }
            off = b.end;
        }

        if (r.jpegSize <= 0 || r.jpegOffset <= 0 || r.jpegOffset + r.jpegSize > len) {
            throw new IOException("JPG tidak ditemukan di dalam CR3");
        }
        ByteBuffer soi = read(ch, r.jpegOffset, 2);
        if ((soi.get(0) & 0xff) != 0xFF || (soi.get(1) & 0xff) != 0xD8) {
            throw new IOException("Data JPG di dalam CR3 tidak valid");
        }
        return r;
    }

    /** Reads the embedded full-size JPEG. */
    public static byte[] readJpeg(FileChannel ch, Result r) throws IOException {
        if (r.jpegSize > 200L * 1024 * 1024) throw new IOException("JPG di dalam CR3 terlalu besar");
        return read(ch, r.jpegOffset, (int) r.jpegSize).array();
    }

    // ------------------------------------------------------------------ boxes

    private static final class Box {
        String type;
        String uuid;
        long body;
        long end;
    }

    private static Box readBox(FileChannel ch, long off, long limit) throws IOException {
        ByteBuffer h = read(ch, off, 8);
        long size = h.getInt(0) & 0xffffffffL;
        String type = new String(h.array(), 4, 4, StandardCharsets.ISO_8859_1);
        long hdr = 8;
        if (size == 1) {
            size = read(ch, off + 8, 8).getLong(0);
            hdr = 16;
        } else if (size == 0) {
            size = limit - off;
        }
        if (size < hdr || off + size > limit) throw new IOException("Struktur CR3 rusak");
        Box b = new Box();
        b.type = type;
        b.body = off + hdr;
        b.end = off + size;
        if ("uuid".equals(type)) {
            b.uuid = hex(read(ch, b.body, 16).array());
            b.body += 16;
        }
        return b;
    }

    private static Box child(FileChannel ch, long off, long end, String type) throws IOException {
        while (off + 8 <= end) {
            Box b = readBox(ch, off, end);
            if (type.equals(b.type)) return b;
            off = b.end;
        }
        return null;
    }

    private static void parseTrak(FileChannel ch, Box trak, Result r) throws IOException {
        Box mdia = child(ch, trak.body, trak.end, "mdia");
        if (mdia == null) return;
        Box minf = child(ch, mdia.body, mdia.end, "minf");
        if (minf == null) return;
        Box stbl = child(ch, minf.body, minf.end, "stbl");
        if (stbl == null) return;

        // stsz: version/flags(4) sample_size(4) sample_count(4) [entry_size(4)...]
        Box stsz = child(ch, stbl.body, stbl.end, "stsz");
        if (stsz == null) return;
        ByteBuffer s = read(ch, stsz.body, 12);
        long size = s.getInt(4) & 0xffffffffL;
        long count = s.getInt(8) & 0xffffffffL;
        if (size == 0 && count > 0) size = read(ch, stsz.body + 12, 4).getInt(0) & 0xffffffffL;

        // co64 / stco: version/flags(4) entry_count(4) [offset...]
        long offset;
        Box co = child(ch, stbl.body, stbl.end, "co64");
        if (co != null) {
            offset = read(ch, co.body + 8, 8).getLong(0);
        } else {
            co = child(ch, stbl.body, stbl.end, "stco");
            if (co == null) return;
            offset = read(ch, co.body + 8, 4).getInt(0) & 0xffffffffL;
        }
        r.jpegOffset = offset;
        r.jpegSize = size;
    }

    private static void parseCanon(FileChannel ch, Box canon, Result r) throws IOException {
        long off = canon.body;
        while (off + 8 <= canon.end) {
            Box b = readBox(ch, off, canon.end);
            Map<Integer, String> names = null;
            if ("CMT1".equals(b.type)) names = IFD0_TAGS;
            else if ("CMT2".equals(b.type)) names = EXIF_TAGS;
            else if ("CMT4".equals(b.type)) names = GPS_TAGS;
            long n = b.end - b.body;
            if (names != null && n > 8 && n < 1024 * 1024) {
                parseTiff(read(ch, b.body, (int) n).array(), names, r);
            }
            off = b.end;
        }
    }

    // ------------------------------------------------------------------- TIFF

    private static void parseTiff(byte[] t, Map<Integer, String> names, Result r) {
        if (t.length < 8) return;
        ByteOrder order;
        if (t[0] == 'I' && t[1] == 'I') order = ByteOrder.LITTLE_ENDIAN;
        else if (t[0] == 'M' && t[1] == 'M') order = ByteOrder.BIG_ENDIAN;
        else return;
        ByteBuffer b = ByteBuffer.wrap(t).order(order);
        long ifd = b.getInt(4) & 0xffffffffL;
        if (ifd < 8 || ifd + 2 > t.length) return;
        int n = b.getShort((int) ifd) & 0xffff;
        for (int i = 0; i < n; i++) {
            int e = (int) ifd + 2 + i * 12;
            if (e + 12 > t.length) break;
            int tag = b.getShort(e) & 0xffff;
            String name = names.get(tag);
            if (name == null) continue;
            int type = b.getShort(e + 2) & 0xffff;
            long count = b.getInt(e + 4) & 0xffffffffL;
            int unit = typeSize(type);
            if (unit == 0 || count == 0 || count > 4096) continue;
            long total = unit * count;
            long vo = total <= 4 ? e + 8 : (b.getInt(e + 8) & 0xffffffffL);
            if (vo + total > t.length) continue;
            String v = format(b, t, type, (int) count, (int) vo, name);
            if (v != null && !v.isEmpty()) r.exif.put(name, v);
        }
    }

    private static int typeSize(int type) {
        switch (type) {
            case 1: case 2: case 7: return 1;   // BYTE, ASCII, UNDEFINED
            case 3: return 2;                   // SHORT
            case 4: case 9: return 4;           // LONG, SLONG
            case 5: case 10: return 8;          // RATIONAL, SRATIONAL
            default: return 0;
        }
    }

    private static String format(ByteBuffer b, byte[] t, int type, int count, int vo, String name) {
        StringBuilder sb = new StringBuilder();
        switch (type) {
            case 2: {
                String s = new String(t, vo, count, StandardCharsets.US_ASCII);
                int z = s.indexOf('\0');
                return (z >= 0 ? s.substring(0, z) : s).trim();
            }
            case 1:
                for (int i = 0; i < count; i++) append(sb, Integer.toString(t[vo + i] & 0xff));
                return sb.toString();
            case 3:
                for (int i = 0; i < count; i++) append(sb, Integer.toString(b.getShort(vo + 2 * i) & 0xffff));
                return sb.toString();
            case 4:
                for (int i = 0; i < count; i++) append(sb, Long.toString(b.getInt(vo + 4 * i) & 0xffffffffL));
                return sb.toString();
            case 9:
                for (int i = 0; i < count; i++) append(sb, Integer.toString(b.getInt(vo + 4 * i)));
                return sb.toString();
            case 5:
            case 10: {
                boolean signed = type == 10;
                long[] num = new long[count];
                long[] den = new long[count];
                for (int i = 0; i < count; i++) {
                    num[i] = signed ? b.getInt(vo + 8 * i) : b.getInt(vo + 8 * i) & 0xffffffffL;
                    den[i] = signed ? b.getInt(vo + 8 * i + 4) : b.getInt(vo + 8 * i + 4) & 0xffffffffL;
                }
                if (DECIMAL_TAGS.contains(name)) {
                    if (den[0] == 0) return null;
                    return Double.toString((double) num[0] / den[0]);
                }
                if ("GPSTimeStamp".equals(name)) {
                    if (count < 3) return null;
                    StringBuilder ts = new StringBuilder();
                    for (int i = 0; i < 3; i++) {
                        long v = den[i] == 0 ? 0 : num[i] / den[i];
                        if (i > 0) ts.append(':');
                        ts.append(v < 10 ? "0" : "").append(v);
                    }
                    return ts.toString();
                }
                for (int i = 0; i < count; i++) {
                    if (den[i] == 0) return null;
                    append(sb, num[i] + "/" + den[i]);
                }
                return sb.toString();
            }
            default:
                return null;
        }
    }

    // ------------------------------------------------------------------- util

    private static void append(StringBuilder sb, String v) {
        if (sb.length() > 0) sb.append(',');
        sb.append(v);
    }

    private static ByteBuffer read(FileChannel ch, long pos, int n) throws IOException {
        ByteBuffer buf = ByteBuffer.allocate(n);
        while (buf.hasRemaining()) {
            int k = ch.read(buf, pos + buf.position());
            if (k < 0) throw new EOFException("CR3 terpotong");
        }
        buf.flip();
        return buf;
    }

    private static String hex(byte[] a) {
        StringBuilder sb = new StringBuilder();
        for (byte x : a) sb.append(String.format("%02x", x & 0xff));
        return sb.toString();
    }

    /** Desktop test: java Cr3Parser.java file.CR3 [out.jpg] */
    public static void main(String[] args) throws IOException {
        try (FileInputStream in = new FileInputStream(args[0]); FileChannel ch = in.getChannel()) {
            Result r = parse(ch);
            System.out.println("jpeg offset=" + r.jpegOffset + " size=" + r.jpegSize);
            for (Map.Entry<String, String> e : r.exif.entrySet()) {
                System.out.println("  " + e.getKey() + " = " + e.getValue());
            }
            if (args.length > 1) {
                try (java.io.FileOutputStream out = new java.io.FileOutputStream(args[1])) {
                    out.write(readJpeg(ch, r));
                }
            }
        }
    }
}
