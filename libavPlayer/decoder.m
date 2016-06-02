#import "lavp_common.h"

#import "packetqueue.h" // for packet_queue_get()

@implementation Decoder
@end

int decoder_init(Decoder *d, AVCodecContext *avctx, pthread_cond_t *empty_queue_cond_ptr, int frame_queue_max_size, AVStream *stream) {
    d->stream = stream;
    d->avctx = avctx;
    d->empty_queue_cond_ptr = empty_queue_cond_ptr;
    d->start_pts = AV_NOPTS_VALUE;
    int err = frame_queue_init(&d->frameq, &d->packetq, frame_queue_max_size, 1);
    if(err < 0) return err;
    packet_queue_init(&d->packetq);
    return 0;
}

int decoder_decode_frame(Decoder *d, AVFrame *frame) {
    int got_frame = 0;

    do {
        int ret = -1;

        if (d->packetq.pq_abort)
            return -1;

        if (!d->packet_pending || d->packetq.pq_serial != d->pkt_serial) {
            AVPacket pkt;
            do {
                if (d->packetq.pq_length == 0)
                    pthread_cond_signal(d->empty_queue_cond_ptr);
                if (packet_queue_get(&d->packetq, &pkt, 1, &d->pkt_serial) < 0)
                    return -1;
                if (pkt.data == flush_pkt.data) {
                    avcodec_flush_buffers(d->avctx);
                    d->finished = 0;
                    d->next_pts = d->start_pts;
                    d->next_pts_tb = d->start_pts_tb;
                }
            } while (pkt.data == flush_pkt.data || d->packetq.pq_serial != d->pkt_serial);
            av_packet_unref(&d->pkt);
            d->pkt_temp = d->pkt = pkt;
            d->packet_pending = 1;
        }

        switch (d->avctx->codec_type) {
            case AVMEDIA_TYPE_VIDEO:
                ret = avcodec_decode_video2(d->avctx, frame, &got_frame, &d->pkt_temp);
                if (got_frame) {
                    frame->pts = av_frame_get_best_effort_timestamp(frame);
                }
                break;
            case AVMEDIA_TYPE_AUDIO:
                ret = avcodec_decode_audio4(d->avctx, frame, &got_frame, &d->pkt_temp);
                if (got_frame) {
                    AVRational tb = (AVRational){1, frame->sample_rate};
                    if (frame->pts != AV_NOPTS_VALUE)
                        frame->pts = av_rescale_q(frame->pts, d->avctx->time_base, tb);
                    else if (frame->pkt_pts != AV_NOPTS_VALUE)
                        frame->pts = av_rescale_q(frame->pkt_pts, av_codec_get_pkt_timebase(d->avctx), tb);
                    else if (d->next_pts != AV_NOPTS_VALUE)
                        frame->pts = av_rescale_q(d->next_pts, d->next_pts_tb, tb);
                    if (frame->pts != AV_NOPTS_VALUE) {
                        d->next_pts = frame->pts + frame->nb_samples;
                        d->next_pts_tb = tb;
                    }
                }
                break;
            default:
                break;
        }

        if (ret < 0) {
            d->packet_pending = 0;
        } else {
            d->pkt_temp.dts =
            d->pkt_temp.pts = AV_NOPTS_VALUE;
            if (d->pkt_temp.data) {
                if (d->avctx->codec_type != AVMEDIA_TYPE_AUDIO)
                    ret = d->pkt_temp.size;
                d->pkt_temp.data += ret;
                d->pkt_temp.size -= ret;
                if (d->pkt_temp.size <= 0)
                    d->packet_pending = 0;
            } else {
                if (!got_frame) {
                    d->packet_pending = 0;
                    d->finished = d->pkt_serial;
                }
            }
        }
    } while (!got_frame && !d->finished);

    return got_frame;
}

void decoder_destroy(Decoder *d)
{
    packet_queue_abort(&d->packetq);
    frame_queue_signal(&d->frameq);

    dispatch_group_wait(d->dispatch_group, DISPATCH_TIME_FOREVER);
    d->dispatch_group = NULL;
    d->dispatch_queue = NULL;

    packet_queue_flush(&d->packetq);
    d->stream->discard = AVDISCARD_ALL;
    d->stream = NULL;
    av_packet_unref(&d->pkt);
    avcodec_free_context(&d->avctx);

    packet_queue_destroy(&d->packetq);
    frame_queue_destory(&d->frameq);
}

// LAVP: in ffplay the signature is:
// static void decoder_start(Decoder *d, int (*fn)(void *), void *arg)
void decoder_start(Decoder *d, int (*fn)(VideoState *), VideoState *is)
{
    packet_queue_start(&d->packetq);
    // LAVP: Use a dispatch queue instead of an SDL thread.
    d->dispatch_queue = dispatch_queue_create(NULL, NULL);
    d->dispatch_group = dispatch_group_create();
    __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
    dispatch_group_async(d->dispatch_group, d->dispatch_queue, ^(void) {
        __strong VideoState* strongIs = weakIs;
        if(strongIs) fn(strongIs);
    });
}

bool decoder_maybe_handle_packet(Decoder *d, AVPacket *pkt)
{
    if (pkt->stream_index != d->stream->index)
        return false;
    packet_queue_put(&d->packetq, pkt);
    return true;
}

void decoder_update_for_seek(Decoder *d)
{
    packet_queue_flush(&d->packetq);
    packet_queue_put(&d->packetq, &flush_pkt);
}

void decoder_update_for_eof(Decoder *d)
{
    packet_queue_put_nullpacket(&d->packetq, d->stream->index);
}

bool decoder_needs_more_packets(Decoder *d)
{
    return !d->packetq.pq_abort && d->packetq.pq_length < MIN_FRAMES;
}

bool decoder_finished(Decoder *d)
{
    return d->finished == d->packetq.pq_serial && frame_queue_nb_remaining(&d->frameq) == 0;
}

bool decoder_push_frame(Decoder *d, AVFrame *frame, double pts)
{
    Frame* fr = frame_queue_peek_writable(&d->frameq);
    if(!fr) return false;
    fr->frm_pts = pts;
    fr->frm_serial = d->pkt_serial;
    av_frame_move_ref(fr->frm_frame, frame);
    frame_queue_push(&d->frameq);
    return true;
}

Frame* decoder_get_current_frame_or_null(Decoder *d)
{
    pthread_mutex_lock(&d->frameq.mutex);
    Frame* rv = frame_queue_nb_remaining(&d->frameq) > 0 ? frame_queue_peek(&d->frameq) : NULL;
    pthread_mutex_unlock(&d->frameq.mutex);
    return rv;
}

bool decoder_drop_frames_with_expired_serial(Decoder *d)
{
    // Skips any frames left over from before seeking.
    int i = 0;
    for(;;) {
        if (frame_queue_nb_remaining(&d->frameq) == 0) return true;
        Frame *fr = frame_queue_peek(&d->frameq);
        if (fr->frm_serial == d->packetq.pq_serial) break;
        frame_queue_next(&d->frameq);
        ++i;
    }
    return false;
}
