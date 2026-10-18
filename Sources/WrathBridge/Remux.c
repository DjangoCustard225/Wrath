#include "WrathBridge.h"
#include "MediaOptions.h"
#ifdef __APPLE__
#include <AetherLibavformat/avformat.h>
#include <AetherLibavutil/avutil.h>
#include <AetherLibavutil/time.h>
#include <AetherLibavcodec/packet.h>
#include <AetherLibavcodec/codec_id.h>
#else
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/time.h>
#include <libavcodec/packet.h>
#include <libavcodec/codec_id.h>
#endif
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
extern int wrath_is_cancelled(WrathToken *);
const char *wrath_ffmpeg_version(void) { return av_version_info(); }
static int interrupted(void *opaque) { return wrath_is_cancelled(opaque); }
typedef struct {
    AVFormatContext *format;
    AVPacket *packet;
    int source_indices[2], destination_indices[2], streams, ready, eof;
} Input;

static int slot(Input *input, int index) {
    for(int i=0;i<input->streams;i++) if(input->source_indices[i]==index) return i;
    return -1;
}

static int64_t offset_for(Input *input, AVRational time_base) {
    return input->format->start_time==AV_NOPTS_VALUE ? 0 : av_rescale_q(input->format->start_time,AV_TIME_BASE_Q,time_base);
}

static int64_t packet_time(Input *input) {
    AVStream *stream=input->format->streams[input->packet->stream_index];
    int64_t offset=offset_for(input,stream->time_base);
    int64_t time=input->packet->dts==AV_NOPTS_VALUE ? input->packet->pts : input->packet->dts;
    return time==AV_NOPTS_VALUE ? 0 : av_rescale_q(time-offset,stream->time_base,AV_TIME_BASE_Q);
}

static int read_next(Input *input) {
    int result;
    while ((result = av_read_frame(input->format, input->packet)) >= 0) {
        if (slot(input,input->packet->stream_index)>=0) { input->ready=1; return 0; }
        av_packet_unref(input->packet);
    }
    if (result == AVERROR_EOF) { input->eof=1; return 0; }
    return result;
}
int wrath_remux(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, WrathProgress progress, void *context, char *error, int error_size,
                char *extension, int extension_size) {
    return wrath_remux_with_options(first,first_headers,second,second_headers,output,audio_only,
        token,progress,context,error,error_size,extension,extension_size,"",NULL,0,0);
}
int wrath_remux_with_options(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, WrathProgress progress, void *context, char *error, int error_size,
                char *extension, int extension_size, const char *cover_path,
                const WrathSegment *segments, int segment_count, int sponsor_mode) {
    return wrath_remux_with_subtitles(first,first_headers,second,second_headers,output,audio_only,
        token,progress,context,error,error_size,extension,extension_size,cover_path,segments,segment_count,sponsor_mode,
        NULL,0,"","");
}
int wrath_remux_with_subtitles(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, WrathProgress progress, void *context, char *error, int error_size,
                char *extension, int extension_size, const char *cover_path,
                const WrathSegment *segments, int segment_count, int sponsor_mode,
                const WrathSubtitleCue *subtitles, int subtitle_count, const char *language, const char *subtitle_name) {
    return wrath_remux_with_status(first,first_headers,second,second_headers,output,audio_only,
        token,progress,context,error,error_size,extension,extension_size,cover_path,segments,segment_count,sponsor_mode,
        subtitles,subtitle_count,language,subtitle_name,NULL);
}
int wrath_remux_with_status(const char *first, const char *first_headers, const char *second,
                const char *second_headers, const char *output, int audio_only,
                WrathToken *token, WrathProgress progress, void *context, char *error, int error_size,
                char *extension, int extension_size, const char *cover_path,
                const WrathSegment *segments, int segment_count, int sponsor_mode,
                const WrathSubtitleCue *subtitles, int subtitle_count, const char *language, const char *subtitle_name,
                WrathStatus status) {
    Input inputs[2] = {0}; int count=0, result=0;
    AVFormatContext *out=NULL;
    AVPacket *picture=NULL;
    WrathCut *cuts=NULL; int cut_count=0;
    WrathCaptions captions={0};
    char destination[4096]={0};
    const char *stage="Media processing";
    av_log_set_level(AV_LOG_ERROR);
    avformat_network_init();
    if(status) status(0,-1,context);
    const char *paths[2]={first,second}, *headers[2]={first_headers,second_headers};
    int included[2]={0};
    for(int p=0;p<2;p++) {
        if(!paths[p] || !paths[p][0]) continue;
        if(wrath_wait_if_paused(token)) { result=AVERROR_EXIT; goto done; }
        // One demuxer per input, including progressive/HLS files with both tracks.
        // This avoids fetching the same HLS segments once for video and again for audio.
        Input *in=&inputs[count];
        in->format=avformat_alloc_context();
        if(!in->format) { result=AVERROR(ENOMEM); goto done; }
        in->format->interrupt_callback=(AVIOInterruptCB){interrupted,token};
        AVDictionary *options=NULL;
        av_dict_set(&options,"rw_timeout","20000000",0);
        if(headers[p] && headers[p][0]) av_dict_set(&options,"headers",headers[p],0);
        result=avformat_open_input(&in->format,paths[p],NULL,&options); av_dict_free(&options);
        if(result<0) goto done;
        result=avformat_find_stream_info(in->format,NULL); if(result<0) goto done;
        for(int media=0;media<2;media++) {
            enum AVMediaType type=media==0 ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO;
            if((audio_only && type==AVMEDIA_TYPE_VIDEO) || included[media]) continue;
            int index=av_find_best_stream(in->format,type,-1,-1,NULL,0);
            if(index<0) continue;
            in->source_indices[in->streams++]=index; included[media]=1;
        }
        if(!in->streams) { avformat_close_input(&in->format); continue; }
        in->packet=av_packet_alloc(); if(!in->packet) { result=AVERROR(ENOMEM); goto done; }
        count++;
    }
    if(!count) { result=AVERROR_STREAM_NOT_FOUND; goto done; }
    enum AVCodecID video=AV_CODEC_ID_NONE, audio=AV_CODEC_ID_NONE;
    AVFormatContext *video_format=NULL; int video_index=-1;
    double duration=0;
    for(int i=0;i<count;i++) {
        if(inputs[i].format->duration>0) duration=fmax(duration,inputs[i].format->duration/(double)AV_TIME_BASE);
        for(int j=0;j<inputs[i].streams;j++) {
            AVCodecParameters *parameters=inputs[i].format->streams[inputs[i].source_indices[j]]->codecpar;
            if(parameters->codec_type==AVMEDIA_TYPE_VIDEO) { video=parameters->codec_id; video_format=inputs[i].format; video_index=inputs[i].source_indices[j]; }
            else if(parameters->codec_type==AVMEDIA_TYPE_AUDIO) audio=parameters->codec_id;
        }
    }
    if(sponsor_mode) {
        if(status && segment_count>0) status(1,-1,context);
        result=wrath_prepare_segments(video_format,video_index,duration,segments,segment_count,sponsor_mode==2,token,&cuts,&cut_count);
        if(result<0) goto done;
    }
    const char *ext="mkv";
    if(audio_only) {
        if(audio==AV_CODEC_ID_NONE) { result=AVERROR_STREAM_NOT_FOUND; goto done; }
        if(audio==AV_CODEC_ID_AAC || audio==AV_CODEC_ID_ALAC) ext="m4a";
        else if(audio==AV_CODEC_ID_OPUS) ext="opus";
        else if(audio==AV_CODEC_ID_VORBIS) ext="ogg";
        else if(audio==AV_CODEC_ID_MP3) ext="mp3";
        else if(audio==AV_CODEC_ID_FLAC) ext="flac";
    } else if((video==AV_CODEC_ID_H264 || video==AV_CODEC_ID_HEVC || video==AV_CODEC_ID_AV1 || video==AV_CODEC_ID_NONE) &&
              (audio==AV_CODEC_ID_AAC || audio==AV_CODEC_ID_ALAC || audio==AV_CODEC_ID_MP3 || audio==AV_CODEC_ID_NONE)) ext="mp4";
    if(snprintf(destination,sizeof(destination),"%s.%s",output,ext)>=(int)sizeof(destination)) { result=AVERROR(ENAMETOOLONG); goto done; }
    // Keep selected VP9/Opus streams usable with a bundle that only ships the
    // MP4/MOV muxers. Choose a supported container without changing codecs.
    int mp4_video=video==AV_CODEC_ID_NONE || video==AV_CODEC_ID_H264 || video==AV_CODEC_ID_HEVC || video==AV_CODEC_ID_AV1 || video==AV_CODEC_ID_VP9;
    int mp4_audio=audio==AV_CODEC_ID_NONE || audio==AV_CODEC_ID_AAC || audio==AV_CODEC_ID_ALAC || audio==AV_CODEC_ID_MP3 || audio==AV_CODEC_ID_OPUS;
    if(strcmp(ext,"m4a") && !av_guess_format(NULL,destination,NULL) && mp4_video && mp4_audio) {
        ext="mp4";
        if(snprintf(destination,sizeof(destination),"%s.%s",output,ext)>=(int)sizeof(destination)) { result=AVERROR(ENAMETOOLONG); goto done; }
    }
    // The iOS bundle includes the MP4 muxer but not the separate "ipod" muxer
    // selected by FFmpeg's default .m4a extension lookup. MP4 supports AAC/ALAC.
    result=avformat_alloc_output_context2(&out,NULL,!strcmp(ext,"m4a") ? "mp4" : NULL,destination);
    if(result<0 || !out) goto done;
    for(int i=0;i<count;i++) {
        for(int j=0;j<inputs[i].streams;j++) {
            AVStream *source=inputs[i].format->streams[inputs[i].source_indices[j]];
            AVStream *stream=avformat_new_stream(out,NULL);
            if(!stream) { result=AVERROR(ENOMEM); goto done; }
            result=avcodec_parameters_copy(stream->codecpar,source->codecpar); if(result<0) goto done;
            stream->codecpar->codec_tag=0;
            stream->time_base=source->time_base; inputs[i].destination_indices[j]=stream->index;
        }
    }
    if(cut_count>0) {
        av_dict_set(&out->metadata,"comment","Uses SponsorBlock data from https://sponsor.ajay.app/ (CC BY-NC-SA 4.0).",0);
        if(sponsor_mode==1) {
            result=wrath_add_chapters(out,cuts,cut_count,duration); if(result<0) goto done;
            if(!strcmp(ext,"opus") || !strcmp(ext,"ogg") || !strcmp(ext,"flac")) {
                for(unsigned i=0;i<out->nb_chapters;i++) {
                    AVChapter *chapter=out->chapters[i];
                    int64_t ms=av_rescale_q(chapter->start,chapter->time_base,(AVRational){1,1000});
                    char key[32],stamp[64];
                    snprintf(key,sizeof(key),"CHAPTER%03u",i+1);
                    snprintf(stamp,sizeof(stamp),"%02lld:%02lld:%02lld.%03lld",(long long)(ms/3600000),(long long)(ms/60000%60),(long long)(ms/1000%60),(long long)(ms%1000));
                    av_dict_set(&out->metadata,key,stamp,0);
                    snprintf(key,sizeof(key),"CHAPTER%03uNAME",i+1);
                    AVDictionaryEntry *title=av_dict_get(chapter->metadata,"title",NULL,0);
                    av_dict_set(&out->metadata,key,title ? title->value : "Content",0);
                }
            }
        }
    }
    stage="Subtitle embedding";
    if(subtitle_count>0 && !audio_only) {
        if(status) status(2,-1,context);
        result=wrath_add_subtitles(out,ext,subtitles,subtitle_count,language,subtitle_name,
                                   sponsor_mode==2 ? cuts : NULL,sponsor_mode==2 ? cut_count : 0,duration,token,&captions);
        if(result<0) goto done;
    }
    stage="Thumbnail embedding";
    if(status && cover_path && cover_path[0]) status(3,-1,context);
    result=wrath_add_artwork(out,cover_path,ext,token,&picture); if(result<0) goto done;
    stage="Media processing";
    if(extension && extension_size) snprintf(extension,extension_size,"%s",ext);
    out->interrupt_callback=(AVIOInterruptCB){interrupted,token};
    if(!(out->oformat->flags & AVFMT_NOFILE)) { result=avio_open(&out->pb,destination,AVIO_FLAG_WRITE); if(result<0) goto done; }
    AVDictionary *mux_options=NULL;
    // Fast start relocates metadata; packet payloads are copied unchanged.
    if(!strcmp(ext,"mp4") || !strcmp(ext,"m4a")) av_dict_set(&mux_options,"movflags","+faststart",0);
    if(captions.count) stage="Subtitle embedding";
    result=avformat_write_header(out,&mux_options); av_dict_free(&mux_options); if(result<0) goto done;
    stage="Media processing";
    if(picture) { result=av_write_frame(out,picture); if(result<0) goto done; }
    int64_t last_report=0;
    if(status) status(4,duration>0 ? 0 : -1,context);
    int packets_written=0;
    for(;;) {
        if(wrath_wait_if_paused(token)) { result=AVERROR_EXIT; goto done; }
        int selected=-1;
        for(int i=0;i<count;i++) {
            Input *in=&inputs[i];
            if(!in->ready && !in->eof) { result=read_next(in); if(result<0) goto done; }
            if(!in->ready) continue;
            if(selected<0) { selected=i; continue; }
            if(packet_time(in)<packet_time(&inputs[selected])) selected=i;
        }
        if(captions.index<captions.count) {
            // Compare in the original timeline; captions have already been
            // retimed using the same keyframe-aligned cuts as the media.
            double seconds=selected<0 ? INFINITY : packet_time(&inputs[selected])/(double)AV_TIME_BASE;
            int skip=0;
            if(sponsor_mode==2) seconds-=wrath_removed_before(cuts,cut_count,seconds,&skip);
            if(selected<0 || captions.cues[captions.index].start<=seconds) {
                stage="Subtitle embedding";
                result=wrath_write_subtitle(out,&captions); if(result<0) goto done;
                stage="Media processing";
                continue;
            }
        }
        if(selected<0) break;
        Input *in=&inputs[selected]; AVPacket *pkt=in->packet;
        AVStream *source=in->format->streams[pkt->stream_index];
        int destination_index=in->destination_indices[slot(in,pkt->stream_index)];
        int64_t offset=offset_for(in,source->time_base);
        if(pkt->pts!=AV_NOPTS_VALUE) pkt->pts-=offset;
        if(pkt->dts!=AV_NOPTS_VALUE) pkt->dts-=offset;
        double seconds=pkt->pts==AV_NOPTS_VALUE ? 0 : pkt->pts*av_q2d(source->time_base);
        if(sponsor_mode==2 && cut_count) {
            int skip=0;
            double removed=wrath_removed_before(cuts,cut_count,seconds,&skip);
            if(skip) { av_packet_unref(pkt); in->ready=0; continue; }
            int64_t shift=av_rescale_q((int64_t)llround(removed*AV_TIME_BASE),AV_TIME_BASE_Q,source->time_base);
            if(pkt->pts!=AV_NOPTS_VALUE) pkt->pts-=shift;
            if(pkt->dts!=AV_NOPTS_VALUE) pkt->dts-=shift;
        }
        if((progress || status) && duration>0 && av_gettime_relative()-last_report>250000) {
            if(progress) progress(seconds/duration,context);
            if(status) status(4,seconds/duration,context);
            last_report=av_gettime_relative();
        }
        av_packet_rescale_ts(pkt,source->time_base,out->streams[destination_index]->time_base);
        pkt->stream_index=destination_index; pkt->pos=-1;
        result=av_interleaved_write_frame(out,pkt); in->ready=0;
        if(result<0) goto done;
        packets_written++;
    }
    if(!packets_written) { result=AVERROR_INVALIDDATA; goto done; }
    if(status) status(5,-1,context);
    result=av_write_trailer(out);
done:
    if(result<0 && error && error_size) {
        char reason[128]; av_strerror(result,reason,sizeof(reason));
        snprintf(error,error_size,"%s: %s",stage,reason);
    }
    av_packet_free(&picture); av_free(cuts); av_free(captions.cues);
    for(int i=0;i<2;i++) { av_packet_free(&inputs[i].packet); avformat_close_input(&inputs[i].format); }
    if(out) { if(out->pb) avio_closep(&out->pb); avformat_free_context(out); }
    if(result<0 && destination[0]) unlink(destination);
    return result;
}
