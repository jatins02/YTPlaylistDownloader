#!/usr/bin/env python3
"""Bounded Linux export worker. No network, credentials or ambient configuration."""
from __future__ import annotations

import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import unicodedata
import zipfile

CHUNK = 65536
UUID = re.compile(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
HASH = re.compile(r'^[a-f0-9]{64}$')


class Invalid(ValueError):
    pass


class Limit(ValueError):
    pass


def require(condition):
    if not condition:
        raise Invalid()


def digest(stream, maximum):
    value, count = hashlib.sha256(), 0
    while data := stream.read(CHUNK):
        count += len(data)
        if count > maximum:
            raise Limit()
        value.update(data)
    return count, value.hexdigest()


def open_regular(path):
    flags = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_RDONLY
    fd = os.open(path, flags)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode))
        return os.fdopen(fd, 'rb')
    except BaseException:
        os.close(fd)
        raise


def portable(text, extension, suffix=''):
    text = unicodedata.normalize('NFC', text)
    text = re.sub(r'[<>:"/\\|?*\x00-\x1f\x7f]', '_', text).strip(' .') or 'Track'
    if text.split('.')[0].upper() in {'CON', 'PRN', 'AUX', 'NUL', *(f'COM{i}' for i in range(1, 10)), *(f'LPT{i}' for i in range(1, 10))}:
        text = '_' + text
    while len((text + suffix + extension).encode('utf-8')) > 184:
        text = text[:-1]
    return text.rstrip(' .') + suffix + extension


def key(text):
    return unicodedata.normalize('NFKC', text).casefold()


def names(request):
    rows = request['tracks']
    require(isinstance(rows, list) and 1 <= len(rows) <= 100)
    used, result = {'manifest.json'}, {}
    for row in rows:
        identity, text = row['track_id'], row['name']
        require(isinstance(identity, str) and UUID.fullmatch(identity) and identity not in result)
        require(isinstance(text, str) and 1 <= len(text) <= 10000)
        number, name = 1, portable(text, '.mp3')
        while key(name) in used:
            number += 1
            name = portable(text, '.mp3', f' ({number})')
        used.add(key(name))
        result[identity] = name
    return {'names': result}


def archive_entries(request):
    rows = request['files']
    require(isinstance(rows, list) and 1 <= len(rows) <= 100)
    result, used, track_ids = [], {'manifest.json'}, set()
    for row in rows:
        require(UUID.fullmatch(row['track_id']) and row['track_id'] not in track_ids)
        track_ids.add(row['track_id'])
        name = row['filename']
        require(isinstance(name, str) and name == portable(name[:-4], '.mp3') and name.endswith('.mp3') and key(name) not in used)
        used.add(key(name))
        require(type(row['bytes']) is int and 0 < row['bytes'] <= request['max_file_bytes'] and HASH.fullmatch(row['sha256']))
        result.append(row)
    manifest = request['manifest']
    require(manifest['filename'] == 'manifest.json' and 0 < manifest['bytes'] <= 1048576 and HASH.fullmatch(manifest['sha256']))
    result.append(manifest)
    return result


def write_archive(request):
    entries = archive_entries(request)
    with open(request['archive'], 'xb') as output:
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED, allowZip64=False) as archive:
            for entry in entries:
                info = zipfile.ZipInfo(entry['filename'], (1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                value, count = hashlib.sha256(), 0
                with open_regular(entry['path']) as source, archive.open(info, 'w') as target:
                    while data := source.read(CHUNK):
                        count += len(data)
                        if count > entry['bytes'] or output.tell() + len(data) > request['max_archive_bytes']:
                            raise Limit()
                        value.update(data)
                        target.write(data)
                require(count == entry['bytes'] and value.hexdigest() == entry['sha256'])
        output.flush()
        os.fsync(output.fileno())
    return verify_archive(request)


def verify_archive(request):
    entries = archive_entries(request)
    expected = {e['filename']: e for e in entries}
    # Verify loose derivatives too, including before a repeated save.
    for entry in entries:
        with open_regular(entry['path']) as source:
            require(digest(source, entry['bytes']) == (entry['bytes'], entry['sha256']))
    with open_regular(request['archive']) as source:
        size, checksum = digest(source, request['max_archive_bytes'])
        source.seek(0)
        with zipfile.ZipFile(source) as archive:
            infos = archive.infolist()
            require(len(infos) == len(expected) and {i.filename for i in infos} == set(expected))
            for info in infos:
                entry = expected[info.filename]
                require(info.compress_type == zipfile.ZIP_STORED and not info.flag_bits & 1 and
                        stat.S_ISREG(info.external_attr >> 16) and info.file_size == entry['bytes'] and
                        info.compress_size == info.file_size and not info.extra and not info.comment)
                with archive.open(info) as payload:
                    require(digest(payload, entry['bytes']) == (entry['bytes'], entry['sha256']))
            require(not archive.comment)
    return {'bytes': size, 'sha256': checksum}


def sync_publication(request):
    directory = Path(request['directory'])
    root = os.path.realpath(request['private_root'])
    require(directory.is_absolute() and os.path.realpath(directory) == str(directory) and
            os.path.commonpath([str(directory), root]) == root)
    entries = list(directory.iterdir())
    require(1 <= len(entries) <= 102)
    for entry in entries:
        require(re.fullmatch(r'[a-f0-9-]{36}\.(mp3|zip|json)', entry.name))
        with open_regular(entry) as payload:
            os.fsync(payload.fileno())
    for parent in (directory, directory.parent):
        fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    return {}


def destination(request):
    identity = request['delivery_id']
    require(isinstance(identity, str) and UUID.fullmatch(identity))
    target = Path(request['destination'])
    require(target.is_absolute() and target.name not in ('', '.', '..') and target.suffix.lower() in ('.mp3', '.zip'))
    parent = str(target.parent)
    root = os.path.realpath(request['private_root'])
    require(os.path.realpath(parent) == parent and os.path.commonpath([parent, root]) != root)
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    return directory, target.name, '.ytpd-' + identity + '.part'


def prepare_destination(request):
    directory, name, temporary = destination(request)
    try:
        space = os.fstatvfs(directory)
        if space.f_bavail * space.f_frsize < request.get('bytes', 0) + request.get('free_reserve_bytes', 0):
            raise OSError(errno.ENOSPC, 'Insufficient destination space')
        try:
            os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise FileExistsError()
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        try:
            os.setxattr(fd, 'user.ytpd.delivery', request['delivery_id'].encode('ascii'))
            info = os.fstat(fd)
            os.fsync(fd)
            return {'device': info.st_dev, 'inode': info.st_ino,
                    'temporary': str(Path(request['destination']).parent / temporary)}
        except BaseException:
            os.unlink(temporary, dir_fd=directory)
            raise
        finally:
            os.close(fd)
    finally:
        os.close(directory)


def owns(info, request, descriptor):
    identity_matches = (request['device'] == 0 and request['inode'] == 0) or (info.st_dev == request['device'] and info.st_ino == request['inode'])
    if not (stat.S_ISREG(info.st_mode) and identity_matches):
        return False
    try:
        return os.getxattr(descriptor, 'user.ytpd.delivery') == request['delivery_id'].encode('ascii')
    except OSError:
        return False


def remove_temporary(directory, temporary, request):
    try:
        fd = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            if owns(os.fstat(fd), request, fd):
                os.unlink(temporary, dir_fd=directory)
                os.fsync(directory)
        finally:
            os.close(fd)
    except OSError as error:
        if error.errno not in (errno.ENOENT, errno.ELOOP):
            raise


def cleanup_destination(request):
    directory, _, temporary = destination(request)
    try:
        remove_temporary(directory, temporary, request)
    finally:
        os.close(directory)
    return {}


def transfer(request):
    require(type(request['device']) is int and request['device'] >= 0 and type(request['inode']) is int and request['inode'] > 0)
    directory, name, temporary = destination(request)
    try:
        fd = os.open(temporary, os.O_RDWR | os.O_NOFOLLOW, dir_fd=directory)
        with os.fdopen(fd, 'r+b') as output:
            require(owns(os.fstat(output.fileno()), request, output.fileno()) and os.fstat(output.fileno()).st_size == 0)
            require(type(request['bytes']) is int and 0 < request['bytes'] <= request['max_bytes'] and HASH.fullmatch(request['sha256']))
            count, value = 0, hashlib.sha256()
            with open_regular(request['source']) as source:
                while data := source.read(CHUNK):
                    count += len(data)
                    if count > request['bytes']:
                        raise Limit()
                    output.write(data)
                    value.update(data)
            require(count == request['bytes'] and value.hexdigest() == request['sha256'])
            output.flush()
            os.fsync(output.fileno())
            output.seek(0)
            require(digest(output, request['bytes']) == (request['bytes'], request['sha256']))
            # Link the verified open inode, never a replaceable pathname. This
            # publishes atomically and fails if ANY destination already exists.
            libc = ctypes.CDLL(None, use_errno=True)
            linkat = libc.linkat
            linkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
            linkat.restype = ctypes.c_int
            if linkat(-100, f'/proc/self/fd/{output.fileno()}'.encode(), directory, os.fsencode(name), 0x400) != 0:
                code = ctypes.get_errno()
                raise OSError(code, os.strerror(code))
            os.fsync(directory)
        return {'bytes': count, 'sha256': value.hexdigest()}
    finally:
        try:
            remove_temporary(directory, temporary, request)
        finally:
            os.close(directory)


def stop(*_):
    raise InterruptedError()


def main():
    signal.signal(signal.SIGTERM, stop)
    try:
        command = sys.argv[1]
        if command == 'versions':
            result = {'version': 1, 'platform': sys.platform}
        else:
            with open_regular(sys.argv[2]) as source:
                raw = source.read(262145)
            if len(raw) > 262144:
                raise Limit()
            request = json.loads(raw)
            for field in ('max_file_bytes', 'max_archive_bytes', 'max_bytes'):
                if field in request:
                    require(type(request[field]) is int and 0 < request[field] <= 1073741824)
            result = {'names': names, 'archive': write_archive, 'verify': verify_archive, 'sync-publication': sync_publication,
                      'prepare-destination': prepare_destination, 'transfer': transfer,
                      'cleanup-destination': cleanup_destination}[command](request)
        print(json.dumps({'ok': True, **result}, ensure_ascii=False))
    except BaseException as error:
        code = ('limit' if isinstance(error, Limit) else 'exists' if isinstance(error, FileExistsError)
                else 'cancelled' if isinstance(error, InterruptedError) else 'permission' if isinstance(error, PermissionError)
                else 'space' if isinstance(error, OSError) and error.errno in (errno.ENOSPC, errno.EDQUOT)
                else 'invalid')
        print(json.dumps({'ok': False, 'error': code}))


if __name__ == '__main__':
    main()
