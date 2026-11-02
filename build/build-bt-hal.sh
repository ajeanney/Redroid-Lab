#!/usr/bin/env bash
set -euo pipefail

require_env() {
    local name=$1
    if [[ -z ${!name:-} ]]; then
        echo "missing build argument: $name" >&2
        exit 2
    fi
}

fetch_archive() {
    local url=$1 output=$2 cache_file
    if [[ -n ${REDROID_DOWNLOAD_CACHE:-} ]]; then
        mkdir -p "$REDROID_DOWNLOAD_CACHE"
        cache_file=$REDROID_DOWNLOAD_CACHE/$(printf '%s' "$url" | sha256sum | awk '{print $1}')
        if [[ ! -s $cache_file ]]; then
            curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$cache_file.tmp"
            mv "$cache_file.tmp" "$cache_file"
        fi
        cp "$cache_file" "$output"
    else
        curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$output"
    fi
}

check_tree() {
    local directory=$1 expected=$2 actual
    actual=$(
        cd "$directory"
        find . -type f -print0 \
            | sort -z \
            | xargs -0 sha256sum \
            | sha256sum \
            | awk '{print $1}'
    )
    if [[ $actual != "$expected" ]]; then
        echo "content checksum mismatch for $directory: expected $expected, got $actual" >&2
        exit 1
    fi
}

for name in \
    BT_SOURCE_URL BT_SOURCE_TREE_SHA256 \
    VNDK_INCLUDE_URL VNDK_INCLUDE_TREE_SHA256 \
    VNDK_SHARED_URL VNDK_SHARED_TREE_SHA256 \
    NDK_URL NDK_SHA256; do
    require_env "$name"
done

mkdir -p /work/source /work/vndk/include /work/vndk/shared /out /opt
fetch_archive "$BT_SOURCE_URL" /work/bt-source.tar.gz
fetch_archive "$VNDK_INCLUDE_URL" /work/vndk-include.tar.gz
fetch_archive "$VNDK_SHARED_URL" /work/vndk-shared.tar.gz
fetch_archive "$NDK_URL" /work/android-ndk.zip
printf '%s  %s\n' "$NDK_SHA256" /work/android-ndk.zip | sha256sum --check --status

tar -xzf /work/bt-source.tar.gz -C /work/source
tar -xzf /work/vndk-include.tar.gz -C /work/vndk/include
tar -xzf /work/vndk-shared.tar.gz -C /work/vndk/shared
check_tree /work/source "$BT_SOURCE_TREE_SHA256"
check_tree /work/vndk/include "$VNDK_INCLUDE_TREE_SHA256"
check_tree /work/vndk/shared "$VNDK_SHARED_TREE_SHA256"
unzip -q /work/android-ndk.zip -d /opt
mv /opt/android-ndk-r27d /opt/android-ndk

# VNDK 30's platform libc++ header supplies Android locale fallbacks that are
# now provided directly by the newer, checksum-pinned NDK's bionic headers.
# Remove that single include after validating the pristine VNDK tree so the
# old platform C++ ABI can be compiled against the current API 30 sysroot.
sed -i '/support\/xlocale\/__posix_l_fallback.h/d' \
    /work/vndk/include/external/libcxx/include/support/android/locale_bionic.h

# The pinned HAL hardcodes hci0. Read the index from a system property instead
# (redroid.sh passes ro.redroid.bt.hci) so any adapter can be used; the default
# stays 0. Applied after the source checksum was verified, like the edit above.
sed -i -e 's/int hci_interface = 0;/int hci_interface = ::android::base::GetIntProperty("ro.redroid.bt.hci", 0);/' \
    -e '1i #include <android-base/properties.h>' /work/source/bluetooth_hci.cc
grep -q 'GetIntProperty("ro.redroid.bt.hci"' /work/source/bluetooth_hci.cc

toolchain=/opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64
cxx=$toolchain/bin/x86_64-linux-android30-clang++

include_args=(
    -nostdinc++
    -I/work/vndk/include/external/libcxx/include
    -I/work/source
    -I/work/vndk/include/system/core/libutils/include
    -I/work/vndk/include/system/core/libcutils/include
    -I/work/vndk/include/system/core/base/include
    -I/work/vndk/include/system/core/liblog/include_vndk
    -I/work/vndk/include/system/libhidl/base/include
    -I/work/vndk/include/system/libhidl/transport/include
    -I/work/vndk/include/system/libhwbinder/include
    -I/work/vndk/include/system/libfmq/include
    -I/work/vndk/include/frameworks/native/libs/binder/include
    -I/work/vndk/include/frameworks/native/libs/nativebase/include
    -I/work/vndk/include/generated-headers/hardware/interfaces/bluetooth/1.0/android.hardware.bluetooth@1.0_genc++_headers/gen
    -I/work/vndk/include/generated-headers/hardware/interfaces/bluetooth/1.1/android.hardware.bluetooth@1.1_genc++_headers/gen
    -I/work/vndk/include/generated-headers/system/libhidl/transport/base/1.0/android.hidl.base@1.0_genc++_headers/gen
    -I/work/vndk/include/generated-headers/system/libhidl/transport/manager/1.0/android.hidl.manager@1.0_genc++_headers/gen
)

library_args=(
    -L/work/vndk/shared/vndk-core
    -L/work/vndk/shared/vndk-sp
    -L/redroid-root/system/lib64
    -L/redroid-root/vendor/lib64
    '-Wl,-rpath-link,/work/vndk/shared/vndk-core'
    '-Wl,-rpath-link,/work/vndk/shared/vndk-sp'
    '-Wl,-rpath-link,/redroid-root/system/lib64'
    '-Wl,-rpath-link,/redroid-root/vendor/lib64'
    '-Wl,--no-undefined'
    '-Wl,--no-as-needed'
    -l:android.hardware.bluetooth@1.0.so
    -l:android.hardware.bluetooth@1.1.so
    -l:libbase.so
    -l:libcutils.so
    -l:libhidlbase.so
    -l:liblog.so
    -l:libutils.so
    -l:libc++.so
    -ldl
)

"$cxx" -std=c++17 -O2 -fPIE -pie -fno-rtti -Wall -Wextra \
    "${include_args[@]}" \
    /work/source/async_fd_watcher.cc \
    /work/source/bluetooth_hci.cc \
    /work/source/h4_protocol.cc \
    /work/source/hci_packetizer.cc \
    /build-input/btlinux-service.cc \
    "${library_args[@]}" \
    -o /out/android.hardware.bluetooth@1.1-service.btlinux
