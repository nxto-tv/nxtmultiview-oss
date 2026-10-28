# Qt 6.7.3 — how the Qt frameworks in NXT Multiview were built

NXT Multiview ships Qt 6.7.3 under the GNU LGPL v3. Qt is not modified.
The frameworks in `NXTMultiview.app/Contents/Frameworks` come from a build of
the unmodified upstream source archive, made by Nextologies on macOS, as a
universal (arm64 + x86_64) release build installed to `/usr/local/Qt-6.7.3`.

Source archive (upstream, unmodified):
https://download.qt.io/archive/qt/6.7/6.7.3/single/qt-everywhere-src-6.7.3.tar.xz

Mirror of the same release on GitHub:
https://github.com/qt/qt5/releases/tag/v6.7.3

## Steps used

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

The macOS SDK and Xcode version used are listed in the About window of the
application (Build Date) and in the release notes.

## Relinking

Every Qt framework is a shared library inside the application bundle. A user
can replace one with a modified build of Qt 6.7.3 made with the same steps.
Doing so breaks the Apple code signature; re-sign the bundle ad hoc
(`codesign --force --deep --sign - NXTMultiview.app`) to run it.
