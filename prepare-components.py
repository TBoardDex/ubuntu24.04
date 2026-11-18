#!/usr/bin/env python3
"""Prepare SDK ARM64 components for Noble without changing Debian packages."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


SDK = Path(__file__).resolve().parent.parent


def control(root, name, version, depends, description):
    metadata = root / 'DEBIAN'
    metadata.mkdir(exist_ok=True)
    (metadata / 'control').write_text(
        f'Package: {name}\nVersion: {version}\nArchitecture: arm64\n'
        'Maintainer: TBoard SDK <sdk@localhost>\nSection: libs\nPriority: optional\n'
        f'Depends: {depends}\nDescription: {description}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--kernel-build-dir', type=Path, default=SDK / 'kernel')
    args = parser.parse_args()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    sources = {}

    def record(path):
        key = str(path.relative_to(SDK)) if SDK in path.parents else str(path)
        sources[key] = hashlib.sha256(path.read_bytes()).hexdigest()
        return path

    with tempfile.TemporaryDirectory(prefix='.noble-components-', dir=output.parent) as tmp:
        stage = Path(tmp)
        packages = stage / 'packages'
        packages.mkdir()

        def pack(root):
            name = re.search(r'^Package: (.+)$', (root / 'DEBIAN/control').read_text(), re.M).group(1)
            subprocess.run(['dpkg-deb', '--root-owner-group', '-Zgzip', '-b', str(root),
                            str(packages / (name + '.deb'))], check=True)

        # These SDK libraries use glibc versions available in Noble. Replace
        # the retired libgcc1 dependency with its actual Noble runtime package.
        names = ['rga2/librga2_2.2.0-1_arm64.deb', 'rga2/librga-dev_2.2.0-1_arm64.deb',
                 'mpp/librockchip-mpp1_1.5.0-1_arm64.deb',
                 'mpp/librockchip-mpp-dev_1.5.0-1_arm64.deb',
                 'mpp/librockchip-vpu0_1.5.0-1_arm64.deb',
                 'mpp/rockchip-mpp-demos_1.5.0-1_arm64.deb',
                 'gst-rkmpp/gstreamer1.0-rockchip1_1.14-4_arm64.deb',
                 'rkaiq/camera_engine_rkaiq_rk3588_arm64.deb']
        for index, name in enumerate(names):
            source = record(SDK / 'debian13/packages/arm64' / name)
            root = stage / str(index)
            subprocess.run(['dpkg-deb', '-R', str(source), str(root)], check=True)
            metadata = root / 'DEBIAN/control'
            text = metadata.read_text()
            text = re.sub(r'\blibgcc1\b(?:\s*\([^)]*\))?', 'libgcc-s1', text)
            text = re.sub(r'^Version: (.+)$', r'Version: \1+noble1', text, flags=re.M)
            text = re.sub(r'(\(= [^)]+)(\))', r'\1+noble1\2', text)
            if name.startswith('rkaiq/'):
                text = re.sub(r'^Depends:.*$',
                              'Depends: systemd, libc6 (>= 2.28), libstdc++6 (>= 13.1), libgcc-s1',
                              text, flags=re.M)
            if name.startswith('rga2/librga-dev_'):
                if not re.search(r'^Depends:', text, re.M):
                    text = 'Depends: librga2 (= 2.2.0-1+noble1)\n' + text
            # RKAIQ packages use /lib/systemd; Noble's /lib is a symlink.
            # Normalize the package payload rather than replacing that link.
            if (root / 'lib').is_dir():
                (root / 'usr/lib').mkdir(parents=True, exist_ok=True)
                shutil.copytree(root / 'lib', root / 'usr/lib', dirs_exist_ok=True, symlinks=True)
                shutil.rmtree(root / 'lib')
                (root / 'DEBIAN/md5sums').unlink(missing_ok=True)
            metadata.write_text(text)
            pack(root)

        npu = stage / 'npu'
        api = SDK / 'external/rknpu2/runtime/Linux/librknn_api'
        for source in [api / 'aarch64/librknnrt.so', *sorted((api / 'include').glob('*.h'))]:
            destination = npu / ('usr/lib' if source.suffix == '.so' else 'usr/include/rknn') / source.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(record(source), destination)
        archive = record(SDK / 'debian13/packages/arm64/rknpu2/rknpu2.tar')
        # Copy only RK3588 examples; do not install the vendor ADB NPU server.
        with tarfile.open(archive) as tar:
            for name in ['usr/bin/rknn_common_test', 'usr/share/model/RK3588/mobilenet_v1.rknn',
                         'usr/share/model/dog_224x224.jpg', 'usr/share/model/cat_224x224.jpg']:
                member = tar.getmember('./' + name)
                destination = npu / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as src, destination.open('wb') as dst:
                    shutil.copyfileobj(src, dst)
                destination.chmod(member.mode & 0o777)
        pc = npu / 'usr/lib/aarch64-linux-gnu/pkgconfig/rknn.pc'
        pc.parent.mkdir(parents=True)
        pc.write_text('prefix=/usr\nlibdir=${prefix}/lib\nincludedir=${prefix}/include/rknn\n'
                      'Name: RKNN\nDescription: Rockchip NPU runtime\nVersion: 2.3.2\n'
                      'Libs: -L${libdir} -lrknnrt\nCflags: -I${includedir}\n')
        control(npu, 'tboard-rknn-dev', '1.0+noble1',
                'libc6, libstdc++6, libgcc-s1', 'RK3588 RKNN runtime, headers and sample model')
        license_file = npu / 'usr/share/doc/tboard-rknn-dev/copyright'
        license_file.parent.mkdir(parents=True)
        shutil.copy2(record(SDK / 'external/rknpu2/LICENSE'), license_file)
        pack(npu)

        # Isolate Mali EGL/GLES/GBM from the distro Mesa/Xorg libraries.
        mali_src = stage / 'mali-source'
        source = record(SDK / 'debian13/packages/arm64/libmali/libmali-valhall-g610-g29p1_1.10-1_arm64.deb')
        subprocess.run(['dpkg-deb', '-x', str(source), str(mali_src)], check=True)
        mali = stage / 'mali'
        libdir = mali / 'opt/rockchip/mali'
        libdir.mkdir(parents=True)
        vendor = mali_src / 'usr/lib/aarch64-linux-gnu'
        for path in list(vendor.iterdir()) + list((vendor / 'mali').iterdir()):
            if path.is_dir():
                continue
            destination = libdir / path.name
            if path.is_symlink():
                destination.symlink_to(os.readlink(path))
            else:
                shutil.copy2(path, destination)
                if path.read_bytes()[:4] == b'\x7fELF':
                    subprocess.run(['patchelf', '--set-rpath', '$ORIGIN', str(destination)], check=True)
        (libdir / 'mali.json').write_text(json.dumps({
            'file_format_version': '1.0.0', 'ICD': {
                'library_path': '/opt/rockchip/mali/libMaliVulkan.so.1', 'api_version': '1.3.276'}}, indent=2) + '\n')
        icd = mali / 'etc/OpenCL/vendors/tboard-mali.icd'
        icd.parent.mkdir(parents=True)
        icd.write_text('/opt/rockchip/mali/libMaliOpenCL.so.1\n')
        wrapper = mali / 'usr/bin/rk3588-mali'
        wrapper.parent.mkdir(parents=True)
        wrapper.write_text('#!/bin/sh\nset -e\n[ "$#" -gt 0 ] || { echo "Usage: rk3588-mali <command> [args...]" >&2; exit 2; }\n'
                           'unset LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER\n'
                           'export LD_LIBRARY_PATH=/opt/rockchip/mali${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\n'
                           'export VK_ICD_FILENAMES=/opt/rockchip/mali/mali.json\nexec "$@"\n')
        wrapper.chmod(0o755)
        control(mali, 'tboard-mali-g610', '1.10+noble2',
                'libc6, libstdc++6, libgcc-s1, libdrm2, libwayland-client0, libwayland-server0, '
                'libx11-xcb1, libxcb-dri2-0, libxcb-dri3-0, libxcb-present0, libxcb-sync1, libxcb-xfixes0',
                'Isolated Mali G610 EGL GLES OpenCL Vulkan application libraries')
        shutil.copytree(mali_src / 'usr/share/doc', mali / 'usr/share/doc', symlinks=True)
        pack(mali)

        # Pack headers from the completed kernel, replacing build-host ELF
        # helpers with the SDK's ARM64 kbuild tools (same method as Debian).
        # No kernel configuration or compilation is performed here.
        kernel = args.kernel_build_dir.resolve()
        release = (kernel / 'include/config/kernel.release').read_text().strip()
        if not re.fullmatch(r'[A-Za-z0-9_.+\-]+', release):
            raise SystemExit('Invalid completed kernel release')
        headers = stage / 'headers'
        tree = headers / 'usr/src' / ('linux-headers-' + release)
        tree.mkdir(parents=True)
        for name in ['.config', 'Module.symvers', 'include/config/kernel.release']:
            record(kernel / name)
        for name in ['Makefile', '.config', 'Module.symvers', 'arch/arm64/Makefile']:
            target = tree / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(kernel / name, target)
        for source in (kernel / 'arch/arm64').rglob('module.lds'):
            target = tree / source.relative_to(kernel)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        for name in ['include', 'scripts', 'arch/arm64/include']:
            shutil.copytree(kernel / name, tree / name, symlinks=True,
                            ignore=shutil.ignore_patterns('*.o', '*.cmd', '.git'))
        kbuild = SDK / 'device/rockchip/common/linux-kbuild/aarch64/linux-kbuild-6.12'
        for name in ['scripts', 'tools']:
            shutil.copytree(kbuild / name, tree / name, symlinks=True, dirs_exist_ok=True)
        module_dir = headers / 'usr/lib/modules' / release
        module_dir.mkdir(parents=True)
        for name in ['build', 'source']:
            (module_dir / name).symlink_to('/usr/src/linux-headers-' + release)
        version = '6.12+' + hashlib.sha256((kernel / '.config').read_bytes() +
                                          (kernel / 'Module.symvers').read_bytes()).hexdigest()[:12]
        control(headers, 'tboard-linux-headers', version,
                'gcc-14, make, bc, libelf-dev, libssl-dev', 'Headers and native ARM64 kbuild for the completed TBoard kernel')
        license_file = headers / 'usr/share/doc/tboard-linux-headers/copyright'
        license_file.parent.mkdir(parents=True)
        shutil.copy2(kernel / 'COPYING', license_file)
        pack(headers)

        manifest = {'source_sha256': sources, 'kernel_release': release,
                    'packages': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(packages.iterdir())}}
        (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        output.mkdir(exist_ok=True)
        if (output / 'manifest.json').exists():
            previous = json.loads((output / 'manifest.json').read_text())
            for name in previous['packages']:
                if Path(name).name != name:
                    raise SystemExit('Invalid previous component manifest')
                (output / name).unlink(missing_ok=True)
        for path in packages.iterdir():
            shutil.copy2(path, output / path.name)
        shutil.copy2(stage / 'manifest.json', output / 'manifest.json')
    print(f'Prepared Noble components: {output}')


if __name__ == '__main__':
    main()
