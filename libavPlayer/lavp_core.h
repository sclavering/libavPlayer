/*
 *  lavp_core.h
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

void stream_close(MovieState *mov);
MovieState* stream_open(NSURL *sourceURL);

void lavp_seek(MovieState *mov, int64_t pos, int64_t current_pos);

void lavp_set_paused_internal(MovieState *mov, bool pause);
void lavp_set_paused(MovieState *mov, bool pause);

int lavp_get_playback_speed_percent(MovieState *mov);
void lavp_set_playback_speed_percent(MovieState *mov, int speed);
