# Add VP8 and VP9 encoders to the universal FFmpeg build

FFmpeg n7.1.1 - macOS universal (arm64 + x86_64)

## Background

On macOS, `libvpx` is the only VP8/VP9 encoder that FFmpeg can use.
VideoToolbox has no VP8 or VP9 encoder. VAAPI and QSV are not macOS.

`libvpx` is BSD-3-Clause. Thus `--enable-libvpx` does not need `--enable-gpl`.

This procedure builds `libvpx` as a UNIVERSAL STATIC archive.
FFmpeg links the archive into `libavcodec.dylib`.
Thus the app gets no new dylib. `bundle_libs.sh` needs no change.

New encoder names after the build:

| FFmpeg encoder name | Codec |
|---|---|
| `libvpx` | VP8 |
| `libvpx-vp9` | VP9 |

The decoders `libvpx` and `libvpx-vp9` also become available.
The native `vp8` and `vp9` decoders stay unchanged.

---

## Step 1 - Install the assembler

The x86_64 pass of libvpx needs `nasm`.

```
/opt/homebrew/bin/brew install nasm
```

Check:

```
nasm -v
```

---

## Step 2 - Build universal static libvpx

The script `vpx.sh` is in this directory. It does these things:

1. It downloads libvpx 1.17.0 and verifies the SHA256.
2. It builds arm64 and x86_64 separately, static and PIC.
3. It merges the two archives with `lipo`.
4. It writes `libvpx/lib/pkgconfig/vpx.pc` with the universal prefix.
5. It prints verification output.

Run:

```
cd /Users/parbat/Utils/universal_ffmpeg && bash vpx.sh
```

Expected result:

```
/Users/parbat/Utils/universal_ffmpeg/libvpx/lib/libvpx.a
/Users/parbat/Utils/universal_ffmpeg/libvpx/lib/pkgconfig/vpx.pc
/Users/parbat/Utils/universal_ffmpeg/libvpx/include/vpx/
```

The verify block must show:

```
Architectures in the fat file: .../libvpx.a are: x86_64 arm64
```

Note: `VP9_HIGHBITDEPTH=0` is set at the top of `vpx.sh`.
This gives 8-bit only, which is the fastest for WebRTC and normal streaming.
Set it to `1` if you need VP9 10-bit or 12-bit.

---

## Step 3 - Edit make_compile_whipwhep.py

Make 4 edits in `build-script/make_compile_whipwhep.py`.

### Edit 3a - new command-line option

Add this block immediately before the line `args = parser.parse_args()`:

```python
    parser.add_argument("--libvpx_dir", type=str, default="",
                        help='libvpx UNIVERSAL STATIC prefix built by vpx.sh (contains '
                             'lib/libvpx.a and lib/pkgconfig/vpx.pc). '
                             'Default: <ffmpeg_dir>/../libvpx')
```

### Edit 3b - resolve the libvpx prefix

Add this block immediately after these two existing lines:

```python
    opus_dir = pathlib.Path("/opt/homebrew/opt/opus")
    opus_pkgconfig = opus_dir / "lib" / "pkgconfig"
```

New block:

```python
    # libvpx prefix (pkg-config based). UNIVERSAL STATIC libvpx.a built by
    # vpx.sh. FFmpeg links it INTO libavcodec.dylib, so there is no extra
    # dylib to stage, bundle, or codesign.
    if args.libvpx_dir:
        vpx_dir = pathlib.Path(args.libvpx_dir).absolute()
    else:
        vpx_dir = (ffmpeg_dir.parent / "libvpx").absolute()
    vpx_pkgconfig = vpx_dir / "lib" / "pkgconfig"
```

### Edit 3c - log and check the prefix

Add this line after `print(f"opus prefix:           {opus_dir}")`:

```python
    print(f"libvpx prefix:         {vpx_dir}")
```

Add this block after the existing opus `if/else` check, at the same indent:

```python
    if not (vpx_pkgconfig / "vpx.pc").exists():
        print(f"WARNING: {vpx_pkgconfig}/vpx.pc not found. "
              f"Run vpx.sh first, or pass --libvpx_dir.")
    else:
        os.system(f"echo 'libvpx archive arch check:' && lipo -info {vpx_dir}/lib/libvpx.a")
```

### Edit 3d - configure flags

In the function `make(arch)`, change this line:

FROM

```python
            f"cd {ffmpeg_dir} && PKG_CONFIG_PATH='{rist_pkgconfig}:{opus_pkgconfig}:'\"$PKG_CONFIG_PATH\" "
```

TO

```python
            f"cd {ffmpeg_dir} && PKG_CONFIG_PATH='{rist_pkgconfig}:{opus_pkgconfig}:{vpx_pkgconfig}:'\"$PKG_CONFIG_PATH\" "
```

And change this line:

FROM

```python
            f"--enable-libopus " 
```

TO

```python
            f"--enable-libopus "
            f"--enable-libvpx "
```

---

## Step 4 - Recompile FFmpeg for both architectures

This is the same command that made the current build.
`--target_dir ..` puts `install_arm64` and `install_x86_64` at the top level.

```
cd /Users/parbat/Utils/universal_ffmpeg/ffmpeg && python3 ../build-script/make_compile_whipwhep.py --target_dir ..
```

The script cleans, configures, builds, and installs arm64. Then it repeats for x86_64.

Watch for this line in BOTH configure passes:

```
libvpx_vp8_encoder      yes
libvpx_vp9_encoder      yes
```

If configure stops with `ERROR: vpx >= 1.4.0 not found using pkg-config`,
then Step 2 did not finish, or the path in `vpx.pc` is wrong.

---

## Step 5 - Make the universal binaries

```
cd /Users/parbat/Utils/universal_ffmpeg/ffmpeg && python3 ../build-script/make_universal.py --dir ..
```

Result: `/Users/parbat/Utils/universal_ffmpeg/install_universal/`

---

## Step 6 - Verify FFmpeg

### 6a - The encoders exist

```
/Users/parbat/Utils/universal_ffmpeg/install_universal/bin/ffmpeg -hide_banner -encoders | grep -i vpx
```

Expected output:

```
 V....D libvpx               libvpx VP8 (codec vp8)
 V....D libvpx-vp9           libvpx VP9 (codec vp9)
```

### 6b - The libraries are still universal

```
lipo -info /Users/parbat/Utils/universal_ffmpeg/install_universal/lib/libavcodec.61.19.101.dylib
```

Expected: `are: x86_64 arm64`

### 6c - No new dylib dependency

This is the key check for static linking.

```
otool -L /Users/parbat/Utils/universal_ffmpeg/install_universal/lib/libavcodec.61.19.101.dylib | grep -i vpx
```

Expected: NO output. If a line appears, libvpx linked as a dylib. Stop and re-check Step 2.

### 6d - Both slices encode

```
arch -arm64 /Users/parbat/Utils/universal_ffmpeg/install_universal/bin/ffmpeg -hide_banner -f lavfi -i testsrc2=size=320x240:rate=30 -t 2 -c:v libvpx -b:v 500k -y /tmp/vp8_arm64.webm
```

```
arch -arm64 /Users/parbat/Utils/universal_ffmpeg/install_universal/bin/ffmpeg -hide_banner -f lavfi -i testsrc2=size=320x240:rate=30 -t 2 -c:v libvpx-vp9 -b:v 500k -y /tmp/vp9_arm64.webm
```

```
arch -x86_64 /Users/parbat/Utils/universal_ffmpeg/install_universal/bin/ffmpeg -hide_banner -f lavfi -i testsrc2=size=320x240:rate=30 -t 2 -c:v libvpx -b:v 500k -y /tmp/vp8_x86.webm
```

```
arch -x86_64 /Users/parbat/Utils/universal_ffmpeg/install_universal/bin/ffmpeg -hide_banner -f lavfi -i testsrc2=size=320x240:rate=30 -t 2 -c:v libvpx-vp9 -b:v 500k -y /tmp/vp9_x86.webm
```

All four commands must finish with no error. `arch -x86_64` needs Rosetta.

### 6e - The old features still work

```
/Users/parbat/Utils/universal_ffmpeg/install_universal/bin/ffmpeg -hide_banner -encoders | grep -E "libopus|h264_videotoolbox|hevc_videotoolbox"
```

```
/Users/parbat/Utils/universal_ffmpeg/install_universal/bin/ffmpeg -hide_banner -protocols | grep -E "srt|rist"
```

```
/Users/parbat/Utils/universal_ffmpeg/install_universal/bin/ffmpeg -hide_banner -muxers | grep -E "whip|webm"
```

---

## Step 7 - Copy the new FFmpeg into the app

```
cp -R /Users/parbat/Utils/universal_ffmpeg/install_universal/include/. /Users/parbat/Workspace/nxtplayerlight/3rdparty/ffmpeg/include/
```

```
cp -R /Users/parbat/Utils/universal_ffmpeg/install_universal/lib/. /Users/parbat/Workspace/nxtplayerlight/3rdparty/ffmpeg/lib/
```

The library version numbers do not change (libavcodec stays 61.19.101).
Thus the file names stay the same and the copy overwrites cleanly.

### WARNING - do not run prepare_universal_libs.sh without FFMPEG_PREFIX

`prepare_universal_libs.sh` has this default:

```
FFMPEG_SRC_PREFIX="${FFMPEG_PREFIX:-$HOME/Utils/universal_ffmpeg/ffmpeg/install_universal}"
```

That path holds an OLD build from 6 July. The app's current libraries came
from `/Users/parbat/Utils/universal_ffmpeg/install_universal` (18 July).
If you run that script, first set the correct prefix:

```
export FFMPEG_PREFIX=/Users/parbat/Utils/universal_ffmpeg/install_universal
```

---

## Step 8 - Rebuild and bundle the app

`bundle_libs.sh` needs NO change. libvpx is inside `libavcodec.dylib`.

Rebuild the app as usual, then:

```
cd /Users/parbat/Workspace/nxtplayerlight && ./bundle_libs.sh --dev
```

```
cd /Users/parbat/Workspace/nxtplayerlight && ./verify_bundle.sh
```

Check that no libvpx dylib entered the bundle:

```
otool -L /Users/parbat/Workspace/nxtplayerlight/*.app/Contents/Frameworks/libavcodec.*.dylib | grep -i vpx
```

Expected: NO output.

---

## What to test in the app

1. The app starts on Apple Silicon and on Intel (or under Rosetta).
2. Existing playback still works (SRT, RIST, NDI, files).
3. Existing publish paths still work (WHIP, RIST, SRT, NDI, SDI).
4. Opus audio still encodes.
5. A new VP8 or VP9 output encodes and plays.
6. `verify_bundle.sh` passes with no new missing library.

## Rollback

The old universal build is not deleted by Step 4 until the new one installs.
To go back, restore `3rdparty/ffmpeg` from `3rdparty/ffmpeg.bak-20260718`,
then re-run `bundle_libs.sh`.
