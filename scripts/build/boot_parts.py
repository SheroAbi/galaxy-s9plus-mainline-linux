"""Strict parsing of the legacy Samsung Android boot image used by star2lte."""
import struct


def parts(blob):
    if len(blob) < 2048 or blob[:8] != b'ANDROID!':
        raise ValueError('not a Samsung Android boot image')
    page = struct.unpack_from('<I', blob, 36)[0]
    if page != 2048:
        raise ValueError(f'unsupported page size: {page}')
    offset = page
    result = {}
    for name, field in (('kernel', 8), ('ramdisk', 16), ('second', 24), ('dt', 40)):
        size = struct.unpack_from('<I', blob, field)[0]
        result[name] = blob[offset:offset + size]
        if len(result[name]) != size:
            raise ValueError(f'truncated {name}')
        offset += (size + page - 1) // page * page
    return result
