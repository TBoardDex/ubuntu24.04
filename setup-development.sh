#!/bin/bash
# Executed in the Noble ARM64 chroot for both fresh and resumed images.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Development counterparts of the libraries included in the Debian image.
# Keep release-native GLib, Mesa, GTK and GStreamer; do not import Debian's
# core libraries or its patched desktop stack into Noble.
packages=(
    systemd-timesyncd tzdata
    build-essential gcc-14 g++-14 cmake meson ninja-build pkg-config git gdb
    python3-dev python3-pip python3-venv wget
    libssl-dev zlib1g-dev libjpeg-dev libpng-dev libwebp-dev libtiff-dev
    libbz2-dev liblzma-dev liblz4-dev libzstd-dev libarchive-dev
    libffi-dev libxml2-dev libudev-dev libsystemd-dev libusb-1.0-0-dev
    libdrm-dev libegl-dev libgles-dev libgl-dev libgbm-dev libwayland-dev
    libseat-dev libx11-dev libx11-xcb-dev libxext-dev libxv-dev libxfixes-dev
    libxcb-dri2-0 libxcb-dri3-0 libxcb-present0 libxcb-sync1 libxcb-xfixes0
    libgtk-3-dev libgtk2.0-dev libasound2-dev libv4l-dev v4l-utils
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-base-apps
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
    gstreamer1.0-alsa gstreamer1.0-gl
    weston libweston-13-dev mesa-utils glmark2-es2
    ocl-icd-opencl-dev clinfo libvulkan-dev vulkan-tools
    bc bison flex libelf-dev libncurses-dev
)

if [[ "${1:-}" == --list-packages ]]; then
    printf '%s\n' "${packages[@]}"
    exit 0
fi

. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_CODENAME" == noble && $(dpkg --print-architecture) == arm64 ]]

stage=/tmp/tboard-components
[[ -f "$stage/manifest.json" ]]
python3 - "$stage" <<'PY'
import hashlib, json, sys
from pathlib import Path
stage = Path(sys.argv[1])
for name, checksum in json.loads((stage / 'manifest.json').read_text())['packages'].items():
    assert hashlib.sha256((stage / name).read_bytes()).hexdigest() == checksum, name
PY

apt-get update
apt-get install -y --no-remove --no-install-recommends "${packages[@]}" "$stage"/*.deb
ldconfig

# Configure offline during image generation; timedatectl needs a running
# system bus. timesyncd starts on the board and retries when networking returns.
ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
printf 'Asia/Shanghai\n' > /etc/timezone
mkdir -p /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/10-tboard.conf <<'NTP'
[Time]
NTP=ntp.aliyun.com time.cloudflare.com
FallbackNTP=ntp.ubuntu.com
NTP
systemctl enable systemd-timesyncd.service

# Software-only checks: compile and link with installed SDK APIs; loading a
# plugin must work without a board, while codec/NPU/GPU execution needs hardware.
work=$(mktemp -d /tmp/tboard-development-check.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
printf '#include <stdio.h>\nint main(void) { puts("C toolchain OK"); return 0; }\n' > "$work/hello.c"
gcc "$work/hello.c" -o "$work/hello"
"$work/hello"
printf '#include <iostream>\nint main() { std::cout << "C++ toolchain OK" << std::endl; }\n' > "$work/hello.cpp"
g++ "$work/hello.cpp" -o "$work/hello-cpp"
"$work/hello-cpp"
pkg-config --exists libdrm egl glesv2 gbm wayland-client gtk+-3.0 \
    gstreamer-1.0 gstreamer-video-1.0 alsa libv4l2 librga rockchip_mpp rknn
cat > "$work/sdk.c" <<'C'
#include <rockchip/rk_mpi.h>
#include <rknn/rknn_api.h>
int main(int argc, char **argv) {
    MppCtx ctx = 0;
    MppApi *api = 0;
    rknn_context npu = 0;
    if (argc == 100) {
        mpp_destroy(ctx);
        rknn_destroy(npu);
    }
    return api != 0 || argv == 0;
}
C
gcc "$work/sdk.c" $(pkg-config --cflags --libs rockchip_mpp rknn) -o "$work/sdk"
printf '#include <cstddef>\n#include <cstdio>\n#include <rga/im2d.h>\nint main() { return imStrError(IM_STATUS_SUCCESS) == 0; }\n' > "$work/rga.cpp"
g++ "$work/rga.cpp" $(pkg-config --cflags --libs librga) -o "$work/rga"

export GST_REGISTRY="$work/gst-registry.bin"
gst-inspect-1.0 --version
# This SDK plugin probes MPP during registration. On an x86 build host its
# GStreamer initialization fails even when every shared symbol resolves.
# Always verify ELF loading below; enumerate hardware elements on the board.
if [[ -e /dev/mpp_service ]]; then
    gst-inspect-1.0 --gst-disable-registry-fork \
        /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstrockchipmpp.so > "$work/gstreamer-rockchip.txt"
fi
# Check all vendor ELF dependencies, including versioned GLIBC/GLIBCXX symbols.
for library in /usr/lib/aarch64-linux-gnu/librga.so \
    /usr/lib/aarch64-linux-gnu/librockchip_mpp.so /usr/lib/librknnrt.so \
    /usr/lib/librkaiq.so /usr/bin/rkaiq_3A_server \
    /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstrockchipmpp.so \
    /opt/rockchip/mali/libmali.so.1 /opt/rockchip/mali/libEGL.so.1 \
    /opt/rockchip/mali/libMaliOpenCL.so.1 /opt/rockchip/mali/libMaliVulkan.so.1; do
    dependencies=$(ldd "$library" 2>&1)
    if [[ "$dependencies" == *"not found"* ]]; then
        printf '%s\n%s\n' "$library" "$dependencies" >&2
        exit 1
    fi
done
python3 - <<'PY'
import ctypes
for name in ['librga.so', 'librockchip_mpp.so', 'librknnrt.so', 'librkaiq.so',
             '/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstrockchipmpp.so',
             '/opt/rockchip/mali/libEGL.so.1', '/opt/rockchip/mali/libMaliOpenCL.so.1',
             # Mali loads these at EGL initialization with dlopen, so ldd
             # on libmali alone cannot detect a missing X11 backend library.
             'libxcb-dri2.so.0', 'libxcb-dri3.so.0', 'libxcb-present.so.0',
             'libxcb-sync.so.1', 'libxcb-xfixes.so.0']:
    ctypes.CDLL(name)
PY

release=$(python3 -c 'import json; print(json.load(open("/tmp/tboard-components/manifest.json"))["kernel_release"])')
headers="/usr/src/linux-headers-$release"
[[ -s "$headers/Module.symvers" && -L "/lib/modules/$release/build" ]]
[[ "$(readlink -f "/lib/modules/$release/build")" == "$headers" ]]
# Compile a harmless module but never load it into the build host's kernel.
printf '#include <linux/module.h>\nMODULE_LICENSE("GPL");\n' > "$work/tboard_check.c"
printf 'obj-m := tboard_check.o\n' > "$work/Makefile"
make -s -C "$headers" M="$work" ARCH=arm64 CC=gcc-14 modules
[[ -s "$work/tboard_check.ko" ]]

getent group render >/dev/null || groupadd --system render
usermod -aG video,render tboard
cat > /etc/udev/rules.d/70-tboard-accelerators.rules <<'UDEV'
KERNEL=="mali[0-9]*", GROUP="video", MODE="0660", TAG+="uaccess"
KERNEL=="rga", GROUP="video", MODE="0660", TAG+="uaccess"
KERNEL=="mpp_service", GROUP="video", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="dma_heap", GROUP="video", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660", TAG+="uaccess"
UDEV
mkdir -p /usr/share/tboard
cp "$stage/manifest.json" /usr/share/tboard/components.json
dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' > /usr/share/tboard/packages.tsv
apt-get check
audit=$(dpkg --audit)
[[ -z "$audit" ]] || { printf '%s\n' "$audit" >&2; exit 1; }
[[ $(readlink /etc/localtime) == /usr/share/zoneinfo/Asia/Shanghai ]]
systemctl is-enabled systemd-timesyncd.service
apt-get clean
echo 'Ubuntu development libraries, Rockchip plugins and kernel module compilation verified.'
