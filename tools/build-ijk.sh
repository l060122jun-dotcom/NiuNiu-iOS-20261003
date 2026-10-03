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
[[ "$(xcodebuild -version | head -n 1)" == 'Xcode 16.4' ]] || { echo 'Requires Xcode 16.4; select DEVELOPER_DIR explicitly.' >&2; exit 1; }
LOGS="$ROOT/build/ijk-logs"
mkdir -p "$LOGS" "$ROOT/Vendor"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ijk-source.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
on_error() {
    if [[ -n "${FF:-}" ]]; then
        for file in config.h config.log ffbuild/config.log ffbuild/config.mak; do
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
# IJK's pointer dictionary helpers use uintptr_t, not void*. Preserve their
# hexadecimal pointer string format while fixing Clang's type diagnostics.
# Match the complete pinned upstream block; never rewrite unrelated NULLs.
replace(ff/'libavutil/dict.c', '''int av_dict_set_intptr(AVDictionary **pm, const char *key, uintptr_t value,
                int flags)
{
    char valuestr[22];
    snprintf(valuestr, sizeof(valuestr), "%p", value);
    flags &= ~AV_DICT_DONT_STRDUP_VAL;
    return av_dict_set(pm, key, valuestr, flags);
}

uintptr_t av_dict_get_intptr(const AVDictionary *m, const char* key) {
    uintptr_t ptr = NULL;
    AVDictionaryEntry *t = NULL;
    if ((t = av_dict_get(m, key, NULL, 0))) {
      return av_dict_strtoptr(t->value);
    }
    return NULL;
}

uintptr_t av_dict_strtoptr(char * value) {
   uintptr_t ptr = NULL;
   char *next = NULL;
   if(!value || value[0] !='0' || (value[1]|0x20)!='x') {
       return NULL;
   }
   ptr = strtoull(value, &next, 16);
   if (next == value) {
       return NULL;
   }
   return ptr;
}

char * av_dict_ptrtostr(uintptr_t value) {
    char valuestr[22] = {0};
    snprintf(valuestr, sizeof(valuestr), "%p", value);
    return av_strdup(valuestr);
}''', '''int av_dict_set_intptr(AVDictionary **pm, const char *key, uintptr_t value,
                int flags)
{
    char valuestr[22];
    snprintf(valuestr, sizeof(valuestr), "%p", (void *)value);
    flags &= ~AV_DICT_DONT_STRDUP_VAL;
    return av_dict_set(pm, key, valuestr, flags);
}

uintptr_t av_dict_get_intptr(const AVDictionary *m, const char* key) {
    AVDictionaryEntry *t = NULL;
    if ((t = av_dict_get(m, key, NULL, 0))) {
      return av_dict_strtoptr(t->value);
    }
    return (uintptr_t)0;
}

uintptr_t av_dict_strtoptr(char * value) {
   uintptr_t ptr = (uintptr_t)0;
   char *next = NULL;
   if(!value || value[0] !='0' || (value[1]|0x20)!='x') {
       return (uintptr_t)0;
   }
   ptr = (uintptr_t)strtoull(value, &next, 16);
   if (next == value) {
       return (uintptr_t)0;
   }
   return ptr;
}

char * av_dict_ptrtostr(uintptr_t value) {
    char valuestr[22] = {0};
    snprintf(valuestr, sizeof(valuestr), "%p", (void *)value);
    return av_strdup(valuestr);
}''', 1)
controller = ijk/'ios/IJKMediaPlayer/IJKMediaPlayer/IJKFFMoviePlayerController.m'
replace(controller, 'static const char *kIJKFFRequiredFFmpegVersion = "ff4.0--ijk0.8.8--20201130--001";', 'static const char *kIJKFFRequiredFFmpegVersion = "ff4.0--ijk0.8.8--20210426--001";', 1)
# Return the actual AVAudioSession result on every BOOL path; keep the
# upstream deactivation exception handler rather than silencing return-type.
replace(ijk/'ios/IJKMediaPlayer/IJKMediaPlayer/IJKAudioKit.m', '''- (BOOL)setActive:(BOOL)active
{
    if (active != NO) {
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
    } else {
        @try {
            [[AVAudioSession sharedInstance] setActive:NO error:nil];
        } @catch (NSException *exception) {
            NSLog(@"failed to inactive AVAudioSession\\n");
        }
    }
}''', '''- (BOOL)setActive:(BOOL)active
{
    if (active != NO) {
        return [[AVAudioSession sharedInstance] setActive:YES error:nil];
    } else {
        @try {
            return [[AVAudioSession sharedInstance] setActive:NO error:nil];
        } @catch (NSException *exception) {
            NSLog(@"failed to inactive AVAudioSession\\n");
            return NO;
        }
    }
}''', 1)
PY
cd "$IJK/ios"
run_logged ffmpeg-build bash ./compile-ffmpeg.sh arm64
cp "$FF/config.h" "$FF/ffbuild/config.mak" "$LOGS/"
for file in "$FF/config.log" "$FF/ffbuild/config.log"; do
    if [[ -f "$file" ]]; then cp "$file" "$LOGS/config.log"; fi
done
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
    'OTHER_LDFLAGS=$(inherited) -lbz2 -lz -framework Security -framework CoreFoundation -framework Foundation -framework UIKit -framework MediaPlayer -framework AudioToolbox -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework OpenGLES -framework QuartzCore' \
    build
FRAMEWORK="$WORK/products/IJKMediaFramework.framework"
run_logged framework-check bash "$ROOT/tools/verify-ijk.sh" --framework "$FRAMEWORK"
ditto "$FRAMEWORK" "$ROOT/Vendor/IJKMediaFramework.framework"
# Keep exact original sources PLUS applied patches/config for redistribution.
mkdir -p "$WORK/compliance" "$ROOT/Vendor/IJK-Licenses"
git -C "$IJK" archive --format=tar.gz -o "$WORK/compliance/ijkplayer-original.tar.gz" "$IJK_SHA"
git -C "$FF" archive --format=tar.gz -o "$WORK/compliance/ffmpeg-original.tar.gz" "$FF_SHA"
git -C "$IJK/extra/gas-preprocessor" archive --format=tar.gz -o "$WORK/compliance/gas-preprocessor-original.tar.gz" "$GAS_SHA"
git -C "$IJK" diff --binary >"$WORK/compliance/ijk-modern-apple.patch"
git -C "$FF" diff --binary >"$WORK/compliance/ffmpeg-source.patch"
cp "$IJK/config/module.sh" "$WORK/compliance/module.sh"
cp "$ROOT/tools/build-ijk.sh" "$WORK/compliance/"
cp "$ROOT/tools/verify-ijk.sh" "$WORK/compliance/"
cp "$ROOT/LICENSES/IJK.md" "$WORK/compliance/NOTICE.md"
cp "$IJK/COPYING.LGPLv2.1" "$ROOT/Vendor/IJK-Licenses/IJK-LGPL-2.1.txt"
cp "$FF/COPYING.LGPLv2.1" "$ROOT/Vendor/IJK-Licenses/FFmpeg-LGPL-2.1.txt"
cp "$IJK/COPYING.LGPLv2.1" "$WORK/compliance/"
cp "$FF/LICENSE.md" "$WORK/compliance/FFmpeg-LICENSE.md"
cp "$LOGS/config.h" "$LOGS/config.mak" "$WORK/compliance/"
printf 'ijk=%s\nffmpeg-tag=%s\nffmpeg=%s\ngas-preprocessor=%s\n' "$IJK_SHA" "$FF_TAG" "$FF_SHA" "$GAS_SHA" >"$WORK/compliance/source-lock.txt"
xcodebuild -version >>"$WORK/compliance/source-lock.txt"
xcrun --sdk iphoneos --show-sdk-version >>"$WORK/compliance/source-lock.txt"
# Hash precisely the tracked source inputs (not generated objects or .git).
# The restored original archives + patches must reproduce every such input.
export COMPLIANCE="$WORK/compliance" GAS_SOURCE="$IJK/extra/gas-preprocessor"
python3 <<'PY'
import hashlib, json, os, subprocess
from pathlib import Path
out = {}
for name, env in [('ijk', 'IJK_SOURCE'), ('ffmpeg', 'FF_SOURCE'), ('gas', 'GAS_SOURCE')]:
    root = Path(os.environ[env])
    paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
    entries = {}
    for rel in sorted(p for p in paths if p):
        p = root / rel
        data = ('symlink:' + os.readlink(p)).encode() if p.is_symlink() else p.read_bytes()
        entries[rel] = hashlib.sha256(data).hexdigest()
    out[name] = entries
Path(os.environ['COMPLIANCE'], 'source-tree-sha256.json').write_text(json.dumps(out, sort_keys=True, indent=2) + '\n')
PY
cat >"$WORK/compliance/REBUILD.md" <<'DOC'
# Restore and rebuild the exact patched sources (macOS / Xcode 16.4)

Extract IJK-corresponding-source.tar.gz into a new directory. From compliance/:

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
test -d "$DEVELOPER_DIR"
bash verify-ijk.sh --restore-source ./restored
cd restored/ijk/ios
bash compile-ffmpeg.sh arm64
xcodebuild -project IJKMediaPlayer/IJKMediaPlayer.xcodeproj -target IJKMediaFramework \
  -configuration Release -sdk iphoneos -arch arm64 \
  CONFIGURATION_BUILD_DIR="$PWD/products" IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  ARCHS=arm64 VALID_ARCHS=arm64 SUPPORTED_PLATFORMS=iphoneos ONLY_ACTIVE_ARCH=NO \
  ENABLE_BITCODE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  MACH_O_TYPE=mh_dylib DEFINES_MODULE=YES CLANG_ENABLE_MODULES=YES \
  ENABLE_USER_SCRIPT_SANDBOXING=NO \
  'OTHER_CFLAGS=$(inherited) -Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types' \
  'OTHER_LDFLAGS=$(inherited) -lbz2 -lz -framework Security -framework CoreFoundation -framework Foundation -framework UIKit -framework MediaPlayer -framework AudioToolbox -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework OpenGLES -framework QuartzCore' build
```

Restore checks archive/patch hashes, runs git apply --check before applying both
patches, and checks the restored tracked source trees against the build inputs.
The FFmpeg tag is recreated locally for av_version_info(). No network fetch or
third-party binary is needed. config.h/config.mak record the original build;
FFmpeg reconfigures for the local SDK rather than reusing temporary prefix paths.
Copy products/IJKMediaFramework.framework into the App checkout's Vendor/, and
run its tools/verify-ijk.sh before xcodegen and after the complete App build.
The App source (including App/Player.swift), project.yml and workflow must also
be distributed to rebuild the App; they are not contained in this library pack.
Compare configuration and versions, not bit-identical binaries: timestamps and
build paths may differ. Static CI checks do not replace signed-device TLS/HLS
tests (valid/expired/untrusted/wrong-host certificates, playlist/segment/key).
For an independent IJK checkout version marker, use the archived RELEASE/VERSION
files; the restored git repositories are local reconstruction metadata, not the
original commit history. source-lock.txt records the original commit identities.
DOC
python3 <<'PY'
import hashlib, json, os
from pathlib import Path
root = Path(os.environ['COMPLIANCE'])
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.iterdir()) if p.is_file()}
(root / 'package-sha256.json').write_text(json.dumps(hashes, sort_keys=True, indent=2) + '\n')
PY
tar -czf "$ROOT/Vendor/IJK-corresponding-source.tar.gz" -C "$WORK" compliance
cp "$ROOT/LICENSES/IJK.md" "$ROOT/Vendor/IJK-Licenses/NOTICE.md"
run_logged distribution-check bash "$ROOT/tools/verify-ijk.sh"
echo 'IJK: official arm64 device framework and corresponding sources ready.'
