/*
 *  packetqueue.h
 *  libavPlayer
 *
 *  Created by Takashi Mochizuki on 11/06/18.
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

extern AVPacket flush_pkt;

typedef struct MyAVPacketList {
    AVPacket pkt;
    struct MyAVPacketList *next;
    int serial;
} MyAVPacketList;

typedef struct PacketQueue {
    MyAVPacketList *first_pkt, *last_pkt;
    int pq_length;
    int pq_abort;
    int pq_serial;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} PacketQueue;

void packet_queue_init(PacketQueue *q);
void packet_queue_flush(PacketQueue *q);
void packet_queue_abort(PacketQueue *q);
void packet_queue_destroy(PacketQueue *q);
int packet_queue_put(PacketQueue *q, AVPacket *pkt);
int packet_queue_put_nullpacket(PacketQueue *q, int stream_index);
int packet_queue_get(PacketQueue *q, AVPacket *pkt, int *serial);
