#!/usr/bin/env python3
"""Validate a device IPA's host, embedded keyboard, IDs, privacy settings, and dictionary."""
import argparse
import plistlib
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile


def validate(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'This is not an iPhone device build.'
    assert info['CFBundleIdentifier'] == 'dev.liana.ime.ios'
    assert info['CFBundleShortVersionString'] and '$(' not in info['CFBundleShortVersionString']
    manifest = info.get('UIApplicationSceneManifest', {})
    configurations = manifest.get('UISceneConfigurations', {}).get('UIWindowSceneSessionRoleApplication', [])
    assert configurations, 'Missing scene configuration: iOS 27 refuses to launch legacy UIKit apps.'
    assert any(config.get('UISceneDelegateClassName', '').endswith('.SceneDelegate')
               and '$(' not in config['UISceneDelegateClassName'] for config in configurations), 'Missing resolved scene delegate class.'
    assert info.get('UILaunchScreen') is not None, 'Launch screen declaration missing.'
    plugins = list((app / 'PlugIns').glob('*.appex'))
    assert len(plugins) == 1, 'Expected one keyboard extension.'
    extension = plugins[0]
    keyboard = plistlib.loads((extension / 'Info.plist').read_bytes())
    assert keyboard['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.keyboard'
    assert keyboard['CFBundleShortVersionString'] == info['CFBundleShortVersionString']
    assert keyboard['CFBundleVersion'] == info['CFBundleVersion']
    assert keyboard['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.keyboard-service'
    attributes = keyboard['NSExtension']['NSExtensionAttributes']
    assert attributes['RequestsOpenAccess'] is True, 'Optional Bluetooth access must be declared.'
    assert keyboard['NSBluetoothAlwaysUsageDescription']
    assert info['NSBluetoothAlwaysUsageDescription']
    assert info['NSCameraUsageDescription']
    assert info['NSMicrophoneUsageDescription']
    assert info['NSSpeechRecognitionUsageDescription']
    assert keyboard['NSLocalNetworkUsageDescription']
    assert info['NSLocalNetworkUsageDescription']
    assert '_liana-pet._tcp' in info['NSBonjourServices']
    assert any('public.item' in item['LSItemContentTypes'] and item['CFBundleTypeRole'] == 'Viewer' for item in info['CFBundleDocumentTypes'])
    assert attributes['IsASCIICapable'] is True
    assert (extension / 'base.ifd').read_bytes().startswith(b'IFD1')
    assert (extension / 'base.lm').read_bytes().startswith(b'LMC2'), 'Missing collocation model: sentence ranking degrades to unigram.'
    assert (extension / 'mobile.sqlite').read_bytes().startswith(b'SQLite format 3')
    for resource in ['mmah.json', 'hanzilookup.min.js', 'LICENSE', 'LICENSE-APL', 'LICENSE-Wubi.txt']:
        assert (extension / resource).is_file(), f'Missing offline resource / license: {resource}'
    for bundle, metadata in [(app, info), (extension, keyboard)]:
        executable = bundle / metadata['CFBundleExecutable']
        architectures = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip().split()
        assert architectures == ['arm64'], f'Unexpected architecture: {architectures}'
        load_commands = subprocess.check_output(['otool', '-l', str(executable)], text=True)
        # LC_BUILD_VERSION platform 2 is iOS; 7 is iOS Simulator.
        assert 'platform 2' in load_commands, 'Executable is not built for iOS devices.'
    print(f'IPA validation passed: iPhone arm64 + keyboard extension, {info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]})')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path, nargs='?')
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    if args.app:
        validate(args.app)
    else:
        if not args.ipa:
            parser.error('Supply an IPA or --app directory.')
        with tempfile.TemporaryDirectory(prefix='liana-ipa-check-') as temp:
            with ZipFile(args.ipa) as archive:
                assert archive.testzip() is None
                root = Path(temp).resolve()
                for name in archive.namelist():
                    assert (root / name).resolve().is_relative_to(root), 'Unsafe ZIP path.'
                archive.extractall(root)
            # Ignore AppleDouble sidecars (._Foo.app) preserved by zip/ditto.
            apps = [p for p in (root / 'Payload').glob('*.app') if not p.name.startswith('._')]
            assert len(apps) == 1
            validate(apps[0])


if __name__ == '__main__':
    main()
