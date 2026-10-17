#include "MediaOptions.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
extern int wrath_is_cancelled(WrathToken *);

static void append_caption(WrathCaptions *captions, const char *text, double start, double end,
                           const WrathCut *cuts, int cut_count) {
    int skip;
    double mapped_start=start-wrath_removed_before(cuts,cut_count,start,&skip);
    double mapped_end=end-wrath_removed_before(cuts,cut_count,end,&skip);
    if(llround(mapped_end*1000)>llround(mapped_start*1000))
        captions->cues[captions->count++]=(WrathSubtitleCue){mapped_start,mapped_end,text};
}
int wrath_add_subtitles(AVFormatContext *output, const char *extension,
                       const WrathSubtitleCue *cues, int count, const char *language, const char *name,
                       const WrathCut *cuts, int cut_count, double duration, WrathToken *token, WrathCaptions *captions) {
    if(count<=0) return 0;
    if(!cues || count>40000 || cut_count<0 || cut_count>500) return AVERROR(EINVAL);
    captions->cues=av_calloc(count+cut_count+1,sizeof(WrathSubtitleCue));
    if(!captions->cues) return AVERROR(ENOMEM);
    size_t bytes=0;
    double previous_end=0;
    for(int i=0;i<count;i++) {
        if(wrath_is_cancelled(token)) return AVERROR_EXIT;
        double start=cues[i].start,end=cues[i].end;
        if(!isfinite(start) || !isfinite(end) || start<previous_end || end<=start || end>1e9 || !cues[i].text)
            return AVERROR_INVALIDDATA;
        size_t length=strlen(cues[i].text);
        bytes+=length;
        if(!length || length>60000 || bytes>8*1024*1024) return AVERROR_INVALIDDATA;
        previous_end=end;
        if(duration>0) end=fmin(end,duration);
        if(start>=end) continue;
        double cursor=start;
        for(int j=0;j<cut_count && cursor<end;j++) {
            if(cuts[j].end<=cursor) continue;
            if(cuts[j].start>=end) break;
            if(cuts[j].start>cursor) append_caption(captions,cues[i].text,cursor,fmin(end,cuts[j].start),cuts,cut_count);
            cursor=fmax(cursor,cuts[j].end);
        }
        if(cursor<end) append_caption(captions,cues[i].text,cursor,end,cuts,cut_count);
    }
    if(!captions->count) return 0;
    int mp4=!strcmp(extension,"mp4");
    if(!mp4 && strcmp(extension,"mkv")) return AVERROR_MUXER_NOT_FOUND;
    AVStream *stream=avformat_new_stream(output,NULL);
    if(!stream) return AVERROR(ENOMEM);
    captions->stream=stream;
    stream->time_base=(AVRational){1,1000};
    stream->codecpar->codec_type=AVMEDIA_TYPE_SUBTITLE;
    stream->codecpar->codec_id=mp4 ? AV_CODEC_ID_MOV_TEXT : AV_CODEC_ID_SUBRIP;
    stream->disposition=0; // Selectable in the player; never burn captions into video.
    av_dict_set(&stream->metadata,"language",language && language[0] ? language : "und",0);
    av_dict_set(&stream->metadata,"title",name && name[0] ? name : "Subtitles",0);
    av_dict_set(&stream->metadata,"handler_name",name && name[0] ? name : "Subtitles",0);
    if(mp4) {
        // ISO/IEC 14496-17 tx3g sample description: centered white text,
        // bottom alignment, transparent background, and one sans-serif font.
        // Construct timed text directly: the iOS bundle has no subtitle encoder.
        static const uint8_t description[]={
            0,0,0,0, 1,255, 0,0,0,0, 0,0,0,0,0,0,0,0,
            0,0,0,0, 0,1,0,18, 255,255,255,255,
            0,0,0,18, 'f','t','a','b', 0,1, 0,1,5,'A','r','i','a','l'
        };
        stream->codecpar->extradata=av_mallocz(sizeof(description)+AV_INPUT_BUFFER_PADDING_SIZE);
        if(!stream->codecpar->extradata) return AVERROR(ENOMEM);
        memcpy(stream->codecpar->extradata,description,sizeof(description));
        stream->codecpar->extradata_size=sizeof(description);
    }
    return 0;
}
int wrath_write_subtitle(AVFormatContext *output, WrathCaptions *captions) {
    const WrathSubtitleCue *cue=&captions->cues[captions->index++];
    int length=(int)strlen(cue->text),mp4=captions->stream->codecpar->codec_id==AV_CODEC_ID_MOV_TEXT;
    AVPacket *packet=av_packet_alloc();
    if(!packet) return AVERROR(ENOMEM);
    int result=av_new_packet(packet,length+(mp4 ? 2 : 0));
    if(result>=0) {
        if(mp4) AV_WB16(packet->data,length);
        memcpy(packet->data+(mp4 ? 2 : 0),cue->text,length);
        packet->pts=packet->dts=llround(cue->start*1000);
        packet->duration=llround(cue->end*1000)-packet->pts;
        packet->flags=AV_PKT_FLAG_KEY;
        packet->stream_index=captions->stream->index;
        packet->pos=-1;
        av_packet_rescale_ts(packet,(AVRational){1,1000},captions->stream->time_base);
        result=av_interleaved_write_frame(output,packet);
    }
    av_packet_free(&packet);
    return result;
}

static int compare_cuts(const void *a, const void *b) {
    const WrathCut *x=a,*y=b;
    return x->start<y->start ? -1 : x->start>y->start;
}
static int next_keyframe(AVFormatContext *format, int index, double wanted, double duration, WrathToken *token, double *time) {
    AVStream *stream=format->streams[index];
    int64_t origin=format->start_time==AV_NOPTS_VALUE ? 0 : av_rescale_q(format->start_time,AV_TIME_BASE_Q,stream->time_base);
    int64_t position=av_rescale_q((int64_t)llround(wanted*AV_TIME_BASE),AV_TIME_BASE_Q,stream->time_base)+origin;
    int result=av_seek_frame(format,index,position,AVSEEK_FLAG_BACKWARD);
    if(result<0) return result;
    AVPacket *packet=av_packet_alloc();
    if(!packet) return AVERROR(ENOMEM);
    while((result=av_read_frame(format,packet))>=0) {
        if(wrath_is_cancelled(token)) { result=AVERROR_EXIT; break; }
        if(packet->stream_index==index && (packet->flags&AV_PKT_FLAG_KEY) && packet->pts!=AV_NOPTS_VALUE) {
            double seconds=(packet->pts-origin)*av_q2d(stream->time_base);
            if(seconds+0.000001>=wanted) { *time=fmax(0,seconds); result=0; break; }
        }
        av_packet_unref(packet);
    }
    av_packet_free(&packet);
    if(result==AVERROR_EOF && duration>0) { *time=duration; return 0; }
    return result;
}
int wrath_prepare_segments(AVFormatContext *video, int video_index, double duration,
                          const WrathSegment *segments, int count, int align, WrathToken *token,
                          WrathCut **cuts, int *cut_count) {
    *cuts=NULL; *cut_count=0;
    if(!segments || count<=0) return 0;
    if(count>500) return AVERROR(EINVAL);
    WrathCut *result=av_calloc(count,sizeof(WrathCut));
    if(!result) return AVERROR(ENOMEM);
    int used=0;
    for(int i=0;i<count;i++) {
        double start=segments[i].start,end=segments[i].end;
        if(!isfinite(start) || !isfinite(end) || start<0 || end<=start) continue;
        if(duration>0) end=fmin(end,duration);
        if(start>=end) continue;
        result[used++]=(WrathCut){start,end,segments[i].category};
    }
    qsort(result,used,sizeof(WrathCut),compare_cuts);
    int merged=0;
    for(int i=0;i<used;i++) {
        WrathCut cut=result[i];
        if(align && video) {
            int status=next_keyframe(video,video_index,cut.start,duration,token,&cut.start);
            if(status>=0) status=next_keyframe(video,video_index,cut.end,duration,token,&cut.end);
            if(status<0) { av_free(result); return status; }
        }
        if(cut.end<=cut.start) continue;
        if(merged && cut.start<=result[merged-1].end+0.000001) result[merged-1].end=fmax(result[merged-1].end,cut.end);
        else result[merged++]=cut;
    }
    if(align && video) {
        AVStream *stream=video->streams[video_index];
        int64_t start=stream->start_time==AV_NOPTS_VALUE ? 0 : stream->start_time;
        int status=av_seek_frame(video,video_index,start,AVSEEK_FLAG_BACKWARD);
        if(status<0) { av_free(result); return status; }
        avformat_flush(video);
    }
    if(align && duration>0 && merged==1 && result[0].start<0.000001 && result[0].end>=duration-0.001) {
        av_free(result); return AVERROR_INVALIDDATA;
    }
    *cuts=result; *cut_count=merged;
    return 0;
}
double wrath_removed_before(const WrathCut *cuts, int count, double time, int *skip) {
    double removed=0; *skip=0;
    for(int i=0;i<count;i++) {
        if(time+0.000001>=cuts[i].start && time<cuts[i].end-0.000001) { *skip=1; break; }
        if(time+0.000001>=cuts[i].end) removed+=cuts[i].end-cuts[i].start;
    }
    return removed;
}
static int add_chapter(AVFormatContext *output, double start, double end, const char *title) {
    if(end<=start) return 0;
    AVChapter **chapters=av_realloc_array(output->chapters,output->nb_chapters+1,sizeof(AVChapter *));
    if(!chapters) return AVERROR(ENOMEM);
    output->chapters=chapters;
    AVChapter *chapter=av_mallocz(sizeof(AVChapter));
    if(!chapter) return AVERROR(ENOMEM);
    chapter->id=output->nb_chapters; chapter->time_base=(AVRational){1,1000};
    chapter->start=llround(start*1000); chapter->end=llround(end*1000);
    av_dict_set(&chapter->metadata,"title",title,0);
    output->chapters[output->nb_chapters++]=chapter;
    return 0;
}
int wrath_add_chapters(AVFormatContext *output, const WrathCut *cuts, int count, double duration) {
    static const char *titles[]={"Sponsor","Self-promotion","Subscribe & like reminder","Intro","Outro","Preview","Non-music section","Filler"};
    double position=0;
    for(int i=0;i<count;i++) {
        int result=add_chapter(output,position,cuts[i].start,"Content");
        if(result<0) return result;
        const char *title=cuts[i].category>=0 && cuts[i].category<8 ? titles[cuts[i].category] : "SponsorBlock segment";
        result=add_chapter(output,cuts[i].start,cuts[i].end,title);
        if(result<0) return result;
        position=cuts[i].end;
    }
    return add_chapter(output,position,duration,"Content");
}
// ImageIO already validates and converts artwork to JPEG on iOS. Read its bytes
// directly: the bundled FFmpeg intentionally has no image demuxer or decoder.
static int load_artwork(const char *path, WrathToken *token, AVPacket *packet, AVCodecParameters *parameters) {
    if(wrath_is_cancelled(token)) return AVERROR_EXIT;
    FILE *file=fopen(path,"rb");
    if(!file) return AVERROR(errno);
    int result=AVERROR_INVALIDDATA;
    if(fseek(file,0,SEEK_END)) goto done;
    long size=ftell(file);
    if(size<4 || size>8*1024*1024 || fseek(file,0,SEEK_SET)) goto done;
    result=av_new_packet(packet,(int)size); if(result<0) goto done;
    result=AVERROR_INVALIDDATA;
    if(fread(packet->data,1,size,file)!=(size_t)size) goto done;
    if(wrath_is_cancelled(token)) { result=AVERROR_EXIT; goto done; }
    const uint8_t *bytes=packet->data;
    if(bytes[0]!=0xff || bytes[1]!=0xd8 || bytes[size-2]!=0xff || bytes[size-1]!=0xd9) goto done;
    size_t offset=2;
    while(offset<(size_t)size-2) {
        if(bytes[offset++]!=0xff) goto done;
        while(offset<(size_t)size && bytes[offset]==0xff) offset++;
        if(offset>=(size_t)size) goto done;
        int marker=bytes[offset++];
        if(marker==0xda || marker==0xd9 || marker==0x00) goto done;
        if(marker==0x01 || (marker>=0xd0 && marker<=0xd7)) continue;
        if(offset+2>(size_t)size) goto done;
        size_t length=AV_RB16(bytes+offset);
        if(length<2 || length>(size_t)size-offset) goto done;
        // All JPEG start-of-frame variants, excluding DHT, JPG, and DAC.
        if(marker>=0xc0 && marker<=0xcf && marker!=0xc4 && marker!=0xc8 && marker!=0xcc) {
            if(length<8 || !bytes[offset+7] || length!=8+3*(size_t)bytes[offset+7]) goto done;
            int height=AV_RB16(bytes+offset+3),width=AV_RB16(bytes+offset+5);
            if(!width || !height) goto done;
            parameters->codec_type=AVMEDIA_TYPE_VIDEO;
            parameters->codec_id=AV_CODEC_ID_MJPEG;
            parameters->width=width; parameters->height=height;
            result=0; goto done;
        }
        offset+=length;
    }
done:
    fclose(file);
    return result;
}
int wrath_add_artwork(AVFormatContext *output, const char *path, const char *extension, WrathToken *token, AVPacket **picture) {
    *picture=NULL;
    if(!path || !path[0]) return 0;
    AVCodecParameters *parameters=avcodec_parameters_alloc();
    AVPacket *packet=av_packet_alloc(); int result;
    if(!packet || !parameters) { result=AVERROR(ENOMEM); goto done; }
    result=load_artwork(path,token,packet,parameters); if(result<0) goto done;
    const char *mime="image/jpeg";
    if(!strcmp(extension,"opus") || !strcmp(extension,"ogg")) {
        int mime_size=(int)strlen(mime),size=32+mime_size+packet->size;
        uint8_t *block=av_malloc(size);
        char *encoded=av_malloc(AV_BASE64_SIZE(size));
        if(!block || !encoded) { av_free(block); av_free(encoded); result=AVERROR(ENOMEM); goto done; }
        uint8_t *p=block;
        AV_WB32(p,3); p+=4; AV_WB32(p,mime_size); p+=4; memcpy(p,mime,mime_size); p+=mime_size;
        AV_WB32(p,0); p+=4;
        AV_WB32(p,parameters->width); p+=4; AV_WB32(p,parameters->height); p+=4;
        AV_WB32(p,24); p+=4; AV_WB32(p,0); p+=4; AV_WB32(p,packet->size); p+=4;
        memcpy(p,packet->data,packet->size);
        av_base64_encode(encoded,AV_BASE64_SIZE(size),block,size);
        av_dict_set(&output->metadata,"METADATA_BLOCK_PICTURE",encoded,0);
        for(unsigned i=0;i<output->nb_streams;i++) if(output->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO)
            av_dict_set(&output->streams[i]->metadata,"METADATA_BLOCK_PICTURE",encoded,0);
        av_free(block); av_free(encoded); result=0;
    } else {
        AVStream *cover=avformat_new_stream(output,NULL);
        if(!cover) { result=AVERROR(ENOMEM); goto done; }
        if(!strcmp(extension,"mkv")) {
            cover->codecpar->codec_type=AVMEDIA_TYPE_ATTACHMENT;
            cover->codecpar->codec_id=parameters->codec_id;
            cover->codecpar->extradata=av_mallocz(packet->size+AV_INPUT_BUFFER_PADDING_SIZE);
            if(!cover->codecpar->extradata) { result=AVERROR(ENOMEM); goto done; }
            memcpy(cover->codecpar->extradata,packet->data,packet->size); cover->codecpar->extradata_size=packet->size;
            av_dict_set(&cover->metadata,"filename",parameters->codec_id==AV_CODEC_ID_PNG ? "cover.png" : "cover.jpg",0);
            av_dict_set(&cover->metadata,"mimetype",mime,0);
        } else {
            result=avcodec_parameters_copy(cover->codecpar,parameters); if(result<0) goto done;
            cover->codecpar->codec_tag=0; cover->disposition=AV_DISPOSITION_ATTACHED_PIC;
            cover->time_base=(AVRational){1,90000};
            av_dict_set(&cover->metadata,"title","Cover",0);
            av_dict_set(&cover->metadata,"comment","Cover (front)",0);
            packet->stream_index=cover->index; packet->pts=0; packet->dts=0; packet->duration=0;
            result=av_packet_ref(&cover->attached_pic,packet); if(result<0) goto done;
            *picture=av_packet_clone(packet); if(!*picture) { result=AVERROR(ENOMEM); goto done; }
        }
        result=0;
    }
done:
    av_packet_free(&packet); avcodec_parameters_free(&parameters);
    return result;
}
