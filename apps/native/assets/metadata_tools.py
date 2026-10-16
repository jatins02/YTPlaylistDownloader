"""Bounded Linux Stage 4 image/ID3 worker. No network, dotenv, or credentials."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import stat
import sys
import warnings

MAX_IMAGE = 5 * 1024 * 1024
MAX_COVER = 1024 * 1024
MAX_AUDIO = 50 * 1024 * 1024


def regular(path, limit):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= limit:
        raise ValueError('invalid input')
    return path


def normalize(source, destination):
    from PIL import Image, ImageOps
    source = regular(source, MAX_IMAGE)
    Image.MAX_IMAGE_PIXELS = 8_000_000
    with warnings.catch_warnings():
        warnings.simplefilter('error', Image.DecompressionBombWarning)
        with Image.open(source) as image:
            if image.format not in {'JPEG', 'PNG', 'WEBP'} or getattr(image, 'n_frames', 1) != 1:
                raise ValueError('invalid image')
            if image.width > 8192 or image.height > 8192 or image.width * image.height > 8_000_000:
                raise ValueError('pixel limit')
            image.verify()
        with Image.open(source) as image:
            image.load()
            image = ImageOps.exif_transpose(image).convert('RGB')
            image.thumbnail((768, 768))
            buffer = io.BytesIO()
            image.save(buffer, 'JPEG', quality=88, optimize=True)
            data = buffer.getvalue()
            if not 0 < len(data) <= MAX_COVER:
                raise ValueError('cover size')
            with Path(destination).open('xb') as output:
                output.write(data)
            return {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
                    'width': image.width, 'height': image.height, 'mime': 'image/jpeg'}


def verify_image(source):
    from PIL import Image
    source = regular(source, MAX_COVER)
    with Image.open(source) as image:
        if image.format != 'JPEG' or not 0 < image.width <= 768 or not 0 < image.height <= 768:
            raise ValueError('invalid cached cover')
        image.verify()
    with Image.open(source) as image:
        image.load()
    return {'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}


def audio_digest(path):
    """ID3v2/v1 are excluded; tagging must preserve every encoded audio byte."""
    data = regular(path, MAX_AUDIO).read_bytes()
    start = 0
    if data[:3] == b'ID3':
        if any(value >= 128 for value in data[6:10]):
            raise ValueError('invalid ID3 size')
        start = 10 + sum(value << shift for value, shift in zip(data[6:10], (21, 14, 7, 0)))
        if data[5] & 0x10:
            start += 10
    end = len(data) - 128 if data[-128:-125] == b'TAG' else len(data)
    if start >= end:
        raise ValueError('missing audio')
    return hashlib.sha256(data[start:end]).hexdigest()


def tag(source, destination, request_path):
    from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1, TXXX, WOAS
    from mutagen.mp3 import MP3
    source = regular(source, MAX_AUDIO)
    request = json.loads(regular(request_path, 65536).read_text(encoding='utf-8'))
    metadata = request['metadata']
    # The native domain owns semantic version formatting for UI, filenames and
    # tags. Read back this exact frozen value rather than recomputing it here.
    title = request['song_title']
    artists = metadata['artists'] or ['Unknown Artist']
    for value in [title, *artists, *metadata['featured_artists'], metadata['album'] or '']:
        if not isinstance(value, str) or len(value) > 1000 or any(ord(c) < 32 for c in value):
            raise ValueError('invalid metadata')
    cover = regular(request['cover_path'], MAX_COVER).read_bytes() if request['cover_path'] else None
    if cover is not None:
        from PIL import Image
        with Image.open(io.BytesIO(cover)) as image:
            if image.format != 'JPEG' or not 0 < image.width <= 768 or not 0 < image.height <= 768:
                raise ValueError('cover must be normalized')
            image.verify()
        with Image.open(io.BytesIO(cover)) as image:
            image.load()
        if hashlib.sha256(cover).hexdigest() != request['cover_sha256']:
            raise ValueError('cover mismatch')
    before = audio_digest(source)
    # Exclusive creation; always tag a new derivative, never source/preview bytes.
    with Path(destination).open('xb') as output, source.open('rb') as input_file:
        shutil.copyfileobj(input_file, output)
    tags = ID3()
    tags.add(TIT2(encoding=3, text=title))
    tags.add(TPE1(encoding=3, text=', '.join(artists)))
    if metadata['album']:
        tags.add(TALB(encoding=3, text=metadata['album']))
    if metadata['featured_artists']:
        tags.add(TXXX(encoding=3, desc='FEATURED_ARTISTS', text=', '.join(metadata['featured_artists'])))
    tags.add(TXXX(encoding=3, desc='SOURCE_VIDEO_ID', text=request['video_id']))
    tags.add(WOAS(url='https://www.youtube.com/watch?v=' + request['video_id']))
    if cover:
        tags.add(APIC(encoding=3, mime='image/jpeg', type=3, desc='Front cover', data=cover))
    tags.save(destination, v2_version=3)
    actual = ID3(destination)
    if actual.version[:2] != (2, 3) or str(actual['TIT2']) != title or str(actual['TPE1']) != ', '.join(artists):
        raise ValueError('tag mismatch')
    if (str(actual['TALB']) if 'TALB' in actual else None) != metadata['album']:
        raise ValueError('album mismatch')
    features = actual.get('TXXX:FEATURED_ARTISTS')
    if (str(features) if features else None) != (', '.join(metadata['featured_artists']) or None):
        raise ValueError('features mismatch')
    if str(actual['TXXX:SOURCE_VIDEO_ID']) != request['video_id'] or actual['WOAS'].url != 'https://www.youtube.com/watch?v=' + request['video_id']:
        raise ValueError('source mismatch')
    images = actual.getall('APIC')
    if (cover is None and images) or (cover is not None and (len(images) != 1 or images[0].type != 3 or images[0].mime != 'image/jpeg' or images[0].data != cover)):
        raise ValueError('embedded cover mismatch')
    if before != audio_digest(destination) or MP3(destination).info.length <= 0:
        raise ValueError('audio changed')
    result = {'snapshot_hash': request['snapshot_hash'], 'track_id': request['track_id'],
              'song_title': str(actual['TIT2']),
              'track_revision': request['track_revision'], 'audio_sha256': before,
              'cover_sha256': hashlib.sha256(images[0].data).hexdigest() if images else None,
              'sha256': hashlib.sha256(Path(destination).read_bytes()).hexdigest(),
              'bytes': Path(destination).stat().st_size, 'id3_version': 3}
    return result


def main():
    if sys.argv[1] == 'versions':
        import importlib.metadata
        result = {name: importlib.metadata.version(name) for name in ['mutagen', 'pillow']}
    elif sys.argv[1] == 'verify-image' and len(sys.argv) == 3:
        result = verify_image(sys.argv[2])
    elif sys.argv[1] == 'image' and len(sys.argv) == 4:
        result = normalize(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == 'tag' and len(sys.argv) == 5:
        result = tag(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        raise ValueError('unsupported operation')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Filenames, metadata and raw codec/image errors never become logs.
        print('Metadata worker verification failed.', file=sys.stderr)
        sys.exit(1)
