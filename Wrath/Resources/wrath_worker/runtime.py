"""Cancellation, event reporting and log capture shared by every worker operation."""
import json
import re

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
    """Like check_cancelled, but also waits here while the download is paused."""
    if wrath_native and wrath_native.checkpoint(context):
        raise DownloadCancelled()


def native_context():
    return wrath_native.context() if wrath_native else None


def safe_message(message):
    # Upstream warnings may contain signed URLs; never forward those to the UI.
    return re.sub(r'https?://[^\s<>]+', '[link]', str(message)).removeprefix('ERROR: ').replace('\r', '').strip()[:1200]


def report(context, event):
    if wrath_native:
        wrath_native.report(context, json.dumps(event, allow_nan=False))


class QuietLogger:
    """yt-dlp logger that keeps a few sanitized messages and polls for cancellation."""

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
