# NXT Multiview — build scripts for the open-source components

This repository holds the scripts that Nextologies Limited used to build the
open-source libraries shipped inside **NXT Multiview** for macOS. It exists to
satisfy the source-availability terms of those libraries (GNU LGPL 2.1,
GNU LGPL 3, Mozilla Public License 2.0). The application itself is not open
source and is not in this repository.

The written offer, and the list of components per release, is at
https://www.nextologies.com/nxtmultiview/open-source

One git tag per application release marks the exact scripts used:
`nxtmultiview-<app version>` (for example `nxtmultiview-1.2.14`).

## Components and where the source is

| Component | Licence | Modified by Nextologies? | Source as built |
| --- | --- | --- | --- |
| FFmpeg 7.1.1 | LGPL 2.1+ | **Yes** (WHIP/WHEP/Janus WebRTC input via libdatachannel; RTP VP9/H.264 depacketizer changes) | https://github.com/nxto-tv/ffmpeg — branch `nextologies/7.1.1`, tag `nxtmultiview-1.2.14` (base: upstream tag `n7.1.1`) |
| libdatachannel 0.24.5+196 | MPL 2.0 | No | https://github.com/paullouisageneau/libdatachannel/tree/1ca898d66e5646ad7b04340cbd57556be02a198e (with its submodules: libjuice `3c40a3545b6b1b62c7adee7f8f2bd58aa290afd6` v1.7.2, libsrtp `24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5`, usrsctp `fec583d54493f879d2ae44a743423bf8a04371ab`, plog `94899e0b926ac1b0f4750bfbd495167b4a6ae9ef`, json `55f93686c01528224f448c19128836e7df245f72`) |
| SRT 1.5.4+11 | MPL 2.0 | No | https://github.com/Haivision/srt/tree/1ec61fc04db843ead4bebcb9db90cef8fbdd96d1 |
| libusb 1.0.30 | LGPL 2.1+ | No | https://github.com/libusb/libusb/releases/tag/v1.0.30 |
| Qt 6.7.3 | LGPL 3 | No | https://download.qt.io/archive/qt/6.7/6.7.3/single/qt-everywhere-src-6.7.3.tar.xz |

## Layout

```
ffmpeg/
  build-script/             the FFmpeg build driver
    make_compile_whipwhep.py  configure + make + install, once per arch (arm64, x86_64);
                              the exact ./configure line is inside this file
    make_universal.py         merges the two installs with lipo into install_universal/
    build_libdatachannel.sh   builds universal libdatachannel (FFmpeg dependency)
    fix_datachannel_install_name.sh
    stage_librist_universal.sh, stage_opus_universal.sh
    make_compile.py, install.py, package.py, README.md   (upstream ColorsWind files, kept as-is)
  vpx.sh                    universal static libvpx 1.17.0 (BSD-3) linked into libavcodec
  opus.sh, rist.sh, ssl_universal.sh   make the Homebrew opus / librist / openssl@3 dylibs universal
  STEPS_vp8_vp9.md          the procedure that adds libvpx to the build
  whip-whep-7.1.1.patch     the FFmpeg patch as a diff against n7.1.1 (reference only; see note)
  LICENSE-FFmpeg-macOS      MIT licence of the ColorsWind/FFmpeg-macOS scripts in build-script/
libusb/prepare_universal_libusb.sh    builds universal libusb 1.0.30 from the upstream tarball
srt-openssl/prepare_universal_libs.sh builds universal SRT and OpenSSL
librist/build_librist_universal.sh    builds universal librist
qt/BUILD.md                           the cmake line and steps used to build Qt 6.7.3
```

Note on `whip-whep-7.1.1.patch`: it is an earlier snapshot of the FFmpeg
change and does not contain `libavformat/janus.c`. The authoritative source of
the modified FFmpeg is the commit tagged `nxtmultiview-1.2.14` in
https://github.com/nxto-tv/ffmpeg. The WHIP/WHEP/Janus code and the RTP
depacketizer changes were written by Nextologies Limited and are released
under the FFmpeg licence (LGPL 2.1 or later), as the file headers state.

## FFmpeg configure line as shipped in NXT Multiview 1.2.14

Read back from `libavutil.59.39.100.dylib` in the application bundle
(x86_64 pass; the arm64 pass is identical except `--arch=arm64 --cc='clang -arch arm64'`):

```
--enable-cross-compile --prefix=/Users/parbat/Utils/universal_ffmpeg/ffmpeg/../install_x86_64 --enable-shared --disable-static --enable-libsrt --disable-x86asm --enable-libdatachannel --extra-cflags=-I/Users/parbat/Utils/universal_ffmpeg/libdatachannel/include --extra-ldflags=-L/Users/parbat/Utils/universal_ffmpeg/libdatachannel/lib --enable-librist --enable-libopus --enable-libvpx --arch=x86_64 --cc='clang -arch x86_64'
```

## Build order used on the build machine (macOS, Apple Silicon, Xcode)

1. `ffmpeg/ssl_universal.sh` — universal OpenSSL 3 (Homebrew openssl@3 for both arches).
2. `ffmpeg/build-script/build_libdatachannel.sh` — universal libdatachannel at the commit above.
3. `ffmpeg/rist.sh`, `ffmpeg/opus.sh` — universal librist and opus.
4. `ffmpeg/vpx.sh` — universal static libvpx.
5. `srt-openssl/prepare_universal_libs.sh` — universal SRT (and OpenSSL).
6. In the FFmpeg tree (fork, tag `nxtmultiview-1.2.14`):
   `python3 ../build-script/make_compile_whipwhep.py` then
   `python3 ../build-script/make_universal.py`.
7. `libusb/prepare_universal_libusb.sh` — universal libusb.
8. `qt/BUILD.md` — Qt 6.7.3.

The scripts contain absolute paths of the build machine
(`/Users/parbat/Utils/...`, `/opt/homebrew/...`). They are published exactly
as used; adjust the paths for another machine.

## Licences of the scripts

- `ffmpeg/build-script/make_compile.py`, `make_universal.py`, `install.py`,
  `package.py`, `README.md`, `.gitignore`: Copyright (c) 2022 ColorsWind,
  MIT licence (`ffmpeg/LICENSE-FFmpeg-macOS`). `make_compile_whipwhep.py` is a
  Nextologies modification of `make_compile.py` and keeps the MIT licence.
- All other scripts and documents in this repository: Copyright (c)
  Nextologies Limited, released under the MIT licence (`LICENSE`).

## Contact

support@nextologies.com
