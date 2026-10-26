"""Real simulator companion file exchange; explicitly NOT physical USB evidence.

Runs after simulator UI tests. Never reads/writes Photos, only the two disposable
connection metadata slots. Screenshots verify visible connected/expired states.
"""
import json
import pathlib
import subprocess
import sys
import time
import uuid


def main(device):
    bundle = 'com.photobridge.OrderProbe'
    def sim(*args):
        return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()
    # xcodebuild may shut down its target after UI testing. Prepare an explicit
    # instance instead of assuming the test runner left a foreground app alive.
    devices = json.loads(sim('list', 'devices', 'available', '-j'))['devices']
    target = next(d for group in devices.values() for d in group if d['udid'] == device)
    if target['state'] != 'Booted': sim('boot', device)
    sim('bootstatus', device, '-b')
    sim('install', device, 'build/SimulatorData/Build/Products/Debug-iphonesimulator/PhotoBridgeOrderProbe.app')
    root = pathlib.Path(sim('get_app_container', device, bundle, 'data')) / 'Documents' / 'Control'
    out = pathlib.Path('build/ui-screenshots'); out.mkdir(parents=True, exist_ok=True)
    sim('launch', '--terminate-running-process', device, bundle)
    def exchange(confirmed=None):
        nonce = str(uuid.uuid4())
        raw = dict(kind='PhotoBridgeConnection', nonce=nonce, confirmedNonce=confirmed)
        temporary = root / 'connection-request.json.part'
        temporary.write_text(json.dumps(raw))
        temporary.replace(root / 'connection-request.json')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                reply = json.loads((root / 'connection-reply.json').read_text())
                if reply['nonce'].lower() == nonce and reply['foreground'] is True:
                    return nonce
            except (OSError, ValueError, KeyError): pass
            time.sleep(.1)
        raise AssertionError('Actual simulator app did not acknowledge the fresh challenge')
    root.mkdir(parents=True, exist_ok=True)
    first = exchange()
    exchange(first)
    time.sleep(.8)
    sim('io', device, 'screenshot', str(out / 'iPhone-connection-confirmed.png'))
    time.sleep(9)
    sim('io', device, 'screenshot', str(out / 'iPhone-connection-expired.png'))
    sim('launch', '--terminate-running-process', device, bundle)
    time.sleep(2)
    sim('io', device, 'screenshot', str(out / 'iPhone-connection-relaunched.png'))
    print(json.dumps(dict(result='PASS', evidence='SIMULATOR_FILE_EXCHANGE_ONLY',
                         freshNonceReplies=2, physicalUSB='NOT_RUN',
                         visualChecks='Screenshots require inspection: green, expired, relaunched')))


if __name__ == '__main__': main(sys.argv[1])
