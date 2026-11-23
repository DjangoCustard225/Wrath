"""Format selection, size estimates and the download plan handed to the app."""
import math
import urllib.parse

import yt_dlp

from .runtime import QuietLogger, check_cancelled
from .subtitles import subtitle_catalog
from .urls import thumbnail_url

# Codec choices offered in the app, by the prefixes yt-dlp reports for them.
VIDEO_CODECS = {'h264': ('avc1', 'h264'), 'hevc': ('hev1', 'hvc1', 'hevc', 'h265'),
                'av1': ('av01', 'av1'), 'vp9': ('vp09', 'vp9')}
AUDIO_CODECS = {'aac': ('mp4a', 'aac'), 'opus': ('opus',)}
NO_INFO = 'yt-dlp did not return media information for this link.'


def _codec_pattern(codecs, choice):
    return '(' + '|'.join(codecs[choice]) + ')' if choice in codecs else None


def selector(kind, height, video_codec='automatic', audio_codec='automatic', exact_height=False):
    cap = (f'[height={height}]' if exact_height else f'[height<=?{height}]') if height else ''
    video = _codec_pattern(VIDEO_CODECS, video_codec)
    audio = _codec_pattern(AUDIO_CODECS, audio_codec)
    vf = f'[vcodec~="^{video}"]' if video else ''
    af = f'[acodec~="^{audio}"]' if audio else ''
    if kind == 'audio':
        return f'ba{af}/b{af}'
    # The standard best-video expression, constrained only by user selections.
    video_audio_filter = f'[acodec~="^(none|{audio[1:-1]})"]' if audio else ''
    return f'bv*{cap}{vf}{video_audio_filter}+ba{af}/b{cap}{vf}{af}'


def require_single_video(info):
    if not isinstance(info, dict):
        raise ValueError(NO_INFO)
    if info.get('_type') in ('playlist', 'multi_video') or info.get('entries') is not None:
        raise ValueError('Paste a link to one video. Playlist downloads are not supported yet.')
    if info.get('is_live'):
        raise ValueError('Live streams are not supported. Try again after the stream has ended.')


def track_role(fmt):
    return 'audio' if fmt.get('vcodec') == 'none' else 'video'


def _file_extension(kind, formats, info):
    audio_codec = next((f.get('acodec', '') for f in formats if f.get('acodec') not in (None, 'none')), '')
    video_codec = next((f.get('vcodec', '') for f in formats if f.get('vcodec') not in (None, 'none')), '')
    apple_audio = audio_codec.startswith(('mp4a', 'aac', 'alac'))
    if kind == 'audio':
        if apple_audio:
            return 'm4a'
        return 'opus' if 'opus' in audio_codec else ('mp3' if 'mp3' in audio_codec else 'ogg')
    compatible_video = (video_codec.startswith(('avc', 'h264', 'hev', 'hvc', 'hevc', 'av01'))
                        or (not video_codec and info.get('ext') == 'mp4'))
    return 'mp4' if compatible_video and (not audio_codec or apple_audio) else 'mkv'


def _plan_track(fmt, info):
    url = fmt.get('url', '')
    if urllib.parse.urlparse(url).scheme not in ('https', 'http'):
        raise ValueError('This source did not provide a downloadable HTTP stream.')
    protocol = fmt.get('protocol') or 'https'
    if protocol not in ('https', 'http', 'm3u8', 'm3u8_native', 'http_dash_segments', 'file'):
        raise ValueError('This stream format is not supported yet.')
    headers = {str(k): str(v) for k, v in (fmt.get('http_headers') or info.get('http_headers') or {}).items()
               if '\r' not in str(k) + str(v) and '\n' not in str(k) + str(v)}
    return dict(url=url, headers=headers, role=track_role(fmt), streaming=protocol.startswith('m3u8'),
                bytes=fmt.get('filesize'), chunkSize=(fmt.get('downloader_options') or {}).get('http_chunk_size'))


def make_plan(info, kind):
    require_single_video(info)
    formats = [fmt for fmt in (info.get('requested_formats') or [info]) if isinstance(fmt, dict)]
    tracks = [_plan_track(fmt, info) for fmt in formats]
    if not tracks or len(tracks) > 2:
        raise ValueError('No compatible media tracks were found.')
    height = max((f.get('height') or 0 for f in formats), default=0)
    return dict(title=info.get('title') or info.get('id') or 'Download',
                author=info.get('uploader') or info.get('channel') or '',
                source=info.get('extractor_key') or 'Web', duration=info.get('duration'),
                thumbnail=thumbnail_url(info), tracks=tracks, fileExtension=_file_extension(kind, formats, info),
                quality=(f'{height}p' if height else 'Video') if kind == 'video' else 'Original audio')


def _positive(value):
    return isinstance(value, (int, float)) and math.isfinite(value) and 0 < value < 2**63


def estimated_track_bytes(fmt, duration, audio_only=False):
    # Audio extracted from a combined stream must not include the video bytes.
    extracting_audio = audio_only and fmt.get('vcodec') != 'none'
    if not extracting_audio:
        for field in ('filesize', 'filesize_approx'):
            if _positive(fmt.get(field)):
                return int(fmt[field])
    bitrate = fmt.get('abr') if extracting_audio else fmt.get('tbr')
    if not _positive(bitrate) and not extracting_audio:
        rates = [fmt.get(key) for key in ('vbr', 'abr') if _positive(fmt.get(key))]
        bitrate = sum(rates) if rates else None
    if _positive(duration) and _positive(bitrate):
        size = duration * bitrate * 1000 / 8
        if _positive(size):
            return int(size)
    return None


def supported_format(fmt):
    """Formats yt-dlp's built-in downloaders can fetch on iOS, without DRM or external tools."""
    if not isinstance(fmt, dict):
        return False
    from yt_dlp.downloader import get_suitable_downloader
    from yt_dlp.downloader.dash import DashSegmentsFD
    from yt_dlp.downloader.hls import HlsFD
    from yt_dlp.downloader.http import HttpFD
    return (urllib.parse.urlparse(fmt.get('url', '')).scheme in ('https', 'http')
            and not fmt.get('has_drm')
            and get_suitable_downloader(dict(fmt), {}) in (HttpFD, HlsFD, DashSegmentsFD))


def selected_formats(info):
    if not isinstance(info, dict):
        raise ValueError(NO_INFO)
    formats = info.get('requested_formats')
    return [fmt for fmt in formats if isinstance(fmt, dict)] if formats else [info]


def _offered_codecs(codecs, field, formats):
    return ('automatic', *[c for c, prefixes in codecs.items()
                           if any(str(f.get(field) or '').startswith(prefixes) for f in formats)])


def _video_heights(formats):
    return sorted({int(f['height']) for f in formats if f.get('vcodec') != 'none'
                   and isinstance(f.get('height'), (int, float)) and math.isfinite(f['height'])
                   and 0 < f['height'] <= 65536 and int(f['height']) == f['height']})


def _choice(sorter, formats, combination, duration):
    """The choice for one (kind, height, video, audio) combination, or None when no format satisfies it."""
    kind, height, video, audio = combination
    check_cancelled()
    spec = selector(kind, height, video, audio, exact_height=True)
    selected = list(sorter.build_format_selector(spec)({
        'formats': formats,
        'has_merged_format': any(f.get('vcodec') != 'none' and f.get('acodec') != 'none' for f in formats),
        'incomplete_formats': all(f.get('vcodec') == 'none' for f in formats)
        or all(f.get('acodec') == 'none' for f in formats),
    }))
    if not selected:
        return None
    tracks = selected_formats(selected[0])
    if all(f.get('acodec' if kind == 'audio' else 'vcodec') == 'none' for f in tracks):
        return None
    sizes = [estimated_track_bytes(f, duration, audio_only=kind == 'audio') for f in tracks]
    size = sum(sizes) if sizes and all(s is not None for s in sizes) else None
    return dict(kind=kind, quality=height, videoCodec=video, audioCodec=audio,
                estimatedBytes=size if size is not None and 0 < size < 2**63 else None)


def codec_availability(info, ydl=None):
    require_single_video(info)
    formats = [dict(fmt) for fmt in (info.get('formats') or [info]) if supported_format(fmt)]
    video_codecs = _offered_codecs(VIDEO_CODECS, 'vcodec', formats)
    audio_codecs = _offered_codecs(AUDIO_CODECS, 'acodec', formats)
    heights = _video_heights(formats)
    combinations = [('video', height, video, audio)
                    for height in (0, *heights) for video in video_codecs for audio in audio_codecs]
    combinations += [('audio', 0, 'automatic', audio) for audio in audio_codecs]
    # Upstream has already sorted extracted formats. Select from the same in-memory
    # catalog for each choice; no additional page, probe, or HEAD requests.
    sorter = ydl or yt_dlp.YoutubeDL({'quiet': True, 'logger': QuietLogger()}, auto_init=False)
    try:
        sorter.sort_formats(dict(formats=formats, _format_sort_fields=info.get('_format_sort_fields')))
        choices = [choice for combination in combinations
                   if (choice := _choice(sorter, formats, combination, info.get('duration')))]
    finally:
        if ydl is None:
            sorter.close()
    thumbnail = thumbnail_url(info)
    return dict(choices=choices, exactQualities=True, thumbnailAvailable=thumbnail is not None,
                thumbnail=thumbnail, subtitles=[metadata for metadata, _ in subtitle_catalog(info)],
                title=str(info.get('title') or info.get('id') or '')[:300],
                author=str(info.get('uploader') or info.get('channel') or '')[:200],
                duration=info.get('duration'), formatCount=len(formats), maxHeight=max(heights) if heights else None)
