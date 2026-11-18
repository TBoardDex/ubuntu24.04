#!/usr/bin/env python3
"""Cross-build Rockchip Xorg against an Ubuntu Noble ARM64 sysroot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

SDK = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sysroot', type=Path, required=True)
    parser.add_argument('--cc', type=Path, required=True)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=SDK / 'ubuntu24.04/packages/noble/arm64')
    args = parser.parse_args()
    root, cc, build, output = (p.resolve() for p in (args.sysroot, args.cc, args.build_dir, args.output))
    os_release = (root / 'etc/os-release').read_text()
    if 'VERSION_ID="24.04"' not in os_release or 'ID=ubuntu\n' not in os_release:
        raise SystemExit('Expected an Ubuntu 24.04 ARM64 sysroot')
    if build.exists():
        raise SystemExit('Use a new build directory to avoid reusing a stale Meson configuration')
    build.mkdir(parents=True)
    source = SDK / 'external/xserver'
    prefix = str(cc)[:-3]
    common = ['--sysroot=' + str(root), '-isystem', str(root / 'usr/include/aarch64-linux-gnu'),
              '-B' + str(root / 'usr/lib/aarch64-linux-gnu') + '/']
    link = ['-L' + str(root / 'usr/lib/aarch64-linux-gnu'),
            '-Wl,-rpath-link,' + str(root / 'usr/lib/aarch64-linux-gnu')]
    cross = build / 'cross.ini'
    cross.write_text('[binaries]\nc = ' + repr(str(cc)) + '\nar = ' + repr(prefix + 'ar') +
                     '\nstrip = ' + repr(prefix + 'strip') + "\npkgconfig = '/usr/bin/pkg-config'\n"
                     '[properties]\nneeds_exe_wrapper = true\nc_args = ' + repr(common) +
                     '\nc_link_args = ' + repr(common + link) +
                     "\n[host_machine]\nsystem = 'linux'\ncpu_family = 'aarch64'\ncpu = 'aarch64'\nendian = 'little'\n")
    env = {**os.environ, 'LC_ALL': 'C', 'PKG_CONFIG_PATH': '', 'PKG_CONFIG_SYSROOT_DIR': str(root),
           'PKG_CONFIG_LIBDIR': ':'.join(str(root / p) for p in
                                       ['usr/lib/aarch64-linux-gnu/pkgconfig', 'usr/share/pkgconfig'])}
    options = ['--prefix=/opt/rockchip/xserver', '--libdir=lib', '--libexecdir=lib', '--buildtype=release',
               '-Dxorg=true', '-Dglamor=true', '-Dxephyr=false', '-Dxnest=false', '-Dxvfb=false',
               '-Dxwin=false', '-Dxquartz=false', '-Dxselinux=false', '-Ddocs=false', '-Ddevel-docs=false',
               '-Ddocs-pdf=false', '-Dsystemd_logind=true', '-Dsuid_wrapper=false', '-Dsha1=libnettle',
               '-Dsecure-rpc=false', '-Ddefault_font_path=/usr/share/fonts/X11/misc',
               '-Dxkb_bin_dir=/usr/bin', '-Dxkb_dir=/usr/share/X11/xkb', '-Dxkb_output_dir=/var/lib/xkb']
    subprocess.run(['meson', 'setup', str(build / 'build'), str(source), '--cross-file', str(cross), *options], env=env, check=True)
    subprocess.run(['ninja', '-C', str(build / 'build'), '-j', str(min(os.cpu_count() or 4, 16))], env=env, check=True)
    package_xserver(build / 'build', output, root, cc, options)


def package_xserver(build, output, sysroot, cc, options):
    source = SDK / 'external/xserver'
    stage = build.parent / ('package-' + build.name)
    if stage.exists():
        raise SystemExit('Package staging directory already exists')
    prefix = stage / 'opt/rockchip/xserver'
    files = {'hw/xfree86/Xorg': 'bin/Xorg', 'hw/xfree86/gtf': 'bin/gtf',
             'hw/xfree86/glamor_egl/libglamoregl.so': 'lib/xorg/modules/libglamoregl.so',
             'hw/xfree86/drivers/modesetting/modesetting_drv.so': 'lib/xorg/modules/drivers/modesetting_drv.so',
             'hw/xfree86/dixmods/libglx.so': 'lib/xorg/modules/extensions/libglx.so',
             'hw/xfree86/exa/libexa.so': 'lib/xorg/modules/libexa.so',
             'hw/xfree86/dixmods/libshadow.so': 'lib/xorg/modules/libshadow.so',
             'hw/xfree86/shadowfb/libshadowfb.so': 'lib/xorg/modules/libshadowfb.so',
             'hw/xfree86/fbdevhw/libfbdevhw.so': 'lib/xorg/modules/libfbdevhw.so',
             'hw/xfree86/dixmods/libwfb.so': 'lib/xorg/modules/libwfb.so',
             'hw/xfree86/int10/libint10.so': 'lib/xorg/modules/libint10.so',
             'hw/xfree86/vgahw/libvgahw.so': 'lib/xorg/modules/libvgahw.so'}
    for name, destination in files.items():
        src = build / name
        if not src.exists():
            continue
        dest = prefix / destination
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        subprocess.run([str(cc)[:-3] + 'strip', '--strip-unneeded', str(dest)], check=True)
        subprocess.run(['patchelf', '--remove-rpath', str(dest)], check=True)
    for name in ['bin/Xorg', 'lib/xorg/modules/libglamoregl.so',
                 'lib/xorg/modules/drivers/modesetting_drv.so', 'lib/xorg/modules/extensions/libglx.so']:
        if not (prefix / name).exists():
            raise SystemExit('Missing Xorg build product: ' + name)
    metadata = stage / 'DEBIAN'
    metadata.mkdir()
    version = '21.1.7-1tboard1+noble'
    (metadata / 'control').write_text(
        f'Package: tboard-xserver-rockchip\nVersion: {version}\nArchitecture: arm64\n'
        'Maintainer: TBoard SDK <sdk@localhost>\nSection: x11\nPriority: optional\n'
        'Depends: libc6 (>= 2.39), libnettle8t64, libxfont2, libpixman-1-0, libdrm2, libepoxy0, '
        'libgbm1, libegl1, libgl1, libgles2, libxshmfence1, libbsd0, libxau6, libxdmcp6, '
        'libudev1, libsystemd0, libdbus-1-3, libpciaccess0, libxcvt0, '
        'xserver-xorg-core (>= 2:21.1), xserver-xorg-input-libinput, x11-xkb-utils, xkb-data\n'
        'Description: Noble-native Rockchip Xorg with Mali GLES glamor and DRI support\n')
    doc = stage / 'usr/share/doc/tboard-xserver-rockchip'
    doc.mkdir(parents=True)
    shutil.copy2(source / 'COPYING', doc / 'copyright')
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    manifest = {'source': 'external/xserver', 'revision': revision,
                'compiler': subprocess.check_output([str(cc), '--version'], text=True).splitlines()[0],
                'sysroot': str(sysroot), 'meson_options': options,
                'files': {str(p.relative_to(stage)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in prefix.rglob('*') if p.is_file()}}
    (doc / 'build-info.json').write_text(json.dumps(manifest, indent=2) + '\n')
    output.mkdir(parents=True, exist_ok=True)
    package = output / f'tboard-xserver-rockchip_{version}_arm64.deb'
    subprocess.run(['dpkg-deb', '--root-owner-group', '-Zgzip', '-b', str(stage), str(package)], check=True)
    (output / 'SHA256SUMS').write_text(hashlib.sha256(package.read_bytes()).hexdigest() + '  ' + package.name + '\n')
    print(package)


if __name__ == '__main__':
    main()
