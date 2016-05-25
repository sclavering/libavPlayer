/*
 *  LAVPcore.c
 *  libavPlayer
 *
 *  Created by Takashi Mochizuki on 11/06/19.
 *  Copyright 2011 MyCometG3. All rights reserved.
 *
 */
/*
 This file is part of libavPlayer.

 libavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 libavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "lavp_common.h"
#import "lavp_core.h"
#import "lavp_video.h"
#import "packetqueue.h"
#import "lavp_audio.h"

#import "LAVPMovie+Internal.h"


/* =========================================================== */

int stream_component_open(VideoState *is, int stream_index);
void stream_component_close(VideoState *is, int stream_index);
int is_realtime(AVFormatContext *s);
int read_thread(VideoState *is);

/* =========================================================== */

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
    AVDictionary *opts = NULL;
    int sample_rate, nb_channels;
    int64_t channel_layout;
    int ret;

    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return -1;

    avctx = avcodec_alloc_context3(NULL);
    if (!avctx)
        return AVERROR(ENOMEM);

    ret = avcodec_parameters_to_context(avctx, ic->streams[stream_index]->codecpar);
    if (ret < 0)
        goto fail;
    av_codec_set_pkt_timebase(avctx, ic->streams[stream_index]->time_base);

    codec = avcodec_find_decoder(avctx->codec_id);

    //
    if (forced_codec_name)
        codec = avcodec_find_decoder_by_name(forced_codec_name);
    if (!codec) {
        if (forced_codec_name) av_log(NULL, AV_LOG_WARNING,
                                      "No codec could be found with name '%s'\n", forced_codec_name);
        else                   av_log(NULL, AV_LOG_WARNING,
                                      "No codec could be found with id %d\n", avctx->codec_id);
        ret = AVERROR(EINVAL);
        goto fail;
    }

    avctx->codec_id = codec->id;
    avctx->workaround_bugs = 1;
    av_codec_set_lowres(avctx, 0);
    avctx->error_concealment = 3;

    av_dict_set(&opts, "threads", "auto", 0);
    av_dict_set(&opts, "refcounted_frames", "1", 0);
    if (avcodec_open2(avctx, codec, &opts) < 0)
        goto fail;

    is->eof = 0;
    ic->streams[stream_index]->discard = AVDISCARD_DEFAULT;
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            // LAVP: set before audio_open
            is->audio_stream = stream_index;
            is->audio_st = ic->streams[stream_index];

            is->auddec = [[Decoder alloc] init];
            decoder_init(is->auddec, avctx, &is->audioq, is->continue_read_thread);
            if ((is->ic->iformat->flags & (AVFMT_NOBINSEARCH | AVFMT_NOGENSEARCH | AVFMT_NO_BYTE_SEEK)) && !is->ic->iformat->read_seek) {
                is->auddec->start_pts = is->audio_st->start_time;
                is->auddec->start_pts_tb = is->audio_st->time_base;
            }
            decoder_start(is->auddec, audio_thread, is);

            sample_rate    = avctx->sample_rate;
            nb_channels    = avctx->channels;
            channel_layout = avctx->channel_layout;

            /* prepare audio output */
            if ((ret = audio_open(is, channel_layout, nb_channels, sample_rate, &is->audio_tgt)) < 0)
                goto out;
            is->audio_hw_buf_size = ret;
            is->audio_src = is->audio_tgt;
            is->audio_buf_size  = 0;
            is->audio_buf_index = 0;

            // LAVP: start AudioQueue
            LAVPAudioQueueInit(is, avctx);
            LAVPAudioQueueStart(is);

            break;
        case AVMEDIA_TYPE_VIDEO:
            is->video_stream = stream_index;
            is->video_st = ic->streams[stream_index];
            is->width = is->video_st->codecpar->width;
            is->height = is->video_st->codecpar->height;

            is->viddec = [[Decoder alloc] init];
            decoder_init(is->viddec, avctx, &is->videoq, is->continue_read_thread);
            decoder_start(is->viddec, video_thread, is);

            is->queue_attachments_req = 1;
            break;
        default:
            break;
    }
    goto out;

fail:
    avcodec_free_context(&avctx);
out:
    av_dict_free(&opts);

    return 0;
}

void stream_component_close(VideoState *is, int stream_index)
{
    //NSLog(@"DEBUG: stream_component_close(%d)", stream_index);

    AVFormatContext *ic = is->ic;
    AVCodecParameters *codecpar;

    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return;
    codecpar = ic->streams[stream_index]->codecpar;

    switch (codecpar->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            decoder_abort(is->auddec, &is->sampq);

            // LAVP: Stop Audio Queue
            LAVPAudioQueueStop(is);
            LAVPAudioQueueDealloc(is);

            decoder_destroy(is->auddec);
            swr_free(&is->swr_ctx);
            av_freep(&is->audio_buf1);
            is->audio_buf1_size = 0;
            is->audio_buf = NULL;

            break;
        case AVMEDIA_TYPE_VIDEO:
            decoder_abort(is->viddec, &is->pictq);
            decoder_destroy(is->viddec);
            break;
        default:
            break;
    }

    ic->streams[stream_index]->discard = AVDISCARD_ALL;
    switch (codecpar->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            is->audio_st = NULL;
            is->audio_stream = -1;
            break;
        case AVMEDIA_TYPE_VIDEO:
            is->video_st = NULL;
            is->video_stream = -1;
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

        pthread_mutex_t* wait_mutex = lavp_pthread_mutex_create();

        // LAVP: Choose best stream for Video, Audio
        int vid_index = -1;
        int aud_index = (st_index[AVMEDIA_TYPE_VIDEO]);

        st_index[AVMEDIA_TYPE_VIDEO] = av_find_best_stream(is->ic, AVMEDIA_TYPE_VIDEO, -1, vid_index, NULL, 0);
        st_index[AVMEDIA_TYPE_AUDIO] = av_find_best_stream(is->ic, AVMEDIA_TYPE_AUDIO, -1,  aud_index, NULL , 0);

        /* open the streams */
        if (st_index[AVMEDIA_TYPE_AUDIO] >= 0)
            stream_component_open(is, st_index[AVMEDIA_TYPE_AUDIO]);

        ret = -1;
        if (st_index[AVMEDIA_TYPE_VIDEO] >= 0)
            ret = stream_component_open(is, st_index[AVMEDIA_TYPE_VIDEO]);

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

                // Seek
                if (is->seek_req) {
                    is->last_frame = NULL;
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
                            packet_queue_put(&is->audioq, &flush_pkt);
                        }
                        if (is->video_stream >= 0) {
                            packet_queue_flush(&is->videoq);
                            packet_queue_put(&is->videoq, &flush_pkt);
                        }
                    }
                    is->seek_req = 0;
                    is->queue_attachments_req = 1;
                    is->eof = 0;
                    if (is->paused) {
                        lavp_set_paused_internal(is, false);
                        is->is_temporarily_unpaused_to_handle_seeking = true;
                    }
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
                    (is->audioq.size + is->videoq.size > MAX_QUEUE_SIZE
                     || (   (is->audioq   .nb_packets > MIN_FRAMES || is->audio_stream < 0 || is->audioq.abort_request)
                         && (is->videoq   .nb_packets > MIN_FRAMES || is->video_stream < 0 || is->videoq.abort_request
                             || (is->video_st && is->video_st->disposition & AV_DISPOSITION_ATTACHED_PIC))
                         ))) {
                         /* wait 10 ms */
                         pthread_mutex_lock(wait_mutex);
                         lavp_pthread_cond_wait_with_timeout(is->continue_read_thread, wait_mutex, 10);
                         pthread_mutex_unlock(wait_mutex);
                         continue;
                     }

                if (!is->paused &&
                    (!is->audio_st || (is->auddec->finished == is->audioq.serial && frame_queue_nb_remaining(&is->sampq) == 0)) &&
                    (!is->video_st || (is->viddec->finished == is->videoq.serial && frame_queue_nb_remaining(&is->pictq) == 0))) {
                    // LAVP: force stream paused on EOF
                    lavp_set_paused(is, true);
                }

                ret = av_read_frame(is->ic, pkt);
                if (ret < 0) {
                    if ((ret == AVERROR_EOF || avio_feof(is->ic->pb)) && !is->eof) {
                        if (is->video_stream >= 0)
                            packet_queue_put_nullpacket(&is->videoq, is->video_stream);
                        if (is->audio_stream >= 0)
                            packet_queue_put_nullpacket(&is->audioq, is->audio_stream);
                        is->eof = 1;
                    }
                    if (is->ic->pb && is->ic->pb->error)
                        break;
                    pthread_mutex_lock(wait_mutex);
                    lavp_pthread_cond_wait_with_timeout(is->continue_read_thread, wait_mutex, 10);
                    pthread_mutex_unlock(wait_mutex);
                    continue;
                } else {
                    is->eof = 0;
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
                } else if (pkt->stream_index == is->video_stream && pkt_in_play_range
                           && !(is->video_st && is->video_st->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                    packet_queue_put(&is->videoq, pkt);
                } else {
                    av_packet_unref(pkt);
                }
            }
        }

        /* ================================================================================== */

        // finish thread
        ret = 0;

    bail:
        lavp_pthread_mutex_destroy(wait_mutex);

        return ret;
    }
}

#pragma mark -
#pragma mark functions (main_thread)


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

/* get the current master clock value */
double get_master_clock(VideoState *is)
{
    //NSLog(@"DEBUG: vidclk:%8.3f audclk:%8.3f", (double)get_clock(&is->vidclk), (double)get_clock(&is->audclk));
    return get_clock(&is->audclk);
}

/* seek in the stream */
void stream_seek(VideoState *is, int64_t pos, int64_t rel)
{
    if (!is->seek_req) {
        is->seek_pos = pos;
        is->seek_rel = rel;
        is->seek_flags &= ~AVSEEK_FLAG_BYTE;
        is->seek_req = 1;
        is->remaining_time = 0.0; // LAVP: reset remaining time
        pthread_cond_signal(is->continue_read_thread);
    }
}

void lavp_set_paused_internal(VideoState *is, bool pause)
{
    if(pause == is->paused)
        return;
    is->is_temporarily_unpaused_to_handle_seeking = false;
    if (is->paused && !pause) {
        is->frame_timer += av_gettime_relative() / 1000000.0 - is->vidclk.last_updated;
        if (is->read_pause_return != AVERROR(ENOSYS)) is->vidclk.paused = 0;
        set_clock(&is->vidclk, get_clock(&is->vidclk), is->vidclk.serial);
    }
    is->paused = is->audclk.paused = is->vidclk.paused = pause;
    if (is->audio_stream >= 0) {
        if (is->paused)
            LAVPAudioQueuePause(is);
        else
            LAVPAudioQueueStart(is);
    }
}

void lavp_set_paused(VideoState *is, bool pause)
{
    lavp_set_paused_internal(is, pause);
    __strong id<LAVPMovieOutput> movieOutput = is ? is->weakOutput : NULL;
    if(movieOutput) [movieOutput movieOutputNeedsContinuousUpdating:!pause];
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

        /* close each stream */
        if (is->audio_stream >= 0)
            stream_component_close(is, is->audio_stream);
        if (is->video_stream >= 0)
            stream_component_close(is, is->video_stream);

        avformat_close_input(&is->ic);

        packet_queue_destroy(&is->videoq);
        packet_queue_destroy(&is->audioq);

        /* free all pictures */
        frame_queue_destory(&is->pictq);
        frame_queue_destory(&is->sampq);

        lavp_pthread_cond_destroy(is->continue_read_thread);

        is->weakOutput = NULL;
    }

    avformat_network_deinit();
    av_log(NULL, AV_LOG_QUIET, "%s", "");
}

VideoState* stream_open(NSURL *sourceURL)
{
    // LAVP: in ffplay.c this is done only once, in main().  Re-doing it ought to be fine, as av_init_packet() is documented as not modifying .data
    av_init_packet(&flush_pkt);
    flush_pkt.data = (uint8_t *)&flush_pkt;

    int err, ret;

    // Initialize VideoState struct
    VideoState *is = [[VideoState alloc] init];

    const char* path = [[sourceURL path] fileSystemRepresentation];
    if (path) {
        is->filename = strdup(path);
    }

    /* ======================================== */

    is->volume_percent = 100;

    is->weakOutput = NULL;
    is->last_frame = NULL;

    is->infinite_buffer = -1;

    is->paused = 0;
    is->playbackSpeedPercent = 100;
    is->playRate = 1.0;

    is->video_stream = -1;
    is->audio_stream = -1;
    is->eof = 0;

    /* ======================================== */

    /* original: main() */
    {
        av_log_set_flags(AV_LOG_SKIP_REPEATED);

        /* register all codecs, demux and protocols */
        av_register_all();
        avformat_network_init();
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
        err = avformat_find_stream_info(is->ic, NULL);
        if (err < 0) {
            av_log(NULL, AV_LOG_WARNING,
                   "%s: could not find codec parameters\n", is->filename);
            ret = -1;
            goto bail;
        }
    }

    if (is->ic->pb)
        is->ic->pb->eof_reached = 0; // FIXME hack, ffplay maybe should not use avio_feof() to test for the end

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
        if (frame_queue_init(&is->sampq, &is->audioq, SAMPLE_QUEUE_SIZE, 1) < 0)
            goto fail;

        packet_queue_init(&is->audioq);
        packet_queue_init(&is->videoq);

        is->continue_read_thread = lavp_pthread_cond_create();

        //
        init_clock(&is->vidclk, &is->videoq.serial);
        init_clock(&is->audclk, &is->audioq.serial);

        is->audio_clock_serial = -1;

        // LAVP: Use a dispatch queue instead of an SDL thread.
        is->parse_queue = dispatch_queue_create("parse", NULL);
        is->parse_group = dispatch_group_create();
        {
            __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
            dispatch_group_async(is->parse_group, is->parse_queue, ^(void) {
                __strong VideoState* strongIs = weakIs;
                if(strongIs) read_thread(strongIs);
            });
        }
    }

    // We want to start paused, but we also want to display the first frame rather than nothing.  This is exactly the same as wanting to display a frame after seeking while paused.
    is->is_temporarily_unpaused_to_handle_seeking = true;
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


int lavp_get_playback_speed_percent(VideoState *is)
{
    if (!is || !is->ic || is->ic->duration <= 0) return 0;
    return is->playbackSpeedPercent;
}

void lavp_set_playback_speed_percent(VideoState *is, int speed)
{
    if (!is || speed < 0) return;
    if (is->playbackSpeedPercent == speed) return;
    is->playbackSpeedPercent = speed;
    is->playRate = (double)speed / 100.0;
    set_clock_speed(&is->vidclk, is->playRate);
    set_clock_speed(&is->audclk, is->playRate);
}
