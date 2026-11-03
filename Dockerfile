ARG BASE_IMAGE=redroid/redroid@sha256:11d58a64bfbde2253d1cce81bff409ff58174980222d1bada232d9ef59181191

FROM ${BASE_IMAGE} AS redroid_root

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241 AS bt_builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

ARG BT_SOURCE_URL
ARG BT_SOURCE_TREE_SHA256
ARG VNDK_INCLUDE_URL
ARG VNDK_INCLUDE_TREE_SHA256
ARG VNDK_SHARED_URL
ARG VNDK_SHARED_TREE_SHA256
ARG NDK_URL
ARG NDK_SHA256

COPY build/build-bt-hal.sh /usr/local/bin/build-bt-hal
COPY build/btlinux-service.cc /build-input/btlinux-service.cc
# Platform LL-NDK libraries (not shipped in the VNDK snapshot) come from the
# exact redroid image that will run the executable.
COPY --from=redroid_root /system/lib64/ /redroid-root/system/lib64/
COPY --from=redroid_root /vendor/lib64/ /redroid-root/vendor/lib64/

RUN --mount=type=cache,id=redroid-bt-downloads,target=/download-cache \
    REDROID_DOWNLOAD_CACHE=/download-cache /usr/local/bin/build-bt-hal

# Validate the final binary against libraries from the exact pinned redroid image.
COPY build/validate-runtime.sh /usr/local/bin/validate-runtime
RUN /usr/local/bin/validate-runtime \
      /out/android.hardware.bluetooth@1.1-service.btlinux \
      /redroid-root/system/lib64 /redroid-root/vendor/lib64 \
    && /opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip \
      /out/android.hardware.bluetooth@1.1-service.btlinux

FROM bt_builder AS camera_builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends patch \
    && rm -rf /var/lib/apt/lists/*

ARG CAMERA_SOURCE_URL
ARG CAMERA_SOURCE_TREE_SHA256
ARG CAMERA_INTERFACE_URL
ARG CAMERA_INTERFACE_TREE_SHA256
ARG CAMERA_METADATA_HEADER_URL
ARG CAMERA_METADATA_HEADER_SHA256
ARG GRALLOC_SOURCE_URL
ARG GRALLOC_SOURCE_SHA256
ARG GBM_HEADER_URL
ARG GBM_HEADER_SHA256
ARG GRALLOC_HEADER_URL
ARG GRALLOC_HEADER_SHA256
COPY build/build-camera-hal.sh /usr/local/bin/build-camera-hal
COPY build/synthetic-camera-service.cc build/synthetic-camera-jpeg.cc build/synthetic-camera-compat.patch build/camera-gralloc-compat.patch build/check-camera.cc /build-input/
RUN bash /usr/local/bin/build-camera-hal

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="Redroid-Lab: redroid 14 with experimental Linux-HCI Bluetooth HAL" \
      org.opencontainers.image.description="Pinned redroid 14 plus AOSP btlinux and synthetic camera services"

COPY --from=bt_builder --chmod=0755 \
  /out/android.hardware.bluetooth@1.1-service.btlinux \
  /vendor/bin/hw/android.hardware.bluetooth@1.1-service.btlinux
# The stock image loads this filename. Replacing its contents prevents the
# simulated RootCanal service from competing for the default HIDL instance.
COPY --chmod=0644 build/android.hardware.bluetooth@1.1-service.btlinux.rc \
  /vendor/etc/init/android.hardware.bluetooth@1.1-service.sim.rc

COPY --from=camera_builder --chmod=0755 \
  /out/android.hardware.camera.provider@2.4-service.synthetic \
  /vendor/bin/hw/android.hardware.camera.provider@2.4-service.synthetic
COPY --from=camera_builder --chmod=0644 /out/gralloc.gbm.so /vendor/lib64/hw/gralloc.gbm.so
COPY --from=camera_builder --chmod=0644 /out/NOTICE.camera-gbm /vendor/etc/NOTICE.camera-gbm
# These HIDL libraries are in /system in the base image, outside the vendor namespace.
COPY --from=redroid_root \
  /system/lib64/android.hardware.camera.common@1.0.so \
  /system/lib64/android.hardware.camera.device@1.0.so \
  /system/lib64/android.hardware.camera.device@3.2.so \
  /system/lib64/android.hardware.camera.provider@2.4.so \
  /vendor/lib64/
COPY --chmod=0644 build/android.hardware.camera.provider@2.4-service.synthetic.rc /vendor/etc/init/
COPY --chmod=0644 build/android.hardware.camera.provider@2.4.synthetic.xml /vendor/etc/vintf/manifest/
