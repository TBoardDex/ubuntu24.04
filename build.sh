#!/bin/bash
# Build an Ubuntu Server or Desktop rootfs; the SDK supplies the Rockchip kernel.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
SDK_DIR=$(dirname "$SCRIPT_DIR")

usage()
{
	cat <<'EOF'
Usage: ubuntu24.04/build.sh [--check | <image directory>]
  Standalone entry: cd ubuntu24.04 && ./mk-image.sh [--check | <image directory>]
  --check  Check host dependencies without downloading or building anything.
  Default image directories: output/ubuntu-noble-<server|desktop>/images
  Normal SDK entry: ./build.sh ubuntu (uses the configured edition)
  Explicit SDK entries: ./build.sh ubuntu-server / ubuntu-desktop
  Standalone edition: RK_UBUNTU_FLAVOR=server|desktop (Desktop: GNOME + GDM3)
  Standalone release: RK_UBUNTU_VERSION=noble (Ubuntu 24.04 only)
  Image size: calculated automatically from rootfs contents (same as Debian)
  Resume after post-processing failure: UBUNTU_RESUME_ROOTFS=<retained rootfs>
  Local settings: ubuntu24.04/config.local (see config.example)
EOF
}

case "${1:-}" in
	-h|--help|help) usage; exit 0 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 1; }

if [[ -f "$SCRIPT_DIR/config.local" ]]; then
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/config.local"
fi

RELEASE=${RK_UBUNTU_VERSION:-noble}
FLAVOR=${RK_UBUNTU_FLAVOR:-server}
MIRROR=${RK_UBUNTU_MIRROR:-https://ports.ubuntu.com/ubuntu-ports}
# Shared SDK defaults, also applied by the final Debian/Ubuntu account hook.
UBUNTU_USER=tboard
UBUNTU_PASSWORD=tboard
UBUNTU_CONSOLE=${UBUNTU_CONSOLE:-ttyFIQ0}
# SDK menuconfig wins for SDK builds. Standalone builds use config.local or
# UBUNTU_DESKTOP_GPU; wayland = GDM/GNOME on Wayland (Debian trixie reference
# stack), mali = Rockchip Xorg on X11, software = distro Mesa llvmpipe.
UBUNTU_DESKTOP_GPU=${RK_UBUNTU_DESKTOP_GPU:-${UBUNTU_DESKTOP_GPU:-wayland}}
# Hostname follows the board model taken from the selected defconfig prefix
# (tboard-r5a_rk3588s_... -> TBoard-R5A); standalone builds default to R5A.
UBUNTU_MODEL=${RK_DEFCONFIG:-}
UBUNTU_MODEL=${UBUNTU_MODEL%%_*}
case "$UBUNTU_MODEL" in
	tboard-*) UBUNTU_MODEL=${UBUNTU_MODEL#tboard-} ;;
	*) UBUNTU_MODEL=r5a ;;
esac
UBUNTU_HOSTNAME=${UBUNTU_HOSTNAME:-TBoard-${UBUNTU_MODEL^^}}

fail()
{
	echo "ERROR: $*" >&2
	exit 1
}

[[ "$RELEASE" == noble ]] || fail "Only Ubuntu 24.04 (noble) is supported. Update RK_UBUNTU_VERSION or select an Ubuntu 24.04 defconfig."
[[ "$FLAVOR" == server || "$FLAVOR" == desktop ]] || fail "RK_UBUNTU_FLAVOR must be server or desktop."
[[ "$MIRROR" =~ ^https?://[^[:space:]]+$ ]] || fail "Invalid ports mirror URL."
[[ "$UBUNTU_USER" =~ ^[a-z][a-z0-9_-]*$ && "$UBUNTU_USER" != root ]] || fail "Invalid login user."
[[ "$UBUNTU_CONSOLE" =~ ^tty[A-Za-z0-9]+$ ]] || fail "Invalid console device."
[[ "$UBUNTU_PASSWORD" != *$'\n'* && "$UBUNTU_PASSWORD" != *:* ]] || fail "Password cannot contain a newline or colon."
[[ "$UBUNTU_DESKTOP_GPU" == software || "$UBUNTU_DESKTOP_GPU" == mali || "$UBUNTU_DESKTOP_GPU" == wayland ]] || fail "UBUNTU_DESKTOP_GPU must be wayland, mali or software."
if [[ "$FLAVOR" == desktop && "$UBUNTU_DESKTOP_GPU" == mali ]]; then
	(cd "$SCRIPT_DIR/packages/noble/arm64" && sha256sum --check --quiet SHA256SUMS) || fail "Noble Rockchip Xorg package is missing or has a checksum mismatch."
fi

(cd "$SCRIPT_DIR" && sha256sum --check --quiet bsp/SHA256SUMS) || fail "Ubuntu BSP resource checksum mismatch."

missing=()
for tool in debootstrap chroot unshare mount umount mountpoint findmnt \
	mkfs.ext4 truncate flock rsync du find install dpkg-deb sha256sum python3 patchelf; do
	command -v "$tool" >/dev/null || missing+=("$tool")
done
if (( EUID != 0 )); then
	command -v sudo >/dev/null || missing+=(sudo)
fi
if (( ${#missing[@]} )); then
	fail "Missing tools: ${missing[*]}. See ubuntu24.04/README.md for host packages."
fi

HOST_ARCH=$(uname -m)
BUILD_PREFIX=()
[[ -r /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] || fail "Install ubuntu-keyring on the host."
[[ -r /usr/share/debootstrap/scripts/$RELEASE ]] || fail "Host debootstrap does not support $RELEASE; update debootstrap. See ubuntu24.04/README.md."
if [[ "$HOST_ARCH" != aarch64 ]]; then
	command -v qemu-aarch64-static >/dev/null || fail "Install qemu-user-static."
	BINFMT=/proc/sys/fs/binfmt_misc/qemu-aarch64
	[[ -r "$BINFMT" ]] && grep -qx enabled "$BINFMT" || \
		fail "Enable arm64 binfmt on the host: sudo update-binfmts --enable qemu-aarch64"
	if [[ "$HOST_ARCH" == x86_64 ]]; then
		command -v setarch >/dev/null || fail "Install util-linux for setarch."
		setarch "$HOST_ARCH" -R true || fail "Allow setarch -R on this host, or use a native ARM64 build host."
		# Inherit ADDR_NO_RANDOMIZE into QEMU and its fork/exec children; do
		# not change the host-wide ASLR setting or the resulting target image.
		BUILD_PREFIX=(setarch "$HOST_ARCH" -R)
	fi
fi
if findmnt -no OPTIONS -T "$SCRIPT_DIR" | tr ',' '\n' | grep -qx nodev; then
	fail "The SDK filesystem is mounted nodev; debootstrap needs a filesystem allowing device nodes."
fi
echo "Ubuntu host checks passed ($RELEASE, $FLAVOR, arm64, auto-sized image)."
[[ "$FLAVOR" != desktop ]] || echo "Desktop: Ubuntu GNOME + GDM3, Xorg, renderer=$UBUNTU_DESKTOP_GPU."
[[ "${1:-}" != --check ]] || exit 0

OUTPUT_NAME=ubuntu-noble-$FLAVOR
IMAGE_DIR=$(realpath -m "${1:-$SDK_DIR/output/$OUTPUT_NAME/images}")
BUILD_ENV=(
	"RELEASE=$RELEASE" "FLAVOR=$FLAVOR" "MIRROR=$MIRROR"
	"UBUNTU_USER=$UBUNTU_USER" "UBUNTU_PASSWORD=$UBUNTU_PASSWORD"
	"UBUNTU_CONSOLE=$UBUNTU_CONSOLE"
	"UBUNTU_DESKTOP_GPU=$UBUNTU_DESKTOP_GPU"
	"UBUNTU_HOSTNAME=$UBUNTU_HOSTNAME"
	"RK_SESSION=${RK_SESSION:-}"
	"UBUNTU_SDK_CONFIG=${RK_CONFIG:-}"
	"UBUNTU_KERNEL_BUILD_DIR=${UBUNTU_KERNEL_BUILD_DIR:-}"
	"UBUNTU_RESUME_ROOTFS=${UBUNTU_RESUME_ROOTFS:-}"
)

# Private mounts prevent interrupted builds from leaving host bind mounts behind.
# Only pass the configuration needed by the privileged stage.
if (( EUID == 0 )); then
	exec env "${BUILD_ENV[@]}" "${BUILD_PREFIX[@]}" unshare --mount --propagation private \
		"$SCRIPT_DIR/mk-rootfs.sh" "$IMAGE_DIR"
else
	exec sudo env "${BUILD_ENV[@]}" "${BUILD_PREFIX[@]}" unshare --mount --propagation private \
		"$SCRIPT_DIR/mk-rootfs.sh" "$IMAGE_DIR"
fi
