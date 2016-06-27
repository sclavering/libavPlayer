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

#import "MovieState.h"
#import "LAVPMovie+Internal.h"
#import "decoder.h"


void lavp_pthread_cond_wait_with_timeout(pthread_cond_t *cond, pthread_mutex_t *mutex, int ms)
{
    struct timespec time_to_wait = { 0, 0 };
    time_to_wait.tv_nsec = 1000000 * ms;
    pthread_cond_timedwait_relative_np(cond, mutex, &time_to_wait);
}

static int stream_component_open(MovieState *mov, AVStream *stream)
{
    int ret;

    AVCodecContext *avctx = avcodec_alloc_context3(NULL);
    if (!avctx)
        return AVERROR(ENOMEM);

    ret = avcodec_parameters_to_context(avctx, stream->codecpar);
    if (ret < 0)
        goto fail;
    av_codec_set_pkt_timebase(avctx, stream->time_base);

    AVCodec *codec = avcodec_find_decoder(avctx->codec_id);

    if (!codec) {
        av_log(NULL, AV_LOG_WARNING, "No codec could be found with id %d\n", avctx->codec_id);
        ret = AVERROR(EINVAL);
        goto fail;
    }

    avctx->codec_id = codec->id;
    avctx->workaround_bugs = 1;
    av_codec_set_lowres(avctx, 0);
    avctx->error_concealment = 3;

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "threads", "auto", 0);
    av_dict_set(&opts, "refcounted_frames", "1", 0);
    if (avcodec_open2(avctx, codec, &opts) < 0)
        goto fail;

    stream->discard = AVDISCARD_DEFAULT;
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            mov->auddec = [[Decoder alloc] init];
            if (decoder_init(mov->auddec, avctx, &mov->continue_read_thread, stream) < 0)
                goto fail;

            if ((ret = audio_open(mov, avctx)) < 0)
                goto out;
            audio_queue_start(mov);

            break;
        case AVMEDIA_TYPE_VIDEO:
            if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
                goto fail;

            mov->width = stream->codecpar->width;
            mov->height = stream->codecpar->height;

            mov->viddec = [[Decoder alloc] init];
            if (decoder_init(mov->viddec, avctx, &mov->continue_read_thread, stream) < 0)
                goto fail;

            break;
        default:
            break;
    }
    goto out;

fail:
    avcodec_free_context(&avctx);
out:
    av_dict_free(&opts);

    return ret;
}

static int decode_interrupt_cb(void *ctx)
{
    MovieState *mov = (__bridge MovieState *)(ctx);
    return mov->abort_request;
}

void read_thread(MovieState* mov)
{
    pthread_mutex_t wait_mutex;
    pthread_mutex_init(&wait_mutex, NULL);

    bool reached_eof = false;
    AVPacket pkt1, *pkt = &pkt1;
    for(;;) {
        if (mov->abort_request)
            break;

        // Seek
        if (mov->seek_req) {
            mov->last_shown_video_frame_pts = -1;
            int64_t seek_diff = mov->seek_to - mov->seek_from;
            // When trying to seek forward a small distance, we need to specifiy a time in the future as the minimum acceptable seek position, since otherwise the seek could end up going backward slightly (e.g. if keyframes are ~10s apart and we were ~2s past one and request a +5s seek, the key frame immediately before the target time is the one we're just past, and is what avformat_seek_file will seek to).  The "/ 2" is a fairly arbitrary choice.
            // xxx we should use AVSEEK_FLAG_ANY here, but that causes graphical corruption if used naïvely (presumably you need to actually decode the preceding frames back to the key frame).
            int64_t seek_min = seek_diff > 0 ? mov->seek_to - (seek_diff / 2) : INT64_MIN;
            int ret = avformat_seek_file(mov->ic, -1, seek_min, mov->seek_to, INT64_MAX, 0);
            if (ret >= 0) {
                decoder_update_for_seek(mov->auddec);
                decoder_update_for_seek(mov->viddec);
            }
            mov->seek_req = 0;
            reached_eof = false;
            if (mov->paused) {
                lavp_set_paused(mov, false);
                mov->is_temporarily_unpaused_to_handle_seeking = true;
            }
        }

        if(!decoder_needs_more_packets(mov->auddec, AUDIO_FRAME_QUEUE_TARGET_SIZE)
                && !decoder_needs_more_packets(mov->viddec, VIDEO_FRAME_QUEUE_TARGET_SIZE))
        {
            pthread_mutex_lock(&wait_mutex);
            lavp_pthread_cond_wait_with_timeout(&mov->continue_read_thread, &wait_mutex, 10);
            pthread_mutex_unlock(&wait_mutex);
            continue;
        }

        if (!mov->paused && decoder_finished(mov->auddec) && decoder_finished(mov->viddec)) {
            lavp_set_paused(mov, true);
        }

        int ret = av_read_frame(mov->ic, pkt);
        if (ret < 0) {
            if ((ret == AVERROR_EOF || avio_feof(mov->ic->pb)) && !reached_eof) {
                decoder_update_for_eof(mov->auddec);
                decoder_update_for_eof(mov->viddec);
                reached_eof = true;
            }
            if (mov->ic->pb && mov->ic->pb->error)
                break;
            pthread_mutex_lock(&wait_mutex);
            lavp_pthread_cond_wait_with_timeout(&mov->continue_read_thread, &wait_mutex, 10);
            pthread_mutex_unlock(&wait_mutex);
            continue;
        }
        reached_eof = false;

        if(!decoder_maybe_handle_packet(mov->auddec, pkt) && !decoder_maybe_handle_packet(mov->viddec, pkt))
            av_packet_unref(pkt);
    }

    pthread_mutex_destroy(&wait_mutex);
}

void lavp_seek(MovieState *mov, int64_t pos, int64_t current_pos)
{
    if (!mov->seek_req) {
        mov->seek_from = current_pos;
        mov->seek_to = pos;
        mov->seek_req = true;
        pthread_cond_signal(&mov->continue_read_thread);
    }
}

void lavp_set_paused(MovieState *mov, bool pause)
{
    if (pause == mov->paused)
        return;
    mov->is_temporarily_unpaused_to_handle_seeking = false;
    clock_preserve(mov);
    mov->paused = pause;
    if (mov->paused)
        audio_queue_pause(mov);
    else
        audio_queue_start(mov);
    __strong id<LAVPMovieOutput> output = mov->weak_output;
    if (output) [output movieOutputNeedsContinuousUpdating:!pause];
}

void stream_close(MovieState *mov)
{
    if (mov) {
        mov->abort_request = true;

        if (mov->parse_group) dispatch_group_wait(mov->parse_group, DISPATCH_TIME_FOREVER);
        mov->parse_group = NULL;
        mov->parse_queue = NULL;

        if (mov->auddec) decoder_destroy(mov->auddec);
        if (mov->viddec) decoder_destroy(mov->viddec);

        audio_queue_destroy(mov);
        swr_free(&mov->swr_ctx);
        av_freep(&mov->audio_buf1);
        mov->audio_buf1_size = 0;
        mov->audio_buf = NULL;

        avformat_close_input(&mov->ic);

        pthread_cond_destroy(&mov->continue_read_thread);

        mov->weak_output = NULL;
    }
}

MovieState* stream_open(NSURL *sourceURL)
{
    // Re-doing this each time we open a stream ought to be fine, as av_init_packet() is documented as not modifying .data
    av_init_packet(&flush_pkt);
    flush_pkt.data = (uint8_t *)&flush_pkt;

    MovieState *mov = [[MovieState alloc] init];

    mov->volume_percent = 100;
    mov->weak_output = NULL;
    mov->last_shown_video_frame_pts = -1;
    mov->paused = false;
    mov->playback_speed_percent = 100;
    mov->abort_request = false;

    av_log_set_flags(AV_LOG_SKIP_REPEATED);
    av_register_all();

    mov->ic = avformat_alloc_context();
    if (!mov->ic) return NULL;
    mov->ic->interrupt_callback.callback = decode_interrupt_cb;
    mov->ic->interrupt_callback.opaque = (__bridge void *)(mov);
    int err = avformat_open_input(&mov->ic, sourceURL.path.fileSystemRepresentation, NULL, NULL);
    if (err < 0)
        return NULL;

    err = avformat_find_stream_info(mov->ic, NULL);
    if (err < 0)
        return NULL;

    if (mov->ic->pb)
        mov->ic->pb->eof_reached = 0; // FIXME hack, ffplay maybe should not use avio_feof() to test for the end

    for (int i = 0; i < mov->ic->nb_streams; i++)
        mov->ic->streams[i]->discard = AVDISCARD_ALL;

    pthread_cond_init(&mov->continue_read_thread, NULL);

    int vid_index = av_find_best_stream(mov->ic, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vid_index < 0)
        goto fail;
    int aud_index = av_find_best_stream(mov->ic, AVMEDIA_TYPE_AUDIO, -1, vid_index, NULL, 0);
    if (aud_index < 0)
        goto fail;
    if (stream_component_open(mov, mov->ic->streams[aud_index]) < 0)
        goto fail;
    if (stream_component_open(mov, mov->ic->streams[vid_index]) < 0)
        goto fail;

    clock_init(mov);

    mov->parse_queue = dispatch_queue_create("parse", NULL);
    mov->parse_group = dispatch_group_create();
    {
        __weak MovieState* weak_mov = mov;
        dispatch_group_async(mov->parse_group, mov->parse_queue, ^(void) {
            __strong MovieState* strong_mov = weak_mov;
            if (strong_mov) read_thread(strong_mov);
        });
    }

    // We want to start paused, but we also want to display the first frame rather than nothing.  This is exactly the same as wanting to display a frame after seeking while paused.
    mov->is_temporarily_unpaused_to_handle_seeking = true;
    return mov;

fail:
    stream_close(mov);
    return NULL;
}

void lavp_set_playback_speed_percent(MovieState *mov, int speed)
{
    if (speed <= 0) return;
    if (mov->playback_speed_percent == speed) return;
    mov->playback_speed_percent = speed;
    clock_preserve(mov);
    lavp_audio_update_speed(mov);
}
