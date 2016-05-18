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

#include "lavp_common.h"
#include "lavp_core.h"
#include "lavp_video.h"
#import "packetqueue.h"
#include "lavp_audio.h"

#import "lavp_util.h"


/* no AV sync correction is done if below the minimum AV sync threshold */
#define AV_SYNC_THRESHOLD_MIN 0.01
/* AV sync correction is done if above the maximum AV sync threshold */
#define AV_SYNC_THRESHOLD_MAX 0.1
/* If a frame duration is longer than this, it will not be duplicated to compensate AV sync */
#define AV_SYNC_FRAMEDUP_THRESHOLD 0.1
/* no AV correction is done if too big error */
#define AV_NOSYNC_THRESHOLD 10.0


void video_display(VideoState *is);

double compute_target_delay(double delay, VideoState *is);

int queue_picture(VideoState *is, AVFrame *src_frame, double pts, double duration, int64_t pos, int serial);
int get_video_frame(VideoState *is, AVFrame *frame);
void video_refresh(VideoState *is, double *remaining_time);


/* =========================================================== */

#pragma mark -

void free_picture(Frame *vp)
{
    if (vp->bmp) {
        avpicture_free((AVPicture*)vp->bmp);
        av_free(vp->bmp);
        vp->bmp = NULL;
    }
}

/*
 TODO:
 fill_rectangle()
 fill_border()
 calculate_display_rect()
 video_image_display()
 compute_mod()
 video_audio_display()
 */

/* display the current picture, if any */
void video_display(VideoState *is)
{
    if (0 == is->width * is->height ) { // LAVP: zero rect is not allowed
        video_open(is, NULL);
    } else if (is->video_st) {
        //video_image_display(is); /* TODO */
    }
}

#pragma mark -

int video_open(VideoState *is, Frame *vp){
    /* LAVP: No need for SDL support; Independent from screen rect */
    int w,h;

    if (vp && vp->width * vp->height) {
        w = vp->width;
        h = vp->height;
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
    if (vp->serial == nextvp->serial) {
        double duration = nextvp->pts - vp->pts;
        if (isnan(duration) || duration <= 0 || duration > is->max_frame_duration)
            return vp->duration;
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
    double time;

    if (is->video_st) {
    retry:
        if (frame_queue_nb_remaining(&is->pictq) == 0) {
            // nothing to do, no picture to display in the queue
        } else {
            double last_duration, delay;
            Frame *vp, *lastvp;

            /* dequeue the picture */
            lastvp = frame_queue_peek_last(&is->pictq);
            vp = frame_queue_peek(&is->pictq);

            if (vp->serial != is->videoq.serial) {
                frame_queue_next(&is->pictq);
                goto retry;
            }

            if (lastvp->serial != vp->serial)
                is->frame_timer = av_gettime_relative() / 1000000.0;

            if (is->paused)
                goto display;

            /* compute nominal last_duration */
            last_duration = vp_duration(is, lastvp, vp);
            delay = compute_target_delay(last_duration, is);

            time = av_gettime_relative() / 1000000.0;
            if (time < is->frame_timer + delay) {
                *remaining_time = FFMIN(is->frame_timer + delay - time, *remaining_time);
                return;
            }

            is->frame_timer += delay;
            if (delay > 0 && time - is->frame_timer > AV_SYNC_THRESHOLD_MAX)
                is->frame_timer = time;

            LAVPLockMutex(is->pictq.mutex);
            if (!isnan(vp->pts))
                update_video_pts(is, vp->pts, vp->pos, vp->serial);
            LAVPUnlockMutex(is->pictq.mutex);

display:
            video_display(is);

            frame_queue_next(&is->pictq);

            if (is->step && !is->paused)
                stream_toggle_pause(is);
        }
    }
}

/* allocate a picture (needs to do that in main thread to avoid
 potential locking problems */
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

    vp->pts     = -1;
    vp->width   = is->video_st->codec->width;
    vp->height  = is->video_st->codec->height;
    vp->bmp = picture;
    vp->allocated = 1;

    LAVPCondSignal(is->pictq.cond);
    LAVPUnlockMutex(is->pictq.mutex);
}

int queue_picture(VideoState *is, AVFrame *src_frame, double pts, double duration, int64_t pos, int serial)
{
    Frame *vp;

    if (!(vp = frame_queue_peek_writable(&is->pictq)))
        return -1;

    vp->sar = src_frame->sample_aspect_ratio;

    /* alloc or resize hardware picture buffer */
    if (!vp->bmp || vp->reallocate || !vp->allocated ||
        vp->width != is->video_st->codec->width ||
        vp->height != is->video_st->codec->height) {

        vp->allocated = 0;
        vp->reallocate = 0;
        vp->width = src_frame->width;
        vp->height = src_frame->height;

        /* the allocation must be done in the main thread to avoid
         locking problems. */
        /* LAVP: Using is->decoderThread */
        id movieWrapper = is->movieWrapper;
        NSThread *thread = is->decoderThread;
        [movieWrapper performSelector:@selector(allocPicture) onThread:thread withObject:nil waitUntilDone:NO];

        /* wait until the picture is allocated */
        LAVPLockMutex(is->pictq.mutex);
        while (!vp->allocated && !is->videoq.abort_request) {
            LAVPCondWait(is->pictq.cond, is->pictq.mutex);
        }
        /* if the queue is aborted, we have to pop the pending ALLOC event or wait for the allocation to complete */
        if (is->videoq.abort_request) {
            while (!vp->allocated && !is->abort_request) {
                LAVPCondWait(is->pictq.cond, is->pictq.mutex);
            }
        }
        LAVPUnlockMutex(is->pictq.mutex);

        if (is->videoq.abort_request)
            return -1;
    }

    /* if the frame is not skipped, then display it */
    if (vp->bmp) {
        AVPicture pict = { { 0 } };

        /* get a pointer on the bitmap */
        /* LAVP: Using AVFrame */
        memset(&pict,0,sizeof(AVPicture));
        pict.data[0] = vp->bmp->data[0];
        pict.data[1] = vp->bmp->data[1];
        pict.data[2] = vp->bmp->data[2];

        pict.linesize[0] = vp->bmp->linesize[0];
        pict.linesize[1] = vp->bmp->linesize[1];
        pict.linesize[2] = vp->bmp->linesize[2];

        /* LAVP: duplicate or create YUV420P picture */
        LAVPLockMutex(is->pictq.mutex);
        if (src_frame->format == AV_PIX_FMT_YUV420P) {
            CVF_CopyPlane((const UInt8 *)src_frame->data[0], src_frame->linesize[0], vp->height, pict.data[0], pict.linesize[0], vp->height);
            CVF_CopyPlane((const UInt8 *)src_frame->data[1], src_frame->linesize[1], vp->height, pict.data[1], pict.linesize[1], vp->height/2);
            CVF_CopyPlane((const UInt8 *)src_frame->data[2], src_frame->linesize[2], vp->height, pict.data[2], pict.linesize[2], vp->height/2);
        } else {
            /* convert image format */
            is->img_convert_ctx = sws_getCachedContext(is->img_convert_ctx,
                                                       vp->width, vp->height, src_frame->format,
                                                       vp->width, vp->height, AV_PIX_FMT_YUV420P,
                                                       SWS_BICUBIC, NULL, NULL, NULL);
            if (is->img_convert_ctx == NULL) {
                av_log(NULL, AV_LOG_FATAL, "Cannot initialize the conversion context\n");
                exit(1);
            }
            sws_scale(is->img_convert_ctx, (void*)src_frame->data, src_frame->linesize,
                      0, vp->height, pict.data, pict.linesize);
        }
        LAVPUnlockMutex(is->pictq.mutex);

        vp->pts = pts;
        vp->duration = duration;
        vp->pos = pos;
        vp->serial = serial;

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
    double pts;
    double duration;
    int ret;
    AVRational tb = is->video_st->time_base;
    AVRational frame_rate = av_guess_frame_rate(is->ic, is->video_st, NULL);

    for(;;) {
        @autoreleasepool {
            ret = get_video_frame(is, frame);
            if (ret < 0) {
                goto the_end;
            }
            if (!ret)
                continue;

            duration = (frame_rate.num && frame_rate.den ? av_q2d((AVRational){frame_rate.den, frame_rate.num}) : 0);
            pts = (frame->pts == AV_NOPTS_VALUE) ? NAN : frame->pts * av_q2d(tb);
            ret = queue_picture(is, frame, pts, duration, av_frame_get_pkt_pos(frame), is->viddec->pkt_serial);
            av_frame_unref(frame);

            if (ret < 0)
                goto the_end;
        }
    }
the_end:
    av_frame_free(&frame);

    return 0;
}

/* ========================================================================= */

#pragma mark -

int hasImage(VideoState *is)
{
    LAVPLockMutex(is->pictq.mutex);

    if (frame_queue_nb_remaining(&is->pictq) > 0) {
        Frame *vp = frame_queue_peek(&is->pictq);
        if (!vp) vp = frame_queue_peek_last(&is->pictq);
        if (vp) {
            LAVPUnlockMutex(is->pictq.mutex);
            return 1;
        }
    }

bail:
    LAVPUnlockMutex(is->pictq.mutex);
    return 0;
}

int copyImage(VideoState *is, uint8_t* data, int pitch)
{
    uint8_t * out[4] = {0};
    out[0] = data;
    assert(data);

    LAVPLockMutex(is->pictq.mutex);

    if (frame_queue_nb_remaining(&is->pictq) > 0) {
        Frame *vp = frame_queue_peek(&is->pictq);
        if (!vp) vp = frame_queue_peek_last(&is->pictq);

        if (vp) {
            int result = 0;

            if (vp->pts >= 0 && vp->pts == is->lastPTScopied) {
                LAVPUnlockMutex(is->pictq.mutex);
                return 2;
            }

            uint8_t *in[4] = {vp->bmp->data[0], vp->bmp->data[1], vp->bmp->data[2], vp->bmp->data[3]};
            size_t inpitch[4] = {vp->bmp->linesize[0], vp->bmp->linesize[1], vp->bmp->linesize[2], vp->bmp->linesize[3]};
            copy_planar_YUV420_to_2vuy(vp->width, vp->height,
                                       in[0], inpitch[0],
                                       in[1], inpitch[1],
                                       in[2], inpitch[2],
                                       data, pitch);
            result = 1;

            if (result > 0) {
                is->lastPTScopied = vp->pts;
                LAVPUnlockMutex(is->pictq.mutex);
                return 1;
            } else {
                NSLog(@"ERROR: result != 0 (%s)", __FUNCTION__);
            }
        } else {
            NSLog(@"ERROR: vp == NULL (%s)", __FUNCTION__);
        }
    }

bail:
    LAVPUnlockMutex(is->pictq.mutex);
    return 0;
}
