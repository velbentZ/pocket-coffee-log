#!/usr/bin/env python3
"""Create an experimental ARM64 adb copy for DJI subclass 0x43.

Only the exact inspected platform-tools build is supported. This enables
USB enumeration, NOT an ADB handshake. Use a separate server port (5038).
"""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess

SOURCE_SHA256 = '1811e253b21b12cbfda7201ebaf86c10e7ddcb5c606a7a81f7c82b4c429c2d3b'


def patch_bytes(source):
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError('Unrecognized adb build; inspect its match function before patching')
    for index in range(struct.unpack_from('>I', source, 4)[0]):
        cpu, _, offset, size, _ = struct.unpack_from('>IIIII', source, 8 + 20 * index)
        if cpu == 0x100000c:
            arm = bytearray(source[offset:offset + size])
            # is_adb_interface(int,int,int), cmp w1,#0x42 -> cmp w1,#0x43
            position = 0xcced4
            if struct.unpack_from('<I', arm, position)[0] != 0x7101083f:
                raise ValueError('Instruction mismatch')
            struct.pack_into('<I', arm, position, 0x71010c3f)
            return arm
    raise ValueError('ARM64 slice missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default='/opt/homebrew/bin/adb')
    parser.add_argument('--output', default='/tmp/adb_dji')
    args = parser.parse_args()
    source, output = Path(args.source), Path(args.output)
    if source.resolve() == output.resolve():
        parser.error('Source must not be overwritten')
    patched = patch_bytes(source.read_bytes())
    # Exclusive creation prevents overwriting a different binary or following a symlink.
    with output.open('xb') as stream:
        stream.write(patched)
    output.chmod(0o755)
    subprocess.run(['codesign', '-f', '-s', '-', str(output)], check=True)
    print(f'{output} -P 5038 devices -l')
    print('Experimental enumeration only; offline is not a working shell.')


if __name__ == '__main__':
    main()
