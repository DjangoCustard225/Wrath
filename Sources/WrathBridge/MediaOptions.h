#include "WrathBridge.h"
#ifdef __APPLE__
#include <AetherLibavformat/avformat.h>
#include <AetherLibavutil/base64.h>
#include <AetherLibavutil/intreadwrite.h>
#include <AetherLibavutil/mem.h>
#else
#include <libavformat/avformat.h>
#include <libavutil/base64.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>
#endif
typedef struct { double start, end; int category; } WrathCut;
int wrath_prepare_segments(AVFormatContext *video, int video_index, double duration,
                          const WrathSegment *segments, int count, int align, WrathToken *token,
                          WrathCut **cuts, int *cut_count);
double wrath_removed_before(const WrathCut *cuts, int count, double time, int *skip);
int wrath_add_chapters(AVFormatContext *output, const WrathCut *cuts, int count, double duration);
int wrath_add_artwork(AVFormatContext *output, const char *path, const char *extension, WrathToken *token, AVPacket **picture);
typedef struct {
    WrathSubtitleCue *cues;
    int count, index;
    AVStream *stream;
} WrathCaptions;
int wrath_add_subtitles(AVFormatContext *output, const char *extension,
                       const WrathSubtitleCue *cues, int count, const char *language, const char *name,
                       const WrathCut *cuts, int cut_count, double duration, WrathToken *token, WrathCaptions *captions);
int wrath_write_subtitle(AVFormatContext *output, WrathCaptions *captions);
