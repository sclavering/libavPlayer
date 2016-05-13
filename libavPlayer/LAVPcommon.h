/*
 *  LAVPcommon.h
 *  libavPlayer
 *
 *  Created by Takashi Mochizuki on 11/06/19.
 *  Copyright 2011 MyCometG3. All rights reserved.
 *
 */
/*
 This file is part of livavPlayer.

 livavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#ifndef __LAVPCommon_h__
#define __LAVPCommon_h__

@import AudioToolbox;

#include "avcodec.h"
#include "avformat.h"
#include "avutil.h"
#include "swscale.h"

#include "libavcodec/audioconvert.h"
#include "libavcodec/avfft.h"
#include "libavutil/imgutils.h"
#include "libavutil/eval.h"
#include "libavutil/parseutils.h"
#include "libavutil/opt.h"
#include "libavutil/colorspace.h"
#include "libavutil/time.h"
#include "libavutil/avstring.h"
#include "libswresample/swresample.h"

#include "LAVPthread.h"

#define ALLOW_GPL_CODE 1 /* LAVP: enable my pictformat code in GPL */

/* =========================================================== */

#define MAX_QUEUE_SIZE (15 * 1024 * 1024)
#define MIN_FRAMES 5

/* SDL audio buffer size, in samples. Should be small to have precise
 A/V sync as SDL does not have hardware buffer fullness info. */
#define SDL_AUDIO_BUFFER_SIZE 1024

/* no AV sync correction is done if below the minimum AV sync threshold */
#define AV_SYNC_THRESHOLD_MIN 0.01
/* AV sync correction is done if above the maximum AV sync threshold */
#define AV_SYNC_THRESHOLD_MAX 0.1
/* If a frame duration is longer than this, it will not be duplicated to compensate AV sync */
#define AV_SYNC_FRAMEDUP_THRESHOLD 0.1
/* no AV correction is done if too big error */
#define AV_NOSYNC_THRESHOLD 10.0

/* maximum audio speed change to get correct sync */
#define SAMPLE_CORRECTION_PERCENT_MAX 10

/* external clock speed adjustment constants for realtime sources based on buffer fullness */
#define EXTERNAL_CLOCK_SPEED_MIN  0.900
#define EXTERNAL_CLOCK_SPEED_MAX  1.010
#define EXTERNAL_CLOCK_SPEED_STEP 0.001

/* we use about AUDIO_DIFF_AVG_NB A-V differences to make the average */
#define AUDIO_DIFF_AVG_NB   20

/* =========================================================== */

#define VIDEO_PICTURE_QUEUE_SIZE 15 /* LAVP: no-overrun patch in refresh_loop_wait_event() applied */
#define SUBPICTURE_QUEUE_SIZE 16

#define FRAME_QUEUE_SIZE FFMAX(VIDEO_PICTURE_QUEUE_SIZE, SUBPICTURE_QUEUE_SIZE)

/* =========================================================== */

#define ALPHA_BLEND(a, oldp, newp, s)\
((((oldp << s) * (255 - (a))) + (newp * (a))) / (255 << s))

#define RGBA_IN(r, g, b, a, s)\
{\
unsigned int v = ((const uint32_t *)(s))[0];\
a = (v >> 24) & 0xff;\
r = (v >> 16) & 0xff;\
g = (v >> 8) & 0xff;\
b = v & 0xff;\
}

#define YUVA_IN(y, u, v, a, s, pal)\
{\
unsigned int val = ((const uint32_t *)(pal))[*(const uint8_t*)(s)];\
a = (val >> 24) & 0xff;\
y = (val >> 16) & 0xff;\
u = (val >> 8) & 0xff;\
v = val & 0xff;\
}

#define YUVA_OUT(d, y, u, v, a)\
{\
((uint32_t *)(d))[0] = (a << 24) | (y << 16) | (u << 8) | v;\
}

#define BPP 1

/* =========================================================== */

enum {
    AV_SYNC_AUDIO_MASTER, /* default choice */
    AV_SYNC_VIDEO_MASTER,
    AV_SYNC_EXTERNAL_CLOCK, /* synchronize to an external clock */
};

/* =========================================================== */

typedef struct MyAVPacketList {
    AVPacket pkt;
    struct MyAVPacketList *next;
    int serial;
} MyAVPacketList;

typedef struct PacketQueue {
    MyAVPacketList *first_pkt, *last_pkt;
    int nb_packets;
    int size;
    int abort_request;
    int serial;
    LAVPmutex *mutex;
    LAVPcond *cond;

    AVPacket flush_pkt; /* LAVP: assign queue specific flush packet */
} PacketQueue;

typedef struct AudioParams {
    int freq;
    int channels;
    int64_t channel_layout;
    enum AVSampleFormat fmt;
    int frame_size;
    int bytes_per_sec;
} AudioParams;

typedef struct Clock {
    double pts;           /* clock base */
    double pts_drift;     /* clock base minus time at which we updated the clock */
    double last_updated;
    double speed;
    int serial;           /* clock is based on a packet with this serial */
    int paused;
    int *queue_serial;    /* pointer to the current packet queue serial, used for obsolete clock detection */
} Clock;

#include "framequeue.h"
#include "decoder.h"
#include "VideoState.h"

#endif
