from argparse import ArgumentParser
from multiprocessing import cpu_count
import pathlib
import sys
import os


def execute(command: str):
    print(f"Execute: {command}.")
    os.system(command)


if __name__ == "__main__":
    parser = ArgumentParser(description="Configure & Make & Install FFmpeg (with WHIP/WHEP via libdatachannel + RIST).")
    parser.add_argument("--ffmpeg_dir", type=str, default=os.getcwd(), help='indicate FFmpeg dir.')
    parser.add_argument("--target_dir", type=str, default=os.getcwd(), help='indicate target dir.')
    parser.add_argument("--libdatachannel_dir", type=str, default="",
                        help='libdatachannel universal install prefix (contains include/ and lib/). '
                             'Default: <ffmpeg_dir>/../libdatachannel')
    parser.add_argument("--librist_dir", type=str, default="",
                        help='librist UNIVERSAL prefix whose lib/pkgconfig/librist.pc is used '
                             '(a lib/pkgconfig dir must exist). Default: /opt/homebrew/opt/librist '
                             '(after running rist.sh to make it universal).')
    parser.add_argument("--libvpx_dir", type=str, default="",
                        help='libvpx UNIVERSAL STATIC prefix built by vpx.sh (contains '
                             'lib/libvpx.a and lib/pkgconfig/vpx.pc). '
                             'Default: <ffmpeg_dir>/../libvpx')
    args = parser.parse_args()
    ffmpeg_dir = pathlib.Path(args.ffmpeg_dir).absolute()
    target_dir = pathlib.Path(args.target_dir).absolute()

    # libdatachannel universal prefix (dedicated dir under this project, alongside ffmpeg/)
    if args.libdatachannel_dir:
        ldc_dir = pathlib.Path(args.libdatachannel_dir).absolute()
    else:
        ldc_dir = (ffmpeg_dir.parent / "libdatachannel").absolute()

    # librist prefix (pkg-config based). Default: Homebrew's stable symlink.
    rist_dir = pathlib.Path(args.librist_dir).absolute() if args.librist_dir \
        else pathlib.Path("/opt/homebrew/opt/librist")
    rist_pkgconfig = rist_dir / "lib" / "pkgconfig"

    # opus prefix (pkg-config based). Homebrew's stable symlink; run opus.sh
    # first so libopus.0.dylib is universal (arm64 + x86_64).
    opus_dir = pathlib.Path("/opt/homebrew/opt/opus")
    opus_pkgconfig = opus_dir / "lib" / "pkgconfig"

    # libvpx prefix (pkg-config based). UNIVERSAL STATIC libvpx.a built by
    # vpx.sh. FFmpeg links it INTO libavcodec.dylib, so there is no extra
    # dylib to stage, bundle, or codesign.
    if args.libvpx_dir:
        vpx_dir = pathlib.Path(args.libvpx_dir).absolute()
    else:
        vpx_dir = (ffmpeg_dir.parent / "libvpx").absolute()
    vpx_pkgconfig = vpx_dir / "lib" / "pkgconfig"

    print(f"Compile... {ffmpeg_dir}")
    print(f"libdatachannel prefix: {ldc_dir}")
    print(f"librist prefix:        {rist_dir}")
    print(f"opus prefix:           {opus_dir}")
    print(f"libvpx prefix:         {vpx_dir}")
    if not (ldc_dir / "include" / "rtc" / "rtc.h").exists():
        print(f"WARNING: {ldc_dir}/include/rtc/rtc.h not found. "
              f"Run build_libdatachannel.sh first, or pass --libdatachannel_dir.")
    if not (rist_pkgconfig / "librist.pc").exists():
        print(f"WARNING: {rist_pkgconfig}/librist.pc not found. "
              f"Install librist (brew install librist) and run rist.sh to make it universal, "
              f"or pass --librist_dir.")
    if not (opus_pkgconfig / "opus.pc").exists():
        print(f"WARNING: {opus_pkgconfig}/opus.pc not found. "
              f"Install opus (brew install opus, both arches) and run opus.sh to make it universal.")
    else:
        # Confirm the dylib is universal so the x86_64 configure pass won't fail at link time.
        os.system(f"echo 'opus dylib arch check:' && lipo -info {opus_dir}/lib/libopus.0.dylib")

    if not (vpx_pkgconfig / "vpx.pc").exists():
        print(f"WARNING: {vpx_pkgconfig}/vpx.pc not found. "
              f"Run vpx.sh first, or pass --libvpx_dir.")
    else:
        os.system(f"echo 'libvpx archive arch check:' && lipo -info {vpx_dir}/lib/libvpx.a")


    def clean():
        print("Clean project.")
        execute(f"cd {ffmpeg_dir} && make clean && make distclean")


    def make(arch: str):
        n_cpu = cpu_count()
        print("Configure project.")
        execute(
            # librist + opus are discovered via pkg-config, so prepend their .pc dirs to PKG_CONFIG_PATH.
            f"cd {ffmpeg_dir} && PKG_CONFIG_PATH='{rist_pkgconfig}:{opus_pkgconfig}:{vpx_pkgconfig}:'\"$PKG_CONFIG_PATH\" "
            f"./configure --enable-cross-compile --prefix={target_dir / ('install_' + arch + '/')} "
            # NOTE: dropped --enable-libfreetype and --enable-indev=jack — the app uses
            # Qt/OpenGL for OSD (not FFmpeg drawtext) and no JACK, and neither library was
            # installed universal for x86_64 (freetype2 pkg-config failure on the Intel pass).
            f"--enable-shared --disable-static --enable-libsrt --disable-x86asm "
            # ---- WHIP/WHEP additions (libdatachannel: plain 'require', needs -I/-L) ----
            f"--enable-libdatachannel "
            f"--extra-cflags='-I{ldc_dir}/include' "
            f"--extra-ldflags='-L{ldc_dir}/lib' "
            # NOTE: libdatachannel is C++ but built as a shared dylib, so it carries its own
            # libc++ dependency and clang normally links the C test fine. If configure's
            # 'require libdatachannel' check FAILS at link time, add: --extra-libs='-lc++'
            # ---- RIST addition (librist: pkg-config based, requires librist >= 0.2.7) ----
            f"--enable-librist "
            f"--enable-libopus "
            f"--enable-libvpx "
            # -----------------------------------------------------------------------------
            f"--arch={arch} --cc='clang -arch {arch}'"
        )
        print(f"Make project ({n_cpu} threads).")
        execute(f"cd {ffmpeg_dir} && make -j{n_cpu}")
        print(f"Install project.")
        execute(f"cd {ffmpeg_dir} && make install")


    print("----------arm64----------")
    clean()
    make("arm64")
    print("----------x86_64----------")
    clean()
    make("x86_64")
