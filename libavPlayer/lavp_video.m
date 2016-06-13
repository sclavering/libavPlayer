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


void video_refresh(VideoState *is)
{
    if (is->paused)
        return;

    if (!is->viddec->stream) return;

    if(decoder_drop_frames_with_expired_serial(is->viddec))
        return;

    // Skip any frames that are in the past (except the current frame).
    for(;;) {
        Frame *curr = decoder_peek_current_frame(is->viddec);
        if (!curr) return;
        Frame *next = decoder_peek_next_frame(is->viddec);
        double now = clock_get(&is->audclk);
        // If the next frame is still in the future, stop here.
        if (next && !(curr->frm_pts < now && next->frm_pts < now)) break;
        // If we've reached EOF, we should advance the queue, but only once the final frame has had its duration.
        if (!next) {
            AVRational frame_rate = av_guess_frame_rate(is->ic, is->viddec->stream, NULL);
            double duration = frame_rate.num && frame_rate.den ? av_q2d((AVRational){ frame_rate.den, frame_rate.num }) : 0;
            if (now < curr->frm_pts + duration) break;
        }
        decoder_advance_frame(is->viddec);
    }

    if (is->is_temporarily_unpaused_to_handle_seeking) lavp_set_paused_internal(is, true);
}

AVFrame* lavp_get_current_frame(VideoState *is)
{
    // This seems to take ~1ms typically, and occasionally ~10ms (presumably when waiting on the mutex), so shouldn't interfere with 60fps updating.
    video_refresh(is);

    Frame* fr = decoder_peek_current_frame(is->viddec);
    if (!fr || fr->frm_pts == is->last_shown_video_frame_pts) return NULL;

    // Other pixel formats are vanishingly rare, so don't bother with them, at least for now.
    // If we ever do handle them, doing conversion via OpenGL would probably work fine here, but for CPU conversion we'd likely want to do it in advance.
    if (fr->frm_frame->format != AV_PIX_FMT_YUV420P) return NULL;

    is->last_shown_video_frame_pts = fr->frm_pts;
    return fr->frm_frame;
}
