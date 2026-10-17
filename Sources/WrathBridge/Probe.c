#include "WrathBridge.h"
#ifdef __APPLE__
#include <AetherLibavformat/avformat.h>
#include <AetherLibavutil/bprint.h>
#else
#include <libavformat/avformat.h>
#include <libavutil/bprint.h>
#endif
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int interrupted(void *opaque) { return wrath_is_cancelled(opaque); }
static void json_string(AVBPrint *json, const char *value) {
    if(!value || !value[0]) { av_bprintf(json,"null"); return; }
    av_bprintf(json,"\"");
    for(const unsigned char *p=(const unsigned char *)value;*p;p++) {
        if(*p=='"' || *p=='\\') av_bprintf(json,"\\%c",*p);
        else if(*p<32) av_bprintf(json,"\\u%04x",*p);
        else av_bprint_chars(json,*p,1);
    }
    av_bprintf(json,"\"");
}
char *wrath_probe_media(const char *path, WrathToken *token) {
    if(!path || !path[0] || strstr(path,"://") || wrath_is_cancelled(token)) return NULL;
    AVFormatContext *input=avformat_alloc_context();
    if(!input) return NULL;
    input->interrupt_callback=(AVIOInterruptCB){interrupted,token};
    AVDictionary *options=NULL;
    av_dict_set(&options,"protocol_whitelist","file",0);
    av_dict_set(&options,"probesize","1048576",0);
    av_dict_set(&options,"analyzeduration","1000000",0);
    int status=avformat_open_input(&input,path,NULL,&options);
    av_dict_free(&options);
    if(status<0) { avformat_close_input(&input); return NULL; }
    status=avformat_find_stream_info(input,NULL);
    if(status<0 || wrath_is_cancelled(token)) { avformat_close_input(&input); return NULL; }
    AVCodecParameters *video=NULL,*audio=NULL;
    for(unsigned i=0;i<input->nb_streams;i++) {
        AVStream *stream=input->streams[i];
        if(stream->codecpar->codec_type==AVMEDIA_TYPE_VIDEO && !(stream->disposition&AV_DISPOSITION_ATTACHED_PIC) && !video)
            video=stream->codecpar;
        if(stream->codecpar->codec_type==AVMEDIA_TYPE_AUDIO && !audio) audio=stream->codecpar;
    }
    AVBPrint json;
    av_bprint_init(&json,256,65536);
    av_bprintf(&json,"{\"duration\":");
    if(input->duration!=AV_NOPTS_VALUE && input->duration>0) av_bprintf(&json,"%.6f",input->duration/(double)AV_TIME_BASE);
    else av_bprintf(&json,"null");
    if(video && video->width>0 && video->height>0) av_bprintf(&json,",\"width\":%d,\"height\":%d",video->width,video->height);
    else av_bprintf(&json,",\"width\":null,\"height\":null");
    av_bprintf(&json,",\"videoCodec\":"); json_string(&json,video ? avcodec_get_name(video->codec_id) : NULL);
    av_bprintf(&json,",\"audioCodec\":"); json_string(&json,audio ? avcodec_get_name(audio->codec_id) : NULL);
    av_bprintf(&json,",\"subtitles\":[");
    int count=0;
    for(unsigned i=0;i<input->nb_streams;i++) {
        AVStream *stream=input->streams[i];
        if(stream->codecpar->codec_type!=AVMEDIA_TYPE_SUBTITLE) continue;
        AVDictionaryEntry *language=av_dict_get(stream->metadata,"language",NULL,0);
        AVDictionaryEntry *name=av_dict_get(stream->metadata,"title",NULL,0);
        if(!name) name=av_dict_get(stream->metadata,"handler_name",NULL,0);
        av_bprintf(&json,"%s{\"language\":",count++ ? "," : ""); json_string(&json,language ? language->value : NULL);
        av_bprintf(&json,",\"name\":"); json_string(&json,name ? name->value : NULL);
        av_bprintf(&json,"}");
    }
    av_bprintf(&json,"]}");
    char *result=NULL;
    if(av_bprint_is_complete(&json) && !wrath_is_cancelled(token)) {
        result=malloc(json.len+1);
        if(result) memcpy(result,json.str,json.len+1);
    }
    av_bprint_finalize(&json,NULL);
    avformat_close_input(&input);
    return result;
}
