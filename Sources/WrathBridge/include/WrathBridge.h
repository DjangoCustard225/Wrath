#ifndef WRATH_BRIDGE_H
#define WRATH_BRIDGE_H
#include <stdint.h>
typedef struct WrathToken WrathToken;
WrathToken *wrath_token_create(void);
void wrath_token_cancel(WrathToken *token);
int wrath_is_cancelled(WrathToken *token);
void wrath_token_free(WrathToken *token);
void wrath_free(void *pointer);
char *wrath_extract(const char *root, const char *cache, const char *request, WrathToken *token);
const char *wrath_ffmpeg_version(void);
typedef void (*WrathProgress)(double progress, void *context);
typedef void (*WrathStatus)(int phase, double progress, void *context);
// Read local media only. Result is JSON owned by the caller; release with wrath_free.
char *wrath_probe_media(const char *path, WrathToken *token);
typedef struct { double start; double end; int category; } WrathSegment;
typedef struct { double start; double end; const char *text; } WrathSubtitleCue;
int wrath_remux(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, WrathProgress progress, void *context, char *error, int error_size,
                char *extension, int extension_size);
int wrath_remux_with_options(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, WrathProgress progress, void *context, char *error, int error_size,
                char *extension, int extension_size, const char *cover_path,
                const WrathSegment *segments, int segment_count, int sponsor_mode);
int wrath_remux_with_subtitles(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, WrathProgress progress, void *context, char *error, int error_size,
                char *extension, int extension_size, const char *cover_path,
                const WrathSegment *segments, int segment_count, int sponsor_mode,
                const WrathSubtitleCue *subtitles, int subtitle_count, const char *language, const char *subtitle_name);
int wrath_remux_with_status(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, WrathProgress progress, void *context, char *error, int error_size,
                char *extension, int extension_size, const char *cover_path,
                const WrathSegment *segments, int segment_count, int sponsor_mode,
                const WrathSubtitleCue *subtitles, int subtitle_count, const char *language, const char *subtitle_name,
                WrathStatus status);
#endif
