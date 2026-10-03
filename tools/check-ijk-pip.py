"""Static checks only; no Xcode, playback, upload or device access.

--upstream checks the five metadata source files against the exact official SHA.
It downloads source text only and keeps it in memory.
"""
import argparse
import ast
import pathlib
import re
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHA = '30eb9441945da795079492041a791c121d2b8206'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--upstream', action='store_true')
    args = parser.parse_args()
    for name in ['build-ijk.sh', 'verify-ijk.sh']:
        text = (ROOT / 'tools' / name).read_text(encoding='utf-8')
        blocks = re.findall(r"<<'PY'\n(.*?)\nPY", text, re.S)
        assert blocks, name
        for block in blocks:
            ast.parse(block)
        print(name + ': embedded Python syntax OK')
    player = (ROOT / 'App/Player.swift').read_text(encoding='utf-8')
    renderer = (ROOT / 'App/IJKSampleBufferView.m').read_text(encoding='utf-8')
    assert 'AVPlayer(' not in player
    assert 'initWithMoreContent:url withOptions:options withGLView:renderer' in renderer
    assert 'CVPixelBufferRetain(overlay->pixel_buffer)' in renderer
    assert 'kCVPixelBufferPoolAllocationThresholdKey: @6' in renderer
    assert '_pending = buffer' in renderer and 'generation != _generation' in renderer
    assert 'isPictureInPicturePossible' in player and 'setPauseInBackground(true)' in player
    print('App static real-frame / bounded queue / PiP gates: OK (not compilation)')
    if args.upstream:
        build = (ROOT / 'tools/build-ijk.sh').read_text(encoding='utf-8')
        start = build.index("prefix = 'ios/IJKMediaPlayer/IJKMediaPlayer/'")
        end = build.index("replace(controller,", start)
        section = build[start:end]
        patched = {}

        class SourcePath:
            def __truediv__(self, rel):
                return rel

        def replace(rel, old, new, count=None):
            if rel not in patched:
                url = f'https://raw.githubusercontent.com/bilibili/ijkplayer/{SHA}/{rel}'
                with urllib.request.urlopen(url, timeout=30) as response:
                    patched[rel] = response.read().decode()
            assert patched[rel].count(old) == count, rel
            patched[rel] = patched[rel].replace(old, new)

        exec(compile(section, 'metadata-patch', 'exec'), {'ijk': SourcePath(), 'replace': replace})
        assert len(patched) == 5
        # The seek result carries an immutable queue serial in message-owned
        # storage. Validate this additional exact patch, not a guessed getter.
        serial_start = build.index('# Carry the queue serial')
        serial_end = build.index('# Return the actual AVAudioSession', serial_start)
        exec(compile(build[serial_start:serial_end], 'seek-serial-patch', 'exec'), {
            'ijk': SourcePath(), 'replace': replace,
            'controller': 'ios/IJKMediaPlayer/IJKMediaPlayer/IJKFFMoviePlayerController.m'})
        assert len(patched) == 6
        for rel in patched:
            print('Pinned source assertion passed: ' + rel)
    print('No library/App build or device playback was performed.')


if __name__ == '__main__':
    main()
