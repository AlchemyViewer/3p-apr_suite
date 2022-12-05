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

    for proj in apr aprutil apriconv
      do build_sln "apr-util/aprutil.sln" "Debug|$AUTOBUILD_WIN_VSPLATFORM" "$proj"
    done

    mkdir -p "$DEBUG_OUT_DIR" || echo "$DEBUG_OUT_DIR exists"

    cp "apr$bitdir/Debug/apr-1.lib" "$DEBUG_OUT_DIR"
    cp "apr-iconv$bitdir/Debug/apriconv-1.lib" "$DEBUG_OUT_DIR"
    cp "apr-util$bitdir/Debug/aprutil-1.lib" "$DEBUG_OUT_DIR"

    for proj in apr aprutil apriconv
      do build_sln "apr-util/aprutil.sln" "Release|$AUTOBUILD_WIN_VSPLATFORM" "$proj"
    done

    mkdir -p "$RELEASE_OUT_DIR" || echo "$RELEASE_OUT_DIR exists"

    cp "apr$bitdir/Release/apr-1.lib" "$RELEASE_OUT_DIR"
    cp "apr-iconv$bitdir/Release/apriconv-1.lib" "$RELEASE_OUT_DIR"
    cp "apr-util$bitdir/Release/aprutil-1.lib" "$RELEASE_OUT_DIR"

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
    SDKNAME="macosx"
    export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)

    # Deploy Targets
    X86_DEPLOY=10.13
    ARM64_DEPLOY=11.0

    # Setup build flags
    ARCH_FLAGS_X86="-arch x86_64 -mmacosx-version-min=${X86_DEPLOY} -isysroot ${SDKROOT}"
    ARCH_FLAGS_ARM64="-arch arm64 -mmacosx-version-min=${ARM64_DEPLOY} -isysroot ${SDKROOT}"
    DEBUG_COMMON_FLAGS="-O0 -g -fPIC -DPIC"
    RELEASE_COMMON_FLAGS="-O3 -g -fPIC -DPIC -fstack-protector-strong"
    DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
    RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
    DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
    RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
    DEBUG_CPPFLAGS="-DPIC"
    RELEASE_CPPFLAGS="-DPIC"
    DEBUG_LDFLAGS="-Wl,-headerpad_max_install_names"
    RELEASE_LDFLAGS="-Wl,-headerpad_max_install_names"

    # x86 Deploy Target
    export MACOSX_DEPLOYMENT_TARGET=${X86_DEPLOY}

    PREFIX="$STAGING_DIR"
    PREFIX_DEBUG_X86="$PREFIX/temp_debug_x86"
    PREFIX_DEBUG_ARM64="$PREFIX/temp_debug_arm64"
    PREFIX_RELEASE_X86="$PREFIX/temp_release_x86"
    PREFIX_RELEASE_ARM64="$PREFIX/temp_release_arm64"

    mkdir -p $PREFIX_DEBUG_X86
    mkdir -p $PREFIX_DEBUG_ARM64
    mkdir -p $PREFIX_RELEASE_X86
    mkdir -p $PREFIX_RELEASE_ARM64

    pushd "$TOP_DIR/apr"
        autoreconf -fvi

        mkdir -p "build_debug_x86"
        pushd "build_debug_x86"
            CFLAGS="$ARCH_FLAGS_X86 $DEBUG_CFLAGS -msse4.2" CXXFLAGS="$ARCH_FLAGS_X86 $DEBUG_CXXFLAGS -msse4.2" LDFLAGS="$ARCH_FLAGS_X86 $DEBUG_LDFLAGS" \
                ../configure --enable-debug --disable-shared --enable-static --prefix="$PREFIX_DEBUG_X86" --host=x86_64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd

        mkdir -p "build_release_x86"
        pushd "build_release_x86"
            CFLAGS="$ARCH_FLAGS_X86 $RELEASE_CFLAGS -msse4.2" CXXFLAGS="$ARCH_FLAGS_X86 $RELEASE_CXXFLAGS -msse4.2" LDFLAGS="$ARCH_FLAGS_X86 $RELEASE_LDFLAGS" \
                ../configure --disable-shared --enable-static --prefix="$PREFIX_RELEASE_X86" --host=x86_64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd

        # ARM64 Deploy Target
        export MACOSX_DEPLOYMENT_TARGET=${ARM64_DEPLOY}

        mkdir -p "build_debug_arm64"
        pushd "build_debug_arm64"
            CFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CFLAGS" CXXFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CXXFLAGS" LDFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_LDFLAGS" \
                ../configure --enable-debug --disable-shared --enable-static --prefix="$PREFIX_DEBUG_ARM64" --host=aarch64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd

        mkdir -p "build_release_arm64"
        pushd "build_release_arm64"
            CFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CFLAGS" CXXFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CXXFLAGS" LDFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_LDFLAGS" \
                ../configure --disable-shared --enable-static --prefix="$PREFIX_RELEASE_ARM64" --host=aarch64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd        
    popd

    # pushd "$PREFIX_DEBUG/lib"
    #     fix_dylib_id "libapr-1.dylib"
    #     dsymutil libapr-*.*.dylib
    #     strip -x -S libapr-*.*.dylib
    # popd

    # pushd "$PREFIX_RELEASE/lib"
    #     fix_dylib_id "libapr-1.dylib"
    #     dsymutil libapr-*.*.dylib
    #     strip -x -S libapr-*.*.dylib
    # popd

    pushd "$TOP_DIR/apr-util"
        autoreconf -fvi

        # x86_64 Deploy Target
        export MACOSX_DEPLOYMENT_TARGET=${X86_DEPLOY}

        mkdir -p "build_debug_x86"
        pushd "build_debug_x86"
            cp -a $STAGING_DIR/packages/lib/debug/*.a $STAGING_DIR/packages/lib

            CFLAGS="$ARCH_FLAGS_X86 $DEBUG_CFLAGS -msse4.2" CXXFLAGS="$ARCH_FLAGS_X86 $DEBUG_CXXFLAGS -msse4.2" LDFLAGS="$ARCH_FLAGS_X86 $DEBUG_LDFLAGS" \
                ../configure --prefix="$PREFIX_DEBUG_X86" --with-apr="$PREFIX_DEBUG_X86" \
                --with-expat="$PREFIX/packages" --disable-shared --enable-static --host=x86_64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export DYLD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd

        mkdir -p "build_release_x86"
        pushd "build_release_x86"
            cp -a $STAGING_DIR/packages/lib/release/*.a $STAGING_DIR/packages/lib

            CFLAGS="$ARCH_FLAGS_X86 $RELEASE_CFLAGS -msse4.2" CXXFLAGS="$ARCH_FLAGS_X86 $RELEASE_CXXFLAGS -msse4.2" LDFLAGS="$ARCH_FLAGS_X86 $RELEASE_LDFLAGS" \
                ../configure --prefix="$PREFIX_RELEASE_X86" --with-apr="$PREFIX_RELEASE_X86" \
                --with-expat="$PREFIX/packages" --disable-shared --enable-static --host=x86_64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export DYLD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd

        # ARM64 Deploy Target
        export MACOSX_DEPLOYMENT_TARGET=${ARM64_DEPLOY}

        mkdir -p "build_debug_arm64"
        pushd "build_debug_arm64"
            cp -a $STAGING_DIR/packages/lib/debug/*.a $STAGING_DIR/packages/lib

            CFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CFLAGS" CXXFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CXXFLAGS" LDFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_LDFLAGS" \
                ../configure --prefix="$PREFIX_DEBUG_ARM64" --with-apr="$PREFIX_DEBUG_ARM64" \
                --with-expat="$PREFIX/packages" --disable-shared --enable-static --host=aarch64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export DYLD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd

        mkdir -p "build_release_arm64"
        pushd "build_release_arm64"
            cp -a $STAGING_DIR/packages/lib/release/*.a $STAGING_DIR/packages/lib

            CFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CFLAGS" CXXFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CXXFLAGS" LDFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_LDFLAGS" \
                ../configure --prefix="$PREFIX_RELEASE_ARM64" --with-apr="$PREFIX_RELEASE_ARM64" \
                --with-expat="$PREFIX/packages" --disable-shared --enable-static --host=aarch64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export DYLD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd
    popd

    mkdir -p "$PREFIX/include"
    mkdir -p "$PREFIX/lib/debug"
    mkdir -p "$PREFIX/lib/release"

    # create fat libraries
    lipo -create ${STAGING_DIR}/temp_debug_x86/lib/libapr-1.a ${STAGING_DIR}/temp_debug_arm64/lib/libapr-1.a -output ${STAGING_DIR}/lib/debug/libapr-1.a
    lipo -create ${STAGING_DIR}/temp_debug_x86/lib/libaprutil-1.a ${STAGING_DIR}/temp_debug_arm64/lib/libaprutil-1.a -output ${STAGING_DIR}/lib/debug/libaprutil-1.a
    lipo -create ${STAGING_DIR}/temp_release_x86/lib/libapr-1.a ${STAGING_DIR}/temp_release_arm64/lib/libapr-1.a -output ${STAGING_DIR}/lib/release/libapr-1.a
    lipo -create ${STAGING_DIR}/temp_release_x86/lib/libaprutil-1.a ${STAGING_DIR}/temp_release_arm64/lib/libaprutil-1.a -output ${STAGING_DIR}/lib/release/libaprutil-1.a

    # copy headers
    mv $STAGING_DIR/temp_release_x86/include/* $STAGING_DIR/include/expat/
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

    # Handle any deliberate platform targeting
    if [ -z "${TARGET_CPPFLAGS:-}" ]; then
        # Remove sysroot contamination from build environment
        unset CPPFLAGS
    else
        # Incorporate special pre-processing flags
        export CPPFLAGS="$TARGET_CPPFLAGS"
    fi

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
                ../configure --enable-debug --disable-shared --enable-static --prefix="$PREFIX_DEBUG"
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd

        mkdir -p "build_release"
        pushd "build_release"
            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" LDFLAGS="$RELEASE_LDFLAGS" \
                ../configure --disable-shared --enable-static --prefix="$PREFIX_RELEASE"
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd
    popd

    pushd "$TOP_DIR/apr-util"
        autoreconf -fvi

        cp -a $STAGING_DIR/packages/include/expat/*.h $STAGING_DIR/packages/include/

        mkdir -p "build_debug"
        pushd "build_debug"
            cp -a $STAGING_DIR/packages/lib/debug/*.a $STAGING_DIR/packages/lib

            CFLAGS="$DEBUG_CFLAGS -L$STAGING_DIR/packages/include" \
            CXXFLAGS="$DEBUG_CXXFLAGS -L$STAGING_DIR/packages/include" \
            LDFLAGS="$DEBUG_LDFLAGS" \
                ../configure --prefix="$PREFIX_DEBUG" --with-apr="$PREFIX_DEBUG" \
                --with-expat="$PREFIX/packages" --without-crypto --disable-shared --enable-static
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export LD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd

        mkdir -p "build_release"
        pushd "build_release"
            cp -a $STAGING_DIR/packages/lib/release/*.a $STAGING_DIR/packages/lib

            CFLAGS="$RELEASE_CFLAGS -L$STAGING_DIR/packages/include" \
            CXXFLAGS="$RELEASE_CXXFLAGS -L$STAGING_DIR/packages/include" \
            LDFLAGS="$RELEASE_LDFLAGS" \
                ../configure --prefix="$PREFIX_RELEASE" --with-apr="$PREFIX_RELEASE" \
                --with-expat="$PREFIX/packages" --without-crypto --disable-shared --enable-static
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export LD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd
    popd

    mkdir -p "$PREFIX/include"
    mkdir -p "$PREFIX/lib/debug"
    mkdir -p "$PREFIX/lib/release"

    cp -a $PREFIX_DEBUG/lib/*.a $PREFIX/lib/debug
    cp -a $PREFIX_RELEASE/lib/*.a $PREFIX/lib/release

    cp -a $PREFIX_RELEASE/include/* $PREFIX/include/
  ;;
esac

mkdir -p "$STAGING_DIR/LICENSES"
cat "$TOP_DIR/apr/LICENSE" > "$STAGING_DIR/LICENSES/apr_suite.txt"
