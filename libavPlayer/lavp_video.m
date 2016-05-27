/*
 *  Created by Takashi Mochizuki on 11/06/19.
 *  Copyright 2011 MyCometG3. All rights reserved.
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


/* no AV sync correction is done if below the minimum AV sync threshold */
#define AV_SYNC_THRESHOLD_MIN 0.01
/* AV sync correction is done if above the maximum AV sync threshold */
#define AV_SYNC_THRESHOLD_MAX 0.1
/* If a frame duration is longer than this, it will not be duplicated to compensate AV sync */
#define AV_SYNC_FRAMEDUP_THRESHOLD 0.1
/* no AV correction is done if too big error */
#define AV_NOSYNC_THRESHOLD 10.0


double compute_target_delay(double delay, VideoState *is);

int get_video_frame(VideoState *is, AVFrame *frame);
void video_refresh(VideoState *is, double *remaining_time);


/* =========================================================== */

#pragma mark -

double compute_target_delay(double delay, VideoState *is)
{
    /* update delay to follow master synchronisation source */
    /* if video is slave, we try to correct big delays by duplicating or deleting a frame */
    double diff = get_clock(&is->vidclk) - get_master_clock(is);
    /* skip or repeat frame. We take into account the delay to compute the threshold. I still don't know if it is the best guess */
    double sync_threshold = FFMAX(AV_SYNC_THRESHOLD_MIN, FFMIN(AV_SYNC_THRESHOLD_MAX, delay));
    if (!isnan(diff) && fabs(diff) < is->max_frame_duration) {
        if (diff <= -sync_threshold)
            delay = FFMAX(0, delay + diff);
        else if (diff >= sync_threshold && delay > AV_SYNC_FRAMEDUP_THRESHOLD)
            delay = delay + diff;
        else if (diff >= sync_threshold)
            delay = 2 * delay;
    }
    return delay;
}

static double vp_duration(VideoState *is, Frame *vp, Frame *nextvp) {
    if (vp->frm_serial == nextvp->frm_serial) {
        double duration = nextvp->frm_pts - vp->frm_pts;
        if (isnan(duration) || duration <= 0 || duration > is->max_frame_duration)
            return vp->frm_duration;
        else
            return duration;
    } else {
        return 0.0;
    }
}

void refresh_loop_wait_event(VideoState *is) {
    double remaining_time = 0.0;

    // LAVP: use remaining time to avoid over-run
    if (is->remaining_time > 1.0)
        return;

    if (!is->paused)
        video_refresh(is, &remaining_time);

    //
    is->remaining_time = remaining_time;
}

/* called to display each frame */
void video_refresh(VideoState *is, double *remaining_time)
{
    if (!is->viddec->stream) return;

    Frame *vp, *lastvp;
    for(;;) {
        // nothing to do, no picture to display in the queue
        if (frame_queue_nb_remaining(&is->viddec->frameq) == 0) return;

        /* dequeue the picture */
        lastvp = frame_queue_peek_last(&is->viddec->frameq);
        vp = frame_queue_peek(&is->viddec->frameq);

        if (vp->frm_serial != is->viddec->packetq.serial) {
            frame_queue_next(&is->viddec->frameq);
            continue;
        }
        break;
    }

    if (lastvp->frm_serial != vp->frm_serial)
        is->frame_timer = av_gettime_relative() / 1000000.0;

    if (!is->paused) {
        /* compute nominal last_duration */
        double last_duration = vp_duration(is, lastvp, vp);
        double delay = compute_target_delay(last_duration, is);

        double time = av_gettime_relative() / 1000000.0;
        if (time < is->frame_timer + delay) {
            *remaining_time = FFMIN(is->frame_timer + delay - time, *remaining_time);
            return;
        }

        is->frame_timer += delay;
        if (delay > 0 && time - is->frame_timer > AV_SYNC_THRESHOLD_MAX)
            is->frame_timer = time;

        pthread_mutex_lock(is->viddec->frameq.mutex);
        if (!isnan(vp->frm_pts))
            set_clock(&is->vidclk, vp->frm_pts, vp->frm_serial);

        pthread_mutex_unlock(is->viddec->frameq.mutex);
    }

    frame_queue_next(&is->viddec->frameq);

    if (is->is_temporarily_unpaused_to_handle_seeking) {
        lavp_set_paused_internal(is, true);
        __strong id<LAVPMovieOutput> movieOutput = is->weakOutput;
        if(movieOutput) [movieOutput movieOutputNeedsSingleUpdate];
    }
}

int get_video_frame(VideoState *is, AVFrame *frame)
{
    int got_picture;

    if ((got_picture = decoder_decode_frame(is->viddec, frame)) < 0)
        return -1;

    if (got_picture) {
        if (frame->pts != AV_NOPTS_VALUE) {
            double dpts = av_q2d(is->viddec->stream->time_base) * frame->pts;
            double diff = dpts - get_master_clock(is);
            if (!isnan(diff) && fabs(diff) < AV_NOSYNC_THRESHOLD &&
                diff < 0 &&
                is->viddec->pkt_serial == is->vidclk.serial &&
                is->viddec->packetq.nb_packets) {
                av_frame_unref(frame);
                got_picture = 0;
            }
        }
    }
    return got_picture;
}

int video_thread(VideoState *is)
{
    AVFrame *frame= av_frame_alloc();
    AVRational tb = is->viddec->stream->time_base;
    AVRational frame_rate = av_guess_frame_rate(is->ic, is->viddec->stream, NULL);

    for(;;) {
            int ret = get_video_frame(is, frame);
            if (ret < 0)
                break;
            if (!ret)
                continue;

            // Other pixel formats are rare, and converting them would be hard (and probably end up happening in software, rather than on the GPU), so don't bother, at least for now.
            if (frame->format != AV_PIX_FMT_YUV420P)
                break;

            Frame *fr;
            if (!(fr = frame_queue_peek_writable(&is->viddec->frameq)))
                break;

            fr->frm_pts = (frame->pts == AV_NOPTS_VALUE) ? NAN : frame->pts * av_q2d(tb);
            fr->frm_duration = frame_rate.num && frame_rate.den ? av_q2d((AVRational){frame_rate.den, frame_rate.num}) : 0;
            fr->frm_serial = is->viddec->pkt_serial;

            av_frame_move_ref(fr->frm_frame, frame);

            frame_queue_push(&is->viddec->frameq);
    }

    av_frame_free(&frame);
    return 0;
}

/* ========================================================================= */

#pragma mark -

Frame* lavp_get_current_frame(VideoState *is)
{
    pthread_mutex_lock(is->viddec->frameq.mutex);
    bool success = false;

    if (frame_queue_nb_remaining(&is->viddec->frameq) <= 0)
        goto finish;

    Frame *vp = frame_queue_peek(&is->viddec->frameq);

    if (!vp)
        goto finish;

    if (vp->frm_pts >= 0 && vp == is->last_frame)
        goto finish;

    is->last_frame = vp;
    success = true;

finish:
    pthread_mutex_unlock(is->viddec->frameq.mutex);
    return success ? is->last_frame : NULL;
}
