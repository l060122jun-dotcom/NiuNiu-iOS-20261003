#!/usr/bin/env bash
# Official source build only. Run with bash (also works with macOS Bash 3.2).
set -euo pipefail
IJK_SHA=30eb9441945da795079492041a791c121d2b8206
FF_TAG=ff4.0--ijk0.8.8--20210426--001
FF_SHA=e88b5afbf9ca543a098ede6dd6765ef0e629836d
GAS_SHA=dd811e7a8403ef762e333909c54c24674ee04892
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --print-lock ]]; then
    printf 'ijk=%s\nffmpeg=%s\n' "$IJK_SHA" "$FF_SHA"
    exit 0
fi
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS and Xcode.' >&2; exit 1; }
LOGS="$ROOT/build/ijk-logs"
mkdir -p "$LOGS" "$ROOT/Vendor"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ijk-source.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
on_error() {
    if [[ -n "${FF:-}" ]]; then
        for file in config.h config.log ffbuild/config.mak; do
            if [[ -f "$FF/$file" ]]; then cp "$FF/$file" "$LOGS/"; fi
        done
    fi
    echo 'IJK build failed; see build/ijk-logs artifacts.' >&2
}
trap on_error ERR
run_logged() {
    local name="$1"; shift
    echo "IJK: $name"
    if "$@" >"$LOGS/$name.log" 2>&1; then
        echo "IJK: $name OK"
    else
        tail -n 70 "$LOGS/$name.log" >&2
        return 1
    fi
}
fetch_source() {
    local url="$1" path="$2" ref="$3" sha="$4"
    git init -q "$path"
    git -C "$path" remote add origin "$url"
    git -C "$path" fetch -q --depth 1 origin "$ref"
    [[ "$(git -C "$path" rev-parse 'FETCH_HEAD^{commit}')" == "$sha" ]]
    git -C "$path" checkout -q --detach "$sha"
}
run_logged ijk-fetch fetch_source https://github.com/bilibili/ijkplayer.git "$WORK/ijk" "$IJK_SHA" "$IJK_SHA"
IJK="$WORK/ijk"
# Verify the FFmpeg ref selected by THIS pinned official init-ios.sh.
SELECTED_TAG="$(sed -n 's/^IJK_FFMPEG_COMMIT=//p' "$IJK/init-ios.sh")"
[[ "$SELECTED_TAG" == "$FF_TAG" ]] || { echo 'Unexpected official FFmpeg ref' >&2; exit 1; }
run_logged ffmpeg-fetch fetch_source https://github.com/Bilibili/FFmpeg.git "$IJK/ios/ffmpeg-arm64" "refs/tags/$SELECTED_TAG" "$FF_SHA"
FF="$IJK/ios/ffmpeg-arm64"
# Keep the selected tag locally so upstream av_version_info() is reproducible.
git -C "$FF" update-ref "refs/tags/$FF_TAG" FETCH_HEAD
run_logged gas-fetch fetch_source https://github.com/Bilibili/gas-preprocessor.git "$IJK/extra/gas-preprocessor" "$GAS_SHA" "$GAS_SHA"
export IJK_SOURCE="$IJK" FF_SOURCE="$FF"
# Apply narrowly scoped, assertion-checked changes to real upstream scripts.
python3 <<'PY'
import os
from pathlib import Path
ijk, ff = Path(os.environ['IJK_SOURCE']), Path(os.environ['FF_SOURCE'])
def replace(path, old, new, count=None):
    text = path.read_text()
    found = text.count(old)
    if not found or (count is not None and found != count):
        raise SystemExit(f'Upstream patch mismatch: {path}: {old!r} ({found})')
    path.write_text(text.replace(old, new))
replace(ijk/'ios/compile-ffmpeg.sh', 'FF_ALL_ARCHS=$FF_ALL_ARCHS_IOS8_SDK', 'FF_ALL_ARCHS="arm64"', 1)
p = ijk/'ios/tools/do-compile-ffmpeg.sh'
replace(p, '-miphoneos-version-min=7.0', '-miphoneos-version-min=16.0', 1)
replace(p, 'FF_XCODE_BITCODE="-fembed-bitcode"', 'FF_XCODE_BITCODE=""', 3)
replace(p, '--cc="$FF_XCRUN_CC" \\\n', '--cc="$FF_XCRUN_CC" \\\n        --ar="$(xcrun --sdk iphoneos --find ar)" \\\n        --ranlib="$(xcrun --sdk iphoneos --find ranlib)" \\\n        --sysroot="$(xcrun --sdk iphoneos --show-sdk-path)" \\\n', 1)
# Old C sources predate Apple Clang 16's promoted diagnostics; keep other errors.
replace(p, 'FFMPEG_EXTRA_CFLAGS=\n', 'FFMPEG_EXTRA_CFLAGS="-Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types"\n', 1)
replace(p, 'make -j3 $FF_GASPP_EXPORT', 'make -j"$(sysctl -n hw.logicalcpu)" $FF_GASPP_EXPORT', 1)
# module.sh is an upstream symlink; Windows git can expose it as plain text.
module = ijk/'config/module.sh'
module.unlink()
module.write_text((ijk/'config/module-lite.sh').read_text().replace('--disable-protocol=crypto', '--enable-protocol=crypto') + '\nexport COMMON_FF_CFG_FLAGS="$COMMON_FF_CFG_FLAGS --enable-securetransport --disable-openssl --enable-protocol=https --enable-protocol=tls --disable-gpl --disable-nonfree --disable-version3"\n')
# SecureTransport must verify certificates by default, including HLS key requests.
replace(ff/'libavformat/tls.h', 'offsetof(pstruct, options_field . verify),    AV_OPT_TYPE_INT, { .i64 = 0 }', 'offsetof(pstruct, options_field . verify),    AV_OPT_TYPE_INT, { .i64 = 1 }', 1)
controller = ijk/'ios/IJKMediaPlayer/IJKMediaPlayer/IJKFFMoviePlayerController.m'
replace(controller, 'static const char *kIJKFFRequiredFFmpegVersion = "ff4.0--ijk0.8.8--20201130--001";', 'static const char *kIJKFFRequiredFFmpegVersion = "ff4.0--ijk0.8.8--20210426--001";', 1)
PY
cd "$IJK/ios"
run_logged ffmpeg-build bash ./compile-ffmpeg.sh arm64
cp "$FF/config.h" "$FF/config.log" "$FF/ffbuild/config.mak" "$LOGS/"
for feature in SECURETRANSPORT HTTPS_PROTOCOL TLS_PROTOCOL CRYPTO_PROTOCOL HLS_DEMUXER; do
    grep -q "#define CONFIG_${feature} 1" "$FF/config.h" || { echo "Missing $feature" >&2; exit 1; }
done
for feature in GPL NONFREE VERSION3 OPENSSL; do
    grep -q "#define CONFIG_${feature} 0" "$FF/config.h" || { echo "Forbidden $feature" >&2; exit 1; }
done
# Official target is staticlib upstream. Override to a replaceable dylib;
# its six FFmpeg archives are still linked by the upstream target itself.
run_logged framework-build xcodebuild \
    -project IJKMediaPlayer/IJKMediaPlayer.xcodeproj -target IJKMediaFramework \
    -configuration Release -sdk iphoneos -arch arm64 \
    "CONFIGURATION_BUILD_DIR=$WORK/products" \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 ARCHS=arm64 VALID_ARCHS=arm64 \
    SUPPORTED_PLATFORMS=iphoneos ONLY_ACTIVE_ARCH=NO ENABLE_BITCODE=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    MACH_O_TYPE=mh_dylib DEFINES_MODULE=YES CLANG_ENABLE_MODULES=YES \
    ENABLE_USER_SCRIPT_SANDBOXING=NO \
    'OTHER_CFLAGS=$(inherited) -Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types' \
    'OTHER_LDFLAGS=$(inherited) -lbz2 -lz -framework Security -framework CoreFoundation -framework Foundation -framework UIKit -framework AudioToolbox -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework OpenGLES -framework QuartzCore' \
    build
FRAMEWORK="$WORK/products/IJKMediaFramework.framework"
[[ "$(xcrun lipo -archs "$FRAMEWORK/IJKMediaFramework")" == arm64 ]]
xcrun otool -hv "$FRAMEWORK/IJKMediaFramework" >"$LOGS/framework-mach-o.txt"
grep -q DYLIB "$LOGS/framework-mach-o.txt"
test -f "$FRAMEWORK/Modules/module.modulemap"
# Compile an actual Swift import, not merely a header existence check.
printf 'import IJKMediaFramework\nlet controller: IJKFFMoviePlayerController? = nil\n' >"$WORK/import.swift"
run_logged swift-module-check xcrun --sdk iphoneos swiftc -typecheck \
    -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -F "$WORK/products" "$WORK/import.swift"
ditto "$FRAMEWORK" "$ROOT/Vendor/IJKMediaFramework.framework"
# Keep exact original sources PLUS applied patches/config for redistribution.
mkdir -p "$WORK/compliance" "$ROOT/Vendor/IJK-Licenses"
git -C "$IJK" archive --format=tar.gz -o "$WORK/compliance/ijkplayer-original.tar.gz" "$IJK_SHA"
git -C "$FF" archive --format=tar.gz -o "$WORK/compliance/ffmpeg-original.tar.gz" "$FF_SHA"
git -C "$IJK/extra/gas-preprocessor" archive --format=tar.gz -o "$WORK/compliance/gas-preprocessor-original.tar.gz" "$GAS_SHA"
git -C "$IJK" diff --binary >"$WORK/compliance/ijk-modern-apple.patch"
git -C "$FF" diff --binary >"$WORK/compliance/ffmpeg-tls-verify.patch"
cp "$IJK/config/module.sh" "$WORK/compliance/module.sh"
cp "$ROOT/tools/build-ijk.sh" "$WORK/compliance/"
cp "$ROOT/LICENSES/IJK.md" "$WORK/compliance/NOTICE.md"
cp "$IJK/COPYING.LGPLv2.1" "$ROOT/Vendor/IJK-Licenses/IJK-LGPL-2.1.txt"
cp "$FF/COPYING.LGPLv2.1" "$ROOT/Vendor/IJK-Licenses/FFmpeg-LGPL-2.1.txt"
cp "$IJK/COPYING.LGPLv2.1" "$WORK/compliance/"
cp "$FF/LICENSE.md" "$WORK/compliance/FFmpeg-LICENSE.md"
cp "$LOGS/config.h" "$LOGS/config.mak" "$WORK/compliance/"
printf 'ijk=%s\nffmpeg-tag=%s\nffmpeg=%s\ngas-preprocessor=%s\n' "$IJK_SHA" "$FF_TAG" "$FF_SHA" "$GAS_SHA" >"$WORK/compliance/source-lock.txt"
xcodebuild -version >>"$WORK/compliance/source-lock.txt"
xcrun --sdk iphoneos --show-sdk-version >>"$WORK/compliance/source-lock.txt"
tar -czf "$ROOT/Vendor/IJK-corresponding-source.tar.gz" -C "$WORK" compliance
cp "$ROOT/LICENSES/IJK.md" "$ROOT/Vendor/IJK-Licenses/NOTICE.md"
echo 'IJK: official arm64 device framework and corresponding sources ready.'
