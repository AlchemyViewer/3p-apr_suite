#!/usr/bin/env bash

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

APR_INCLUDE_DIR="apr/include"

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

STAGING_DIR="$(pwd)"
TOP_DIR="$(dirname "$0")"

# load autobuild provided shell functions and variables
source_environment_tempfile="$STAGING_DIR/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# extract APR version into VERSION.txt
APR_INCLUDE_DIR="../apr/include"
# will match -- #<whitespace>define<whitespace>APR_MAJOR_VERSION<whitespace>number  future proofed :)
major_version="$(sed -n -E 's/#[[:space:]]*define[[:space:]]+APR_MAJOR_VERSION[[:space:]]+([0-9]+)/\1/p' "${APR_INCLUDE_DIR}/apr_version.h")"
minor_version="$(sed -n -E 's/#[[:space:]]*define[[:space:]]+APR_MINOR_VERSION[[:space:]]+([0-9]+)/\1/p' "${APR_INCLUDE_DIR}/apr_version.h")"
patch_version="$(sed -n -E 's/#[[:space:]]*define[[:space:]]+APR_PATCH_VERSION[[:space:]]+([0-9]+)/\1/p' "${APR_INCLUDE_DIR}/apr_version.h")"
version="${major_version}.${minor_version}.${patch_version}"
echo "${version}" > "${STAGING_DIR}/VERSION.txt"

case "$AUTOBUILD_PLATFORM" in
  windows*)
    pushd "$TOP_DIR"
    DEBUG_OUT_DIR="$STAGING_DIR/lib/debug"
    RELEASE_OUT_DIR="$STAGING_DIR/lib/release"

    load_vsvars

    # We've observed some weird failures in which the PATH is too big to be
    # passed to a child process! When that gets munged, we start seeing errors
    # like failing to understand the 'nmake' command. Thing is, by this point
    # in the script we've acquired a shocking number of duplicate entries.
    # Dedup the PATH using Python's OrderedDict, which preserves the order in
    # which you insert keys.
    # We find that some of the Visual Studio PATH entries appear both with and
    # without a trailing slash, which is pointless. Strip those off and dedup
    # what's left.
    # Pass the existing PATH as an explicit argument rather than reading it
    # from the environment to bypass the fact that cygwin implicitly converts
    # PATH to Windows form when running a native executable. Since we're
    # setting bash's PATH, leave everything in cygwin form. That means
    # splitting and rejoining on ':' rather than on os.pathsep, which on
    # Windows is ';'.
    # Use python -u, else the resulting PATH will end with a spurious '\r'.
    export PATH="$(python -u -c "import sys
from collections import OrderedDict
print(':'.join(OrderedDict((dir.rstrip('/'), 1) for dir in sys.argv[1].split(':'))))" "$PATH")"

    export PATH="$(python -u -c "import sys
print(':'.join(d for d in sys.argv[1].split(':')
if not any(frag in d for frag in ('CommonExtensions', 'VSPerfCollectionTools', 'Team Tools'))))" "$PATH")"

    python -c "print(' PATH '.center(72, '='))"
    cygpath -p -m "$PATH" | tr ';' '\n'
    python -c "print(' ${#PATH} chars in PATH '.center(72, '='))"

    if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
      then 
        bitdir="/Win32"
      else
        bitdir="/x64"
    fi

    which nmake

    for proj in libapr libaprutil libapriconv
      do build_sln "apr-util/aprutil.sln" "Debug" "$AUTOBUILD_WIN_VSPLATFORM" "$proj"
    done

    mkdir -p "$DEBUG_OUT_DIR" || echo "$DEBUG_OUT_DIR exists"

    cp "apr$bitdir/Debug/libapr-1."{lib,dll,exp,pdb} "$DEBUG_OUT_DIR"
    cp "apr-iconv$bitdir/Debug/libapriconv-1."{lib,dll,exp,pdb} "$DEBUG_OUT_DIR"
    cp "apr-util$bitdir/Debug/libaprutil-1."{lib,dll,exp,pdb} "$DEBUG_OUT_DIR"

    for proj in libapr libaprutil libapriconv
      do build_sln "apr-util/aprutil.sln" "Release" "$AUTOBUILD_WIN_VSPLATFORM" "$proj"
    done

    mkdir -p "$RELEASE_OUT_DIR" || echo "$RELEASE_OUT_DIR exists"

    cp "apr$bitdir/Release/libapr-1."{lib,dll,exp,pdb} "$RELEASE_OUT_DIR"
    cp "apr-iconv$bitdir/Release/libapriconv-1."{lib,dll,exp,pdb} "$RELEASE_OUT_DIR"
    cp "apr-util$bitdir/Release/libaprutil-1."{lib,dll,exp,pdb} "$RELEASE_OUT_DIR"

    INCLUDE_DIR="$STAGING_DIR/include/apr-1"
    mkdir -p "$INCLUDE_DIR"      || echo "$INCLUDE_DIR exists"
    cp apr/include/*.h "$INCLUDE_DIR"
    cp apr-iconv/include/*.h "$INCLUDE_DIR"
    cp apr-util/include/*.h "$INCLUDE_DIR"
    mkdir "$INCLUDE_DIR/arch"    || echo "$INCLUDE_DIR/arch exists"
    cp apr/include/arch/apr_private_common.h "$INCLUDE_DIR/arch"
    cp -R "apr/include/arch/win32" "$INCLUDE_DIR/arch"
    mkdir "$INCLUDE_DIR/private" || echo "$INCLUDE_DIR/private exists"
    cp -R apr-util/include/private "$INCLUDE_DIR"
    popd
  ;;

  darwin*)
    PREFIX="$STAGING_DIR"

    opts="-arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE"

    pushd "$TOP_DIR/apr"
    CC="clang" CFLAGS="$opts" CXXFLAGS="$opts" LDFLAGS="$opts" \
        ./configure --prefix="$PREFIX"
    make
    make install
    popd

    pushd "$TOP_DIR/apr-util"
    CC="clang" CFLAGS="$opts" CXXFLAGS="$opts" LDFLAGS="$opts" \
        ./configure --prefix="$PREFIX" --with-apr="$PREFIX" \
        --with-expat="$PREFIX"
    make
    make install
    popd

    # To conform with autobuild install-package conventions, we want to move
    # the libraries presently in "$PREFIX/lib" to "$PREFIX/lib/release".
    # We want something like:

    # libapr-1.a
    # libaprutil-1.a
    # libapr-1.0.dylib
    # libapr-1.dylib --> libapr-1.0.dylib
    # libaprutil-1.0.dylib
    # libaprutil-1.dylib --> libaprutil-1.0.dylib

    # But as of 2012-02-08, we observe that the real libraries are
    # libapr-1.0.4.5.dylib and libaprutil-1.0.4.1.dylib, with
    # libapr[util]-1.0.dylib (as well as libapr[util]-1.dylib) symlinked to
    # them. That's no good: our Copy3rdPartyLibs.cmake and viewer_manifest.py
    # scripts don't deal with the libapr[util]-1.0.major.minor.dylib files
    # directly, they want to manipulate only libapr[util]-1.0.dylib. Fix
    # things while relocating.

    mkdir -p "$PREFIX/lib/release" || echo "reusing $PREFIX/lib/release"
    for libname in libapr libaprutil
    do # First just move the static library, that part is easy
       mv "$PREFIX/lib/$libname-1.a" "$PREFIX/lib/release/"
       # Ensure that lib/release/$libname-1.0.dylib is a real file, not a symlink
       cp "$PREFIX/lib/$libname-1.0.dylib" "$PREFIX/lib/release"
       # Make sure it's stamped with the -id we need in our app bundle.
       # As of 2012-02-07, with APR 1.4.5, this function has been observed to
       # fail on TeamCity builds. Does the failure matter? Hopefully not...
       pushd "$PREFIX/lib/release"
       fix_dylib_id "$libname-1.0.dylib" || \
       echo "fix_dylib_id $libname-1.0.dylib failed, proceeding"
       popd
       # Recreate the $libname-1.dylib symlink, because the one in lib/ is
       # pointing to (e.g.) libapr-1.0.4.5.dylib -- no good
       ln -svf "$libname-1.0.dylib" "$PREFIX/lib/release/$libname-1.dylib"
       # Clean up whatever's left in $PREFIX/lib for this $libname (e.g.
       # libapr-1.0.4.5.dylib)
       rm "$PREFIX/lib/$libname-"*.dylib || echo "moved all $libname-*.dylib"
    done

    # When we linked apr-util against apr (above), it grabbed the -id baked
    # into libapr-1.0.dylib as of that moment. A libaprutil-1.0.dylib built
    # that way fails to load because it looks for
    # "$PREFIX/lib/libapr-1.0.dylib" even on the user's machine. We tried
    # horsing around with install_name_tool -id between building apr and
    # building apr-util, but that didn't work too well. Fix it after the fact
    # with install_name_tool -change.

    # <deep breath>

    # List library dependencies with otool -L. Skip the first two lines (tail
    # -n +3): the first is otool reporting which library file it's reading,
    # the second is that library's own -id stamp. Find embedded references to
    # our own build area (Bad). From each such line, isolate just the
    # pathname. (Theoretically we could use just awk instead of grep | awk,
    # but getting awk to deal with the forward-slashes embedded in the
    # pathname would be a royal pain. Simpler to use grep.) Now emit a -change
    # switch for each of those pathnames: extract the basename and change it
    # to the canonical relative Resources path. NOW: feed all those -change
    # switches into an install_name_tool command operating on that same
    # .dylib.
    lib="$PREFIX/lib/release/libaprutil-1.0.dylib"
    install_name_tool \
        $(otool -L "$lib" | tail -n +3 | \
          grep "$PREFIX/lib" | awk '{ print $1 }' | \
          (while read f; \
           do echo -change "$f" "@executable_path/../Resources/$(basename "$f")"; \
           done) ) \
        "$lib"
  ;;

  linux*)
    # Default target per --address-size
    opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"

    # Setup build flags
    DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC"
    RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
    DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
    RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
    DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
    RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
    DEBUG_CPPFLAGS="-DPIC"
    RELEASE_CPPFLAGS="-DPIC"
    DEBUG_LDFLAGS="$opts"
    RELEASE_LDFLAGS="$opts"      

    JOBS=`cat /proc/cpuinfo | grep processor | wc -l`

    # Handle any deliberate platform targeting
    if [ -z "${TARGET_CPPFLAGS:-}" ]; then
        # Remove sysroot contamination from build environment
        unset CPPFLAGS
    else
        # Incorporate special pre-processing flags
        export CPPFLAGS="$TARGET_CPPFLAGS"
    fi

    # Fix up path for pkgconfig
    if [ -d "$STAGING_DIR/packages/lib/release/pkgconfig" ]; then
        fix_pkgconfig_prefix "$STAGING_DIR/packages"
    fi

    OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

    PREFIX="$STAGING_DIR"
    PREFIX_DEBUG="$PREFIX/temp_debug"
    PREFIX_RELEASE="$PREFIX/temp_release"

    mkdir -p $PREFIX_DEBUG
    mkdir -p $PREFIX_RELEASE

    pushd "$TOP_DIR/apr"
        autoreconf -fvi

        mkdir -p "build_debug"
        pushd "build_debug"
            # debug configure and build
            export PKG_CONFIG_PATH="$STAGING_DIR/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" LDFLAGS="$DEBUG_LDFLAGS" \
                ../configure --enable-debug --prefix="$PREFIX_DEBUG"
            make -j$JOBS
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd

        mkdir -p "build_release"
        pushd "build_release"
            # debug configure and build
            export PKG_CONFIG_PATH="$STAGING_DIR/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" LDFLAGS="$RELEASE_LDFLAGS" \
                ../configure --prefix="$PREFIX_RELEASE"
            make -j$JOBS
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd
    popd

    pushd "$TOP_DIR/apr-util"
        autoreconf -fvi

        mkdir -p "build_debug"
        pushd "build_debug"
            # debug configure and build
            export PKG_CONFIG_PATH="$STAGING_DIR/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            cp -a $STAGING_DIR/packages/lib/release/*.so* $STAGING_DIR/packages/lib

            CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" LDFLAGS="$DEBUG_LDFLAGS" \
                ../configure --prefix="$PREFIX_DEBUG" --with-apr="$PREFIX_DEBUG" \
                --with-expat="$PREFIX/packages"
            make -j$JOBS
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export LD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.so*
        popd

        mkdir -p "build_release"
        pushd "build_release"
            # debug configure and build
            export PKG_CONFIG_PATH="$STAGING_DIR/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            cp -a $STAGING_DIR/packages/lib/release/*.so* $STAGING_DIR/packages/lib

            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" LDFLAGS="$RELEASE_LDFLAGS" \
                ../configure --prefix="$PREFIX_RELEASE" --with-apr="$PREFIX_RELEASE" \
                --with-expat="$PREFIX/packages"
            make -j$JOBS
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export LD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.so*
        popd
    popd

    mkdir -p "$PREFIX/include"
    mkdir -p "$PREFIX/lib/debug"
    mkdir -p "$PREFIX/lib/release"

    cp -a $PREFIX_DEBUG/lib/*.so* $PREFIX/lib/debug
    cp -a $PREFIX_RELEASE/lib/*.so* $PREFIX/lib/release

    pushd "$PREFIX/lib/debug"
        chrpath -d libapr-1.so
        chrpath -d libaprutil-1.so
    popd

    pushd "$PREFIX/lib/release"
        chrpath -d libapr-1.so
        chrpath -d libaprutil-1.so
    popd

    cp -a $PREFIX_RELEASE/include/* $PREFIX/include/
  ;;
esac

mkdir -p "$STAGING_DIR/LICENSES"
cat "$TOP_DIR/apr/LICENSE" > "$STAGING_DIR/LICENSES/apr_suite.txt"
