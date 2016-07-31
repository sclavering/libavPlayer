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


void lavp_if_new_video_frame_is_available_then_run(MovieState *mov, void (^func)(AVFrame *))
{
    int64_t now = clock_get_usec(mov);
    Frame *fr = NULL;
    // Note: the loop generally takes ~1ms which is plenty fast enough with us being called every ~16ms.
    for (;;) {
        fr = decoder_peek_current_frame(mov->viddec, mov);
        if (!fr) break;

        // If we've just seeked we want a new frame up ASAP (the clock comes from the first audio frame, which sometimes has a pts a little before that of the first video frame).
        if (fr->frm_serial != mov->last_shown_frame_serial) break;

        // If fr is still in the future don't show it yet (and we'll carry on showing the one already uploaded into a GL texture).
        if (now < fr->frm_pts_usec) {
            fr = NULL;
            break;
        }

        // If there's a later frame that we should already have shown or be showing then skip the earlier one.
        // xxx Maybe we should add a threshold to this, since if we've only overshot by a little bit it might be better to show a slightly stale frame for the sake of smoother playback in scenes with a lot of motion?
        Frame *next = decoder_peek_next_frame(mov->viddec);
        if (!next) break;
        if (now < next->frm_pts_usec) break;
        decoder_advance_frame(mov->viddec, mov);
    }

    if (fr) {
        func(fr->frm_frame);
        mov->last_shown_frame_serial = fr->frm_serial;
        decoder_advance_frame(mov->viddec, mov);
    }
}
