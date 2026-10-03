#!/usr/bin/env bash
# Shared fail-closed verification for freshly built and cached official IJK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
# Also works from the library compliance package, without the App checkout.
if [[ "$MODE" == --restore-source ]]; then
    [[ $# == 2 ]] || { echo 'Usage: verify-ijk.sh --restore-source NEW_DIRECTORY' >&2; exit 1; }
    python3 - "${IJK_COMPLIANCE_DIR:-$(cd "$(dirname "$0")" && pwd)}" "$2" <<'PY'
import hashlib, json, os, subprocess, sys, tarfile
from pathlib import Path
package, dest = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
required = ['ijkplayer-original.tar.gz', 'ffmpeg-original.tar.gz', 'gas-preprocessor-original.tar.gz',
            'ijk-modern-apple.patch', 'ffmpeg-source.patch', 'module.sh', 'config.h', 'config.mak',
            'source-lock.txt', 'source-tree-sha256.json', 'REBUILD.md', 'build-ijk.sh', 'verify-ijk.sh',
            'NOTICE.md', 'COPYING.LGPLv2.1', 'FFmpeg-LICENSE.md']
hashes = json.loads((package / 'package-sha256.json').read_text())
for name, expected in hashes.items():
    if Path(name).name != name:
        raise SystemExit('Unsafe package hash path: ' + name)
    p = package / name
    if not p.is_file() or not p.stat().st_size or hashlib.sha256(p.read_bytes()).hexdigest() != expected:
        raise SystemExit('Changed package input: ' + name)
for name in required:
    p = package / name
    if not p.is_file() or not p.stat().st_size or hashes.get(name) != hashlib.sha256(p.read_bytes()).hexdigest():
        raise SystemExit('Missing/empty/changed compliance input: ' + name)
lock = (package / 'source-lock.txt').read_text().splitlines()
for line in ['ijk=30eb9441945da795079492041a791c121d2b8206',
             'ffmpeg-tag=ff4.0--ijk0.8.8--20210426--001',
             'ffmpeg=e88b5afbf9ca543a098ede6dd6765ef0e629836d',
             'gas-preprocessor=dd811e7a8403ef762e333909c54c24674ee04892']:
    if line not in lock:
        raise SystemExit('Source lock mismatch: ' + line)
if dest.exists():
    raise SystemExit('Restore destination must not exist: ' + str(dest))
dest.mkdir(parents=True)
def extract(archive, target):
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'r:gz') as tar:
        for m in tar.getmembers():
            p = (target / m.name).resolve()
            if not p.is_relative_to(target.resolve()) or not (m.isfile() or m.isdir() or m.issym()):
                raise SystemExit('Unsafe archive member: ' + m.name)
            if m.issym() and not (p.parent / m.linkname).resolve().is_relative_to(target.resolve()):
                raise SystemExit('Unsafe archive symlink: ' + m.name)
            tar.extract(m, target)
ijk = dest / 'ijk'
ff = ijk / 'ios/ffmpeg-arm64'
gas = ijk / 'extra/gas-preprocessor'
extract(package / 'ijkplayer-original.tar.gz', ijk)
extract(package / 'ffmpeg-original.tar.gz', ff)
extract(package / 'gas-preprocessor-original.tar.gz', gas)
for root, patch in [(ijk, 'ijk-modern-apple.patch'), (ff, 'ffmpeg-source.patch')]:
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    subprocess.run(['git', '-C', str(root), 'apply', '--check', str(package / patch)], check=True)
    subprocess.run(['git', '-C', str(root), 'apply', str(package / patch)], check=True)
manifest = json.loads((package / 'source-tree-sha256.json').read_text())
for name, root in [('ijk', ijk), ('ffmpeg', ff), ('gas', gas)]:
    if not manifest.get(name):
        raise SystemExit('Empty source manifest: ' + name)
    for rel, expected in manifest[name].items():
        p = root / rel
        if not p.resolve().is_relative_to(root.resolve()):
            raise SystemExit('Unsafe manifest path: ' + rel)
        data = ('symlink:' + os.readlink(p)).encode() if p.is_symlink() else p.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise SystemExit('Restored source mismatch: ' + name + '/' + rel)
    actual = set()
    for folder, dirs, files in os.walk(root, followlinks=False):
        here = Path(folder)
        dirs[:] = [d for d in dirs if d != '.git' and (here / d) not in [ff, gas]]
        for d in list(dirs):
            if (here / d).is_symlink():
                actual.add((here / d).relative_to(root).as_posix())
                dirs.remove(d)
        actual.update((here / f).relative_to(root).as_posix() for f in files)
    if actual != set(manifest[name]):
        raise SystemExit('Restored source file-set mismatch: ' + name)
if (ijk / 'config/module.sh').read_bytes() != (package / 'module.sh').read_bytes():
    raise SystemExit('Restored module config mismatch')
if 'offsetof(pstruct, options_field . verify),    AV_OPT_TYPE_INT, { .i64 = 1 }' not in (ff / 'libavformat/tls.h').read_text():
    raise SystemExit('Restored sources do not enable TLS verification by default')
# Archives contain no .git; create a local tag carrying the exact version name.
subprocess.run(['git', '-C', str(ff), 'add', '.'], check=True)
subprocess.run(['git', '-C', str(ff), '-c', 'user.name=Source Restore', '-c',
                'user.email=restore@localhost', 'commit', '-qm', 'Restored corresponding source'], check=True)
subprocess.run(['git', '-C', str(ff), 'tag', 'ff4.0--ijk0.8.8--20210426--001'], check=True)
print('IJK: archives, patch applicability and restored source hashes verified')
PY
    exit 0
fi
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS and Xcode 16.4.' >&2; exit 1; }
[[ "$(xcodebuild -version | head -n 1)" == 'Xcode 16.4' ]] || { echo 'Expected Xcode 16.4' >&2; exit 1; }
LOGS="$ROOT/build/ijk-logs"
mkdir -p "$LOGS"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ijk-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FRAMEWORK="$ROOT/Vendor/IJKMediaFramework.framework"
APP=
case "$MODE" in
    '') ;;
    --framework) [[ $# == 2 ]]; FRAMEWORK="$2" ;;
    --app) [[ $# == 2 ]]; APP="$2" ;;
    *) echo 'Usage: verify-ijk.sh [--framework PATH | --app APP_PATH | --restore-source NEW_DIRECTORY]' >&2; exit 1 ;;
esac
check_binary() {
    local binary="$1" kind="$2" label="$3"
    test -s "$binary"
    [[ "$(xcrun lipo -archs "$binary")" == arm64 ]]
    xcrun otool -hv "$binary" >"$LOGS/$label-mach-o.txt"
    grep -q " $kind " "$LOGS/$label-mach-o.txt"
    xcrun otool -L "$binary" >"$LOGS/$label-dependencies.txt"
    xcrun otool -l "$binary" >"$LOGS/$label-load-commands.txt"
    python3 - "$LOGS/$label-dependencies.txt" <<'PY'
import re, sys
from pathlib import Path
deps = [line.strip().split(' (compatibility version', 1)[0] for line in Path(sys.argv[1]).read_text().splitlines()[1:] if line.strip()]
if not deps:
    raise SystemExit('No Mach-O dependencies found')
for dep in deps:
    if not dep.startswith(('/System/Library/', '/usr/lib/', '@rpath/')):
        raise SystemExit('Non-distributable dependency: ' + dep)
    if dep.startswith('@rpath/') and dep != '@rpath/IJKMediaFramework.framework/IJKMediaFramework' and not re.fullmatch(r'@rpath/libswift[A-Za-z0-9_]+\.dylib', dep):
        raise SystemExit('Unapproved embedded dependency: ' + dep)
PY
}
check_binary "$FRAMEWORK/IJKMediaFramework" DYLIB framework
xcrun otool -D "$FRAMEWORK/IJKMediaFramework" >"$LOGS/framework-install-name.txt"
[[ "$(sed -n '2p' "$LOGS/framework-install-name.txt")" == '@rpath/IJKMediaFramework.framework/IJKMediaFramework' ]]
grep -q '/System/Library/Frameworks/MediaPlayer.framework/' "$LOGS/framework-dependencies.txt"
python3 - "$LOGS/framework-load-commands.txt" <<'PY'
import re, sys
from pathlib import Path
paths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (\S+) \(offset', Path(sys.argv[1]).read_text())
if any(p not in ['@executable_path/Frameworks', '@loader_path/Frameworks', '/usr/lib/swift'] for p in paths):
    raise SystemExit('Unexpected framework LC_RPATH: ' + repr(paths))
PY
test -s "$FRAMEWORK/Modules/module.modulemap"
test -s "$FRAMEWORK/Headers/IJKMediaFramework.h"
test -s "$FRAMEWORK/Info.plist"
grep -q 'IJKMediaFramework' "$FRAMEWORK/Modules/module.modulemap"
# Use the real application integration, not only an import of one class.
xcrun --sdk iphoneos swiftc -typecheck -swift-version 5 \
    -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -F "$(dirname "$FRAMEWORK")" "$ROOT/App/Player.swift" >"$LOGS/swift-player-check.log" 2>&1 || {
        tail -n 80 "$LOGS/swift-player-check.log" >&2; exit 1;
    }
if [[ "$MODE" != --framework ]]; then
    test -s "$ROOT/Vendor/IJK-corresponding-source.tar.gz"
    for name in IJK-LGPL-2.1.txt FFmpeg-LGPL-2.1.txt NOTICE.md; do
        test -s "$ROOT/Vendor/IJK-Licenses/$name"
    done
    # The package contains only flat compliance inputs; do not trust arbitrary tar paths.
    python3 - "$ROOT/Vendor/IJK-corresponding-source.tar.gz" "$WORK" <<'PY'
import sys, tarfile
from pathlib import Path, PurePosixPath
target = Path(sys.argv[2])
with tarfile.open(sys.argv[1], 'r:gz') as tar:
    for m in tar.getmembers():
        p = PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0] != 'compliance' or not (m.isdir() or m.isfile()) or len(p.parts) > 2:
            raise SystemExit('Unsafe compliance archive member: ' + m.name)
        tar.extract(m, target)
PY
    IJK_COMPLIANCE_DIR="$WORK/compliance" bash "$ROOT/tools/verify-ijk.sh" --restore-source "$WORK/restored" >"$LOGS/source-restore-check.log" 2>&1 || {
        tail -n 80 "$LOGS/source-restore-check.log" >&2; exit 1;
    }
    for feature in SECURETRANSPORT HTTPS_PROTOCOL TLS_PROTOCOL CRYPTO_PROTOCOL HLS_DEMUXER HTTP_PROTOCOL TCP_PROTOCOL FILE_PROTOCOL NETWORK; do
        grep -q "^#define CONFIG_${feature} 1$" "$WORK/compliance/config.h"
    done
    for feature in GPL NONFREE VERSION3 OPENSSL GNUTLS LIBTLS; do
        grep -q "^#define CONFIG_${feature} 0$" "$WORK/compliance/config.h"
    done
fi
if [[ -n "$APP" ]]; then
    check_binary "$APP/NiuNiu" EXECUTE app
    grep -q '@rpath/IJKMediaFramework.framework/IJKMediaFramework ' "$LOGS/app-dependencies.txt"
    python3 - "$LOGS/app-load-commands.txt" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
paths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (\S+) \(offset', text)
if '@executable_path/Frameworks' not in paths:
    raise SystemExit('App missing @executable_path/Frameworks LC_RPATH')
if any(p not in ['@executable_path/Frameworks', '@loader_path/Frameworks', '/usr/lib/swift'] for p in paths):
    raise SystemExit('Unexpected App LC_RPATH: ' + repr(paths))
PY
    EMBEDDED="$APP/Frameworks/IJKMediaFramework.framework"
    check_binary "$EMBEDDED/IJKMediaFramework" DYLIB embedded-framework
    cmp "$FRAMEWORK/IJKMediaFramework" "$EMBEDDED/IJKMediaFramework"
    cmp "$FRAMEWORK/Info.plist" "$EMBEDDED/Info.plist"
    for name in IJK-LGPL-2.1.txt FFmpeg-LGPL-2.1.txt NOTICE.md; do
        cmp "$ROOT/Vendor/IJK-Licenses/$name" "$APP/IJK-Licenses/$name"
    done
fi
echo 'IJK: static verification passed; signed-device TLS/HLS and playback tests still required.'
