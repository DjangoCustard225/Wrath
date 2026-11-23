"""Upstream yt-dlp and gallery-dl extraction; native FFmpeg handles media processing.

The native bridge (Sources/WrathBridge/Runtime.c) calls extract() and download() with a JSON
request and expects a JSON reply holding a plan, an availability, or an error message.
"""
import copy
import json
import math
import os
import re
import time
from contextlib import contextmanager
from pathlib import Path

import certifi
import yt_dlp

from .formats import codec_availability, make_plan, selected_formats, selector, supported_format, track_role
from .gallery import GalleryLimitError, clear_gallery_cache, download_gallery, gallery_availability, gallery_catalog
from .runtime import (
    DownloadCancelled,
    QuietLogger,
    check_cancelled,
    checkpoint,
    native_context,
    report,
    require_info,
    safe_message,
)
from .social import social_cookie_jar, social_user_agent, user_error
from .sponsorblock import sponsor_segments
from .subtitles import download_subtitle
from .urls import is_youtube_url

__all__ = ['extract', 'download']


class InspectionYoutubeDL(yt_dlp.YoutubeDL):
    # Presentation only: the app renders the same structured -F catalog.
    def list_formats(self, info_dict):
        check_cancelled()

    def list_subtitles(self, video_id, subtitles, name='subtitles'):
        check_cancelled()


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
    plan = make_plan(info, data['kind'])
    options = data.get('options') or {}
    if options.get('embedSubtitles') and data['kind'] == 'video':
        try:
            plan['subtitle'] = download_subtitle(info, options, ydl)
        except Exception:
            check_cancelled()
            plan['subtitleWarning'] = 'Saved without subtitles: the selected track could not be downloaded or read.'
    plan['sponsorSegments'] = sponsor_segments(info, options)
    return plan


@contextmanager
def _open(params, cookies, ydl_class=yt_dlp.YoutubeDL):
    with ydl_class(params) as ydl:
        for cookie in cookies:
            ydl.cookiejar.set_cookie(cookie)
        yield ydl


def _error_reply(error, data):
    if isinstance(error, DownloadCancelled):
        return json.dumps({'error': 'Cancelled'})
    if isinstance(data, dict):
        return json.dumps({'error': user_error(error, data.get('url'))})
    return json.dumps({'error': safe_message(error)})


def _inspect_gallery(data):
    """Gallery availability, or None to fall through to yt-dlp."""
    try:
        catalog = gallery_catalog(data)
        return gallery_availability(catalog) if catalog else None
    except (DownloadCancelled, GalleryLimitError):
        raise
    except Exception:
        # A video post may also match an image extractor. Preserve the
        # existing yt-dlp path when gallery-dl cannot find its images.
        check_cancelled()
        return None


def extract(request):
    """Inspects a link (operation 'inspect'), resolves a plan, or clears the inspection cache."""
    data = None
    try:
        data = json.loads(request)
        check_cancelled()
        operation = data.get('operation')
        if operation == 'clearInspectionCache':
            clear_gallery_cache()
            return json.dumps({'cleared': True})
        if operation == 'inspect':
            availability = _inspect_gallery(data)
            if availability:
                return json.dumps({'availability': availability})
        logger = QuietLogger()
        params, cookies = request_options(data, logger)
        with _open(params, cookies, InspectionYoutubeDL if operation == 'inspect' else yt_dlp.YoutubeDL) as ydl:
            info = require_info(ydl.extract_info(data['url'], download=False), logger)
            check_cancelled()
            if operation == 'inspect':
                return json.dumps({'availability': codec_availability(info, ydl)})
            return json.dumps({'plan': prepare_plan(info, data, ydl)})
    except (DownloadCancelled, Exception) as error:
        return _error_reply(error, data)


class _TrackProgress:
    """yt-dlp progress hook that forwards sanitized, throttled events for the active track."""

    def __init__(self, context):
        self.context = context
        self.index = 0
        self.last_report = 0.0

    def start(self, index):
        self.index = index
        self.last_report = 0.0

    def __call__(self, status):
        checkpoint(self.context)
        now = time.monotonic()
        finished = status.get('status') == 'finished'
        if not finished and now - self.last_report < 0.25:
            return
        self.last_report = now
        event = dict(type='progress', index=self.index, bytes=status.get('downloaded_bytes') or 0,
                     total=status.get('total_bytes') or status.get('total_bytes_estimate') or 0,
                     speed=status.get('speed'), eta=status.get('eta'), finished=finished)
        for key in ('bytes', 'total', 'speed', 'eta'):
            value = event[key]
            if value is not None and (not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0):
                event[key] = None if key in ('speed', 'eta') else 0
        for key in ('bytes', 'total'):
            event[key] = min(int(event[key]), 2**63 - 1)
        if finished and not event['total']:
            event['total'] = event['bytes']
        report(self.context, event)


def _download_track(ydl, info, fmt, filename, context):
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
    return dict(url=Path(filename).as_uri(), headers={}, role=track_role(fmt), streaming=False,
                bytes=os.path.getsize(filename))


def download(request):
    """One upstream session owns extraction, cookies, format headers, and downloads."""
    context = native_context()
    data = None
    try:
        data = json.loads(request)
        if data.get('kind') == 'images':
            return json.dumps({'plan': download_gallery(data, context)})
        logger = QuietLogger(context)
        params, cookies = request_options(data, logger)
        directory = os.path.abspath(data['directory'])
        os.makedirs(directory, exist_ok=True)
        with _open(params, cookies) as ydl:
            check_cancelled(context)
            info = require_info(ydl.extract_info(data['url'], download=False), logger)
            plan = prepare_plan(info, data, ydl)
            formats = selected_formats(info)
            if any(not supported_format(fmt) for fmt in formats):
                raise ValueError('This format requires an external downloader that is unavailable on iOS.')
            report(context, {'type': 'resolved', 'plan': plan})
            progress = _TrackProgress(context)
            ydl.add_progress_hook(progress)
            tracks = []
            for index, fmt in enumerate(formats):
                checkpoint(context)
                progress.start(index)
                extension = re.sub(r'[^a-zA-Z0-9]', '', fmt.get('ext') or 'media')
                filename = os.path.join(directory, f'track-{index}.{extension}')
                tracks.append(_download_track(ydl, info, fmt, filename, context))
            plan['tracks'] = tracks
            plan['warnings'] = logger.warnings
            return json.dumps({'plan': plan})
    except (DownloadCancelled, Exception) as error:
        return _error_reply(error, data)
