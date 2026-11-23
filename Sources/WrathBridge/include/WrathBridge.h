#ifndef WRATH_BRIDGE_H
#define WRATH_BRIDGE_H
#include <stdint.h>
typedef struct WrathToken WrathToken;
WrathToken *wrath_token_create(void);
void wrath_token_cancel(WrathToken *token);
void wrath_token_set_paused(WrathToken *token, int paused);
int wrath_wait_if_paused(WrathToken *token);
int wrath_is_cancelled(WrathToken *token);
void wrath_token_free(WrathToken *token);
void wrath_free(void *pointer);
typedef void (*WrathEvent)(const char *json, void *context);
char *wrath_download(const char *root, const char *request, WrathToken *token, WrathEvent event, void *context);
char *wrath_extract(const char *root, const char *request, WrathToken *token);
const char *wrath_ffmpeg_version(void);
typedef void (*WrathStatus)(int phase, double progress, void *context);
// Read local media only. Result is JSON owned by the caller; release with wrath_free.
char *wrath_probe_media(const char *path, WrathToken *token);
typedef struct { double start; double end; int category; } WrathSegment;
typedef struct { double start; double end; const char *text; } WrathSubtitleCue;
// Remuxes one or two inputs into `output` plus the chosen extension. Returns a negative value
// and fills `error` on failure. `status` receives a ProcessingPhase and progress in 0...1 (or -1).
int wrath_remux(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, void *context, char *error, int error_size,
                char *extension, int extension_size, const char *cover_path,
                const WrathSegment *segments, int segment_count, int sponsor_mode,
                const WrathSubtitleCue *subtitles, int subtitle_count, const char *language, const char *subtitle_name,
                WrathStatus status);
#endif
