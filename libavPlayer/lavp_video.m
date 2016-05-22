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

#import "lavp_util.h"


/* no AV sync correction is done if below the minimum AV sync threshold */
#define AV_SYNC_THRESHOLD_MIN 0.01
/* AV sync correction is done if above the maximum AV sync threshold */
#define AV_SYNC_THRESHOLD_MAX 0.1
/* If a frame duration is longer than this, it will not be duplicated to compensate AV sync */
#define AV_SYNC_FRAMEDUP_THRESHOLD 0.1
/* no AV correction is done if too big error */
#define AV_NOSYNC_THRESHOLD 10.0


double compute_target_delay(double delay, VideoState *is);

int queue_picture(VideoState *is, AVFrame *src_frame, double pts, double duration, int64_t pos, int serial);
int get_video_frame(VideoState *is, AVFrame *frame);
void video_refresh(VideoState *is, double *remaining_time);


/* =========================================================== */

#pragma mark -

void free_picture(Frame *vp)
{
    if (vp->frm_bmp) {
        avpicture_free((AVPicture*)vp->frm_bmp);
        av_free(vp->frm_bmp);
        vp->frm_bmp = NULL;
    }
}

int video_open(VideoState *is, Frame *vp){
    /* LAVP: No need for SDL support; Independent from screen rect */
    int w,h;

    if (vp && vp->frm_width * vp->frm_height) {
        w = vp->frm_width;
        h = vp->frm_height;
    } else if (is->video_st && is->video_st->codec->width){
        w = is->video_st->codec->width;
        h = is->video_st->codec->height;
    } else {
        w = 640;
        h = 480;
    }

    is->width = w;
    is->height = h;

    return 0;
}

double compute_target_delay(double delay, VideoState *is)
{
    double sync_threshold, diff;

    /* update delay to follow master synchronisation source */

        /* if video is slave, we try to correct big delays by
         duplicating or deleting a frame */
        diff = get_clock(&is->vidclk) - get_master_clock(is);

        /* skip or repeat frame. We take into account the
         delay to compute the threshold. I still don't know
         if it is the best guess */
        sync_threshold = FFMAX(AV_SYNC_THRESHOLD_MIN, FFMIN(AV_SYNC_THRESHOLD_MAX, delay));
        if (!isnan(diff) && fabs(diff) < is->max_frame_duration) {
            if (diff <= -sync_threshold)
                delay = FFMAX(0, delay + diff);
            else if (diff >= sync_threshold && delay > AV_SYNC_FRAMEDUP_THRESHOLD)
                delay = delay + diff;
            else if (diff >= sync_threshold)
                delay = 2 * delay;
        }

    av_dlog(NULL, "video: delay=%0.3f A-V=%f\n",
            delay, -diff);

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

static void update_video_pts(VideoState *is, double pts, int64_t pos, int serial) {
    /* update current video pts */
    set_clock(&is->vidclk, pts, serial);
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
    if (!is->video_st) return;

    Frame *vp, *lastvp;
    for(;;) {
        // nothing to do, no picture to display in the queue
        if (frame_queue_nb_remaining(&is->pictq) == 0) return;

        /* dequeue the picture */
        lastvp = frame_queue_peek_last(&is->pictq);
        vp = frame_queue_peek(&is->pictq);

        if (vp->frm_serial != is->videoq.serial) {
            frame_queue_next(&is->pictq);
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

        LAVPLockMutex(is->pictq.mutex);
        if (!isnan(vp->frm_pts))
            update_video_pts(is, vp->frm_pts, vp->frm_pos, vp->frm_serial);
        LAVPUnlockMutex(is->pictq.mutex);
    }

    if (0 == is->width * is->height ) { // LAVP: zero rect is not allowed
        video_open(is, NULL);
    }

    frame_queue_next(&is->pictq);

    if (is->step && !is->paused) stream_set_paused(is, true);
}

void alloc_picture(VideoState *is)
{
    /* LAVP: Use AVFrame instead of SDL_YUVOverlay */
    AVFrame *picture = av_frame_alloc();
    int ret = av_image_alloc(picture->data, picture->linesize,
                             is->video_st->codec->width, is->video_st->codec->height, AV_PIX_FMT_YUV420P, 0x10);
    assert(ret > 0);

    //
    Frame *vp;

    LAVPLockMutex(is->pictq.mutex);

    vp = &is->pictq.queue[is->pictq.windex];

    free_picture(vp);

    video_open(is, vp);

    vp->frm_pts     = -1;
    vp->frm_width   = is->video_st->codec->width;
    vp->frm_height  = is->video_st->codec->height;
    vp->frm_bmp = picture;
    vp->frm_allocated = 1;

    LAVPCondSignal(is->pictq.cond);
    LAVPUnlockMutex(is->pictq.mutex);
}

int queue_picture(VideoState *is, AVFrame *src_frame, double pts, double duration, int64_t pos, int serial)
{
    Frame *vp;

    if (!(vp = frame_queue_peek_writable(&is->pictq)))
        return -1;

    /* alloc or resize hardware picture buffer */
    if (!vp->frm_bmp || !vp->frm_allocated ||
        vp->frm_width != is->video_st->codec->width ||
        vp->frm_height != is->video_st->codec->height) {

        vp->frm_allocated = 0;
        vp->frm_width = src_frame->width;
        vp->frm_height = src_frame->height;

        alloc_picture(is);

        if (is->videoq.abort_request)
            return -1;
    }

    /* if the frame is not skipped, then display it */
    if (vp->frm_bmp) {
        AVPicture pict = { { 0 } };

        /* get a pointer on the bitmap */
        /* LAVP: Using AVFrame */
        memset(&pict,0,sizeof(AVPicture));
        pict.data[0] = vp->frm_bmp->data[0];
        pict.data[1] = vp->frm_bmp->data[1];
        pict.data[2] = vp->frm_bmp->data[2];

        pict.linesize[0] = vp->frm_bmp->linesize[0];
        pict.linesize[1] = vp->frm_bmp->linesize[1];
        pict.linesize[2] = vp->frm_bmp->linesize[2];

        /* LAVP: duplicate or create YUV420P picture */
        LAVPLockMutex(is->pictq.mutex);
        if (src_frame->format == AV_PIX_FMT_YUV420P) {
            CVF_CopyPlane(src_frame->data[0], src_frame->linesize[0], vp->frm_height, pict.data[0], pict.linesize[0], vp->frm_height);
            CVF_CopyPlane(src_frame->data[1], src_frame->linesize[1], vp->frm_height, pict.data[1], pict.linesize[1], vp->frm_height/2);
            CVF_CopyPlane(src_frame->data[2], src_frame->linesize[2], vp->frm_height, pict.data[2], pict.linesize[2], vp->frm_height/2);
        } else {
            /* convert image format */
            is->img_convert_ctx = sws_getCachedContext(is->img_convert_ctx,
                                                       vp->frm_width, vp->frm_height, src_frame->format,
                                                       vp->frm_width, vp->frm_height, AV_PIX_FMT_YUV420P,
                                                       SWS_BICUBIC, NULL, NULL, NULL);
            if (is->img_convert_ctx == NULL) {
                av_log(NULL, AV_LOG_FATAL, "Cannot initialize the conversion context\n");
                exit(1);
            }
            sws_scale(is->img_convert_ctx, (void*)src_frame->data, src_frame->linesize,
                      0, vp->frm_height, pict.data, pict.linesize);
        }
        LAVPUnlockMutex(is->pictq.mutex);

        vp->frm_pts = pts;
        vp->frm_duration = duration;
        vp->frm_pos = pos;
        vp->frm_serial = serial;

        /* now we can update the picture count */
        frame_queue_push(&is->pictq);
    }
    return 0;
}

int get_video_frame(VideoState *is, AVFrame *frame)
{
    int got_picture;

    if ((got_picture = decoder_decode_frame(is->viddec, frame)) < 0)
        return -1;

    if (got_picture) {
        double dpts = NAN;

        if (frame->pts != AV_NOPTS_VALUE)
            dpts = av_q2d(is->video_st->time_base) * frame->pts;

        frame->sample_aspect_ratio = av_guess_sample_aspect_ratio(is->ic, is->video_st, frame);

        if (frame->pts != AV_NOPTS_VALUE) {
            double diff = dpts - get_master_clock(is);
            if (!isnan(diff) && fabs(diff) < AV_NOSYNC_THRESHOLD &&
                diff - is->frame_last_filter_delay < 0 &&
                is->viddec->pkt_serial == is->vidclk.serial &&
                is->videoq.nb_packets) {
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
    AVRational tb = is->video_st->time_base;
    AVRational frame_rate = av_guess_frame_rate(is->ic, is->video_st, NULL);

    for(;;) {
        @autoreleasepool {
            int ret = get_video_frame(is, frame);
            if (ret < 0)
                break;
            if (!ret)
                continue;

            double duration = (frame_rate.num && frame_rate.den ? av_q2d((AVRational){frame_rate.den, frame_rate.num}) : 0);
            double pts = (frame->pts == AV_NOPTS_VALUE) ? NAN : frame->pts * av_q2d(tb);
            ret = queue_picture(is, frame, pts, duration, av_frame_get_pkt_pos(frame), is->viddec->pkt_serial);
            av_frame_unref(frame);
            if (ret < 0)
                break;
        }
    }

    av_frame_free(&frame);
    return 0;
}

/* ========================================================================= */

#pragma mark -

Frame* lavp_get_current_frame(VideoState *is)
{
    LAVPLockMutex(is->pictq.mutex);
    bool success = false;

    if (frame_queue_nb_remaining(&is->pictq) <= 0)
        goto finish;

    Frame *vp = frame_queue_peek(&is->pictq);

    if (!vp)
        goto finish;

    if (vp->frm_pts >= 0 && vp == is->last_frame)
        goto finish;

    is->last_frame = vp;
    success = true;

finish:
    LAVPUnlockMutex(is->pictq.mutex);
    return success ? is->last_frame : NULL;
}
