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


/* no AV correction is done if too big error */
#define AV_NOSYNC_THRESHOLD 10.0


void video_refresh(VideoState *is)
{
    if (is->paused)
        return;

    if (!is->viddec->stream) return;

    if(decoder_drop_frames_with_expired_serial(is->viddec))
        return;

    // Skip any frames that are in the past (except the current frame).
    for(;;) {
        if (frame_queue_nb_remaining(&is->viddec->frameq) == 0) return;
        Frame *curr = frame_queue_peek(&is->viddec->frameq);
        Frame *next = frame_queue_peek_next(&is->viddec->frameq);
        double now = get_clock(&is->audclk);
        // If the next frame is still in the future, stop here.
        if (next && !(curr->frm_pts < now && next->frm_pts < now)) break;
        // If we've reached EOF, we should advance the queue, but only once the final frame has had its duration.
        if (!next && now < curr->frm_pts + curr->frm_duration) break;
        frame_queue_next(&is->viddec->frameq);
    }

    if (is->is_temporarily_unpaused_to_handle_seeking) {
        lavp_set_paused_internal(is, true);
        __strong id<LAVPMovieOutput> movieOutput = is->weakOutput;
        if(movieOutput) [movieOutput movieOutputNeedsSingleUpdate];
    }
}

int video_thread(VideoState *is)
{
    AVFrame *frame = av_frame_alloc();
    AVRational tb = is->viddec->stream->time_base;
    AVRational frame_rate = av_guess_frame_rate(is->ic, is->viddec->stream, NULL);
    double duration = frame_rate.num && frame_rate.den ? av_q2d((AVRational){frame_rate.den, frame_rate.num}) : 0;

    for(;;) {
        int err = decoder_decode_frame(is->viddec, frame);
        if (err < 0) break;
        if (err == 0) continue;

        if (frame->pts != AV_NOPTS_VALUE) {
            double dpts = av_q2d(tb) * frame->pts;
            double diff = dpts - get_clock(&is->audclk);
            if (!isnan(diff) && fabs(diff) < AV_NOSYNC_THRESHOLD && diff < 0 && is->viddec->pkt_serial == is->audclk.serial && is->viddec->packetq.nb_packets) {
                av_frame_unref(frame);
                continue;
            }
        }

        // Other pixel formats are rare, and converting them would be hard (and probably end up happening in software, rather than on the GPU), so don't bother, at least for now.
        if (frame->format != AV_PIX_FMT_YUV420P)
            break;

        if(!decoder_push_frame(is->viddec, frame,
                /* pts */ frame->pts == AV_NOPTS_VALUE ? NAN : frame->pts * av_q2d(tb),
                /* duration */ duration
                ))
            break;
    }

    av_frame_free(&frame);
    return 0;
}

Frame* lavp_get_current_frame(VideoState *is)
{
    Frame* fr = decoder_get_current_frame_or_null(is->viddec);
    if(fr == is->last_frame) return NULL;
    if(fr) is->last_frame = fr;
    return fr;
}
