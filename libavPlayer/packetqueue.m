/*
 *  Created by Takashi Mochizuki on 11/06/18.
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

#import "lavp_core.h"
#import "lavp_video.h"
#import "packetqueue.h"
#import "lavp_audio.h"


void packet_queue_init(PacketQueue *q)
{
    memset(q, 0, sizeof(PacketQueue));
    pthread_mutex_init(&q->mutex, NULL);
    pthread_cond_init(&q->cond, NULL);
}

void packet_queue_flush(PacketQueue *q)
{
    MyAVPacketList *pkt, *pkt1;

    pthread_mutex_lock(&q->mutex);
    for (pkt = q->first_pkt; pkt; pkt = pkt1) {
        pkt1 = pkt->next;
        av_packet_unref(&pkt->pkt);
        av_freep(&pkt);
    }
    q->last_pkt = NULL;
    q->first_pkt = NULL;
    q->pq_length = 0;
    pthread_mutex_unlock(&q->mutex);
}

void packet_queue_abort(PacketQueue *q)
{
    pthread_mutex_lock(&q->mutex);
    pthread_cond_signal(&q->cond);
    pthread_mutex_unlock(&q->mutex);
}

void packet_queue_destroy(PacketQueue *q)
{
    packet_queue_flush(q);
    pthread_mutex_destroy(&q->mutex);
    pthread_cond_destroy(&q->cond);
}

int packet_queue_put(PacketQueue *q, AVPacket *pkt, Decoder *d)
{
    if (d->abort) goto fail;
    MyAVPacketList *pkt1 = av_malloc(sizeof(MyAVPacketList));
    if (!pkt1) goto fail;
    pthread_mutex_lock(&q->mutex);
    pkt1->pkt = *pkt;
    pkt1->next = NULL;
    pkt1->serial = d->current_serial;
    if (!q->last_pkt)
        q->first_pkt = pkt1;
    else
        q->last_pkt->next = pkt1;
    q->last_pkt = pkt1;
    q->pq_length++;
    /* XXX: should duplicate packet data in DV case */
    pthread_cond_signal(&q->cond);
    pthread_mutex_unlock(&q->mutex);
    return 0;
fail:
    av_packet_unref(pkt);
    return -1;
}

int packet_queue_put_nullpacket(PacketQueue *q, int stream_index, Decoder *d)
{
    AVPacket pkt1, *pkt = &pkt1;
    av_init_packet(pkt);
    pkt->data = NULL;
    pkt->size = 0;
    pkt->stream_index = stream_index;
    return packet_queue_put(q, pkt, d);
}

int packet_queue_get(PacketQueue *q, AVPacket *pkt, int *serial, Decoder *d)
{
    MyAVPacketList *pkt1;
    int ret = 0;
    pthread_mutex_lock(&q->mutex);
    for(;;) {
        if (d->abort) {
            ret = -1;
            break;
        }
        pkt1 = q->first_pkt;
        if (pkt1) {
            q->first_pkt = pkt1->next;
            if (!q->first_pkt)
                q->last_pkt = NULL;
            q->pq_length--;
            *pkt = pkt1->pkt;
            if (serial)
                *serial = pkt1->serial;
            av_free(pkt1);
            break;
        }
        pthread_cond_wait(&q->cond, &q->mutex);
    }
    pthread_mutex_unlock(&q->mutex);
    return ret;
}
