"""Bounded photo galleries through gallery-dl: single posts and albums, never profiles or feeds."""
import copy
import hashlib
import json
import logging
import time
import urllib.parse
from pathlib import Path

from .runtime import checkpoint, report, safe_message
from .social import social_cookie_jar, social_user_agent
from .urls import domain_matches

GALLERY_EXTENSIONS = frozenset(('jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'heic'))
GALLERY_DOMAINS = ('reddit.com', 'redd.it', 'imgur.com', 'instagram.com', 'twitter.com', 'x.com', 'pixiv.net',
                   'flickr.com', 'deviantart.com', 'tumblr.com', 'bsky.app', 'pinterest.com', 'tiktok.com')
ALLOWED_EXTRACTORS = ('PostExtractor', 'ImageExtractor', 'GalleryExtractor', 'AlbumExtractor',
                      'SubmissionExtractor', 'TweetExtractor', 'StatusExtractor', 'WorkExtractor',
                      'DeviationExtractor', 'PinExtractor', 'PhotoExtractor')
GALLERY_LIMIT = 200
GALLERY_IMAGE_LIMIT = 100 * 1024 * 1024
GALLERY_TOTAL_LIMIT = 2 * 1024 * 1024 * 1024
CACHE_SECONDS = 180
CACHE_SIZE = 4
# (url, social-access digest) -> (monotonic time, catalog). Inspection results reused by the download.
GALLERY_CACHE = {}


class GalleryLimitError(ValueError):
    pass


def gallery_extractor(url):
    """Only bounded post/album extractors; never crawl profiles or feeds."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ('http', 'https') or parsed.username or parsed.password:
        return None
    host = (parsed.hostname or '').lower()
    if Path(parsed.path).suffix[1:].lower() not in GALLERY_EXTENSIONS and not domain_matches(host, GALLERY_DOMAINS):
        return None
    from gallery_dl import config, extractor
    # Extractor token caches must not create plaintext credentials outside the
    # app's Keychain-backed cookie settings, including in gallery-dl's defaults.
    config.set(('cache',), 'file', ':memory:')
    instance = extractor.find(url)
    if not instance or instance.subcategory == 'reel':
        return None
    name = instance.__class__.__name__
    return instance if name.endswith(ALLOWED_EXTRACTORS) or name == 'DirectlinkExtractor' else None


def close_gallery(catalog):
    for session in catalog['sessions']:
        session.close()


def clear_gallery_cache():
    for _, catalog in GALLERY_CACHE.values():
        close_gallery(catalog)
    GALLERY_CACHE.clear()


def _expire_cache():
    for old_key, (stamp, catalog) in list(GALLERY_CACHE.items()):
        if time.monotonic() - stamp > CACHE_SECONDS:
            GALLERY_CACHE.pop(old_key)
            close_gallery(catalog)


def _remember(key, catalog):
    while len(GALLERY_CACHE) >= CACHE_SIZE:
        close_gallery(GALLERY_CACHE.pop(next(iter(GALLERY_CACHE)))[1])
    GALLERY_CACHE[key] = (time.monotonic(), catalog)


def _title_and_author(metadata, extractor_name):
    title = metadata.get('title') or metadata.get('description') or metadata.get('caption') or ''
    if not title and extractor_name == 'DirectlinkExtractor':
        title = metadata.get('filename') or ''
    user = (metadata.get('author') or metadata.get('user') or metadata.get('uploader')
            or metadata.get('username') or '')
    if isinstance(user, dict):
        user = user.get('name') or user.get('username') or ''
    return (str(title).strip()[:300] if isinstance(title, str) else '',
            str(user)[:120] if isinstance(user, str) else '')


class _Collector:
    """Walks an extractor and its nested queue entries, gathering image files into a catalog."""

    def __init__(self, data, context):
        self.data = data
        self.context = context
        self.catalog = dict(files=[], sessions=[], title='', author='', skippedVideos=0, warnings=[])
        self.visited = set()
        self.media_seen = set()
        self.cookies = social_cookie_jar(data['url'], data.get('socialAccess', {}))

    def _logger(self):
        catalog = self.catalog

        class LogHandler(logging.Handler):
            def emit(self, record):
                message = safe_message(record.getMessage())
                warnings = catalog['warnings']
                if record.levelno >= logging.WARNING and message not in warnings and len(warnings) < 4:
                    warnings.append(message)

        logger = logging.Logger('wrath.gallery', logging.WARNING)
        logger.addHandler(LogHandler())
        logger.propagate = False
        return logger

    def _configure(self, instance):
        instance.log = self._logger()
        original_config = instance.config
        overrides = {'retries': 1, 'timeout': 15, 'sleep-request': 0, 'sleep-429': 1,
                     'recursion': 0, 'comments': 0, 'selftext': False, 'cookies-update': False}
        agent = social_user_agent(instance.url, self.data.get('socialAccess', {}))
        if agent:
            overrides['user-agent'] = agent
        instance.config = lambda name, default=None: overrides.get(name, original_config(name, default))

    def _open_session(self, instance):
        # Initialize the upstream session before site-specific API calls so
        # saved Reddit cookies are available without a plaintext cookie file.
        instance._init_options()
        instance._init_session()
        self.catalog['sessions'].append(instance.session)
        instance.cookies = instance.session.cookies
        if instance.cookies_domain is not None:
            instance._init_cookies()
        for cookie in self.cookies:
            instance.session.cookies.set_cookie(copy.copy(cookie))

    def visit(self, instance, depth=0):
        checkpoint(self.context)
        if instance.url in self.visited:
            return
        if depth > 2 or len(self.visited) >= 8:
            raise GalleryLimitError('This gallery links to too many collections. Use a direct post or album link.')
        self.visited.add(instance.url)
        self._configure(instance)
        original_request = instance.request

        def request(*args, **kwargs):
            checkpoint(self.context)
            response = original_request(*args, **kwargs)
            checkpoint(self.context)
            return response

        instance.request = request
        try:
            self._open_session(instance)
            for index, message in enumerate(instance):
                checkpoint(self.context)
                if index > 1000:
                    raise GalleryLimitError('This link contains too much media. Use an individual post or album.')
                self._handle(message, instance, depth)
        finally:
            # Native contexts belong to one bridge call and must never survive
            # in the short-lived inspection cache for a later download thread.
            instance.request = original_request

    def _handle(self, message, instance, depth):
        from gallery_dl.extractor.message import Message
        catalog = self.catalog
        if message[0] == Message.Queue:
            nested = gallery_extractor(message[1])
            if nested:
                self.visit(nested, depth + 1)
            else:
                catalog['skippedVideos'] += 1
            return
        if message[0] not in (Message.Directory, Message.Url):
            return
        metadata = message[2]
        if not catalog['title']:
            catalog['title'], catalog['author'] = _title_and_author(metadata, instance.__class__.__name__)
        if message[0] != Message.Url:
            return
        url = message[1]
        if url in self.media_seen:
            return
        self.media_seen.add(url)
        extension = str(metadata.get('extension') or Path(urllib.parse.urlsplit(url).path).suffix[1:]).lower()
        if extension not in GALLERY_EXTENSIONS or urllib.parse.urlsplit(url).scheme not in ('http', 'https'):
            catalog['skippedVideos'] += 1
            return
        if len(catalog['files']) >= GALLERY_LIMIT:
            raise GalleryLimitError('This gallery exceeds 200 images. Use a smaller post or album.')
        headers = metadata.get('_http_headers') or {}
        headers = {k: v for k, v in headers.items() if k.lower() in ('referer', 'user-agent', 'accept')}
        catalog['files'].append(dict(url=url, extension=extension, session=instance.session, headers=headers))


def gallery_catalog(data, context=None, consume=False):
    """The images behind a gallery link, or None when gallery-dl has nothing for it.

    Inspection caches the catalog for a few minutes; the download consumes that entry.
    """
    access = json.dumps(data.get('socialAccess', {}), sort_keys=True).encode()
    key = (data['url'], hashlib.sha256(access).hexdigest())
    _expire_cache()
    if key in GALLERY_CACHE:
        return GALLERY_CACHE.pop(key)[1] if consume else GALLERY_CACHE[key][1]
    root = gallery_extractor(data['url'])
    if root is None:
        return None
    collector = _Collector(data, context)
    catalog = collector.catalog
    try:
        collector.visit(root)
        if not catalog['files']:
            close_gallery(catalog)
            return None
        if not catalog['title']:
            catalog['title'] = (catalog['author'] + ' photos').strip() if catalog['author'] else 'Photo gallery'
        if not consume:
            _remember(key, catalog)
        return catalog
    except BaseException:
        close_gallery(catalog)
        raise


def gallery_availability(catalog):
    return dict(choices=[], thumbnailAvailable=False, title=catalog['title'], author=catalog['author'],
                thumbnail=catalog['files'][0]['url'], gallery=dict(count=len(catalog['files']),
                skippedVideos=catalog['skippedVideos']))


IMAGE_SIGNATURES = ((b'\xff\xd8\xff', 'jpg'), (b'\x89PNG\r\n\x1a\n', 'png'), (b'GIF87a', 'gif'), (b'GIF89a', 'gif'))
HEIF_BRANDS = (b'heic', b'heix', b'hevc', b'hevx', b'mif1', b'msf1')


def image_extension(signature):
    """The extension matching an image file's leading bytes, or None if it is not a supported image."""
    extension = next((ext for prefix, ext in IMAGE_SIGNATURES if signature.startswith(prefix)), None)
    if extension:
        return extension
    if signature.startswith(b'RIFF') and signature[8:12] == b'WEBP':
        return 'webp'
    if signature[4:8] != b'ftyp':
        return None
    brands = signature[8:]
    if b'avif' in brands or b'avis' in brands:
        return 'avif'
    return 'heic' if any(brand in brands for brand in HEIF_BRANDS) else None


def _fetch_image(media, target, context, progress):
    """Streams one image to target and returns its size in bytes."""
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
                if received > GALLERY_IMAGE_LIMIT:
                    raise ValueError('An image was larger than the 100 MB limit, so the download was stopped.')
                progress.check_total(received)
                now = time.monotonic()
                if now - last_report >= 0.25:
                    progress.update(received, min(0.99, received / total if total > 0 else 0))
                    last_report = now
    checkpoint(context)
    if received == 0 or (total > 0 and received != total and not response.headers.get('Content-Encoding')):
        raise ValueError('An image download was incomplete. Add the link again to retry.')
    return received


class _GalleryProgress:
    def __init__(self, context, count):
        self.context = context
        self.count = count
        self.index = 0
        self.completed_bytes = 0
        self.start = time.monotonic()

    def check_total(self, received):
        if self.completed_bytes + received > GALLERY_TOTAL_LIMIT:
            raise ValueError('This gallery was larger than the 2 GB limit, so the download was stopped.')

    def update(self, received, image_fraction):
        total = self.completed_bytes + received
        report(self.context, dict(type='galleryProgress', bytes=total,
                                  fraction=(self.index + image_fraction) / self.count,
                                  imageIndex=self.index + 1, imageCount=self.count,
                                  speed=total / max(0.1, time.monotonic() - self.start)))

    def finish_image(self, received):
        self.completed_bytes += received
        report(self.context, dict(type='galleryProgress', bytes=self.completed_bytes,
                                  fraction=(self.index + 1) / self.count,
                                  imageIndex=self.index + 1, imageCount=self.count))


def download_gallery(data, context):
    catalog = gallery_catalog(data, context, consume=True)
    if catalog is None:
        raise ValueError('No supported images were found. Check the post link again.')
    plan = dict(title=catalog['title'], author=catalog['author'], source=data['url'],
                thumbnail=catalog['files'][0]['url'], tracks=[], fileExtension='gallery',
                quality='Original images', galleryFiles=[], warnings=[])
    if catalog['skippedVideos']:
        plan['warnings'].append('Saved images only; video or unsupported linked attachments were not included.')
    directory = Path(data['directory']) / 'gallery'
    progress = _GalleryProgress(context, len(catalog['files']))
    try:
        directory.mkdir(parents=True, exist_ok=False)
        report(context, {'type': 'resolved', 'plan': plan})
        for index, media in enumerate(catalog['files']):
            checkpoint(context)
            progress.index = index
            target = directory / f'{index + 1:03d}.{media["extension"]}'
            received = _fetch_image(media, target, context, progress)
            with target.open('rb') as image:
                actual = image_extension(image.read(64))
            if actual is None:
                raise ValueError('The website did not return a supported image. Add the link again to retry.')
            # Sites often serve a different format than the URL suggests; name the file after its contents.
            if actual != media['extension']:
                target = target.rename(directory / f'{index + 1:03d}.{actual}')
            progress.finish_image(received)
            plan['galleryFiles'].append(dict(filename=target.name, bytes=received))
        return plan
    finally:
        close_gallery(catalog)
