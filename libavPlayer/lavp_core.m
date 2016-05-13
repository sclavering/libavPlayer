/*
 *  LAVPcore.c
 *  libavPlayer
 *
 *  Created by Takashi Mochizuki on 11/06/19.
 *  Copyright 2011 MyCometG3. All rights reserved.
 *
 */
/*
 This file is part of livavPlayer.

 livavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "lavp_common.h"
#include "lavp_core.h"
#include "lavp_video.h"
#include "lavp_queue.h"
#include "lavp_subs.h"
#include "lavp_audio.h"

/* =========================================================== */

int stream_component_open(VideoState *is, int stream_index);
void stream_component_close(VideoState *is, int stream_index);
int is_realtime(AVFormatContext *s);
int read_thread(VideoState *is);
void step_to_next_frame(VideoState *is);

double get_external_clock(VideoState *is);

extern void free_picture(Frame *vp);
extern int audio_open(VideoState *is, int64_t wanted_channel_layout, int wanted_nb_channels, int wanted_sample_rate, struct AudioParams *audio_hw_params);

/* =========================================================== */

#pragma mark -
#pragma mark functions (cmdutils.c)

// extracted function from ffmpeg : cmdutils.c
int check_stream_specifier(AVFormatContext *s, AVStream *st, const char *spec)
{
    int ret = avformat_match_stream_specifier(s, st, spec);
    if (ret < 0)
        av_log(s, AV_LOG_ERROR, "Invalid stream specifier: %s.\n", spec);
    return ret;
}

// extracted function from ffmpeg : cmdutils.c
AVDictionary *filter_codec_opts(AVDictionary *opts, enum AVCodecID codec_id,
                                AVFormatContext *s, AVStream *st, AVCodec *codec)
{
    AVDictionary    *ret = NULL;
    AVDictionaryEntry *t = NULL;
    int            flags = s->oformat ? AV_OPT_FLAG_ENCODING_PARAM
    : AV_OPT_FLAG_DECODING_PARAM;
    char          prefix = 0;
    const AVClass    *cc = avcodec_get_class();

    if (!codec)
        codec            = s->oformat ? avcodec_find_encoder(codec_id)
        : avcodec_find_decoder(codec_id);

    switch (st->codec->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
            prefix  = 'v';
            flags  |= AV_OPT_FLAG_VIDEO_PARAM;
            break;
        case AVMEDIA_TYPE_AUDIO:
            prefix  = 'a';
            flags  |= AV_OPT_FLAG_AUDIO_PARAM;
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            prefix  = 's';
            flags  |= AV_OPT_FLAG_SUBTITLE_PARAM;
            break;
        default:
            break;
    }

    while ((t = av_dict_get(opts, "", t, AV_DICT_IGNORE_SUFFIX))) {
        char *p = strchr(t->key, ':');

        /* check stream specification in opt name */
        if (p)
            switch (check_stream_specifier(s, st, p + 1)) {
                case  1: *p = 0; break;
                case  0:         continue;
                default:         return NULL;
            }

        if (av_opt_find(&cc, t->key, NULL, flags, AV_OPT_SEARCH_FAKE_OBJ) ||
            (codec && codec->priv_class &&
             av_opt_find(&codec->priv_class, t->key, NULL, flags,
                         AV_OPT_SEARCH_FAKE_OBJ)))
            av_dict_set(&ret, t->key, t->value, 0);
        else if (t->key[0] == prefix &&
                 av_opt_find(&cc, t->key + 1, NULL, flags,
                             AV_OPT_SEARCH_FAKE_OBJ))
            av_dict_set(&ret, t->key + 1, t->value, 0);

        if (p)
            *p = ':';
    }
    return ret;
}

// extracted function from ffmpeg : cmdutils.c
AVDictionary **setup_find_stream_info_opts(AVFormatContext *s,
                                           AVDictionary *codec_opts)
{
    int i;
    AVDictionary **opts;

    if (!s->nb_streams)
        return NULL;
    opts = av_mallocz(s->nb_streams * sizeof(*opts));
    if (!opts) {
        av_log(NULL, AV_LOG_ERROR,
               "Could not alloc memory for stream options.\n");
        return NULL;
    }
    for (i = 0; i < s->nb_streams; i++)
        opts[i] = filter_codec_opts(codec_opts, s->streams[i]->codec->codec_id,
                                    s, s->streams[i], NULL);
    return opts;
}

#pragma mark -
#pragma mark functions (read_thread)

/* open a given stream. Return 0 if OK */
int stream_component_open(VideoState *is, int stream_index)
{
    //NSLog(@"DEBUG: stream_component_open(%d)", stream_index);

    AVFormatContext *ic = is->ic;
    AVCodecContext *avctx;
    AVCodec *codec;
    const char *forced_codec_name = NULL;
    AVDictionary *opts;
    AVDictionaryEntry *t = NULL;
    int sample_rate, nb_channels;
    int64_t channel_layout;
    int ret;

    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return -1;
    avctx = ic->streams[stream_index]->codec;

    codec = avcodec_find_decoder(avctx->codec_id);

    //
    if (forced_codec_name)
        codec = avcodec_find_decoder_by_name(forced_codec_name);
    if (!codec) {
        if (forced_codec_name) av_log(NULL, AV_LOG_WARNING,
                                      "No codec could be found with name '%s'\n", forced_codec_name);
        else                   av_log(NULL, AV_LOG_WARNING,
                                      "No codec could be found with id %d\n", avctx->codec_id);
        return -1;
    }

    avctx->codec_id = codec->id;
    avctx->workaround_bugs = 1;
    av_codec_set_lowres(avctx, 0);
    avctx->error_concealment = 3;

    if(codec->capabilities & CODEC_CAP_DR1)
        avctx->flags |= CODEC_FLAG_EMU_EDGE;

    AVDictionary *codec_opts = NULL; // LAVP: Dummy

    opts = filter_codec_opts(codec_opts, avctx->codec_id, ic, ic->streams[stream_index], codec);
    if (!av_dict_get(opts, "threads", NULL, 0))
        av_dict_set(&opts, "threads", "auto", 0);
    if (avctx->codec_type == AVMEDIA_TYPE_VIDEO || avctx->codec_type == AVMEDIA_TYPE_AUDIO)
        av_dict_set(&opts, "refcounted_frames", "1", 0);
    if (avcodec_open2(avctx, codec, &opts) < 0)
        return -1;
    if ((t = av_dict_get(opts, "", NULL, AV_DICT_IGNORE_SUFFIX))) {
        av_log(NULL, AV_LOG_ERROR, "Option %s not found.\n", t->key);
        return AVERROR_OPTION_NOT_FOUND;
    }

    ic->streams[stream_index]->discard = AVDISCARD_DEFAULT;
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            // LAVP: set before audio_open
            is->audio_stream = stream_index;
            is->audio_st = ic->streams[stream_index];

            packet_queue_start(&is->audioq);
            decoder_init(&is->auddec, avctx, &is->audioq, is->continue_read_thread);
            if ((is->ic->iformat->flags & (AVFMT_NOBINSEARCH | AVFMT_NOGENSEARCH | AVFMT_NO_BYTE_SEEK)) && !is->ic->iformat->read_seek) {
                is->auddec.start_pts = is->audio_st->start_time;
                is->auddec.start_pts_tb = is->audio_st->time_base;
            }

            // LAVP: Use a dispatch queue instead of an SDL thread.
            {
                is->audio_queue = dispatch_queue_create("audio", NULL);
                is->audio_group = dispatch_group_create();
                __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
                dispatch_group_async(is->audio_group, is->audio_queue, ^(void) {
                    __strong VideoState* is = weakIs;
                    if(is) audio_thread(is);
                });
            }

            //
            sample_rate    = avctx->sample_rate;
            nb_channels    = avctx->channels;
            channel_layout = avctx->channel_layout;

            /* prepare audio output */
            if ((ret = audio_open(is, channel_layout, nb_channels, sample_rate, &is->audio_tgt)) < 0)
                return ret;
            is->audio_hw_buf_size = ret;
            is->audio_src = is->audio_tgt;
            is->audio_buf_size  = 0;
            is->audio_buf_index = 0;

            /* init averaging filter */
            is->audio_diff_avg_coef = exp(log(0.01) / AUDIO_DIFF_AVG_NB);
            is->audio_diff_avg_count = 0;
            /* since we do not have a precise anough audio fifo fullness,
             we correct audio sync only if larger than this threshold */
            is->audio_diff_threshold = 2.0 * is->audio_hw_buf_size / is->audio_tgt.bytes_per_sec;

            // LAVP: start AudioQueue
            LAVPAudioQueueInit(is, avctx);
            LAVPAudioQueueStart(is);

            break;
        case AVMEDIA_TYPE_VIDEO:
            is->video_stream = stream_index;
            is->video_st = ic->streams[stream_index];

            packet_queue_start(&is->videoq);
            decoder_init(&is->viddec, avctx, &is->videoq, is->continue_read_thread);

            // LAVP: Use a dispatch queue instead of an SDL thread.
            {
                is->video_queue = dispatch_queue_create("video", NULL);
                is->video_group = dispatch_group_create();
                __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
                dispatch_group_async(is->video_group, is->video_queue, ^(void) {
                    __strong VideoState* is = weakIs;
                    if(is) video_thread(is);
                });
            }
            is->queue_attachments_req = 1;
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            is->subtitle_stream = stream_index;
            is->subtitle_st = ic->streams[stream_index];

            packet_queue_start(&is->subtitleq);
            decoder_init(&is->subdec, avctx, &is->subtitleq, is->continue_read_thread);

            // LAVP: Use a dispatch queue instead of an SDL thread.
            {
                is->subtitle_queue = dispatch_queue_create("subtitle", NULL);
                is->subtitle_group = dispatch_group_create();
                __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
                dispatch_group_async(is->subtitle_group, is->subtitle_queue, ^(void) {
                    __strong VideoState* is = weakIs;
                    if(is) subtitle_thread(is);
                });
            }
            break;
        default:
            break;
    }

    //NSLog(@"DEBUG: stream_component_open(%d) done", stream_index);
    return 0;
}

void stream_component_close(VideoState *is, int stream_index)
{
    //NSLog(@"DEBUG: stream_component_close(%d)", stream_index);

    AVFormatContext *ic = is->ic;
    AVCodecContext *avctx;

    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return;
    avctx = ic->streams[stream_index]->codec;

    switch(avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            packet_queue_abort(&is->audioq);
            frame_queue_signal(&is->sampq);

            // LAVP: Stop Audio Queue
            LAVPAudioQueueStop(is);
            LAVPAudioQueueDealloc(is);
            // LAVP: release dispatch queue
            dispatch_group_wait(is->audio_group, DISPATCH_TIME_FOREVER);
            is->audio_group = NULL;
            is->audio_queue = NULL;

            decoder_destroy(&is->auddec);
            packet_queue_flush(&is->audioq);
            swr_free(&is->swr_ctx);
            av_freep(&is->audio_buf1);
            is->audio_buf1_size = 0;
            is->audio_buf = NULL;

            break;
        case AVMEDIA_TYPE_VIDEO:
            packet_queue_abort(&is->videoq);

            /* note: we also signal this mutex to make sure we deblock the
             video thread in all cases */
            frame_queue_signal(&is->pictq);

            // LAVP: release dispatch queue
            dispatch_group_wait(is->video_group, DISPATCH_TIME_FOREVER);
            is->video_group = NULL;
            is->video_queue = NULL;

            decoder_destroy(&is->viddec);
            packet_queue_flush(&is->videoq);
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            packet_queue_abort(&is->subtitleq);

            /* note: we also signal this mutex to make sure we deblock the
             video thread in all cases */
            frame_queue_signal(&is->subpq);

            // LAVP: release dispatch queue
            dispatch_group_wait(is->subtitle_group, DISPATCH_TIME_FOREVER);
            is->subtitle_group = NULL;
            is->subtitle_queue = NULL;

            decoder_destroy(&is->subdec);
            packet_queue_flush(&is->subtitleq);
            break;
        default:
            break;
    }

    ic->streams[stream_index]->discard = AVDISCARD_ALL;
    avcodec_close(avctx);
    switch(avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            is->audio_st = NULL;
            is->audio_stream = -1;
            break;
        case AVMEDIA_TYPE_VIDEO:
            is->video_st = NULL;
            is->video_stream = -1;
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            is->subtitle_st = NULL;
            is->subtitle_stream = -1;
            break;
        default:
            break;
    }

    //NSLog(@"DEBUG: stream_component_close(%d) done", stream_index);
}

static int decode_interrupt_cb(void *ctx)
{
    VideoState *is = (__bridge VideoState *)(ctx);
    return is->abort_request;
}

int is_realtime(AVFormatContext *s)
{
    if(   !strcmp(s->iformat->name, "rtp")
       || !strcmp(s->iformat->name, "rtsp")
       || !strcmp(s->iformat->name, "sdp")
       )
        return 1;

    if(s->pb && (   !strncmp(s->filename, "rtp:", 4)
                 || !strncmp(s->filename, "udp:", 4)
                 )
       )
        return 1;
    return 0;
}

/* this thread gets the stream from the disk or the network */
int read_thread(VideoState* is)
{
    @autoreleasepool {

        int ret;

        int st_index[AVMEDIA_TYPE_NB] = {-1};

        LAVPmutex* wait_mutex = LAVPCreateMutex();

        // LAVP: Choose best stream for Video, Audio, Subtitle
        int vid_index = -1;
        int aud_index = (st_index[AVMEDIA_TYPE_VIDEO]);
        int sub_index = (st_index[AVMEDIA_TYPE_AUDIO] >= 0 ? st_index[AVMEDIA_TYPE_AUDIO] : st_index[AVMEDIA_TYPE_VIDEO]);

        st_index[AVMEDIA_TYPE_VIDEO] = av_find_best_stream(is->ic, AVMEDIA_TYPE_VIDEO, -1, vid_index, NULL, 0);
        st_index[AVMEDIA_TYPE_AUDIO] = av_find_best_stream(is->ic, AVMEDIA_TYPE_AUDIO, -1,  aud_index, NULL , 0);
        st_index[AVMEDIA_TYPE_SUBTITLE] = av_find_best_stream(is->ic, AVMEDIA_TYPE_SUBTITLE, -1, sub_index , NULL, 0);

        /* open the streams */
        if (st_index[AVMEDIA_TYPE_AUDIO] >= 0)
            stream_component_open(is, st_index[AVMEDIA_TYPE_AUDIO]);

        ret = -1;
        if (st_index[AVMEDIA_TYPE_VIDEO] >= 0)
            ret = stream_component_open(is, st_index[AVMEDIA_TYPE_VIDEO]);

        if (st_index[AVMEDIA_TYPE_SUBTITLE] >= 0)
            stream_component_open(is, st_index[AVMEDIA_TYPE_SUBTITLE]);

        if (is->video_stream < 0 && is->audio_stream < 0) {
            av_log(NULL, AV_LOG_FATAL, "Failed to open file '%s' or configure filtergraph\n",
                   is->filename);
            ret = -1;
            goto bail;
        }

        if (is->infinite_buffer < 0 && is->realtime)
            is->infinite_buffer = 1;

        /* ================================================================================== */

        // decode loop
        int eof = 0;
        AVPacket pkt1, *pkt = &pkt1;
        for(;;) {
            @autoreleasepool {
                // Abort
                if (is->abort_request) {
                    break;
                }

                // Pause
                if (is->paused != is->last_paused) {
                    is->last_paused = is->paused;
                    if (is->paused)
                        is->read_pause_return = av_read_pause(is->ic);
                    else
                        av_read_play(is->ic);

                    //NSLog(@"DEBUG: %@", is->paused ? @"paused:YES" : @"paused:NO");
                }

#if CONFIG_RTSP_DEMUXER
                if (is->paused &&
                    (!strcmp(is->ic->iformat->name, "rtsp") ||
                     (is->ic->pb && !strncmp(input_filename, "mmsh:", 5)))) {
                        /* wait 10 ms to avoid trying to get another packet */
                        /* XXX: horrible */
                        usleep(10*1000);
                        continue;
                    }
#endif

                // Seek
                if (is->seek_req) {
                    is->lastPTScopied = -1;
                    int64_t seek_target= is->seek_pos;
                    int64_t seek_min= is->seek_rel > 0 ? seek_target - is->seek_rel + 2: INT64_MIN;
                    int64_t seek_max= is->seek_rel < 0 ? seek_target - is->seek_rel - 2: INT64_MAX;
                    //FIXME the +-2 is due to rounding being not done in the correct direction in generation
                    //      of the seek_pos/seek_rel variables

                    ret = avformat_seek_file(is->ic, -1, seek_min, seek_target, seek_max, is->seek_flags);
                    if (ret < 0) {
                        av_log(NULL, AV_LOG_ERROR,
                               "%s: error while seeking\n", is->ic->filename);
                    }else{
                        if (is->audio_stream >= 0) {
                            packet_queue_flush(&is->audioq);
                            packet_queue_put(&is->audioq, NULL);
                        }
                        if (is->subtitle_stream >= 0) {
                            packet_queue_flush(&is->subtitleq);
                            packet_queue_put(&is->subtitleq, NULL);
                        }
                        if (is->video_stream >= 0) {
                            packet_queue_flush(&is->videoq);
                            packet_queue_put(&is->videoq, NULL);
                        }
                        if (is->seek_flags & AVSEEK_FLAG_BYTE) {
                            set_clock(&is->extclk, NAN, 0);
                        } else {
                            set_clock(&is->extclk, seek_target / (double)AV_TIME_BASE, 0);
                        }
                    }
                    is->seek_req = 0;
                    is->queue_attachments_req = 1;
                    eof = 0;

                    if (is->paused)
                        step_to_next_frame(is);
                }

                if (is->queue_attachments_req) {
                    if (is->video_st && is->video_st->disposition & AV_DISPOSITION_ATTACHED_PIC) {
                        AVPacket copy;
                        if ((ret = av_copy_packet(&copy, &is->video_st->attached_pic)) < 0)
                            goto bail;
                        packet_queue_put(&is->videoq, &copy);
                        packet_queue_put_nullpacket(&is->videoq, is->video_stream);
                    }
                    is->queue_attachments_req = 0;
                }

                /* if the queue are full, no need to read more */
                if (is->infinite_buffer<1 &&
                    (is->audioq.size + is->videoq.size + is->subtitleq.size > MAX_QUEUE_SIZE
                     || (   (is->audioq   .nb_packets > MIN_FRAMES || is->audio_stream < 0 || is->audioq.abort_request)
                         && (is->videoq   .nb_packets > MIN_FRAMES || is->video_stream < 0 || is->videoq.abort_request
                             || (is->video_st && is->video_st->disposition & AV_DISPOSITION_ATTACHED_PIC))
                         && (is->subtitleq.nb_packets > MIN_FRAMES || is->subtitle_stream < 0 || is->subtitleq.abort_request)))) {
                         /* wait 10 ms */
                         LAVPLockMutex(wait_mutex);
                         LAVPCondWaitTimeout(is->continue_read_thread, wait_mutex, 10);
                         LAVPUnlockMutex(wait_mutex);
                         continue;
                     }

                if (!is->paused &&
                    (!is->audio_st || (is->auddec.finished == is->audioq.serial && frame_queue_nb_remaining(&is->sampq) == 0)) &&
                    (!is->video_st || (is->viddec.finished == is->videoq.serial && frame_queue_nb_remaining(&is->pictq) == 0))) {
                    // LAVP: force stream paused on EOF
                    stream_pause(is);

                    [is->decoder haveReachedEOF];
                }

                ret = av_read_frame(is->ic, pkt);
                if (ret < 0) {
                    if ((ret == AVERROR_EOF || avio_feof(is->ic->pb)) && !eof) {
                        if (is->video_stream >= 0)
                            packet_queue_put_nullpacket(&is->videoq, is->video_stream);
                        if (is->audio_stream >= 0)
                            packet_queue_put_nullpacket(&is->audioq, is->audio_stream);
                        if (is->subtitle_stream >= 0)
                            packet_queue_put_nullpacket(&is->subtitleq, is->subtitle_stream);
                        eof = 1;
                    }
                    if (is->ic->pb && is->ic->pb->error) {
                        break;
                    }
                    LAVPLockMutex(wait_mutex);
                    LAVPCondWaitTimeout(is->continue_read_thread, wait_mutex, 10);
                    LAVPUnlockMutex(wait_mutex);
                    continue;
                } else {
                    eof = 0;
                }

                // Queue packet
                int64_t start_time = AV_NOPTS_VALUE; // LAVP:
                int64_t duration = AV_NOPTS_VALUE; // LAVP:
                int64_t stream_start_time; // LAVP:
                int pkt_in_play_range; // LAVP:

                /* check if packet is in play range specified by user, then queue, otherwise discard */
                stream_start_time = is->ic->streams[pkt->stream_index]->start_time; // LAVP:
                int64_t pkt_ts = pkt->pts == AV_NOPTS_VALUE ? pkt->dts : pkt->pts;
                pkt_in_play_range = duration == AV_NOPTS_VALUE ||
                        (pkt_ts - (stream_start_time != AV_NOPTS_VALUE ? stream_start_time : 0)) *
                        av_q2d(is->ic->streams[pkt->stream_index]->time_base) -
                        (double)(start_time != AV_NOPTS_VALUE ? start_time : 0) / 1000000
                        <= ((double)duration / 1000000);
                if (pkt->stream_index == is->audio_stream && pkt_in_play_range) {
                    packet_queue_put(&is->audioq, pkt);
                } else if (pkt->stream_index == is->video_stream && pkt_in_play_range && !(is->video_st && is->video_st->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                    packet_queue_put(&is->videoq, pkt);
                } else if (pkt->stream_index == is->subtitle_stream && pkt_in_play_range) {
                    packet_queue_put(&is->subtitleq, pkt);
                } else {
                    av_free_packet(pkt);
                }

            }
        }

        /* ================================================================================== */

        /* wait until the end */
        while (!is->abort_request) {
            usleep(10*1000);
        }

        // finish thread
        ret = 0;

    bail:
        /* close each stream */
        if (is->audio_stream >= 0)
            stream_component_close(is, is->audio_stream);
        if (is->video_stream >= 0)
            stream_component_close(is, is->video_stream);
        if (is->subtitle_stream >= 0)
            stream_component_close(is, is->subtitle_stream);

        LAVPDestroyMutex(wait_mutex);

        return ret;
    }
}

#pragma mark -
#pragma mark functions (main_thread)


static int lockmgr(void **mtx, enum AVLockOp op)
{
    switch(op) {
        case AV_LOCK_CREATE:
            *mtx = LAVPCreateMutex();
            if(!*mtx)
                return 1;
            return 0;
        case AV_LOCK_OBTAIN:
            LAVPLockMutex(*mtx);
            return 0;
        case AV_LOCK_RELEASE:
            LAVPUnlockMutex(*mtx);
            return 0;
        case AV_LOCK_DESTROY:
            LAVPDestroyMutex(*mtx);
            return 0;
    }
    return 1;
}

double get_clock(Clock *c)
{
    if (*c->queue_serial != c->serial)
        return NAN;
    if (c->paused) {
        return c->pts;
    } else {
        double time = av_gettime_relative() / 1000000.0;
        return c->pts_drift + time - (time - c->last_updated) * (1.0 - c->speed);
    }
}

void set_clock_at(Clock *c, double pts, int serial, double time)
{
    c->pts = pts;
    c->last_updated = time;
    c->pts_drift = c->pts - time;
    c->serial = serial;
}

void set_clock(Clock *c, double pts, int serial)
{
    double time = av_gettime_relative() / 1000000.0;
    set_clock_at(c, pts, serial, time);
}

void set_clock_speed(Clock *c, double speed)
{
    set_clock(c, get_clock(c), c->serial);
    c->speed = speed;
}

void init_clock(Clock *c, int *queue_serial)
{
    c->speed = 1.0;
    c->paused = 0;
    c->queue_serial = queue_serial;
    set_clock(c, NAN, -1);
}

void sync_clock_to_slave(Clock *c, Clock *slave)
{
    double clock = get_clock(c);
    double slave_clock = get_clock(slave);
    if (!isnan(slave_clock) && (isnan(clock) || fabs(clock - slave_clock) > AV_NOSYNC_THRESHOLD))
        set_clock(c, slave_clock, slave->serial);
}

int get_master_sync_type(VideoState *is) {
    if (is->av_sync_type == AV_SYNC_VIDEO_MASTER) {
        if (is->video_st)
            return AV_SYNC_VIDEO_MASTER;
        else
            return AV_SYNC_AUDIO_MASTER;
    } else if (is->av_sync_type == AV_SYNC_AUDIO_MASTER) {
        if (is->audio_st)
            return AV_SYNC_AUDIO_MASTER;
        else
            return AV_SYNC_EXTERNAL_CLOCK;
    } else {
        return AV_SYNC_EXTERNAL_CLOCK;
    }
}

/* get the current master clock value */
double get_master_clock(VideoState *is)
{
    //NSLog(@"DEBUG: vidclk:%8.3f audclk:%8.3f", (double_t)get_clock(&is->vidclk), (double_t)get_clock(&is->audclk));

    double val;
    switch (get_master_sync_type(is)) {
        case AV_SYNC_VIDEO_MASTER:
            val = get_clock(&is->vidclk);
            break;
        case AV_SYNC_AUDIO_MASTER:
            val = get_clock(&is->audclk);
            break;
        default:
            val = get_clock(&is->extclk);
            break;
    }
    return val;
}

void check_external_clock_speed(VideoState *is) {
    if ((is->video_stream >= 0 && is->videoq.nb_packets <= MIN_FRAMES / 2) ||
        (is->audio_stream >= 0 && is->audioq.nb_packets <= MIN_FRAMES / 2)) {
        set_clock_speed(&is->extclk, FFMAX(EXTERNAL_CLOCK_SPEED_MIN, is->extclk.speed - EXTERNAL_CLOCK_SPEED_STEP));
    } else if ((is->video_stream < 0 || is->videoq.nb_packets > MIN_FRAMES * 2) &&
               (is->audio_stream < 0 || is->audioq.nb_packets > MIN_FRAMES * 2)) {
        set_clock_speed(&is->extclk, FFMIN(EXTERNAL_CLOCK_SPEED_MAX, is->extclk.speed + EXTERNAL_CLOCK_SPEED_STEP));
    } else {
        double speed = is->extclk.speed;
        if (speed != 1.0)
            set_clock_speed(&is->extclk, speed + EXTERNAL_CLOCK_SPEED_STEP * (1.0 - speed) / fabs(1.0 - speed));
    }
}

/* seek in the stream */
void stream_seek(VideoState *is, int64_t pos, int64_t rel, int seek_by_bytes)
{
    if (!is->seek_req) {
        is->seek_pos = pos;
        is->seek_rel = rel;
        is->seek_flags &= ~AVSEEK_FLAG_BYTE;
        if (seek_by_bytes)
            is->seek_flags |= AVSEEK_FLAG_BYTE;
        is->seek_req = 1;

        is->remaining_time = 0.0; // LAVP: reset remaining time

        LAVPCondSignal(is->continue_read_thread);
    }
}

/* pause or resume the video */
void stream_toggle_pause(VideoState *is)
{
    if (is->paused) {
        is->frame_timer += av_gettime_relative() / 1000000.0 + is->vidclk.pts_drift - is->vidclk.pts;
        if (is->read_pause_return != AVERROR(ENOSYS)) {
            is->vidclk.paused = 0;
        }
        set_clock(&is->vidclk, get_clock(&is->vidclk), is->vidclk.serial);
    }
    set_clock(&is->extclk, get_clock(&is->extclk), is->extclk.serial);
    is->paused = is->audclk.paused = is->vidclk.paused = is->extclk.paused = !is->paused;
}

void toggle_pause(VideoState *is)
{
    stream_toggle_pause(is);
    is->step = 0;
}

void step_to_next_frame(VideoState *is)
{
    /* if the stream is paused unpause it, then step */
    if (is->paused)
        stream_toggle_pause(is);
    is->step = 1;
}

/* pause or resume the video */
void stream_pause(VideoState *is)
{
    toggle_pause(is);

    if (is->audio_stream >= 0) {
        if (is->paused)
            LAVPAudioQueuePause(is);
        else
            LAVPAudioQueueStart(is);
    }

    //NSLog(@"DEBUG: stream_pause = %s at %3.3f", (is->paused ? "paused" : "play"), get_master_clock(is));
}

void stream_close(VideoState *is)
{
    /* original: stream_close() */
    if (is) {
        /* XXX: use a special url_shutdown call to abort parse cleanly */
        is->abort_request = 1;

        dispatch_group_wait(is->parse_group, DISPATCH_TIME_FOREVER);
        {
            is->parse_group = NULL;
            is->parse_queue = NULL;
        }
        //
        packet_queue_destroy(&is->videoq);
        packet_queue_destroy(&is->audioq);
        packet_queue_destroy(&is->subtitleq);

        /* free all pictures */
        frame_queue_destory(&is->pictq);
        frame_queue_destory(&is->sampq);
        frame_queue_destory(&is->subpq);

        LAVPDestroyCond(is->continue_read_thread);

        // LAVP: free image converter
        if (is->img_convert_ctx)
            sws_freeContext(is->img_convert_ctx);

        // LAVP: free format context
        if (is->ic) {
            avformat_close_input(&is->ic);
            is->ic = NULL;
        }

        is->decoder = NULL;
    }

    av_lockmgr_register(NULL);
    //
    avformat_network_deinit();
    av_log(NULL, AV_LOG_QUIET, "%s", "");
}

VideoState* stream_open(/* LAVPDecoder * */ id decoder, NSURL *sourceURL)
{
    int err, i, ret;

    // Initialize VideoState struct
    VideoState *is = [[VideoState alloc] init];

    const char* path = [[sourceURL path] fileSystemRepresentation];
    if (path) {
        is->filename = strdup(path);
    }

    /* ======================================== */

    is->decoder = decoder;
    is->lastPTScopied = -1;

    is->infinite_buffer = -1;
    is->rdftspeed = 0.02;

    is->paused = 0;
    is->playRate = 1.0;

    is->last_video_stream = is->video_stream = -1;
    is->last_audio_stream = is->audio_stream = -1;
    is->last_subtitle_stream = is->subtitle_stream = -1;

    /* ======================================== */

    /* original: main() */
    {
        av_log_set_flags(AV_LOG_SKIP_REPEATED);

        /* register all codecs, demux and protocols */
        av_register_all();
        avformat_network_init();

        //
        if (av_lockmgr_register(lockmgr)) {
            av_log(NULL, AV_LOG_FATAL, "Could not initialize lock manager!\n");
            goto bail;
        }
    }

    /* ======================================== */

    /* original: opt_format() */
    // TODO
    const char * extension = [[sourceURL pathExtension] cStringUsingEncoding:NSASCIIStringEncoding];

    // LAVP: Guess file format
    if (extension) {
        AVInputFormat *file_iformat = av_find_input_format(extension);
        if (file_iformat) {
            is->iformat = file_iformat;
        }
    }

    /* ======================================== */

    /* original: read_thread() */
    // Open file
    {
        AVFormatContext *ic = NULL;
        AVDictionaryEntry *t = NULL;
        AVDictionary *format_opts = NULL; // LAVP: difine as local value

        ic = avformat_alloc_context();
        ic->interrupt_callback.callback = decode_interrupt_cb;
        ic->interrupt_callback.opaque = (__bridge void *)(is);
        err = avformat_open_input(&ic, is->filename, is->iformat, &format_opts);
        if (err < 0) {
            // LAVP: inline for print_error(is->filename, err);
            {
                char errbuf[128];
                const char *errbuf_ptr = errbuf;

                if (av_strerror(err, errbuf, sizeof(errbuf)) < 0)
                    errbuf_ptr = strerror(AVUNERROR(err));
                av_log(NULL, AV_LOG_ERROR, "%s: %s\n", is->filename, errbuf_ptr);
            }
            ret = -1;
            goto bail;
        }
        if ((t = av_dict_get(format_opts, "", NULL, AV_DICT_IGNORE_SUFFIX))) {
            av_log(NULL, AV_LOG_ERROR, "Option %s not found.\n", t->key);
            ret = AVERROR_OPTION_NOT_FOUND;
            goto bail;
        }
        is->ic = ic;
    }

    // Examine stream info
    {
        AVDictionary **opts;
        AVDictionary *codec_opts = NULL; // LAVP: Dummy
        int orig_nb_streams;

        opts = setup_find_stream_info_opts(is->ic, codec_opts);
        orig_nb_streams = is->ic->nb_streams;

        err = avformat_find_stream_info(is->ic, opts);
        if (err < 0) {
            av_log(NULL, AV_LOG_WARNING,
                   "%s: could not find codec parameters\n", is->filename);
            ret = -1;
            goto bail;
        }

        for (i = 0; i < orig_nb_streams; i++)
            av_dict_free(&opts[i]);
        av_freep(&opts);
    }

    if (is->ic->pb)
        is->ic->pb->eof_reached = 0; // FIXME hack, ffplay maybe should not use avio_feof() to test for the end

    is->seek_by_bytes = !!(is->ic->iformat->flags & AVFMT_TS_DISCONT) && strcmp("ogg", is->ic->iformat->name);

    is->max_frame_duration = (is->ic->iformat->flags & AVFMT_TS_DISCONT) ? 10.0 : 3600.0;

    //

    is->realtime = is_realtime(is->ic);

    for (int i = 0; i < is->ic->nb_streams; i++)
        is->ic->streams[i]->discard = AVDISCARD_ALL;

    // LAVP: av_find_best_stream is moved to read_thread()

    /* ======================================== */

    /* original: stream_open() */
    {
        if (frame_queue_init(&is->pictq, &is->videoq, VIDEO_PICTURE_QUEUE_SIZE, 1) < 0)
            goto fail;
        if (frame_queue_init(&is->subpq, &is->subtitleq, SUBPICTURE_QUEUE_SIZE, 0) < 0)
            goto fail;
        if (frame_queue_init(&is->sampq, &is->audioq, SAMPLE_QUEUE_SIZE, 1) < 0)
            goto fail;

        packet_queue_init(&is->audioq);
        packet_queue_init(&is->videoq);
        packet_queue_init(&is->subtitleq);

        is->continue_read_thread = LAVPCreateCond();

        //
        init_clock(&is->vidclk, &is->videoq.serial);
        init_clock(&is->audclk, &is->audioq.serial);
        init_clock(&is->extclk, &is->extclk.serial);

        is->audio_clock_serial = -1;
        is->av_sync_type = AV_SYNC_AUDIO_MASTER; // LAVP: fixed value

        // LAVP: Use a dispatch queue instead of an SDL thread.
        is->parse_queue = dispatch_queue_create("parse", NULL);
        is->parse_group = dispatch_group_create();
        {
            __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
            dispatch_group_async(is->parse_group, is->parse_queue, ^(void) {
                __strong VideoState* is = weakIs;
                if(is) read_thread(is);
            });
        }
    }
    return is;

bail:
    av_log(NULL, AV_LOG_ERROR, "ret = %d, err = %d\n", ret, err);
    if (is->filename)
        free(is->filename);
    is = NULL;
    return NULL;

fail:
    stream_close(is);
    return NULL;
}

/*
 TODO:
 stream_cycle_channel()
 toggle_audio_display()
 */

double_t stream_playRate(VideoState *is)
{
    return is->playRate;
}

void stream_setPlayRate(VideoState *is, double_t newRate)
{
    assert(newRate > 0.0);

    is->playRate = newRate;

    set_clock_speed(&is->vidclk, newRate);
    set_clock_speed(&is->audclk, newRate);
    set_clock_speed(&is->extclk, newRate);
}
