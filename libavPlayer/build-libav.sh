#
# This is intended to be run by Xcode from a "Run Script" build phase.

THESDK="$DEVELOPER_SDK_DIR/MacOSX10.6.sdk"
THEARC="x86_64"
THECPU="core2"
THEOPT="-m64 -mtune=core2 " # -ffast-math -falign-loops=16 -fstrict-aliasing

# Use yasm from MacPort
PATH=$PATH:/opt/local/bin/

echo "-- Running configure (this takes ages) --"

cd ../libav
./configure \
    --enable-cross-compile \
    --arch=$THEARC \
    --cpu=$THECPU \
    --cc=clang \
    --enable-small \
    --target-os=darwin \
    --enable-decoders \
    --disable-encoders \
    --enable-demuxers \
    --disable-muxers \
    --enable-parsers \
    --disable-avdevice \
    --disable-postproc \
    --disable-avfilter \
    --disable-filters \
    --enable-protocols \
    --enable-network \
    --enable-pthreads \
    --enable-gpl \
    --disable-ffmpeg \
    --disable-ffprobe \
    --disable-ffserver \
    --disable-ffplay \
    --extra-ldflags=" -arch $THEARC -isystem $THESDK -mmacosx-version-min=10.6 -Wl,-syslibroot,$THESDK " \
    --extra-cflags=" -arch $THEARC -isystem $THESDK -mmacosx-version-min=10.6 -Wno-deprecated-declarations $THEOPT " \
    --enable-protocol=file \
|| { echo "-- ERROR on confiure --" ; tail config.err ; exit 1 ; }

echo "-- Running make clean --"
make clean || { echo "-- ERROR on make clean --" ; exit 1 ; }

echo "-- Running make lib --"
make -j4 || { exit 1 ; }

cp -p lib*/*.a ./
#strip -x *.a

echo "-- Done --"

exit 0
