/*
 *  lavp_audio.h
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

int audio_open(VideoState *is, int64_t wanted_channel_layout, int wanted_nb_channels, int wanted_sample_rate, struct AudioParams *audio_hw_params);

void audio_queue_init(VideoState *is, AVCodecContext *avctx);
void audio_queue_start(VideoState *is);
void audio_queue_pause(VideoState *is);
void audio_queue_destroy(VideoState *is);

int audio_thread(VideoState *is);

void lavp_audio_update_speed(VideoState *is);
int lavp_get_volume_percent(VideoState *is);
void lavp_set_volume_percent(VideoState *is, int volume);
