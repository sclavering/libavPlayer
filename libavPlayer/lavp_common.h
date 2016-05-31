/*
 *  lavp_common.h
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

@import AudioToolbox;

#include "avcodec.h"
#include "avformat.h"
#include "avutil.h"

#include "libavutil/opt.h"
#include "libavutil/time.h"
#include "libswresample/swresample.h"

#import "LAVPMovie.h"

#include <pthread.h>


#define MAX_QUEUE_SIZE (15 * 1024 * 1024)
#define MIN_FRAMES 25

#define VIDEO_PICTURE_QUEUE_SIZE 15
#define SAMPLE_QUEUE_SIZE 9
#define FRAME_QUEUE_SIZE FFMAX(SAMPLE_QUEUE_SIZE, VIDEO_PICTURE_QUEUE_SIZE)

/* =========================================================== */

typedef struct AudioParams {
    int freq;
    int channels;
    int64_t channel_layout;
    enum AVSampleFormat fmt;
    int frame_size;
    int bytes_per_sec;
} AudioParams;

#import "clock.h"
#import "framequeue.h"
#import "decoder.h"
#import "VideoState.h"
