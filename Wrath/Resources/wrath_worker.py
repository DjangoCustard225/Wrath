"""Upstream yt-dlp and gallery-dl extraction; native FFmpeg handles media processing."""
import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error
import hashlib
import math
import ssl
import re
import html
import io
import copy
from pathlib import Path

import certifi
import yt_dlp

GALLERY_EXTENSIONS = frozenset(('jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'heic'))
GALLERY_CACHE = {}
GALLERY_LIMIT = 200


class GalleryLimitError(ValueError):
    pass


def gallery_extractor(url):
    """Only bounded post/album extractors; never crawl profiles or feeds."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ('http', 'https') or parsed.username or parsed.password:
        return None
    domains = ('reddit.com', 'redd.it', 'imgur.com', 'instagram.com', 'twitter.com', 'x.com',
               'pixiv.net', 'flickr.com', 'deviantart.com', 'tumblr.com', 'bsky.app', 'pinterest.com', 'tiktok.com')
    host = (parsed.hostname or '').lower()
    if Path(parsed.path).suffix[1:].lower() not in GALLERY_EXTENSIONS and not any(host == d or host.endswith('.' + d) for d in domains):
        return None
    from gallery_dl import config, extractor
    # Extractor token caches must not create plaintext credentials outside the
    # app's Keychain-backed cookie settings, including in gallery-dl's defaults.
    config.set(('cache',), 'file', ':memory:')
    instance = extractor.find(url)
    if not instance or instance.subcategory == 'reel':
        return None
    allowed = ('PostExtractor', 'ImageExtractor', 'GalleryExtractor', 'AlbumExtractor',
               'SubmissionExtractor', 'TweetExtractor', 'StatusExtractor', 'WorkExtractor',
               'DeviationExtractor', 'PinExtractor', 'PhotoExtractor')
    if instance.__class__.__name__.endswith(allowed) or instance.__class__.__name__ == 'DirectlinkExtractor':
        return instance
    return None


def close_gallery(catalog):
    for session in catalog['sessions']:
        session.close()


def clear_gallery_cache():
    for _, catalog in GALLERY_CACHE.values():
        close_gallery(catalog)
    GALLERY_CACHE.clear()


def gallery_catalog(data, context=None, consume=False):
    import logging
    import time
    key = (data['url'], hashlib.sha256(json.dumps(data.get('socialAccess', {}), sort_keys=True).encode()).hexdigest())
    for old_key, (stamp, catalog) in list(GALLERY_CACHE.items()):
        if time.monotonic() - stamp > 180:
            GALLERY_CACHE.pop(old_key)
            close_gallery(catalog)
    if key in GALLERY_CACHE:
        return GALLERY_CACHE.pop(key)[1] if consume else GALLERY_CACHE[key][1]
    root = gallery_extractor(data['url'])
    if root is None:
        return None
    from gallery_dl.extractor.message import Message
    catalog = dict(files=[], sessions=[], title='', author='', skippedVideos=0, warnings=[])
    visited, media_seen = set(), set()
    cookies = social_cookie_jar(data['url'], data.get('socialAccess', {}))

    class LogHandler(logging.Handler):
        def emit(self, record):
            message = safe_message(record.getMessage())
            if record.levelno >= logging.WARNING and message not in catalog['warnings'] and len(catalog['warnings']) < 4:
                catalog['warnings'].append(message)

    def visit(instance, depth):
        checkpoint(context)
        if instance.url in visited:
            return
        if depth > 2 or len(visited) >= 8:
            raise GalleryLimitError('This gallery links to too many collections. Use a direct post or album link.')
        visited.add(instance.url)
        logger = logging.Logger('wrath.gallery', logging.WARNING)
        logger.addHandler(LogHandler())
        logger.propagate = False
        instance.log = logger
        original_config = instance.config
        overrides = {'retries': 1, 'timeout': 15, 'sleep-request': 0, 'sleep-429': 1,
                     'recursion': 0, 'comments': 0, 'selftext': False, 'cookies-update': False}
        agent = social_user_agent(instance.url, data.get('socialAccess', {}))
        if agent:
            overrides['user-agent'] = agent
        instance.config = lambda name, default=None: overrides.get(name, original_config(name, default))
        original_request = instance.request
        def request(*args, **kwargs):
            checkpoint(context)
            response = original_request(*args, **kwargs)
            checkpoint(context)
            return response
        instance.request = request
        try:
            # Initialize the upstream session before site-specific API calls so
            # saved Reddit cookies are available without a plaintext cookie file.
            instance._init_options()
            instance._init_session()
            catalog['sessions'].append(instance.session)
            instance.cookies = instance.session.cookies
            if instance.cookies_domain is not None:
                instance._init_cookies()
            for cookie in cookies:
                instance.session.cookies.set_cookie(copy.copy(cookie))
            for index, message in enumerate(instance):
                checkpoint(context)
                if index > 1000:
                    raise GalleryLimitError('This link contains too much media. Use an individual post or album.')
                if message[0] == Message.Queue:
                    nested = gallery_extractor(message[1])
                    if nested:
                        visit(nested, depth + 1)
                    else:
                        catalog['skippedVideos'] += 1
                    continue
                if message[0] not in (Message.Directory, Message.Url):
                    continue
                metadata = message[2]
                if not catalog['title']:
                    title = metadata.get('title') or metadata.get('description') or metadata.get('caption') or ''
                    if not title and instance.__class__.__name__ == 'DirectlinkExtractor':
                        title = metadata.get('filename') or ''
                    catalog['title'] = str(title).strip()[:300] if isinstance(title, str) else ''
                    user = metadata.get('author') or metadata.get('user') or metadata.get('uploader') or metadata.get('username') or ''
                    if isinstance(user, dict):
                        user = user.get('name') or user.get('username') or ''
                    catalog['author'] = str(user)[:120] if isinstance(user, str) else ''
                if message[0] != Message.Url:
                    continue
                url = message[1]
                if url in media_seen:
                    continue
                media_seen.add(url)
                extension = str(metadata.get('extension') or Path(urllib.parse.urlsplit(url).path).suffix[1:]).lower()
                if extension not in GALLERY_EXTENSIONS or urllib.parse.urlsplit(url).scheme not in ('http', 'https'):
                    catalog['skippedVideos'] += 1
                    continue
                if len(catalog['files']) >= GALLERY_LIMIT:
                    raise GalleryLimitError('This gallery exceeds 200 images. Use a smaller post or album.')
                headers = metadata.get('_http_headers') or {}
                headers = {k: v for k, v in headers.items() if k.lower() in ('referer', 'user-agent', 'accept')}
                catalog['files'].append(dict(url=url, extension=extension, session=instance.session, headers=headers))
        finally:
            # Native contexts belong to one bridge call and must never survive
            # in the short-lived inspection cache for a later download thread.
            instance.request = original_request

    try:
        visit(root, 0)
        if not catalog['files']:
            close_gallery(catalog)
            return None
        if not catalog['title']:
            catalog['title'] = (catalog['author'] + ' photos').strip() if catalog['author'] else 'Photo gallery'
        if not consume:
            while len(GALLERY_CACHE) >= 4:
                close_gallery(GALLERY_CACHE.pop(next(iter(GALLERY_CACHE)))[1])
            GALLERY_CACHE[key] = (time.monotonic(), catalog)
        return catalog
    except BaseException:
        close_gallery(catalog)
        raise


def gallery_availability(catalog):
    return dict(choices=[], thumbnailAvailable=False, title=catalog['title'], author=catalog['author'],
                thumbnail=catalog['files'][0]['url'], gallery=dict(count=len(catalog['files']),
                skippedVideos=catalog['skippedVideos']))


def download_gallery(data, context):
    import time
    catalog = gallery_catalog(data, context, consume=True)
    if catalog is None:
        raise ValueError('No supported images were found. Check the post link again.')
    plan = dict(title=catalog['title'], author=catalog['author'], source=data['url'],
                thumbnail=catalog['files'][0]['url'], tracks=[], fileExtension='gallery',
                quality='Original images', galleryFiles=[], warnings=[])
    if catalog['skippedVideos']:
        plan['warnings'].append('Saved images only; video or unsupported linked attachments were not included.')
    directory = Path(data['directory']) / 'gallery'
    completed_bytes = 0
    start = time.monotonic()
    try:
        directory.mkdir(parents=True, exist_ok=False)
        report(context, {'type': 'resolved', 'plan': plan})
        for index, media in enumerate(catalog['files']):
            checkpoint(context)
            filename = f'{index + 1:03d}.{media["extension"]}'
            target = directory / filename
            received, last_report = 0, 0
            with media['session'].get(media['url'], headers=media['headers'], stream=True, timeout=(15, 20)) as response:
                response.raise_for_status()
                content_type = response.headers.get('Content-Type', '').split(';')[0].strip().lower()
                if content_type and not (content_type.startswith('image/') or content_type == 'application/octet-stream'):
                    raise ValueError('The website returned a page instead of an image. Check access to this post.')
                total = int(response.headers.get('Content-Length') or 0)
                with target.open('xb') as output:
                    for chunk in response.iter_content(64 * 1024):
                        checkpoint(context)
                        output.write(chunk)
                        received += len(chunk)
                        now = time.monotonic()
                        if now - last_report >= 0.25:
                            fraction = (index + min(0.99, received / total if total > 0 else 0)) / len(catalog['files'])
                            report(context, dict(type='galleryProgress', bytes=completed_bytes + received,
                                                 fraction=fraction, imageIndex=index + 1, imageCount=len(catalog['files']),
                                                 speed=(completed_bytes + received) / max(0.1, now - start)))
                            last_report = now
            checkpoint(context)
            if received == 0 or (total > 0 and received != total and not response.headers.get('Content-Encoding')):
                raise ValueError('An image download was incomplete. Add the link again to retry.')
            with target.open('rb') as image:
                signature = image.read(64)
            valid = (signature.startswith((b'\xff\xd8\xff', b'\x89PNG\r\n\x1a\n', b'GIF87a', b'GIF89a'))
                     or (signature.startswith(b'RIFF') and signature[8:12] == b'WEBP')
                     or (signature[4:8] == b'ftyp' and any(brand in signature[8:] for brand in
                         (b'avif', b'avis', b'heic', b'heix', b'hevc', b'hevx', b'mif1', b'msf1'))))
            if not valid:
                raise ValueError('The website did not return a supported image. Add the link again to retry.')
            if signature.startswith(b'\xff\xd8\xff'):
                actual = 'jpg'
            elif signature.startswith(b'\x89PNG'):
                actual = 'png'
            elif signature.startswith(b'GIF'):
                actual = 'gif'
            elif signature.startswith(b'RIFF'):
                actual = 'webp'
            else:
                actual = 'avif' if b'avif' in signature[8:] or b'avis' in signature[8:] else 'heic'
            if actual != media['extension']:
                filename = f'{index + 1:03d}.{actual}'
                target.rename(directory / filename)
            completed_bytes += received
            plan['galleryFiles'].append(dict(filename=filename, bytes=received))
            report(context, dict(type='galleryProgress', bytes=completed_bytes, fraction=(index + 1) / len(catalog['files']),
                                 imageIndex=index + 1, imageCount=len(catalog['files'])))
        return plan
    finally:
        close_gallery(catalog)

try:
    import wrath_native
except ImportError:  # Allows host-side integration tests.
    wrath_native = None

class DownloadCancelled(BaseException):
    """Leave upstream retry loops immediately without changing downloader code."""


def check_cancelled(context=None):
    if wrath_native and wrath_native.cancelled(context):
        raise DownloadCancelled()


def checkpoint(context):
    if wrath_native and wrath_native.checkpoint(context):
        raise DownloadCancelled()


def safe_message(message):
    # Upstream warnings may contain signed URLs; never forward those to the UI.
    return re.sub(r'https?://[^\s<>]+', '[link]', str(message)).removeprefix('ERROR: ').replace('\r', '').strip()[:1200]


def report(context, event):
    if wrath_native:
        wrath_native.report(context, json.dumps(event, allow_nan=False))


class QuietLogger:
    def __init__(self, context=None):
        self.context = context
        self.warnings = []
        self.errors = []

    def debug(self, message):
        check_cancelled(self.context)

    def warning(self, message):
        check_cancelled(self.context)
        if re.match(r'^\[youtube\]\s+No supported JavaScript runtime could be found\.', str(message), re.I):
            return
        message = safe_message(message)
        if message not in self.warnings and len(self.warnings) < 4:
            self.warnings.append(message)

    def error(self, message):
        check_cancelled(self.context)
        message = safe_message(message)
        if message and message not in self.errors and len(self.errors) < 4:
            self.errors.append(message)


def require_info(info, logger):
    if isinstance(info, dict):
        return info
    if logger.errors:
        raise ValueError(logger.errors[-1])
    raise ValueError('yt-dlp did not return media information for this link.')


class InspectionYoutubeDL(yt_dlp.YoutubeDL):
    # Presentation only: the app renders the same structured -F catalog.
    def list_formats(self, info_dict):
        check_cancelled()

    def list_subtitles(self, video_id, subtitles, name='subtitles'):
        check_cancelled()


def selector(kind, height, video_codec='automatic', audio_codec='automatic', exact_height=False):
    cap = (f'[height={height}]' if exact_height else f'[height<=?{height}]') if height else ''
    video_patterns = {'h264': '^(avc1|h264)', 'hevc': '^(hev1|hvc1|hevc|h265)', 'av1': '^(av01|av1)', 'vp9': '^(vp09|vp9)'}
    audio_patterns = {'aac': '^(mp4a|aac)', 'opus': '^opus'}
    vf = f'[vcodec~="{video_patterns[video_codec]}"]' if video_codec in video_patterns else ''
    af = f'[acodec~="{audio_patterns[audio_codec]}"]' if audio_codec in audio_patterns else ''
    if kind == 'audio':
        return f'ba{af}/b{af}'
    # The standard best-video expression, constrained only by user selections.
    video_audio_filter = f'[acodec~="^(none|{audio_patterns[audio_codec][1:]})"]' if af else ''
    return f'bv*{cap}{vf}{video_audio_filter}+ba{af}/b{cap}{vf}{af}'


SPONSOR_CATEGORIES = ('sponsor', 'selfpromo', 'interaction', 'intro', 'outro', 'preview', 'music_offtopic', 'filler')


def parse_sponsor_segments(records, video_id, categories, duration):
    result = []
    seen = set()
    for record in records:
        if not isinstance(record, dict) or record.get('videoID') != video_id or not isinstance(record.get('segments'), list):
            continue
        for segment in record.get('segments', []):
            if not isinstance(segment, dict):
                continue
            category = segment.get('category')
            if category not in categories or segment.get('actionType', 'skip') != 'skip':
                continue
            try:
                start, end = (float(x) for x in segment['segment'])
                reported_duration = float(segment.get('videoDuration') or 0)
            except (TypeError, ValueError, KeyError):
                continue
            if not math.isfinite(start) or not math.isfinite(end) or not math.isfinite(reported_duration) or not 0 <= start < end:
                continue
            if duration:
                if reported_duration and abs(reported_duration - duration) > max(2, duration * .01):
                    continue
                end = min(end, duration)
            key = (start, end, category)
            if start < end and key not in seen:
                result.append(dict(start=start, end=end, category=category)); seen.add(key)
    return sorted(result, key=lambda x: (x['start'], x['end']))[:500]


def sponsor_segments(info, options):
    if options.get('sponsorMode', 'off') == 'off' or info.get('extractor_key') != 'Youtube':
        return []
    categories = sorted(set(options.get('sponsorCategories', ['sponsor'])).intersection(SPONSOR_CATEGORIES))
    if not categories:
        raise ValueError('Choose at least one SponsorBlock category, or turn SponsorBlock off.')
    video_id = info['id']
    prefix = hashlib.sha256(video_id.encode()).hexdigest()[:4]
    query = urllib.parse.urlencode({'categories': json.dumps(categories), 'actionTypes': '["skip"]'})
    request = urllib.request.Request(f'https://sponsor.ajay.app/api/skipSegments/{prefix}?{query}', headers={'User-Agent': 'Wrath/1.2.0'})
    check_cancelled()
    try:
        with urllib.request.urlopen(request, timeout=12, context=ssl.create_default_context(cafile=certifi.where())) as response:
            data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError('SponsorBlock response was too large.')
        records = json.loads(data)
        if not isinstance(records, list):
            raise ValueError('Invalid SponsorBlock response.')
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return []
        raise ValueError('SponsorBlock is unavailable. Retry or turn SponsorBlock off.') from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ValueError('SponsorBlock is unavailable. Retry or turn SponsorBlock off.') from error
    check_cancelled()
    return parse_sponsor_segments(records, video_id, categories, info.get('duration'))


def thumbnail_url(info):
    candidates = [info.get('thumbnail')]
    candidates.extend(item.get('url') for item in reversed(info.get('thumbnails') or []) if isinstance(item, dict))
    for url in candidates:
        if not isinstance(url, str) or any(character.isspace() for character in url):
            continue
        try:
            parsed = urllib.parse.urlparse(url)
            if parsed.scheme in ('https', 'http') and parsed.hostname:
                return url
        except ValueError:
            continue
    return None


def subtitle_catalog(info):
    """Offer only actual caption tracks we can read without a subtitle decoder."""
    result = []
    extensions = ('vtt', 'srt', 'ttml', 'dfxp')
    for field, automatic in (('subtitles', False), ('automatic_captions', True)):
        for language, formats in (info.get(field) or {}).items():
            if language == 'live_chat' or not isinstance(formats, list):
                continue
            if automatic and language.endswith('-orig') and language[:-5] in info[field]:
                continue
            candidates = [f for f in formats if isinstance(f, dict) and f.get('ext') in extensions
                          and (isinstance(f.get('data'), str) or
                               (thumbnail_url({'thumbnail': f.get('url')}) and
                                f.get('protocol', 'https') in ('http', 'https')))]
            if automatic and info.get('extractor_key') == 'Youtube':
                candidates = [f for f in candidates if not urllib.parse.parse_qs(urllib.parse.urlparse(f.get('url', '')).query).get('tlang')]
            if not candidates:
                continue
            fmt = min(candidates, key=lambda f: extensions.index(f['ext']))
            result.append((dict(id=f'{"auto" if automatic else "manual"}:{language}',
                                language=str(language)[:100], name=str(fmt.get('name') or language)[:200],
                                automatic=automatic), fmt))
    return sorted(result, key=lambda item: (item[0]['automatic'],
                                           not item[0]['language'].startswith('en'), item[0]['name'].casefold()))


def parse_subtitle_cues(content, extension):
    """Plain selectable text, with overlapping WebVTT cues made nonoverlapping."""
    if extension in ('ttml', 'dfxp'):
        from yt_dlp.utils import dfxp2srt
        content = dfxp2srt(content.encode('utf-8'))
    timestamp = r'(?:\d+:)?\d{2}:\d{2}[.,]\d{3}'
    timing = re.compile(rf'^\s*({timestamp})\s*-->\s*({timestamp})(?:\s.*)?$')

    def seconds(value):
        parts = value.replace(',', '.').split(':')
        return sum(float(p) * factor for p, factor in zip(reversed(parts), (1, 60, 3600)))

    cues = []
    for block in re.split(r'\n[ \t]*\n', content.replace('\r\n', '\n').replace('\r', '\n')):
        lines = block.strip().split('\n')
        if not lines or lines[0].startswith(('NOTE', 'STYLE', 'REGION')):
            continue
        for index, line in enumerate(lines[:3]):
            match = timing.match(line)
            if not match:
                continue
            start, end = map(seconds, match.groups())
            text = html.unescape(re.sub(r'<[^>]*>', '', '\n'.join(lines[index + 1:]))).replace('\x00', '').strip()
            # Remove SRT positioning/style override codes; retain Unicode and line breaks.
            text = re.sub(r'\{\\[^}]*\}', '', text)
            if 0 <= start < end <= 1e9 and text:
                if len(text.encode('utf-8')) > 20000 or len(cues) >= 20000:
                    raise ValueError('Subtitle track is too large.')
                cues.append(dict(start=start, end=end, text=text))
            break
    if not cues:
        raise ValueError('No usable subtitle cues.')
    # MOV timed text cannot overlap. A sweep preserves simultaneous lines,
    # including rolling automatic captions, without overlapping packet times.
    events = {}
    for index, cue in enumerate(cues):
        events.setdefault(cue['start'], []).append((index, True))
        events.setdefault(cue['end'], []).append((index, False))
    active, result, previous, total_bytes = set(), [], None, 0
    for position in sorted(events):
        check_cancelled()
        if previous is not None and active and position > previous:
            text = '\n'.join(dict.fromkeys(cues[i]['text'] for i in sorted(active)))
            size = len(text.encode('utf-8'))
            total_bytes += size
            if size > 60000 or total_bytes > 8 * 1024 * 1024:
                raise ValueError('Subtitle track is too large.')
            if result and result[-1]['end'] == previous and result[-1]['text'] == text:
                result[-1]['end'] = position
            else:
                result.append(dict(start=previous, end=position, text=text))
        for index, adding in events[position]:
            if adding:
                active.add(index)
            else:
                active.discard(index)
        if len(active) > 32:
            raise ValueError('Too many overlapping subtitle cues.')
        previous = position
    return result


def download_subtitle(info, options, ydl):
    catalog = subtitle_catalog(info)
    selected = options.get('subtitleTrack', 'automatic')
    choice = next((item for item in catalog if item[0]['id'] == selected), None) if selected != 'automatic' else next(iter(catalog), None)
    if choice is None:
        raise ValueError('Selected subtitle track is unavailable.')
    metadata, fmt = choice
    content = fmt.get('data')
    if content is None:
        from yt_dlp.networking import Request
        headers = dict(info.get('http_headers') or {})
        headers.update(fmt.get('http_headers') or {})
        check_cancelled()
        with ydl.urlopen(Request(fmt['url'], headers=headers)) as response:
            data = response.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024:
            raise ValueError('Subtitle track is too large.')
        content = data.decode('utf-8-sig')
    if len(content.encode('utf-8')) > 4 * 1024 * 1024:
        raise ValueError('Subtitle track is too large.')
    check_cancelled()
    from yt_dlp.utils import ISO639Utils
    language = metadata['language'].split('-')[0]
    language = (ISO639Utils.short2long(language) if len(language) == 2 else language if len(language) == 3 else None) or 'und'
    return dict(language=language, name=metadata['name'],
                cues=parse_subtitle_cues(content, fmt['ext']))


def make_plan(info, kind, ydl=None):
    if not isinstance(info, dict):
        raise ValueError('yt-dlp did not return media information for this link.')
    if info.get('_type') in ('playlist', 'multi_video') or info.get('entries') is not None:
        raise ValueError('Paste a link to one video. Playlist downloads are not supported yet.')
    if info.get('is_live'):
        raise ValueError('Live streams are not supported. Try again after the stream has ended.')
    formats = [fmt for fmt in (info.get('requested_formats') or [info]) if isinstance(fmt, dict)]
    tracks = []
    for fmt in formats:
        url = fmt.get('url', '')
        if urllib.parse.urlparse(url).scheme not in ('https', 'http'):
            raise ValueError('This source did not provide a downloadable HTTP stream.')
        protocol = fmt.get('protocol') or 'https'
        if protocol not in ('https', 'http', 'm3u8', 'm3u8_native', 'http_dash_segments', 'file'):
            raise ValueError('This stream format is not supported yet.')
        headers = {str(k): str(v) for k, v in (fmt.get('http_headers') or info.get('http_headers') or {}).items()
                   if '\r' not in str(k) + str(v) and '\n' not in str(k) + str(v)}
        tracks.append(dict(url=url, headers=headers,
                           role='audio' if fmt.get('vcodec') == 'none' else 'video',
                           streaming=protocol.startswith('m3u8'),
                           bytes=fmt.get('filesize'),
                           chunkSize=(fmt.get('downloader_options') or {}).get('http_chunk_size')))
    if not tracks or len(tracks) > 2:
        raise ValueError('No compatible media tracks were found.')
    audio_codec = next((f.get('acodec', '') for f in formats if f.get('acodec') not in (None, 'none')), '')
    video_codec = next((f.get('vcodec', '') for f in formats if f.get('vcodec') not in (None, 'none')), '')
    if kind == 'audio':
        ext = 'm4a' if audio_codec.startswith(('mp4a', 'aac', 'alac')) else ('opus' if 'opus' in audio_codec else ('mp3' if 'mp3' in audio_codec else 'ogg'))
    else:
        compatible_video = video_codec.startswith(('avc', 'h264', 'hev', 'hvc', 'hevc', 'av01')) or (not video_codec and info.get('ext') == 'mp4')
        ext = 'mp4' if compatible_video and (not audio_codec or audio_codec.startswith(('mp4a', 'aac', 'alac'))) else 'mkv'
    height = max((f.get('height') or 0 for f in formats), default=0)
    return dict(title=info.get('title') or info.get('id') or 'Download',
                author=info.get('uploader') or info.get('channel') or '',
                source=info.get('extractor_key') or 'Web', duration=info.get('duration'),
                thumbnail=thumbnail_url(info), tracks=tracks, fileExtension=ext,
                quality=(f'{height}p' if height else 'Video') if kind == 'video' else 'Original audio')


def estimated_track_bytes(fmt, duration, audio_only=False):
    def positive(value):
        return isinstance(value, (int, float)) and math.isfinite(value) and 0 < value < 2**63

    # Audio extracted from a combined stream must not include the video bytes.
    extracting_audio = audio_only and fmt.get('vcodec') != 'none'
    if not extracting_audio:
        for field in ('filesize', 'filesize_approx'):
            if positive(fmt.get(field)):
                return int(fmt[field])
    bitrate = fmt.get('abr') if extracting_audio else fmt.get('tbr')
    if not positive(bitrate) and not extracting_audio:
        rates = [fmt.get(key) for key in ('vbr', 'abr') if positive(fmt.get(key))]
        bitrate = sum(rates) if rates else None
    if positive(duration) and positive(bitrate):
        size = duration * bitrate * 1000 / 8
        if positive(size):
            return int(size)
    return None


def supported_format(fmt):
    if not isinstance(fmt, dict):
        return False
    from yt_dlp.downloader import get_suitable_downloader
    from yt_dlp.downloader.http import HttpFD
    from yt_dlp.downloader.hls import HlsFD
    from yt_dlp.downloader.dash import DashSegmentsFD
    return (urllib.parse.urlparse(fmt.get('url', '')).scheme in ('https', 'http')
            and not fmt.get('has_drm')
            and get_suitable_downloader(dict(fmt), {}) in (HttpFD, HlsFD, DashSegmentsFD))


def selected_formats(info):
    if not isinstance(info, dict):
        raise ValueError('yt-dlp did not return media information for this link.')
    formats = info.get('requested_formats')
    return [fmt for fmt in formats if isinstance(fmt, dict)] if formats else [info]


def codec_availability(info, ydl=None):
    if not isinstance(info, dict):
        raise ValueError('yt-dlp did not return media information for this link.')
    if info.get('_type') in ('playlist', 'multi_video') or info.get('entries') is not None:
        raise ValueError('Paste a link to one video. Playlist downloads are not supported yet.')
    if info.get('is_live'):
        raise ValueError('Live streams are not supported. Try again after the stream has ended.')
    formats = [dict(fmt) for fmt in (info.get('formats') or [info]) if supported_format(fmt)]
    choices = []
    video_patterns = {'h264': ('avc1', 'h264'), 'hevc': ('hev1', 'hvc1', 'hevc', 'h265'),
                      'av1': ('av01', 'av1'), 'vp9': ('vp09', 'vp9')}
    audio_patterns = {'aac': ('mp4a', 'aac'), 'opus': ('opus',)}
    video_candidates = ('automatic', *[c for c, prefixes in video_patterns.items()
                                       if any(str(f.get('vcodec') or '').startswith(prefixes) for f in formats)])
    audio_candidates = ('automatic', *[c for c, prefixes in audio_patterns.items()
                                       if any(str(f.get('acodec') or '').startswith(prefixes) for f in formats)])
    heights = sorted({int(f['height']) for f in formats if f.get('vcodec') != 'none'
                      and isinstance(f.get('height'), (int, float)) and math.isfinite(f['height'])
                      and 0 < f['height'] <= 65536 and int(f['height']) == f['height']})
    # Upstream has already sorted extracted formats. Select from the same in-memory
    # catalog for each choice; no additional page, probe, or HEAD requests.
    owned = ydl is None
    sorter = ydl or yt_dlp.YoutubeDL({'quiet': True, 'logger': QuietLogger()}, auto_init=False)
    try:
        sorter.sort_formats(dict(formats=formats, _format_sort_fields=info.get('_format_sort_fields')))
        for kind in ('video', 'audio'):
            for height in ((0, *heights) if kind == 'video' else (0,)):
                for video in (video_candidates if kind == 'video' else ('automatic',)):
                    for audio in audio_candidates:
                        check_cancelled()
                        spec = selector(kind, height, video, audio, exact_height=True)
                        selected = list(sorter.build_format_selector(spec)({
                            'formats': formats, 'has_merged_format': any(f.get('vcodec') != 'none'
                                                                      and f.get('acodec') != 'none' for f in formats),
                            'incomplete_formats': all(f.get('vcodec') == 'none' for f in formats)
                                                  or all(f.get('acodec') == 'none' for f in formats),
                        }))
                        if not selected:
                            continue
                        tracks = selected_formats(selected[0])
                        if all(f.get('acodec' if kind == 'audio' else 'vcodec') == 'none' for f in tracks):
                            continue
                        sizes = [estimated_track_bytes(f, info.get('duration'), audio_only=kind == 'audio') for f in tracks]
                        size = sum(sizes) if sizes and all(s is not None for s in sizes) else None
                        choices.append(dict(kind=kind, quality=height, videoCodec=video, audioCodec=audio,
                                            estimatedBytes=size if size is not None and 0 < size < 2**63 else None))
    finally:
        if owned:
            sorter.close()
    return dict(choices=choices, exactQualities=True, thumbnailAvailable=thumbnail_url(info) is not None,
                thumbnail=thumbnail_url(info), subtitles=[metadata for metadata, _ in subtitle_catalog(info)],
                title=str(info.get('title') or info.get('id') or '')[:300],
                author=str(info.get('uploader') or info.get('channel') or '')[:200],
                duration=info.get('duration'), formatCount=len(formats), maxHeight=max(heights) if heights else None)


def is_youtube_url(url):
    try:
        host = (urllib.parse.urlparse(url).hostname or '').lower()
    except (TypeError, ValueError):
        return False
    return any(host == domain or host.endswith('.' + domain)
               for domain in ('youtube.com', 'youtu.be', 'youtube-nocookie.com'))


# Keep social-site session cookies isolated from YouTube and other hosts.
# No browser-wide cookie file or arbitrary Cookie HTTP header is accepted here.
SOCIAL_DOMAINS = {'reddit': ('reddit.com', 'redd.it'), 'instagram': ('instagram.com', 'instagr.am')}


def domain_matches(host, domains):
    return any(host == domain or host.endswith('.' + domain) for domain in domains)


def social_user_agent(url, access):
    if not isinstance(access, dict):
        return None
    platform = access.get('platform')
    domains = SOCIAL_DOMAINS.get(platform) if isinstance(platform, str) else None
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != 'https' or not domains or not domain_matches((parsed.hostname or '').lower(), domains):
        return None
    agent = access.get('userAgent')
    if agent is not None and (not isinstance(agent, str) or not agent or len(agent) > 1024
                              or any(ord(c) < 32 or ord(c) >= 127 for c in agent)):
        raise ValueError('The saved social-media User-Agent is invalid. Reset it in Settings.')
    return agent


def social_cookie_jar(url, access):
    invalid = 'Could not read saved social-media cookies. Sign in again in Settings > Cookies.'
    if not isinstance(access, dict):
        raise ValueError(invalid)
    if not access:
        return []
    platform = access.get('platform')
    domains = SOCIAL_DOMAINS.get(platform) if isinstance(platform, str) else None
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or '').lower()
    if parsed.scheme != 'https' or not domains or not domain_matches(host, domains):
        # A caller cannot attach a stored social session to another website.
        return []
    text = access.get('cookies')
    if text is None:
        return []
    if not isinstance(text, str) or len(text.encode('utf-8')) > 512 * 1024:
        raise ValueError(invalid)
    lines = text.removeprefix('\ufeff').replace('\r\n', '\n').replace('\r', '\n').split('\n')
    if not lines or lines[0] not in ('# Netscape HTTP Cookie File', '# HTTP Cookie File'):
        raise ValueError(invalid)
    rows = []
    for original in lines[1:]:
        line = original.removeprefix('#HttpOnly_')
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) != 7:
            raise ValueError(invalid)
        domain = fields[0].lower()
        cookie_host = domain.removeprefix('.')
        if not domain_matches(cookie_host, domains):
            # Even a manually constructed request cannot transfer credentials.
            continue
        if (fields[1] not in ('TRUE', 'FALSE') or fields[3] not in ('TRUE', 'FALSE')
                or (fields[1] == 'TRUE') != domain.startswith('.')
                or not fields[2].startswith('/') or not fields[5]
                or not re.fullmatch(r'[0-9]{0,19}', fields[4])
                or int(fields[4] or '0') > 2**63 - 1
                or any(ord(c) < 32 or ord(c) >= 127 for field in fields for c in field)
                or any(c in fields[5] for c in ' ;=') or ';' in fields[6]):
            raise ValueError(invalid)
        fields[0] = domain
        fields[4] = fields[4] or '0'
        rows.append(('#HttpOnly_' if original.startswith('#HttpOnly_') else '') + '\t'.join(fields))
    from yt_dlp.cookies import YoutubeDLCookieJar
    jar = YoutubeDLCookieJar()
    try:
        jar.load(io.StringIO('# Netscape HTTP Cookie File\n' + '\n'.join(rows) + '\n'), ignore_expires=True)
    except Exception:
        raise ValueError(invalid) from None
    return [cookie for cookie in jar if not cookie.is_expired()]


def user_error(error, url):
    message = safe_message(error) or 'Unable to access this media.'
    try:
        host = (urllib.parse.urlparse(url).hostname or '').lower()
    except (TypeError, ValueError):
        return message
    site = next((name for name, domains in SOCIAL_DOMAINS.items() if domain_matches(host, domains)), None)
    if not site:
        return message
    if re.search(r'(?:log\s?in|sign\s?in|cookies|authentication|account required|private)', message, re.I):
        return f'{site.title()} may require an authenticated session or access permission. Connect or reconnect {site.title()} in Settings > Cookies, then retry. ({message})'[:1200]
    if re.search(r'(?:\b429\b|rate.?limit|too many requests)', message, re.I):
        return f'{site.title()} is rate-limiting requests. Try again later. ({message})'[:1200]
    if re.search(r'(?:\b403\b|forbidden|access denied|challenge|captcha)', message, re.I):
        return f'{site.title()} denied access. Check that the link opens in your browser and reconnect your account if needed. ({message})'[:1200]
    return message


def request_options(data, logger):
    options = data.get('options') or {}
    inspecting = data.get('operation') == 'inspect'
    # Start with CLI defaults: bare YoutubeDL({}) has different retry defaults.
    result = copy.deepcopy(yt_dlp.parse_options(['--ignore-config']).ydl_opts)
    result.update(noplaylist=True, quiet=True, logger=logger, cachedir=data['cache'],
                  ca_certs=certifi.where(), listformats=inspecting,
                  format=selector(data.get('kind', 'video'), int(data.get('quality', 0)),
                                  options.get('videoCodec', 'automatic'), options.get('audioCodec', 'automatic'),
                                  exact_height=bool(data.get('exactQuality'))))
    if inspecting:
        result['simulate'] = 'list_only'
    cookies = []
    if not is_youtube_url(data.get('url')):
        social = data.get('socialAccess') or {}
        cookies.extend(social_cookie_jar(data.get('url'), social))
        agent = social_user_agent(data.get('url'), social)
        if agent:
            result['http_headers'] = {'User-Agent': agent}
    return result, cookies


def prepare_plan(info, data, ydl):
    plan = make_plan(info, data['kind'], ydl)
    options = data.get('options') or {}
    if options.get('embedSubtitles') and data['kind'] == 'video':
        try:
            plan['subtitle'] = download_subtitle(info, options, ydl)
        except Exception:
            check_cancelled()
            plan['subtitleWarning'] = 'Saved without subtitles: the selected track could not be downloaded or read.'
    plan['sponsorSegments'] = sponsor_segments(info, options)
    return plan


def extract(request):
    try:
        data = json.loads(request)
        check_cancelled()
        if data.get('operation') == 'clearInspectionCache':
            clear_gallery_cache()
            return json.dumps({'cleared': True})
        if data.get('operation') == 'inspect':
            try:
                catalog = gallery_catalog(data)
                if catalog:
                    return json.dumps({'availability': gallery_availability(catalog)})
            except (DownloadCancelled, GalleryLimitError):
                raise
            except Exception:
                # A video post may also match an image extractor. Preserve the
                # existing yt-dlp path when gallery-dl cannot find its images.
                check_cancelled()
        logger = QuietLogger()
        params, cookies = request_options(data, logger)
        with (InspectionYoutubeDL if data.get('operation') == 'inspect' else yt_dlp.YoutubeDL)(params) as ydl:
            for cookie in cookies:
                ydl.cookiejar.set_cookie(cookie)
            info = require_info(ydl.extract_info(data['url'], download=False), logger)
            check_cancelled()
            if data.get('operation') == 'inspect':
                return json.dumps({'availability': codec_availability(info, ydl)})
            return json.dumps({'plan': prepare_plan(info, data, ydl)})
    except DownloadCancelled:
        return json.dumps({'error': 'Cancelled'})
    except Exception as error:
        return json.dumps({'error': user_error(error, data.get('url')) if 'data' in locals() else safe_message(error)})


def download(request):
    """One upstream session owns extraction, cookies, format headers, and downloads."""
    context = wrath_native.context() if wrath_native else None
    try:
        data = json.loads(request)
        if data.get('kind') == 'images':
            return json.dumps({'plan': download_gallery(data, context)})
        logger = QuietLogger(context)
        params, cookies = request_options(data, logger)
        directory = os.path.abspath(data['directory'])
        os.makedirs(directory, exist_ok=True)
        with yt_dlp.YoutubeDL(params) as ydl:
            for cookie in cookies:
                ydl.cookiejar.set_cookie(cookie)
            check_cancelled(context)
            info = require_info(ydl.extract_info(data['url'], download=False), logger)
            plan = prepare_plan(info, data, ydl)
            formats = selected_formats(info)
            if any(not supported_format(fmt) for fmt in formats):
                raise ValueError('This format requires an external downloader that is unavailable on iOS.')
            report(context, {'type': 'resolved', 'plan': plan})
            local_tracks = []
            active_index = [0]
            last_report = [0.0]
            def progress(status):
                import time
                checkpoint(context)
                now = time.monotonic()
                if status.get('status') != 'finished' and now - last_report[0] < 0.25:
                    return
                last_report[0] = now
                event = dict(type='progress', index=active_index[0],
                             bytes=status.get('downloaded_bytes') or 0,
                             total=status.get('total_bytes') or status.get('total_bytes_estimate') or 0,
                             speed=status.get('speed'), eta=status.get('eta'),
                             finished=status.get('status') == 'finished')
                for key in ('bytes', 'total', 'speed', 'eta'):
                    value = event[key]
                    if value is not None and (not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0):
                        event[key] = None if key in ('speed', 'eta') else 0
                for key in ('bytes', 'total'):
                    event[key] = min(int(event[key]), 2**63 - 1)
                if event['finished'] and not event['total']:
                    event['total'] = event['bytes']
                report(context, event)
            ydl.add_progress_hook(progress)
            for index, fmt in enumerate(formats):
                checkpoint(context)
                active_index[0] = index
                last_report[0] = 0.0
                filename = os.path.join(directory, f'track-{index}.' + re.sub(r'[^a-zA-Z0-9]', '', fmt.get('ext') or 'media'))
                # Match upstream's per-track metadata merge before calling its
                # downloader. Keep original fragments, headers and options.
                track_info = dict(info)
                track_info.pop('requested_formats', None)
                track_info.pop('requested_downloads', None)
                track_info.update(fmt)
                success, _ = ydl.dl(filename, track_info)
                if not success:
                    raise ValueError('yt-dlp could not finish downloading the selected format.')
                check_cancelled(context)
                if not os.path.isfile(filename) or os.path.getsize(filename) == 0:
                    raise ValueError('The downloaded media track is empty.')
                local_tracks.append(dict(url=Path(filename).as_uri(), headers={},
                                         role='audio' if fmt.get('vcodec') == 'none' else 'video',
                                         streaming=False, bytes=os.path.getsize(filename)))
            plan['tracks'] = local_tracks
            plan['warnings'] = logger.warnings
            return json.dumps({'plan': plan})
    except DownloadCancelled:
        return json.dumps({'error': 'Cancelled'})
    except Exception as error:
        return json.dumps({'error': user_error(error, data.get('url')) if 'data' in locals() else safe_message(error)})
