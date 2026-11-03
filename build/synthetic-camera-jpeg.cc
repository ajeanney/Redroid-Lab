#include "JpegCompressor.h"

namespace android {
NV21JpegCompressor::NV21JpegCompressor() { JpegStub_init(&mStub); }
NV21JpegCompressor::~NV21JpegCompressor() { JpegStub_cleanup(&mStub); }
status_t NV21JpegCompressor::compressRawImage(const void* image, int width, int height,
                                            int quality, ExifData* exif) {
    return JpegStub_compress(&mStub, image, width, height, quality, exif);
}
size_t NV21JpegCompressor::getCompressedSize() { return JpegStub_getCompressedSize(&mStub); }
void NV21JpegCompressor::getCompressedImage(void* buffer) { JpegStub_getCompressedImage(&mStub, buffer); }
}
