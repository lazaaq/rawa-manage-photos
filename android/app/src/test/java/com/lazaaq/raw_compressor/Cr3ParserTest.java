package com.lazaaq.raw_compressor;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.Assume;
import org.junit.BeforeClass;
import org.junit.Test;

public class Cr3ParserTest {
    private static final String CANON_UUID = "85c0b687820f11e08111f4ce462b6a48";
    private static final String PRVW_UUID = "eaf42b5e1c984b88b9fbb7dc406e4d16";

    private static byte[] jpeg;

    @BeforeClass
    public static void makeJpeg() {
        // Minimal JPEG-shaped stream: SOI, APP0, SOF0 (64x48, 3 components), EOI.
        jpeg = concat(
                new byte[] {(byte) 0xFF, (byte) 0xD8},
                new byte[] {(byte) 0xFF, (byte) 0xE0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0},
                new byte[] {(byte) 0xFF, (byte) 0xC0, 0, 17, 8, 0, 48, 0, 64, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1},
                new byte[] {(byte) 0xFF, (byte) 0xD9});
    }

    /** Reads {width, height} from the first SOFn marker; null if the stream is not a JPEG. */
    private static int[] jpegDimensions(byte[] j) {
        if (j.length < 4 || (j[0] & 0xff) != 0xFF || (j[1] & 0xff) != 0xD8) return null;
        int i = 2;
        while (i + 4 <= j.length) {
            if ((j[i] & 0xff) != 0xFF) return null;
            int marker = j[i + 1] & 0xff;
            if (marker == 0xD9 || marker == 0xDA) return null;
            int len = ((j[i + 2] & 0xff) << 8) | (j[i + 3] & 0xff);
            boolean sof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
            if (sof && i + 9 <= j.length) {
                int h = ((j[i + 5] & 0xff) << 8) | (j[i + 6] & 0xff);
                int w = ((j[i + 7] & 0xff) << 8) | (j[i + 8] & 0xff);
                return new int[] {w, h};
            }
            i += 2 + len;
        }
        return null;
    }

    private static boolean endsWithEoi(byte[] j) {
        return j.length >= 2 && (j[j.length - 2] & 0xff) == 0xFF && (j[j.length - 1] & 0xff) == 0xD9;
    }

    // ------------------------------------------------------------------ tests

    @Test
    public void parsesFirstTrackJpegAndExif() throws IOException {
        Built f = new Cr3Builder().build();
        Cr3Parser.Result r = parse(f.bytes);

        assertEquals(f.jpegOffset, r.jpegOffset);
        assertEquals(jpeg.length, r.jpegSize);
        assertArrayEquals(jpeg, readJpeg(f.bytes, r));

        assertEquals("Canon", r.exif.get("Make"));
        assertEquals("Canon EOS R6m2", r.exif.get("Model"));
        assertEquals("6", r.exif.get("Orientation"));
        assertEquals("2023:03:30 14:06:03", r.exif.get("DateTimeOriginal"));
        assertEquals("RF24-70mm F2.8 L IS USM", r.exif.get("LensModel"));
    }

    @Test
    public void extractedJpegDecodes() throws IOException {
        Built f = new Cr3Builder().build();
        byte[] j = readJpeg(f.bytes, parse(f.bytes));
        assertArrayEquals(new int[] {64, 48}, jpegDimensions(j));
        assertTrue(endsWithEoi(j));
    }

    @Test
    public void exifValuesUseExifInterfaceFormats() throws IOException {
        Cr3Parser.Result r = parse(new Cr3Builder().build().bytes);

        // Decimal for ExifInterface "compatibility" tags.
        assertEquals(0.0004, Double.parseDouble(r.exif.get("ExposureTime")), 1e-12);
        assertEquals("2.8", r.exif.get("FNumber"));
        // Rationals as num/den, lists comma separated, signed rationals keep sign.
        assertEquals("24/1", r.exif.get("FocalLength"));
        assertEquals("-1/3", r.exif.get("ExposureBiasValue"));
        assertEquals("24/1,70/1,28/10,28/10", r.exif.get("LensSpecification"));
        // SHORT / LONG / ASCII.
        assertEquals("100", r.exif.get("PhotographicSensitivity"));
        assertEquals("023020001382", r.exif.get("BodySerialNumber"));
        // GPS.
        assertEquals("S", r.exif.get("GPSLatitudeRef"));
        assertEquals("6/1,10/1,3000/100", r.exif.get("GPSLatitude"));
        assertEquals("E", r.exif.get("GPSLongitudeRef"));
        assertEquals("106/1,49/1,1234/100", r.exif.get("GPSLongitude"));
        assertEquals("0", r.exif.get("GPSAltitudeRef"));
        assertEquals("07:05:09", r.exif.get("GPSTimeStamp"));
        assertEquals("2023:03:30", r.exif.get("GPSDateStamp"));
    }

    @Test
    public void asciiTrailingNullsAndSpacesAreTrimmed() throws IOException {
        Cr3Builder b = new Cr3Builder();
        b.ifd0 = new Tiff(true).ascii(0x010F, "Canon\0\0\0").ascii(0x0110, "  R6  \0");
        Cr3Parser.Result r = parse(b.build().bytes);
        assertEquals("Canon", r.exif.get("Make"));
        assertEquals("R6", r.exif.get("Model"));
    }

    @Test
    public void zeroDenominatorAndUnknownTagsAreSkipped() throws IOException {
        Cr3Builder b = new Cr3Builder();
        b.exifIfd = new Tiff(true)
                .rational(0x829D, 28, 0)       // FNumber with den 0
                .rational(0x920A, 50, 0)       // FocalLength with den 0
                .shortVal(0x9999, 1)           // unknown tag
                .shortVal(0x8827, 400);
        Cr3Parser.Result r = parse(b.build().bytes);
        assertFalse(r.exif.containsKey("FNumber"));
        assertFalse(r.exif.containsKey("FocalLength"));
        assertEquals("400", r.exif.get("PhotographicSensitivity"));
        assertEquals(1, r.exif.size() - countIfd0AndGps(r));
    }

    @Test
    public void bigEndianTiffBlocks() throws IOException {
        Cr3Builder b = new Cr3Builder();
        b.ifd0 = new Tiff(false).ascii(0x010F, "Canon").shortVal(0x0112, 8);
        b.exifIfd = new Tiff(false).rational(0x829A, 1, 250).shortVal(0x8827, 3200);
        Cr3Parser.Result r = parse(b.build().bytes);
        assertEquals("Canon", r.exif.get("Make"));
        assertEquals("8", r.exif.get("Orientation"));
        assertEquals(0.004, Double.parseDouble(r.exif.get("ExposureTime")), 1e-12);
        assertEquals("3200", r.exif.get("PhotographicSensitivity"));
    }

    @Test
    public void stcoAndUniformSampleSize() throws IOException {
        Cr3Builder b = new Cr3Builder();
        b.useStco = true;
        b.uniformSampleSize = true;
        Built f = b.build();
        Cr3Parser.Result r = parse(f.bytes);
        assertEquals(f.jpegOffset, r.jpegOffset);
        assertArrayEquals(jpeg, readJpeg(f.bytes, r));
    }

    @Test
    public void largeSizeBoxHeader() throws IOException {
        Cr3Builder b = new Cr3Builder();
        b.largeMoovHeader = true;
        Built f = b.build();
        assertArrayEquals(jpeg, readJpeg(f.bytes, parse(f.bytes)));
    }

    @Test
    public void onlyFirstTrackIsUsed() throws IOException {
        Cr3Builder b = new Cr3Builder();
        b.secondTrak = true; // points at a non-JPEG payload
        Built f = b.build();
        Cr3Parser.Result r = parse(f.bytes);
        assertEquals(f.jpegOffset, r.jpegOffset);
    }

    @Test
    public void worksWithoutCanonMetadata() throws IOException {
        Cr3Builder b = new Cr3Builder();
        b.withCanonUuid = false;
        Built f = b.build();
        Cr3Parser.Result r = parse(f.bytes);
        assertTrue(r.exif.isEmpty());
        assertArrayEquals(jpeg, readJpeg(f.bytes, r));
    }

    @Test
    public void rejectsNonCr3Files() {
        expectIOException(jpeg);                                  // plain JPEG
        expectIOException("hello world, not a cr3 at all".getBytes(StandardCharsets.US_ASCII));
        expectIOException(new byte[0]);
    }

    @Test
    public void rejectsTruncatedFile() throws IOException {
        Built f = new Cr3Builder().build();
        for (int cut : new int[] {30, 200, f.jpegOffset - 4, f.jpegOffset + jpeg.length / 2}) {
            expectIOException(Arrays.copyOf(f.bytes, cut));
        }
    }

    @Test
    public void rejectsPayloadThatIsNotJpeg() throws IOException {
        Built f = new Cr3Builder().build();
        byte[] bad = f.bytes.clone();
        bad[f.jpegOffset] = 0x00; // break SOI marker
        expectIOException(bad);
    }

    @Test
    public void rejectsBoxSizeBeyondFile() throws IOException {
        Built f = new Cr3Builder().build();
        byte[] bad = f.bytes.clone();
        ByteBuffer.wrap(bad).putInt(24, Integer.MAX_VALUE); // moov size
        expectIOException(bad);
    }

    /** Real camera files: CR3_SAMPLES_DIR=/path/to/folder ./gradlew testDebugUnitTest */
    @Test
    public void realSamples() throws IOException {
        String dir = System.getProperty("cr3.samples", "");
        Assume.assumeFalse("CR3_SAMPLES_DIR not set", dir.isEmpty());
        File[] files = new File(dir).listFiles((d, n) -> n.toLowerCase().endsWith(".cr3"));
        Assume.assumeTrue(files != null && files.length > 0);
        for (File file : files) {
            try (FileChannel ch = FileChannel.open(file.toPath(), StandardOpenOption.READ)) {
                Cr3Parser.Result r = Cr3Parser.parse(ch);
                byte[] j = Cr3Parser.readJpeg(ch, r);
                int[] wh = jpegDimensions(j);
                assertNotNull(file.getName(), wh);
                assertTrue(file.getName(), endsWithEoi(j));
                assertTrue(file.getName(), Math.max(wh[0], wh[1]) >= 4000);
                assertTrue(file.getName(), r.exif.get("Make").startsWith("Canon"));
                assertTrue(file.getName(), r.exif.get("DateTimeOriginal").matches("\\d{4}:\\d\\d:\\d\\d \\d\\d:\\d\\d:\\d\\d"));
                assertNotNull(file.getName(), r.exif.get("Orientation"));
                System.out.println(file.getName() + ": " + wh[0] + "x" + wh[1] + " " + r.exif);
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    private static int countIfd0AndGps(Cr3Parser.Result r) {
        int n = 0;
        for (String k : r.exif.keySet()) {
            if (k.startsWith("GPS") || k.equals("Make") || k.equals("Model") || k.equals("Orientation")
                    || k.equals("DateTime")) n++;
        }
        return n;
    }

    private static Cr3Parser.Result parse(byte[] bytes) throws IOException {
        try (FileChannel ch = channel(bytes)) {
            return Cr3Parser.parse(ch);
        }
    }

    private static byte[] readJpeg(byte[] bytes, Cr3Parser.Result r) throws IOException {
        try (FileChannel ch = channel(bytes)) {
            return Cr3Parser.readJpeg(ch, r);
        }
    }

    private static void expectIOException(byte[] bytes) {
        try {
            parse(bytes);
            fail("expected IOException for " + bytes.length + " bytes");
        } catch (IOException expected) {
            // ok
        }
    }

    private static FileChannel channel(byte[] bytes) throws IOException {
        Path p = Files.createTempFile("cr3test", ".cr3");
        p.toFile().deleteOnExit();
        Files.write(p, bytes);
        return FileChannel.open(p, StandardOpenOption.READ);
    }

    // ---------------------------------------------------------------- builder

    private static final class Built {
        byte[] bytes;
        int jpegOffset;
    }

    /** Builds a minimal CR3-shaped file: ftyp, moov{canon uuid, trak...}, uuid(PRVW), mdat. */
    private static final class Cr3Builder {
        boolean useStco;
        boolean uniformSampleSize;
        boolean largeMoovHeader;
        boolean secondTrak;
        boolean withCanonUuid = true;

        Tiff ifd0 = new Tiff(true)
                .ascii(0x010F, "Canon")
                .ascii(0x0110, "Canon EOS R6m2")
                .shortVal(0x0112, 6)
                .ascii(0x0132, "2023:03:30 14:06:03");
        Tiff exifIfd = new Tiff(true)
                .rational(0x829A, 1, 2500)
                .rational(0x829D, 28, 10)
                .shortVal(0x8827, 100)
                .ascii(0x9003, "2023:03:30 14:06:03")
                .srational(0x9204, -1, 3)
                .rational(0x920A, 24, 1)
                .ascii(0xA431, "023020001382")
                .rationals(0xA432, new long[] {24, 1, 70, 1, 28, 10, 28, 10})
                .ascii(0xA434, "RF24-70mm F2.8 L IS USM");
        Tiff gps = new Tiff(true)
                .bytes(0x0000, new byte[] {2, 3, 0, 0})
                .ascii(0x0001, "S")
                .rationals(0x0002, new long[] {6, 1, 10, 1, 3000, 100})
                .ascii(0x0003, "E")
                .rationals(0x0004, new long[] {106, 1, 49, 1, 1234, 100})
                .bytes(0x0005, new byte[] {0})
                .rationals(0x0007, new long[] {7, 1, 5, 1, 9, 1})
                .ascii(0x001D, "2023:03:30");

        Built build() {
            byte[] ftyp = box("ftyp", concat("crx ".getBytes(StandardCharsets.US_ASCII), be32(1),
                    "crx isom".getBytes(StandardCharsets.US_ASCII)));
            byte[] prvw = uuidBox(PRVW_UUID, concat(new byte[8], box("PRVW", new byte[16])));
            // First pass with a placeholder offset to learn the layout; offsets are fixed width.
            byte[] moov = moov(0, 0);
            int jpegOffset = ftyp.length + moov.length + prvw.length + 8;
            int junkOffset = jpegOffset + jpeg.length;
            moov = moov(jpegOffset, junkOffset);
            byte[] junk = "NOT A JPEG PAYLOAD".getBytes(StandardCharsets.US_ASCII);
            byte[] mdat = box("mdat", concat(jpeg, junk));
            Built b = new Built();
            b.bytes = concat(ftyp, moov, prvw, mdat);
            b.jpegOffset = jpegOffset;
            return b;
        }

        private byte[] moov(long jpegOffset, long junkOffset) {
            List<byte[]> kids = new ArrayList<>();
            if (withCanonUuid) {
                kids.add(uuidBox(CANON_UUID, concat(
                        box("CNCV", "CanonCR3_001/00.10.00/00.00.00".getBytes(StandardCharsets.US_ASCII)),
                        box("CMT1", ifd0.build()),
                        box("CMT2", exifIfd.build()),
                        box("CMT3", new Tiff(true).shortVal(0x0001, 1).build()),
                        box("CMT4", gps.build()),
                        box("THMB", new byte[32]))));
            }
            kids.add(box("mvhd", new byte[100]));
            kids.add(trak(jpegOffset, jpeg.length));
            if (secondTrak) kids.add(trak(junkOffset, 18));
            byte[] body = concat(kids.toArray(new byte[0][]));
            return largeMoovHeader ? largeBox("moov", body) : box("moov", body);
        }

        private byte[] trak(long offset, int size) {
            byte[] stsd = box("stsd", concat(new byte[4], be32(1), box("CRAW", new byte[16])));
            byte[] stsz = uniformSampleSize
                    ? box("stsz", concat(new byte[4], be32(size), be32(1)))
                    : box("stsz", concat(new byte[4], be32(0), be32(1), be32(size)));
            byte[] co = useStco
                    ? box("stco", concat(new byte[4], be32(1), be32((int) offset)))
                    : box("co64", concat(new byte[4], be32(1), be64(offset)));
            byte[] stbl = box("stbl", concat(stsd, box("free", new byte[7]), stsz, co));
            byte[] minf = box("minf", concat(box("vmhd", new byte[12]), stbl));
            byte[] mdia = box("mdia", concat(box("mdhd", new byte[24]), minf));
            return box("trak", concat(box("tkhd", new byte[84]), mdia));
        }
    }

    /** Builds a single-IFD TIFF block like Canon's CMTn boxes. */
    private static final class Tiff {
        private final boolean little;
        private final List<Object[]> entries = new ArrayList<>(); // {tag, type, count, valueBytes}

        Tiff(boolean little) {
            this.little = little;
        }

        private ByteBuffer buf(int n) {
            return ByteBuffer.allocate(n).order(little ? ByteOrder.LITTLE_ENDIAN : ByteOrder.BIG_ENDIAN);
        }

        Tiff ascii(int tag, String s) {
            byte[] v = (s.endsWith("\0") ? s : s + "\0").getBytes(StandardCharsets.US_ASCII);
            entries.add(new Object[] {tag, 2, v.length, v});
            return this;
        }

        Tiff bytes(int tag, byte[] v) {
            entries.add(new Object[] {tag, 1, v.length, v});
            return this;
        }

        Tiff shortVal(int tag, int v) {
            entries.add(new Object[] {tag, 3, 1, buf(2).putShort((short) v).array()});
            return this;
        }

        Tiff rational(int tag, long num, long den) {
            return rationals(tag, new long[] {num, den});
        }

        Tiff rationals(int tag, long[] nd) {
            ByteBuffer b = buf(4 * nd.length);
            for (long x : nd) b.putInt((int) x);
            entries.add(new Object[] {tag, 5, nd.length / 2, b.array()});
            return this;
        }

        Tiff srational(int tag, int num, int den) {
            entries.add(new Object[] {tag, 10, 1, buf(8).putInt(num).putInt(den).array()});
            return this;
        }

        byte[] build() {
            int n = entries.size();
            int dataStart = 8 + 2 + n * 12 + 4;
            int dataLen = 0;
            for (Object[] e : entries) {
                int len = ((byte[]) e[3]).length;
                if (len > 4) dataLen += len + (len & 1);
            }
            ByteBuffer b = buf(dataStart + dataLen);
            b.put(little ? (byte) 'I' : (byte) 'M').put(little ? (byte) 'I' : (byte) 'M').putShort((short) 42).putInt(8);
            b.putShort((short) n);
            int data = dataStart;
            for (Object[] e : entries) {
                byte[] v = (byte[]) e[3];
                b.putShort((short) (int) (Integer) e[0]).putShort((short) (int) (Integer) e[1]).putInt((Integer) e[2]);
                if (v.length <= 4) {
                    b.put(Arrays.copyOf(v, 4));
                } else {
                    b.putInt(data);
                    int save = b.position();
                    b.position(data);
                    b.put(v);
                    b.position(save);
                    data += v.length + (v.length & 1);
                }
            }
            b.putInt(0);
            return b.array();
        }
    }

    // -------------------------------------------------------------- byte utils

    private static byte[] box(String type, byte[] body) {
        return concat(be32(8 + body.length), type.getBytes(StandardCharsets.ISO_8859_1), body);
    }

    private static byte[] largeBox(String type, byte[] body) {
        return concat(be32(1), type.getBytes(StandardCharsets.ISO_8859_1), be64(16 + body.length), body);
    }

    private static byte[] uuidBox(String uuidHex, byte[] body) {
        byte[] uuid = new byte[16];
        for (int i = 0; i < 16; i++) uuid[i] = (byte) Integer.parseInt(uuidHex.substring(2 * i, 2 * i + 2), 16);
        return box("uuid", concat(uuid, body));
    }

    private static byte[] be32(int v) {
        return ByteBuffer.allocate(4).putInt(v).array();
    }

    private static byte[] be64(long v) {
        return ByteBuffer.allocate(8).putLong(v).array();
    }

    private static byte[] concat(byte[]... parts) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] p : parts) out.write(p, 0, p.length);
        return out.toByteArray();
    }
}
