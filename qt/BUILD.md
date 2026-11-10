# Qt 6.7.3 — how the Qt frameworks in NXT Multiview were built

NXT Multiview ships Qt 6.7.3 under the GNU LGPL v3.

**Qt is modified.** Nextologies Limited changed Qt 6.7.3 on 2026-11-10. The
changes are the three patch files in `qt/patches/` of this repository. They
change the `qtbase` module only. Two shipped binaries contain modified code:
`QtGui.framework` and the Cocoa platform plugin `libqcocoa.dylib`. Every other
Qt framework and plugin in `NXTMultiview.app` is built from the unmodified
upstream source.

Source archive (upstream):
https://download.qt.io/archive/qt/6.7/6.7.3/single/qt-everywhere-src-6.7.3.tar.xz

The `qtbase` module alone (the only module the patches change):
https://download.qt.io/archive/qt/6.7/6.7.3/submodules/qtbase-everywhere-src-6.7.3.tar.xz

Mirror of the same release on GitHub:
https://github.com/qt/qt5/releases/tag/v6.7.3

The source of the Qt that is shipped = the upstream archive + the three
patches, applied in the order of their numbers.

## The changes

| Patch | What it changes | Why |
| --- | --- | --- |
| `0001-qtbase-6.7.3-QTBUG-134784-a11y-refcount-backport.patch` | `src/gui/accessible/qaccessiblecache_mac.mm`, `src/gui/accessible/qaccessiblecache_p.h`, `src/plugins/platforms/cocoa/qcocoaaccessibilityelement.h`, `src/plugins/platforms/cocoa/qcocoaaccessibilityelement.mm`, `src/plugins/platforms/ios/quiaccessibilityelement.mm` | Fixes a crash (`EXC_BAD_ACCESS` in `-[QMacAccessibilityElement dealloc]`) when a macOS assistive technology, for example Full Keyboard Access, reads a list or table. It is a backport of Qt's own commits `2e6acc23`, `bd6e55c8` and `b1ed5f656f064e553b33752f8e87d2f5b9553e38` ("macOS a11y: maintain reference count for cached elements", QTBUG-134784) to 6.7.3. Qt released that fix for 6.8 and later only. The logic is Qt's; only two names differ, because 6.7.3 uses `cocoaElements` and `removeCocoaElement`. |
| `0002-qtbase-6.7.3-QTBUG-145239-yield-build-fix.patch` | `src/corelib/thread/qyieldcpu.h` | Build fix for current Apple clang ("implicitly declaring library function '__yield'"). The check for `__builtin_arm_yield` moves before the check for `__yield`. Both give the same CPU instruction. Qt tracks this compiler problem as QTBUG-145239. |
| `0003-qtbase-6.7.3-no-AGL-build-fix.patch` | `cmake/FindWrapOpenGL.cmake` | Build fix. The AGL framework is not in the current macOS SDK, so Qt does not link it ("ld: framework 'AGL' not found"). |

The patches are changes to Qt source files and are under the same licences as
those files (the Qt file headers apply; for the files above:
LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only, or BSD-3-Clause for the cmake
file, next to The Qt Company's commercial licence).

## Steps used — first build (unmodified source, all of Qt)

```
tar xf qt-everywhere-src-6.7.3.tar.xz
cd qt-everywhere-src-6.7.3
mkdir build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/Qt-6.7.3 -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_BUILD_TYPE=Release -DQT_BUILD_EXAMPLES=OFF DQT_BUILD_TESTS=OFF
cd ..
make -j$(sysctl -n hw.ncpu)
sudo make install
```

Note: the cmake line is recorded exactly as it was run. The last argument
`DQT_BUILD_TESTS=OFF` has no leading `-`, so cmake did not read it as an
option; `QT_BUILD_TESTS` stayed at its default for this build. The installed
tree is not affected by that argument.

## Steps used — second build, 2026-11-10 (patched `qtbase`, two binaries)

The two modified binaries were built from the `qtbase` archive with the three
patches, with the same options, and then copied over the two files of the
first build in `/usr/local/Qt-6.7.3`.

```
tar xf qtbase-everywhere-src-6.7.3.tar.xz
cd qtbase-everywhere-src-6.7.3
patch -p1 < /path/to/nxtmultiview-oss/qt/patches/0001-qtbase-6.7.3-QTBUG-134784-a11y-refcount-backport.patch
patch -p1 < /path/to/nxtmultiview-oss/qt/patches/0002-qtbase-6.7.3-QTBUG-145239-yield-build-fix.patch
patch -p1 < /path/to/nxtmultiview-oss/qt/patches/0003-qtbase-6.7.3-no-AGL-build-fix.patch
mkdir build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/Qt-6.7.3 -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_BUILD_TYPE=Release -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF
cmake --build . --parallel --target Gui QCocoaIntegrationPlugin
sudo cp lib/QtGui.framework/Versions/A/QtGui /usr/local/Qt-6.7.3/lib/QtGui.framework/Versions/A/QtGui
sudo cp plugins/platforms/libqcocoa.dylib /usr/local/Qt-6.7.3/plugins/platforms/libqcocoa.dylib
```

Notes:

- `QtGui` and `libqcocoa.dylib` must be replaced together. Patch 0001 changes
  a private function that both use.
- In a universal build directory, a second `cmake ..` stops with an error on
  the feature `x86intrin`. Delete `CMakeCache.txt` and run the full cmake line
  again.
- To build all of Qt from the full archive with the patches, apply them in
  the `qtbase` directory of `qt-everywhere-src-6.7.3` and use the steps of
  the first build.

To confirm that a build has patch 0001:

```
nm NXTMultiview.app/Contents/PlugIns/platforms/libqcocoa.dylib | grep removeElementsFromCache
```

A patched plugin prints one line. An unmodified Qt 6.7.3 prints nothing.

The macOS SDK and Xcode version used are listed in the About window of the
application (Build Date) and in the release notes.

## Relinking

Every Qt framework is a shared library inside the application bundle. A user
can replace one with a modified build of Qt 6.7.3 made with the same steps.
Doing so breaks the Apple code signature; re-sign the bundle ad hoc
(`codesign --force --deep --sign - NXTMultiview.app`) to run it.
