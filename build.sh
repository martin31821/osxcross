#!/usr/bin/env bash
#
# Build and install the cctools the SDK and macports.
#
# This script requires the OS X SDK and the Clang/LLVM compiler.
#


pushd "${0%/*}" &>/dev/null

source tools/tools.sh

# find sdk version to use
function guess_sdk_version()
{
  tmp1=
  tmp2=
  tmp3=
  file=
  sdk=
  guess_sdk_version_result=
  sdkcount=$(find -L tarballs/ -type f | grep MacOSX | wc -l)
  if [ $sdkcount -eq 0 ]; then
    echo no SDK found in 'tarballs/'. please see README.md
    exit 1
  elif [ $sdkcount -gt 1 ]; then
    sdks=$(find -L tarballs/ -type f | grep MacOSX)
    for sdk in $sdks; do echo $sdk; done
    echo 'more than one MacOSX SDK tarball found. please set'
    echo 'SDK_VERSION environment variable for the one you want'
    echo '(for example: SDK_VERSION=10.x [OSX_VERSION_MIN=10.x] ./build.sh)'
    exit 1
  else
    sdk=$(find -L tarballs/ -type f | grep MacOSX)
    tmp2=$(echo ${sdk/bz2/} | $SED s/[^0-9.]//g)
    tmp3=$(echo $tmp2 | $SED s/\\\.*$//g)
    guess_sdk_version_result=$tmp3
    echo 'found SDK version' $guess_sdk_version_result 'at tarballs/'$(basename $sdk)
  fi
  if [ $guess_sdk_version_result ]; then
    if [ $guess_sdk_version_result = 10.4 ]; then
      guess_sdk_version_result=10.4u
    fi
  fi
  export guess_sdk_version_result
}

# make sure there is actually a file with the given SDK_VERSION
function verify_sdk_version()
{
  sdkv=$1
  for file in tarballs/*; do
    if [ -f "$file" ] && [ $(echo $file | grep OSX.*$sdkv) ]; then
      echo "verified at "$file
      sdk=$file
    fi
  done
  if [ ! $sdk ] ; then
    echo cant find SDK for OSX $sdkv in tarballs. exiting
    exit
  fi
}

if [ $SDK_VERSION ]; then
  echo 'SDK VERSION set in environment variable:' $SDK_VERSION
  test $SDK_VERSION = 10.4 && SDK_VERSION=10.4u
else
  guess_sdk_version
  SDK_VERSION=$guess_sdk_version_result
fi
verify_sdk_version $SDK_VERSION

# Minimum targeted OS X version
# Must be <= SDK_VERSION
if [ -z "$OSX_VERSION_MIN" ]; then
  if [ $SDK_VERSION = 10.4u ]; then
    OSX_VERSION_MIN=10.4
  else
    OSX_VERSION_MIN=10.5
  fi
fi

OSXCROSS_VERSION=0.15

X86_64H_SUPPORTED=0

case $SDK_VERSION in
  10.4*) TARGET=darwin8 ;;
  10.5*) TARGET=darwin9 ;;
  10.6*) TARGET=darwin10 ;;
  10.7*) TARGET=darwin11 ;;
  10.8*) TARGET=darwin12; X86_64H_SUPPORTED=1; ;;
  10.9*) TARGET=darwin13; X86_64H_SUPPORTED=1; ;;
  10.10*) TARGET=darwin14; X86_64H_SUPPORTED=1; ;;
  10.11*) TARGET=darwin15; X86_64H_SUPPORTED=1; ;;
  10.12*) TARGET=darwin16; X86_64H_SUPPORTED=1; ;;
  10.13*) TARGET=darwin17; X86_64H_SUPPORTED=1; ;;
  10.14*) TARGET=darwin18; X86_64H_SUPPORTED=1; ;;
*) echo "Invalid SDK Version" && exit 1 ;;
esac

export TARGET

echo ""
echo "Building OSXCross toolchain, Version: $OSXCROSS_VERSION"
echo ""
echo "OS X SDK Version: $SDK_VERSION, Target: $TARGET"
echo "Minimum targeted OS X Version: $OSX_VERSION_MIN"
echo "Tarball Directory: $TARBALL_DIR"
echo "Build Directory: $BUILD_DIR"
echo "Install Directory: $TARGET_DIR"
echo "SDK Install Directory: $SDK_DIR"
if [ -z "$UNATTENDED" ]; then
  echo ""
  read -p "Press enter to start building"
fi
echo ""

export PATH=$TARGET_DIR/bin:$PATH

mkdir -p $BUILD_DIR
mkdir -p $TARGET_DIR
mkdir -p $SDK_DIR

require $CC
require $CXX

require clang
require patch
require gunzip

pushd $BUILD_DIR &>/dev/null

function remove_locks()
{
  rm -rf $BUILD_DIR/have_cctools*
}

source $BASE_DIR/tools/trap_exit.sh
SDK=$(ls $TARBALL_DIR/MacOSX$SDK_VERSION*)

set +e
ls $TARBALL_DIR/MacOSX$SDK_VERSION* &>/dev/null
while [ $? -ne 0 ]
do
  echo ""
  echo "Get the MacOSX$SDK_VERSION SDK and move it into $TARBALL_DIR"
  echo "(see README for SDK download links)"
  echo ""
  echo "You can press ctrl-c to break the build process,"
  echo "if you restart ./build.sh then we will continue from here"
  echo ""
  if [ -z "$UNATTENDED" ]; then
    read -p "Press enter to continue"
  else
    exit 1
  fi
  ls $TARBALL_DIR/MacOSX$SDK_VERSION* &>/dev/null
done
set -e

extract $SDK 1 1

rm -rf $SDK_DIR/MacOSX$SDK_VERSION* 2>/dev/null

if [ "$(ls -l SDKs/*$SDK_VERSION* 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
  mv -f SDKs/*$SDK_VERSION* $SDK_DIR
else
  mv -f *OSX*$SDK_VERSION*sdk* $SDK_DIR
fi

pushd $SDK_DIR/MacOSX$SDK_VERSION.sdk &>/dev/null
set +e
create_symlink \
  $SDK_DIR/MacOSX$SDK_VERSION.sdk/System/Library/Frameworks/Kernel.framework/Versions/A/Headers/std*.h \
  usr/include 2>/dev/null
[ ! -f "usr/include/float.h" ] && cp -f $BASE_DIR/oclang/quirks/float.h usr/include
[ $PLATFORM == "FreeBSD" ] && cp -f $BASE_DIR/oclang/quirks/tgmath.h usr/include
set -e
popd &>/dev/null

popd &>/dev/null

OSXCROSS_CONF="$TARGET_DIR/bin/osxcross-conf"
OSXCROSS_ENV="$TARGET_DIR/bin/osxcross-env"

rm -f $OSXCROSS_CONF $OSXCROSS_ENV

echo "compiling wrapper ..."

export X86_64H_SUPPORTED

export OSXCROSS_VERSION
export OSXCROSS_TARGET=$TARGET
export OSXCROSS_OSX_VERSION_MIN=$OSX_VERSION_MIN
export OSXCROSS_LINKER_VERSION=274.2
export OSXCROSS_BUILD_DIR=$BUILD_DIR

if [ "$PLATFORM" != "Darwin" ]; then
  # libLTO.so
  set +e
  eval $(cat $BUILD_DIR/cctools*/cctools/config.log | grep LLVM_LIB_DIR | head -n1)
  set -e
  export OSXCROSS_LIBLTO_PATH=$LLVM_LIB_DIR
fi

$BASE_DIR/wrapper/build.sh 1>/dev/null

echo ""

if [ $(osxcross-cmp ${SDK_VERSION/u/} "<" $OSX_VERSION_MIN) -eq 1 ]; then
  echo "OSX_VERSION_MIN must be <= SDK_VERSION"
  trap "" EXIT
  exit 1
elif [ $(osxcross-cmp $OSX_VERSION_MIN "<" 10.4) -eq 1  ]; then
  echo "OSX_VERSION_MIN must be >= 10.4"
  trap "" EXIT
  exit 1
fi

# CMAKE

echo "installing CMake"

cp -f "$BASE_DIR/tools/toolchain.cmake" "$TARGET_DIR/"
cp -f "$BASE_DIR/tools/osxcross-cmake" "$TARGET_DIR/bin/"
chmod 755 "$TARGET_DIR/bin/osxcross-cmake"
create_symlink osxcross-cmake "$TARGET_DIR/bin/i386-apple-$TARGET-cmake"
create_symlink osxcross-cmake "$TARGET_DIR/bin/x86_64-apple-$TARGET-cmake"

# CMAKE END

unset MACOSX_DEPLOYMENT_TARGET

#test_compiler o32-clang $BASE_DIR/oclang/test.c
#test_compiler o64-clang $BASE_DIR/oclang/test.c

#test_compiler o32-clang++ $BASE_DIR/oclang/test.cpp
#test_compiler o64-clang++ $BASE_DIR/oclang/test.cpp

if [ $(osxcross-cmp ${SDK_VERSION/u/} ">=" 10.7) -eq 1 ]; then
  if [ ! -d "$SDK_DIR/MacOSX$SDK_VERSION.sdk/usr/include/c++/v1" ]; then
    echo ""
    echo -n "Given SDK does not contain libc++ headers "
    echo "(-stdlib=libc++ test may fail)"
    echo -n "You may want to re-package your SDK using "
    echo "'tools/gen_sdk_package.sh' on OS X"
  fi
  echo ""
  test_compiler_cxx11 o32-clang++ $BASE_DIR/oclang/test_libcxx.cpp
  test_compiler_cxx11 o64-clang++ $BASE_DIR/oclang/test_libcxx.cpp
fi

echo ""
echo "Do not forget to add"
echo ""
echo -e "\x1B[32m${TARGET_DIR}/bin\x1B[0m"
echo ""
echo "to your PATH variable."
echo ""

echo "All done! Now you can use o32-clang(++) and o64-clang(++) like a normal compiler."
echo ""
echo "Example usage:"
echo ""
echo "Example 1: CC=o32-clang ./configure --host=i386-apple-$TARGET"
echo "Example 2: CC=i386-apple-$TARGET-clang ./configure --host=i386-apple-$TARGET"
echo "Example 3: o64-clang -Wall test.c -o test"
echo "Example 4: x86_64-apple-$TARGET-strip -x test"
echo ""
