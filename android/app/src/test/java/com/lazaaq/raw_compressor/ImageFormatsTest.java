package com.lazaaq.raw_compressor;

import static org.junit.Assert.assertEquals;

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
}
