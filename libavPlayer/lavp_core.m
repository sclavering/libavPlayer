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


void lavp_pthread_cond_wait_with_timeout(pthread_cond_t *cond, pthread_mutex_t *mutex, int ms)
{
    struct timespec time_to_wait = { 0, 0 };
    time_to_wait.tv_nsec = 1000000 * ms;
    pthread_cond_timedwait_relative_np(cond, mutex, &time_to_wait);
}

static int stream_component_open(VideoState *is, AVStream *stream)
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

    is->eof = false;
    stream->discard = AVDISCARD_DEFAULT;
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            is->auddec = [[Decoder alloc] init];
            if(decoder_init(is->auddec, avctx, &is->continue_read_thread, SAMPLE_QUEUE_SIZE, stream) < 0)
                goto fail;

            if ((ret = audio_open(is, avctx->channel_layout, avctx->channels, avctx->sample_rate, &is->audio_tgt)) < 0)
                goto out;
            is->audio_hw_buf_size = ret;
            is->audio_src = is->audio_tgt;
            is->audio_buf_size  = 0;
            is->audio_buf_index = 0;

            audio_queue_init(is, avctx);
            audio_queue_start(is);

            break;
        case AVMEDIA_TYPE_VIDEO:
            if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
                goto fail;

            is->width = stream->codecpar->width;
            is->height = stream->codecpar->height;

            is->viddec = [[Decoder alloc] init];
            if(decoder_init(is->viddec, avctx, &is->continue_read_thread, VIDEO_PICTURE_QUEUE_SIZE, stream) < 0)
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
    VideoState *is = (__bridge VideoState *)(ctx);
    return is->abort_request;
}

int read_thread(VideoState* is)
{
        pthread_mutex_t wait_mutex;
        pthread_mutex_init(&wait_mutex, NULL);
        int ret = -1;

        // decode loop
        AVPacket pkt1, *pkt = &pkt1;
        for(;;) {
                if (is->abort_request)
                    break;

                // Seek
                if (is->seek_req) {
                    is->last_shown_video_frame_pts = -1;
                    int64_t seek_diff = is->seek_to - is->seek_from;
                    // When trying to seek forward a small distance, we need to specifiy a time in the future as the minimum acceptable seek position, since otherwise the seek could end up going backward slightly (e.g. if keyframes are ~10s apart and we were ~2s past one and request a +5s seek, the key frame immediately before the target time is the one we're just past, and is what avformat_seek_file will seek to).  The "/ 2" is a fiarly arbitrary choice.
                    // xxx we should use AVSEEK_FLAG_ANY here, but that causes graphical corruption if used naïvely (presumably you need to actually decode the preceding frames back to the key frame).
                    int64_t seek_min = seek_diff > 0 ? is->seek_to - (seek_diff / 2) : INT64_MIN;
                    ret = avformat_seek_file(is->ic, -1, seek_min, is->seek_to, INT64_MAX, 0);
                    if (ret >= 0) {
                        decoder_update_for_seek(is->auddec);
                        decoder_update_for_seek(is->viddec);
                    }
                    is->seek_req = 0;
                    is->eof = false;
                    if (is->paused) {
                        lavp_set_paused_internal(is, false);
                        is->is_temporarily_unpaused_to_handle_seeking = true;
                    }
                }

                if(!(decoder_needs_more_packets(is->auddec) || decoder_needs_more_packets(is->viddec))) {
                    pthread_mutex_lock(&wait_mutex);
                    lavp_pthread_cond_wait_with_timeout(&is->continue_read_thread, &wait_mutex, 10);
                    pthread_mutex_unlock(&wait_mutex);
                    continue;
                }

                if (!is->paused && decoder_finished(is->auddec) && decoder_finished(is->viddec)) {
                    lavp_set_paused(is, true);
                }

                ret = av_read_frame(is->ic, pkt);
                if (ret < 0) {
                    if ((ret == AVERROR_EOF || avio_feof(is->ic->pb)) && !is->eof) {
                        decoder_update_for_eof(is->auddec);
                        decoder_update_for_eof(is->viddec);
                        is->eof = true;
                    }
                    if (is->ic->pb && is->ic->pb->error)
                        break;
                    pthread_mutex_lock(&wait_mutex);
                    lavp_pthread_cond_wait_with_timeout(&is->continue_read_thread, &wait_mutex, 10);
                    pthread_mutex_unlock(&wait_mutex);
                    continue;
                }
                is->eof = false;

                if(!decoder_maybe_handle_packet(is->auddec, pkt) && !decoder_maybe_handle_packet(is->viddec, pkt))
                    av_packet_unref(pkt);
        }

        ret = 0;

        pthread_mutex_destroy(&wait_mutex);

        return ret;
}

void lavp_seek(VideoState *is, int64_t pos, int64_t current_pos)
{
    if (!is->seek_req) {
        is->seek_from = current_pos;
        is->seek_to = pos;
        is->seek_req = true;
        pthread_cond_signal(&is->continue_read_thread);
    }
}

void lavp_set_paused_internal(VideoState *is, bool pause)
{
    if(pause == is->paused)
        return;
    is->is_temporarily_unpaused_to_handle_seeking = false;
    is->paused = pause;
    clock_set_paused(&is->audclk, pause);
    if (is->auddec->stream) {
        if (is->paused)
            audio_queue_pause(is);
        else
            audio_queue_start(is);
    }
    __strong id<LAVPMovieOutput> movieOutput = is ? is->weak_output : NULL;
    if(movieOutput) [movieOutput movieOutputNeedsContinuousUpdating:!pause];
}

void lavp_set_paused(VideoState *is, bool pause)
{
    lavp_set_paused_internal(is, pause);
}

void stream_close(VideoState *is)
{
    if (is) {
        is->abort_request = true;

        dispatch_group_wait(is->parse_group, DISPATCH_TIME_FOREVER);
        is->parse_group = NULL;
        is->parse_queue = NULL;

        decoder_destroy(is->auddec);
        decoder_destroy(is->viddec);

        audio_queue_destroy(is);
        swr_free(&is->swr_ctx);
        av_freep(&is->audio_buf1);
        is->audio_buf1_size = 0;
        is->audio_buf = NULL;

        avformat_close_input(&is->ic);

        pthread_cond_destroy(&is->continue_read_thread);

        is->weak_output = NULL;
    }
}

VideoState* stream_open(NSURL *sourceURL)
{
    // Re-doing this each time we open a stream ought to be fine, as av_init_packet() is documented as not modifying .data
    av_init_packet(&flush_pkt);
    flush_pkt.data = (uint8_t *)&flush_pkt;

    VideoState *is = [[VideoState alloc] init];

    is->volume_percent = 100;
    is->weak_output = NULL;
    is->last_shown_video_frame_pts = -1;
    is->paused = false;
    is->playback_speed_percent = 100;
    is->eof = false;
    is->abort_request = false;

    av_log_set_flags(AV_LOG_SKIP_REPEATED);
    av_register_all();

    const char * extension = [sourceURL.pathExtension cStringUsingEncoding:NSASCIIStringEncoding];
    if (extension) {
        AVInputFormat *file_iformat = av_find_input_format(extension);
        if (file_iformat) is->iformat = file_iformat;
    }

    AVFormatContext *ic = avformat_alloc_context();
    ic->interrupt_callback.callback = decode_interrupt_cb;
    ic->interrupt_callback.opaque = (__bridge void *)(is);
    int err = avformat_open_input(&ic, sourceURL.path.fileSystemRepresentation, is->iformat, NULL);
    if (err < 0)
        return NULL;
    is->ic = ic;

    err = avformat_find_stream_info(is->ic, NULL);
    if (err < 0)
        return NULL;

    if (is->ic->pb)
        is->ic->pb->eof_reached = 0; // FIXME hack, ffplay maybe should not use avio_feof() to test for the end

    for (int i = 0; i < is->ic->nb_streams; i++)
        is->ic->streams[i]->discard = AVDISCARD_ALL;

    pthread_cond_init(&is->continue_read_thread, NULL);
    is->audio_clock_serial = -1;

    int vid_index = av_find_best_stream(is->ic, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vid_index < 0)
        goto fail;
    int aud_index = av_find_best_stream(is->ic, AVMEDIA_TYPE_AUDIO, -1, vid_index, NULL, 0);
    if (aud_index < 0)
        goto fail;
    if (stream_component_open(is, is->ic->streams[aud_index]) < 0)
        goto fail;
    if (stream_component_open(is, is->ic->streams[vid_index]) < 0)
        goto fail;

    clock_init(&is->audclk, &is->auddec->packetq.pq_serial);

    is->parse_queue = dispatch_queue_create("parse", NULL);
    is->parse_group = dispatch_group_create();
    {
        __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
        dispatch_group_async(is->parse_group, is->parse_queue, ^(void) {
            __strong VideoState* strongIs = weakIs;
            if(strongIs) read_thread(strongIs);
        });
    }

    // We want to start paused, but we also want to display the first frame rather than nothing.  This is exactly the same as wanting to display a frame after seeking while paused.
    is->is_temporarily_unpaused_to_handle_seeking = true;
    return is;

fail:
    stream_close(is);
    return NULL;
}


int lavp_get_playback_speed_percent(VideoState *is)
{
    if (!is || !is->ic || is->ic->duration <= 0) return 0;
    return is->playback_speed_percent;
}

void lavp_set_playback_speed_percent(VideoState *is, int speed)
{
    if (!is || speed < 0) return;
    if (is->playback_speed_percent == speed) return;
    is->playback_speed_percent = speed;
    lavp_audio_update_speed(is);
    clock_set_speed(&is->audclk, (double)speed / 100.0);
}
