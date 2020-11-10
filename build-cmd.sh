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
    # Setup osx sdk platform
    SDKNAME="macosx10.15"
    export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)
    export MACOSX_DEPLOYMENT_TARGET=10.13

    # Setup build flags
    ARCH_FLAGS="-arch x86_64"
    SDK_FLAGS="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${SDKROOT}"
    DEBUG_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -Og -g -msse4.2 -fPIC -DPIC"
    RELEASE_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -Ofast -ffast-math -g -msse4.2 -fPIC -DPIC -fstack-protector-strong"
    DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
    RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
    DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
    RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
    DEBUG_CPPFLAGS="-DPIC"
    RELEASE_CPPFLAGS="-DPIC"
    DEBUG_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names -Wl,-macos_version_min,$MACOSX_DEPLOYMENT_TARGET"
    RELEASE_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names -Wl,-macos_version_min,$MACOSX_DEPLOYMENT_TARGET"

    JOBS=`sysctl -n hw.ncpu`

    PREFIX="$STAGING_DIR"
    PREFIX_DEBUG="$PREFIX/temp_debug"
    PREFIX_RELEASE="$PREFIX/temp_release"

    mkdir -p $PREFIX_DEBUG
    mkdir -p $PREFIX_RELEASE

    pushd "$TOP_DIR/apr"
        autoreconf -fvi

        mkdir -p "build_debug"
        pushd "build_debug"
            CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" LDFLAGS="$DEBUG_LDFLAGS" \
                ../configure --enable-debug --prefix="$PREFIX_DEBUG"
            make -j$JOBS
            make install

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check -j$JOBS
            fi
        popd

        mkdir -p "build_release"
        pushd "build_release"
            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" LDFLAGS="$RELEASE_LDFLAGS" \
                ../configure --prefix="$PREFIX_RELEASE"
            make -j$JOBS
            make install

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check -j$JOBS
            fi
        popd
    popd

    pushd "$PREFIX_DEBUG/lib"
        fix_dylib_id "libapr-1.dylib"
        dsymutil libapr-*.*.dylib
        strip -x -S libapr-*.*.dylib
    popd

    pushd "$PREFIX_RELEASE/lib"
        fix_dylib_id "libapr-1.dylib"
        dsymutil libapr-*.*.dylib
        strip -x -S libapr-*.*.dylib
    popd

    pushd "$TOP_DIR/apr-util"
        autoreconf -fvi

        mkdir -p "build_debug"
        pushd "build_debug"
            cp -a $STAGING_DIR/packages/lib/release/*.dylib $STAGING_DIR/packages/lib

            CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" LDFLAGS="$DEBUG_LDFLAGS" \
                ../configure --prefix="$PREFIX_DEBUG" --with-apr="$PREFIX_DEBUG" \
                --with-expat="$PREFIX/packages"
            make -j$JOBS
            make install

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                export DYLD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
                make check -j$JOBS
            fi

            rm $STAGING_DIR/packages/lib/*.dylib
        popd

        mkdir -p "build_release"
        pushd "build_release"
            cp -a $STAGING_DIR/packages/lib/release/*.dylib $STAGING_DIR/packages/lib

            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" LDFLAGS="$RELEASE_LDFLAGS" \
                ../configure --prefix="$PREFIX_RELEASE" --with-apr="$PREFIX_RELEASE" \
                --with-expat="$PREFIX/packages"
            make -j$JOBS
            make install

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                export DYLD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
                make check -j$JOBS
            fi

            rm $STAGING_DIR/packages/lib/libexpat*.dylib
        popd
    popd

    pushd "$PREFIX_DEBUG/lib"
        fix_dylib_id "libaprutil-1.dylib"
        dsymutil libaprutil-*.*.dylib
        strip -x -S libaprutil-*.*.dylib
    popd

    pushd "$PREFIX_RELEASE/lib"
        fix_dylib_id "libaprutil-1.dylib"
        dsymutil libaprutil-*.*.dylib
        strip -x -S libaprutil-*.*.dylib
    popd

    mkdir -p "$PREFIX/include"
    mkdir -p "$PREFIX/lib/debug"
    mkdir -p "$PREFIX/lib/release"

    cp -a $PREFIX_DEBUG/lib/*.dylib* $PREFIX/lib/debug
    cp -a $PREFIX_RELEASE/lib/*.dylib* $PREFIX/lib/release

    cp -a $PREFIX_RELEASE/include/* $PREFIX/include/
  ;;

  linux*)
    PREFIX="$STAGING_DIR"

    opts="-m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE"

    # do release builds
    pushd "$TOP_DIR/apr"
        LDFLAGS="$opts" CFLAGS="$opts" CXXFLAGS="$opts" \
            ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib/release"
        make
        make install
    popd

    pushd "$TOP_DIR/apr-iconv"
        # NOTE: the autotools scripts in iconv don't honor the --libdir switch so we
        # need to build to a dummy prefix and copy the files into the correct place
        mkdir "$PREFIX/iconv"
        LDFLAGS="$opts" CFLAGS="$opts" CXXFLAGS="$opts" \
            ./configure --prefix="$PREFIX/iconv" --with-apr="../apr"
        make
        make install

        # move the files into place
        mkdir -p "$PREFIX/bin"
        cp -a "$PREFIX"/iconv/lib/* "$PREFIX/lib/release"
        cp -r "$PREFIX/iconv/include/apr-1" "$PREFIX/include/"
        cp "$PREFIX/iconv/bin/apriconv" "$PREFIX/bin/"
        rm -rf "$PREFIX/iconv"
    popd

    pushd "$TOP_DIR/apr-util"
        # the autotools can't find the expat static lib with the layout of our
        # libraries so we need to copy the file to the correct location temporarily
        cp "$PREFIX/packages/lib/release/libexpat.a" "$PREFIX/packages/lib/"

        # the autotools for apr-util don't honor the --libdir switch so we
        # need to build to a dummy prefix and copy the files into the correct place
        mkdir "$PREFIX/util"
        LDFLAGS="$opts" CFLAGS="$opts" CXXFLAGS="$opts" \
            ./configure --prefix="$PREFIX/util" \
            --with-apr="../apr" \
            --with-apr-iconv="../apr-iconv" \
            --with-expat="$PREFIX/packages/"
        make
        make install

        # move files into place
        mkdir -p "$PREFIX/bin"
        cp -a "$PREFIX"/util/lib/* "$PREFIX/lib/release/"
        cp -r "$PREFIX/util/include/apr-1" "$PREFIX/include/"
        cp "$PREFIX"/util/bin/* "$PREFIX/bin/"
        rm -rf "$PREFIX/util"
        rm -rf "$PREFIX/packages/lib/libexpat.a"
    popd

    # APR includes its own expat.h header that doesn't have all of the features
    # in the expat library that we have a dependency
    cp "$PREFIX/packages/include/expat/expat_external.h" "$PREFIX/include/apr-1/"
    cp "$PREFIX/packages/include/expat/expat.h" "$PREFIX/include/apr-1/"

    # clean
    pushd "$TOP_DIR/apr"
        make distclean
    popd
    pushd "$TOP_DIR/apr-iconv"
        make distclean
    popd
    pushd "$TOP_DIR/apr-util"
        make distclean
    popd
  ;;
esac

mkdir -p "$STAGING_DIR/LICENSES"
cat "$TOP_DIR/apr/LICENSE" > "$STAGING_DIR/LICENSES/apr_suite.txt"
