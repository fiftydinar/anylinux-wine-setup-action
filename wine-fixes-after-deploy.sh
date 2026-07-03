#!/bin/sh

ARCH=$(uname -m)

# alright here the pain starts
ln -sr ./AppDir/lib/wine/x86_64-unix/*.so* ./AppDir/bin

# this gets broken by sharun somehow
kek=.$(tr -dc 'A-Za-z0-9_=-' < /dev/urandom | head -c 10)
rm -f ./AppDir/lib/wine/x86_64-unix/wine
cp /usr/lib/wine/x86_64-unix/wine ./AppDir/lib/wine/x86_64-unix/wine
patchelf --set-interpreter /tmp/"$kek" ./AppDir/lib/wine/x86_64-unix/wine
# we used to run patchelf --add-needed anylinux.so on the wine binary
# but after 11.8 this causes the binary to break horribly:
# AppDir/lib/wine/x86_64-unix/wine: oops... not enough space for load commands
# so we will have to make sure anylinux.so loads by adding it as a dependency to the libc
patchelf --add-needed anylinux.so ./AppDir/shared/lib/libc.so.6

cat <<EOF > ./AppDir/bin/random-linker.hook
#!/bin/sh
cp -f "\$APPDIR"/shared/lib/ld-linux*.so* /tmp/"$kek"
EOF

cat <<EOF > ./AppDir/bin/force-portable-home.hook
#!/bin/sh
# wine ignores the HOME env var, which means --appimage-portable-home does not work normally
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
export WINE_HOST_XDG_CACHE_HOME="$XDG_CACHE_HOME"
EOF
chmod +x ./AppDir/bin/*.hook

cat <<EOF > ./AppDir/bin/"$WINE_MAIN_BIN"
#!/bin/sh
if [ ! -d "\${WINEPREFIX}" ]; then
    wineboot
fi
cp -rn \${APPDIR}/share/"${WINE_MAIN_BIN}" "\${WINEPREFIX}"
wine "\${WINEPREFIX}/${WINE_MAIN_BIN}/${WINE_MAIN_BIN}" "\$@"
EOF

echo "WINEPREFIX=\${XDG_DATA_HOME}/anylinux-wine/${WINE_MAIN_BIN}" >> ./AppDir/.env

chmod +x ./AppDir/bin/*.hook

# Set the lib path to also use wine libs
echo 'LD_LIBRARY_PATH=${APPDIR}/lib:${APPDIR}/lib/pulseaudio:${APPDIR}/lib/alsa-lib:${APPDIR}/lib/wine/x86_64-unix' >> ./AppDir/.env

# remove wine static libs
find ./AppDir/lib/ -type f -name '*.a'
find ./AppDir/lib/ -type f -name '*.a' -delete

# strip windows libs, inspired by alpine linux: 
# https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/community/wine/APKBUILD
if [ "$ARCH" = 'x86_64' ]; then
	x86_64-w64-mingw32-strip -R .comment --strip-unneeded ./AppDir/lib/wine/x86_64-windows/*.dll
	i686-w64-mingw32-strip   -R .comment --strip-unneeded ./AppDir/lib/wine/i386-windows/*.dll
fi
