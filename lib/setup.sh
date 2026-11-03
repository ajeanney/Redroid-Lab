# shellcheck shell=bash
# `setup`: host packages, Binder, image build and the ARM64 smoke APK.

# Each entry: command, Arch package, Debian/Ubuntu package ('-' = nothing to install).
HOST_PACKAGES=(
    "docker docker docker.io"
    "systemctl - systemd"
    "btmgmt bluez-utils bluez"
    "adb android-tools adb"
    "scrcpy scrcpy scrcpy"
    "nft nftables nftables"
    "ip iproute2 iproute2"
    "flock util-linux util-linux"
    "rfkill util-linux rfkill"
    "sha256sum coreutils coreutils"
    "modprobe kmod kmod"
    "tcpdump tcpdump tcpdump"
    "mitmdump mitmproxy mitmproxy"
    "editcap wireshark-cli wireshark-common"
    "nsenter util-linux util-linux"
    "curl curl curl"
    "xz xz xz-utils"
)

require_runtime_tools() {
    need docker adb nft flock sudo ip ss sha256sum modprobe
}

host_family() {
    local id='' id_like=''
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        id=${ID:-}
        id_like=${ID_LIKE:-}
    fi
    case $id in
        arch|manjaro|endeavouros) echo arch; return ;;
        ubuntu) echo ubuntu; return ;;
        debian) echo debian; return ;;
    esac
    case " $id_like " in
        *' arch '*) echo arch ;;
        *' ubuntu '*) echo ubuntu ;;
        *' debian '*) echo debian ;;
        *) echo unsupported ;;
    esac
}

binder_guidance() {
    case $(host_family) in
        arch) echo "use an Arch kernel with CONFIG_ANDROID_BINDERFS and CONFIG_ANDROID_BINDER_IPC enabled" ;;
        ubuntu) echo "install linux-modules-extra-$(uname -r), then load binder_linux; otherwise use an Ubuntu kernel with CONFIG_ANDROID_BINDERFS and CONFIG_ANDROID_BINDER_IPC" ;;
        debian) echo "use a kernel with CONFIG_ANDROID_BINDERFS and CONFIG_ANDROID_BINDER_IPC, or install a compatible binder_linux DKMS module" ;;
        *) echo "use a kernel with BinderFS and Android Binder IPC support" ;;
    esac
}

ensure_binder() {
    grep -Eq 'nodev[[:space:]]+binder' /proc/filesystems && return 0
    if modinfo binder_linux >/dev/null 2>&1; then
        note "Loading the host binder_linux module"
        sudo modprobe binder_linux devices=binder,hwbinder,vndbinder || true
    fi
    grep -Eq 'nodev[[:space:]]+binder' /proc/filesystems || \
        die "Binder filesystem is unavailable; $(binder_guidance)"
}

install_host_dependencies() {
    local family entry cmd arch_pkg deb_pkg pkg missing=()
    family=$(host_family)
    [[ $family != unsupported ]] || \
        die "unsupported distribution; install Docker, ADB, scrcpy, nftables, BlueZ tools, iproute2, util-linux, rfkill, kmod, tcpdump, mitmproxy, Wireshark's editcap, curl, and xz manually"
    for entry in "${HOST_PACKAGES[@]}"; do
        read -r cmd arch_pkg deb_pkg <<<"$entry"
        if [[ $family == arch ]]; then pkg=$arch_pkg; else pkg=$deb_pkg; fi
        [[ $pkg == - ]] || type -P "$cmd" >/dev/null || missing+=("$pkg")
    done
    (( ${#missing[@]} )) || return 0
    need sudo
    if [[ $family == arch ]]; then
        need pacman
        note "Installing missing Arch packages: ${missing[*]}"
        sudo pacman -S --needed --noconfirm "${missing[@]}"
    else
        need apt-get
        note "Installing missing Debian/Ubuntu packages: ${missing[*]}"
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    fi
}

validate_host_capabilities() {
    docker info >/dev/null 2>&1 || die "Docker daemon is unavailable (enable docker.service and ensure this user can access it)"
    ensure_binder
    [[ $BT_ENABLE == 0 ]] || validate_adapter_identity
    [[ -e /dev/dri/renderD128 ]] || \
        die "render node /dev/dri/renderD128 is unavailable"
    if [[ -r /sys/class/drm/renderD128/device/vendor ]] && \
       [[ $(< /sys/class/drm/renderD128/device/vendor) != 0x8086 ]]; then
        note "warning: /dev/dri/renderD128 is not an Intel GPU; if Android fails to boot, set REDROID_GPU_MODE=guest in a local config"
    fi
}

build_image() {
    local build_args=()
    local name
    # shellcheck disable=SC1090
    source "$INPUTS_FILE"
    for name in \
        BT_SOURCE_URL BT_SOURCE_TREE_SHA256 \
        VNDK_INCLUDE_URL VNDK_INCLUDE_TREE_SHA256 \
        VNDK_SHARED_URL VNDK_SHARED_TREE_SHA256 \
        NDK_URL NDK_SHA256 \
        CAMERA_SOURCE_URL CAMERA_SOURCE_TREE_SHA256 \
        CAMERA_INTERFACE_URL CAMERA_INTERFACE_TREE_SHA256 \
        CAMERA_METADATA_HEADER_URL CAMERA_METADATA_HEADER_SHA256 \
        GRALLOC_SOURCE_URL GRALLOC_SOURCE_SHA256 GBM_HEADER_URL GBM_HEADER_SHA256 \
        GRALLOC_HEADER_URL GRALLOC_HEADER_SHA256; do
        build_args+=(--build-arg "$name=${!name}")
    done
    note "Building Bluetooth and synthetic camera HAL overlay image"
    docker build --pull \
        --build-arg "BASE_IMAGE=$BASE_IMAGE" \
        "${build_args[@]}" \
        --tag "$LOCAL_IMAGE" "$SCRIPT_DIR"
}

build_arm64_smoke_apk() {
    local sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
    if [[ -z $sdk_root && -d ${HOME:-}/Android/Sdk ]]; then
        sdk_root=$HOME/Android/Sdk
    fi
    if [[ -z $sdk_root || ! -d $sdk_root/build-tools || ! -d $sdk_root/platforms || \
          ! -d $sdk_root/ndk || ! -x $SCRIPT_DIR/build/build-arm64-smoke-apk.sh ]] || \
       ! command -v javac >/dev/null 2>&1 || ! command -v zip >/dev/null 2>&1; then
        note "Android SDK not found; ARM64 app smoke will be skipped at startup"
        return 0
    fi
    note "Building ARM64 native-bridge smoke APK"
    ANDROID_SDK_ROOT=$sdk_root "$SCRIPT_DIR/build/build-arm64-smoke-apk.sh" \
        "$SMOKE_APK"
}

cmd_setup() {
    acquire_lock
    install_host_dependencies
    require_runtime_tools
    need scrcpy
    validate_host_capabilities
    build_arm64_smoke_apk || note "ARM64 smoke APK build failed; the smoke test will be skipped at startup"
    build_image
    note "Validating image metadata"
    docker image inspect "$LOCAL_IMAGE" --format 'image={{.Id}} size={{.Size}} bytes'
    note "Setup complete"
}
