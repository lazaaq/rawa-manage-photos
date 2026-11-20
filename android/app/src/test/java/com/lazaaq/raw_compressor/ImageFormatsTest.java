package com.lazaaq.raw_compressor;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

import org.junit.Test;

public class ImageFormatsTest {
    @Test
    public void explicitFormatWins() {
        assertEquals("png", ImageFormats.resolve("png", "IMG_1.HEIC"));
        assertEquals("webp", ImageFormats.resolve("webp", "a.jpg"));
        assertEquals("jpeg", ImageFormats.resolve("jpeg", "a.png"));
    }

    @Test
    public void sameKeepsWritableSourceFormat() {
        assertEquals("jpeg", ImageFormats.resolve("same", "a.JPG"));
        assertEquals("jpeg", ImageFormats.resolve("same", "a.jpeg"));
        assertEquals("png", ImageFormats.resolve("same", "Screenshot.PNG"));
        assertEquals("webp", ImageFormats.resolve("same", "x.webp"));
    }

    @Test
    public void unwritableSourceFormatsBecomeJpeg() {
        assertEquals("jpeg", ImageFormats.resolve("same", "IMG_1.HEIC"));
        assertEquals("jpeg", ImageFormats.resolve("same", "IMG_1.heif"));
        assertEquals("jpeg", ImageFormats.resolve("same", "noext"));
        assertEquals("jpeg", ImageFormats.resolve(null, null));
        // Format Android cannot write behaves like "same".
        assertEquals("png", ImageFormats.resolve("heic", "a.png"));
        assertEquals("jpeg", ImageFormats.resolve("heic", "a.heic"));
    }

    @Test
    public void extensionsAndMimes() {
        assertEquals("jpg", ImageFormats.extension("jpeg"));
        assertEquals("png", ImageFormats.extension("png"));
        assertEquals("webp", ImageFormats.extension("webp"));
        assertEquals("image/jpeg", ImageFormats.mime("jpeg"));
        assertEquals("image/png", ImageFormats.mime("png"));
        assertEquals("image/webp", ImageFormats.mime("webp"));
    }

    @Test
    public void outputNameReplacesExtension() {
        assertEquals("IMG_1.jpg", ImageFormats.outputName("IMG_1.HEIC", "jpeg"));
        assertEquals("my.photo.png", ImageFormats.outputName("my.photo.jpg", "png"));
        assertEquals("noext.webp", ImageFormats.outputName("noext", "webp"));
        assertEquals(".hidden.jpg", ImageFormats.outputName(".hidden", "jpeg"));
        assertEquals("photo.jpg", ImageFormats.outputName("", "jpeg"));
    }

    @Test
    public void rawDetectionIsCaseInsensitiveAndExcludesNormalPhotos() {
        assertTrue(ImageFormats.isRaw("3U2A6708.CR3"));
        assertTrue(ImageFormats.isRaw("a.dng"));
        assertTrue(ImageFormats.isRaw("x.NEF"));
        assertFalse(ImageFormats.isRaw("IMG_1.HEIC"));
        assertFalse(ImageFormats.isRaw("a.jpg"));
        assertFalse(ImageFormats.isRaw("raw"));
        assertFalse(ImageFormats.isRaw(null));
    }

    @Test
    public void documentPathForInternalAndSdCard() {
        String root = "/storage/emulated/0";
        assertEquals("/storage/emulated/0/Pictures/a.jpg", ImageFormats.documentPath("primary:Pictures/a.jpg", root));
        assertEquals("/storage/emulated/0/x.jpg", ImageFormats.documentPath("PRIMARY:x.jpg", root));
        assertEquals("/storage/1A2B-3C4D/DCIM/rawa/a (1).jpg",
                ImageFormats.documentPath("1A2B-3C4D:DCIM/rawa/a (1).jpg", root));
        assertEquals("/storage/1A2B-3C4D", ImageFormats.documentPath("1A2B-3C4D:", root));
        assertNull(ImageFormats.documentPath("no-colon", root));
        assertNull(ImageFormats.documentPath(":x", root));
        assertNull(ImageFormats.documentPath(null, root));
    }

    @Test
    public void uniqueNameAddsCounterBeforeExtension() {
        Set<String> taken = new HashSet<>(Arrays.asList("a.jpg", "a (1).jpg", "b"));
        assertEquals("c.jpg", ImageFormats.uniqueName("c.jpg", taken::contains));
        assertEquals("a (2).jpg", ImageFormats.uniqueName("a.jpg", taken::contains));
        assertEquals("b (1)", ImageFormats.uniqueName("b", taken::contains));
        assertEquals("my.photo (1).png",
                ImageFormats.uniqueName("my.photo.png", n -> n.equals("my.photo.png")));
    }

    @Test
    public void errorMessages() {
        assertEquals("Foto terlalu besar untuk memori perangkat. Pilih ukuran yang lebih kecil.",
                ImageFormats.errorMessage(new OutOfMemoryError("Failed to allocate 192000000 bytes")));
        assertEquals("Gagal menulis JPG", ImageFormats.errorMessage(new IllegalStateException("Gagal menulis JPG")));
        assertEquals("SecurityException", ImageFormats.errorMessage(new SecurityException()));
    }
}
