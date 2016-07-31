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
 Foundation, Inc.,  1 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "MovieState.h"
#import "LAVPMovie+Internal.h"
#import "decoder.h"


static int movie_stream_open(MovieState *mov, Decoder *dec, AVStream *stream)
{
    dec->avctx = avcodec_alloc_context3(NULL);
    AVCodecContext *avctx = dec->avctx;
    if (!avctx)
        return AVERROR(ENOMEM);

    int err = avcodec_parameters_to_context(avctx, stream->codecpar);
    if (err < 0)
        return err;
    av_codec_set_pkt_timebase(avctx, stream->time_base);

    AVCodec *codec = avcodec_find_decoder(avctx->codec_id);
    if (!codec) {
        NSLog(@"libavPlayer: no codec could be found with id %d\n", avctx->codec_id);
        return AVERROR(EINVAL);
    }

    avctx->codec_id = codec->id;
    avctx->workaround_bugs = 1;
    av_codec_set_lowres(avctx, 0);
    avctx->error_concealment = 3;

    avctx->thread_count = 0; // Tell ffmpeg to choose an appropriate number.
    if (avcodec_open2(avctx, codec, NULL) < 0)
        return -1;

    stream->discard = AVDISCARD_DEFAULT;

    if (decoder_init(dec, avctx, stream) < 0)
        return -1;

    return 0;
}

static int decode_interrupt_cb(void *ctx)
{
    MovieState *mov = (__bridge MovieState *)(ctx);
    return mov->abort_request;
}

int decoders_get_packet(MovieState *mov, AVPacket *pkt, bool *reached_eof)
{
    if (mov->abort_request) return -1;
    int ret = av_read_frame(mov->ic, pkt);
    if (ret < 0) {
        if ((ret == AVERROR_EOF || avio_feof(mov->ic->pb)) && !*reached_eof) {
            *reached_eof = true;
        }
        if (mov->ic->pb && mov->ic->pb->error)
            return -1; // xxx unsure about this
        return 0;
    }
    *reached_eof = false;
    return 0;
}

void lavp_seek(MovieState *mov, int64_t pos, int64_t current_pos)
{
    if (!mov->seek_req) {
        mov->seek_from = current_pos;
        mov->seek_to = pos;
        mov->seek_req = true;
        decoders_wake_thread(mov);
    }
}

// Don't call this except from decoders_thread().
void lavp_handle_paused_change(MovieState *mov)
{
    bool pause = mov->requested_paused;
    if (pause == mov->paused) return;
    clock_preserve(mov);
    mov->paused = pause;
    audio_queue_set_paused(mov, pause);
    __strong id<LAVPMovieOutput> output = mov->weak_output;
    if (output) [output movieOutputNeedsContinuousUpdating:!pause];
}

void lavp_set_paused(MovieState *mov, bool pause)
{
    // Allowing unpause in this case would just let the clock run beyond the duration.
    if (!pause && mov->paused && mov->paused_for_eof)
        return;
    if (pause == mov->requested_paused)
        return;
    mov->requested_paused = pause;
    decoders_wake_thread(mov);
}

void movie_close(MovieState *mov)
{
    if (mov) {
        mov->abort_request = true;

        decoders_wake_thread(mov);
        dispatch_group_wait(mov->decoder_group, DISPATCH_TIME_FOREVER);
        mov->decoder_group = NULL;
        mov->decoder_queue = NULL;

        audio_queue_destroy(mov);

        if (mov->auddec) decoder_destroy(mov->auddec);
        if (mov->viddec) decoder_destroy(mov->viddec);

        swr_free(&mov->swr_ctx);
        av_freep(&mov->audio_buf1);
        mov->audio_buf1_size = 0;
        mov->audio_buf = NULL;

        avformat_close_input(&mov->ic);

        mov->weak_output = NULL;
    }
}

MovieState* movie_open(NSURL *sourceURL)
{
    MovieState *mov = [[MovieState alloc] init];

    mov->volume_percent = 100;
    mov->weak_output = NULL;
    mov->paused = true;
    mov->requested_paused = true;
    mov->playback_speed_percent = 100;
    mov->abort_request = false;
    mov->seek_req = false;
    mov->last_shown_frame_serial = -1;

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

    int vid_index = av_find_best_stream(mov->ic, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vid_index < 0)
        goto fail;
    int aud_index = av_find_best_stream(mov->ic, AVMEDIA_TYPE_AUDIO, -1, vid_index, NULL, 0);
    if (aud_index < 0)
        goto fail;
    mov->auddec = [[Decoder alloc] init];
    if (movie_stream_open(mov, mov->auddec, mov->ic->streams[aud_index]) < 0)
        goto fail;
    if (audio_open(mov, mov->auddec->avctx) < 0)
        goto fail;
    {
        AVStream *vidstream = mov->ic->streams[vid_index];
        if (vidstream->disposition & AV_DISPOSITION_ATTACHED_PIC)
            goto fail;
        mov->width = vidstream->codecpar->width;
        mov->height = vidstream->codecpar->height;
        mov->viddec = [[Decoder alloc] init];
        if (movie_stream_open(mov, mov->viddec, vidstream) < 0)
            goto fail;
    }

    mov->decoder_queue = dispatch_queue_create("decoders", NULL);
    mov->decoder_group = dispatch_group_create();
    {
        dispatch_group_async(mov->decoder_group, mov->decoder_queue, ^(void) {
            decoders_thread(mov);
        });
    }

    return mov;

fail:
    movie_close(mov);
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

void decoders_thread(MovieState *mov)
{
    AVPacket pkt;
    int err = 0;
    bool reached_eof = false;
    bool aud_frames_pending = false;
    bool vid_frames_pending = false;
    // These both start true because we start paused, and want a clock and video update ASAP, which is equivalent to the seek-while-paused case.
    bool need_video_update_after_seeking_while_paused = true;
    bool need_clock_update_after_seeking = true;

    // This loop is often waiting on a condvar in decoder_receive_frame().
    for (;;) {
        if (mov->abort_request) break;

        if (mov->paused != mov->requested_paused) {
            lavp_handle_paused_change(mov);
            need_video_update_after_seeking_while_paused = false;
            continue;
        }

        if (mov->seek_req) {
            int64_t seek_diff = mov->seek_to - mov->seek_from;
            // When trying to seek forward a small distance, we need to specifiy a time in the future as the minimum acceptable seek position, since otherwise the seek could end up going backward slightly (e.g. if keyframes are ~10s apart and we were ~2s past one and request a +5s seek, the key frame immediately before the target time is the one we're just past, and is what avformat_seek_file will seek to).  The "/ 2" is a fairly arbitrary choice.
            int64_t seek_min = seek_diff > 0 ? mov->seek_to - (seek_diff / 2) : INT64_MIN;
            int ret = avformat_seek_file(mov->ic, -1, seek_min, mov->seek_to, INT64_MAX, 0);
            mov->seek_req = false;
            if (ret < 0)
                continue;

            mov->paused_for_eof = false;
            ++mov->current_serial;
            reached_eof = false;
            aud_frames_pending = false;
            vid_frames_pending = false;
            decoder_flush(mov->auddec);
            decoder_flush(mov->viddec);
            need_clock_update_after_seeking = true;
            if (mov->paused) {
                // Clear out stale frames so there's space for new ones.  If we're *not* paused we must leave this to audio_callback() and calls to lavp_get_current_frame() from the LAVPLayer's refresh timer, as otherwise we might discard a frame they're still in the middle of using.
                decoder_peek_current_frame(mov->auddec, mov);
                decoder_peek_current_frame(mov->viddec, mov);
                need_video_update_after_seeking_while_paused = true;
            }
            continue;
        }

        if (need_video_update_after_seeking_while_paused && decoder_peek_current_frame(mov->viddec, mov)) {
            __strong id<LAVPMovieOutput> output = mov->weak_output;
            if (output) [output movieOutputNeedsSingleUpdate];
            need_video_update_after_seeking_while_paused = false;
            continue;
        }
        if (need_clock_update_after_seeking) {
            Frame *fr;
            if ((fr = decoder_peek_current_frame(mov->auddec, mov))) {
                clock_set(mov, fr->frm_pts_usec, fr->frm_serial);
                need_clock_update_after_seeking = false;
            }
        }

        // Note: there can be frames pending even after reached_eof is set (there just shouldn't be any further packets).
        if (aud_frames_pending) {
            aud_frames_pending = decoder_receive_frame(mov->auddec, mov->current_serial, mov);
            continue;
        }
        if (vid_frames_pending) {
            vid_frames_pending = decoder_receive_frame(mov->viddec, mov->current_serial, mov);
            continue;
        }

        if (reached_eof) {
            // We need to wait until something interesting happens (e.g. abort or seek), and it needs to be one of the frameq condvars (where decoder_receive_frame() also waits).  Using viddec rather than auddec is arbitrary.
            // This will actually wake up a bunch as the final frames are used up, but that's fine (the important thing is to just avoid trying to read and decode more packets, and end up getting an error and ending the loop).
            pthread_mutex_lock(&mov->viddec->mutex);
            pthread_cond_wait(&mov->viddec->not_full_cond, &mov->viddec->mutex);
            pthread_mutex_unlock(&mov->viddec->mutex);
            continue;
        }

        bool prev_reached_eof = reached_eof;
        err = decoders_get_packet(mov, &pkt, &reached_eof);
        if (err < 0) break;
        if (reached_eof && !prev_reached_eof) {
            aud_frames_pending = decoder_send_packet(mov->auddec, NULL);
            vid_frames_pending = decoder_send_packet(mov->viddec, NULL);
            continue;
        }

        if (pkt.stream_index == mov->auddec->stream->index) {
            aud_frames_pending = decoder_send_packet(mov->auddec, &pkt);
        } else if (pkt.stream_index == mov->viddec->stream->index) {
            vid_frames_pending = decoder_send_packet(mov->viddec, &pkt);
        } else {
            av_packet_unref(&pkt);
        }
    }
}

void decoders_wake_thread(MovieState *mov)
{
    // When seeking (while paused) or closing, we need to interrupt the decoders_thread if it's waiting in decoder_receive_frame().  And we don't know which frameq it's waiting on, so we must wake both up.
    pthread_cond_signal(&mov->auddec->not_full_cond);
    pthread_cond_signal(&mov->viddec->not_full_cond);
}

bool decoders_should_stop_waiting(MovieState *mov)
{
    return mov->abort_request || mov->seek_req || mov->paused != mov->requested_paused;
}

void decoders_pause_if_finished(MovieState *mov)
{
    if (mov->paused) return;
    if (!decoder_finished(mov->auddec, mov->current_serial)) return;
    if (!decoder_finished(mov->viddec, mov->current_serial)) return;
    mov->paused_for_eof = true;
    lavp_set_paused(mov, true);
}
