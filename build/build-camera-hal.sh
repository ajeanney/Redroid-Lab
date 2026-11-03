#!/usr/bin/env bash
set -Eeuo pipefail

check_tree() {
    local actual
    actual=$(cd "$1"; find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
    [[ $actual == "$2" ]] || { echo "camera source checksum mismatch: $1" >&2; exit 1; }
}

mkdir -p /work/camera/goldfish /work/camera/interfaces
cd /work/camera
curl -fsSL --retry 3 "${CAMERA_SOURCE_URL:?}" -o goldfish.tar.gz
curl -fsSL --retry 3 "${CAMERA_INTERFACE_URL:?}" -o interfaces.tar.gz
tar -xzf goldfish.tar.gz -C goldfish
tar -xzf interfaces.tar.gz -C interfaces
check_tree goldfish "${CAMERA_SOURCE_TREE_SHA256:?}"
check_tree interfaces "${CAMERA_INTERFACE_TREE_SHA256:?}"
curl -fsSL --retry 3 "${CAMERA_METADATA_HEADER_URL:?}" -o header.base64
base64 -d header.base64 >camera_metadata_hidden.h
printf '%s  %s\n' "${CAMERA_METADATA_HEADER_SHA256:?}" camera_metadata_hidden.h | sha256sum --check --status
patch --batch --fuzz=0 -d goldfish -p1 </build-input/synthetic-camera-compat.patch

mkdir -p gralloc graphics-include/android
curl -fsSL --retry 3 "${GRALLOC_SOURCE_URL:?}" -o gralloc.tar.gz
printf '%s  %s\n' "${GRALLOC_SOURCE_SHA256:?}" gralloc.tar.gz | sha256sum --check --status
tar -xzf gralloc.tar.gz --strip-components=1 -C gralloc
for name in GBM GRALLOC; do
    url_name=${name}_HEADER_URL
    hash_name=${name}_HEADER_SHA256
    if [[ $name == GBM ]]; then header=graphics-include/gbm.h; else header=graphics-include/android/gralloc_handle.h; fi
    curl -fsSL --retry 3 "${!url_name}" -o header.base64
    base64 -d header.base64 >"$header"
    printf '%s  %s\n' "${!hash_name}" "$header" | sha256sum --check --status
done
patch --batch --fuzz=0 -d gralloc -p1 </build-input/camera-gralloc-compat.patch
sed -n '1,22p' gralloc/gralloc_gbm.cpp >/out/NOTICE.camera-gbm

includes=(-nostdinc++ -I/work/vndk/include/external/libcxx/include -Igoldfish -I. -Igraphics-include
    -Iinterfaces/common/1.0/default/include -Iinterfaces/device/3.2/default)
for path in system/core/libutils/include system/core/libcutils/include system/core/base/include \
    system/core/liblog/include_vndk system/libhidl/base/include system/libhidl/transport/include \
    system/libhwbinder/include system/libfmq/include frameworks/native/libs/binder/include \
    frameworks/native/libs/nativebase/include frameworks/native/libs/ui/include \
    frameworks/native/libs/math/include hardware/libhardware/include system/media/camera/include \
    external/libjpeg-turbo external/libexif external/libyuv/files/include \
    frameworks/native/libs/nativewindow/include frameworks/native/libs/gralloc/types/include \
    frameworks/native/opengl/include system/core/libsystem/include; do
    includes+=(-I"/work/vndk/include/$path")
done
while IFS= read -r directory; do
    includes+=(-I"$directory" -I"$directory/include")
done < <(find /work/vndk/include/generated-headers -type d -name gen)

sources=(/build-input/synthetic-camera-service.cc /build-input/synthetic-camera-jpeg.cc
    goldfish/jpeg-stub/Compressor.cpp goldfish/jpeg-stub/JpegStub.cpp)
for name in EmulatedBaseCamera EmulatedCamera3 EmulatedFakeCamera3 Exif Thumbnail; do
    sources+=("goldfish/$name.cpp")
done
for name in Sensor Scene JpegCompressor; do
    sources+=("goldfish/fake-pipeline2/$name.cpp")
done
for name in CameraMetadata CameraModule CameraParameters HandleImporter VendorTagDescriptor; do
    sources+=("interfaces/common/1.0/default/$name.cpp")
done
for name in CameraDevice CameraDeviceSession convert; do
    sources+=("interfaces/device/3.2/default/$name.cpp")
done
libraries=()
for name in libbase libbinder liblog libutils libcutils libui libjpeg libexif libyuv libcamera_metadata \
    libhardware libhidlbase libfmq libgralloctypes libsync \
    android.hardware.camera.common@1.0 android.hardware.camera.device@1.0 \
    android.hardware.camera.device@3.2 android.hardware.camera.provider@2.4 \
    android.hardware.graphics.mapper@2.0 android.hardware.graphics.mapper@3.0 android.hardware.graphics.mapper@4.0; do
    libraries+=(-l:"$name.so")
done

toolchain=/opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64
"$toolchain/bin/x86_64-linux-android30-clang++" -std=c++17 -fno-rtti -O2 -fPIC -shared \
    "${includes[@]}" -Igralloc gralloc/gralloc.cpp gralloc/gralloc_gbm.cpp \
    -L/redroid-root/system/lib64 -L/redroid-root/vendor/lib64 \
    -Wl,--no-undefined -l:libgbm.so.1 -l:libcutils.so -l:liblog.so -l:libc++.so \
    -o /out/gralloc.gbm.so
/usr/local/bin/validate-runtime /out/gralloc.gbm.so /redroid-root/system/lib64 /redroid-root/vendor/lib64
"$toolchain/bin/llvm-strip" /out/gralloc.gbm.so

"$toolchain/bin/x86_64-linux-android30-clang++" \
    -std=c++17 -O2 -fno-rtti -fPIE -pie -DLOG_NDEBUG=1 -Wno-c++11-narrowing \
    "${includes[@]}" "${sources[@]}" \
    -L/redroid-root/system/lib64 -L/redroid-root/vendor/lib64 \
    -L/work/vndk/shared/vndk-core -L/work/vndk/shared/vndk-sp \
    -Wl,-rpath-link,/redroid-root/system/lib64 -Wl,-rpath-link,/redroid-root/vendor/lib64 \
    -Wl,-rpath-link,/work/vndk/shared/vndk-core -Wl,-rpath-link,/work/vndk/shared/vndk-sp \
    -Wl,--no-undefined "${libraries[@]}" -l:libc++.so -ldl -lm \
    -o /out/android.hardware.camera.provider@2.4-service.synthetic
/usr/local/bin/validate-runtime /out/android.hardware.camera.provider@2.4-service.synthetic \
    /redroid-root/system/lib64 /redroid-root/vendor/lib64
"$toolchain/bin/llvm-strip" /out/android.hardware.camera.provider@2.4-service.synthetic

# The check is extracted from the builder for runtime verification, not shipped in the image.
"$toolchain/bin/x86_64-linux-android30-clang++" -std=c++17 -O2 -static-libstdc++ \
    -I/work/vndk/include/frameworks/native/libs/binder/ndk/include_platform \
    /build-input/check-camera.cc -lcamera2ndk -lmediandk -landroid \
    /redroid-root/system/lib64/libbinder_ndk.so -o /out/check-camera
