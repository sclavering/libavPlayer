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

#import "MovieState.h"
#import "decoder.h"


void video_refresh(MovieState *mov)
{
    if (mov->paused)
        return;

    // Skip any frames that are in the past (except the current frame).
    for(;;) {
        Frame *curr = decoder_peek_current_frame(mov->viddec);
        if (!curr) return;
        Frame *next = decoder_peek_next_frame(mov->viddec);
        int64_t now = clock_get_usec(mov);
        // If the next frame is still in the future, stop here.
        if (next && !(curr->frm_pts_usec < now && next->frm_pts_usec < now)) break;
        // If we've reached EOF, we should advance the queue, but only once the final frame has had its duration.
        if (!next) {
            AVRational frame_rate = av_guess_frame_rate(mov->ic, mov->viddec->stream, NULL);
            int64_t duration = frame_rate.num && frame_rate.den ? (frame_rate.den * 1000000LL) / frame_rate.num : 0;
            if (now < curr->frm_pts_usec + duration) break;
        }
        decoder_advance_frame(mov->viddec);
    }

    if (mov->is_temporarily_unpaused_to_handle_seeking) lavp_set_paused_internal(mov, true);
}

AVFrame* lavp_get_current_frame(MovieState *mov)
{
    // This seems to take ~1ms typically, and occasionally ~10ms (presumably when waiting on the mutex), so shouldn't interfere with 60fps updating.
    video_refresh(mov);

    Frame* fr = decoder_peek_current_frame(mov->viddec);
    if (!fr || fr->frm_pts_usec == mov->last_shown_video_frame_pts) return NULL;

    // Other pixel formats are vanishingly rare, so don't bother with them, at least for now.
    // If we ever do handle them, doing conversion via OpenGL would probably work fine here, but for CPU conversion we'd likely want to do it in advance.
    if (fr->frm_frame->format != AV_PIX_FMT_YUV420P) return NULL;

    mov->last_shown_video_frame_pts = fr->frm_pts_usec;
    return fr->frm_frame;
}
