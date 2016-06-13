#import "lavp_common.h"

#import "packetqueue.h"


@implementation Decoder
@end

static int decoder_decode_single_frame_from_packet_into(Decoder *d, AVPacket *pkt, int *got_frame, Frame *fr);
void decoder_thread(Decoder *d);

int decoder_init(Decoder *d, AVCodecContext *avctx, pthread_cond_t *empty_queue_cond_ptr, int frame_queue_max_size, AVStream *stream) {
    d->tmp_frame = av_frame_alloc();
    d->stream = stream;
    d->avctx = avctx;
    d->empty_queue_cond_ptr = empty_queue_cond_ptr;
    // Note: if we pass 0 for keep_last then audio is an unrecognisable mess (presumably we're relying on the frame-queue to keep the currentlly-being-played sample) alive, or somesuch.
    int err = frame_queue_init(&d->frameq, &d->packetq, frame_queue_max_size, 1);
    if(err < 0) return err;
    packet_queue_init(&d->packetq);
    d->dispatch_queue = dispatch_queue_create(NULL, NULL);
    d->dispatch_group = dispatch_group_create();
    dispatch_group_async(d->dispatch_group, d->dispatch_queue, ^(void) {
        decoder_thread(d);
    });
    return 0;
}

int decoder_decode_next_packet(Decoder *d) {
    int ret = 0;

    AVPacket pkt;
    AVPacket partial_pkt;

    if (d->packetq.pq_abort)
        goto fail;

    do {
        if (d->packetq.pq_length == 0)
            pthread_cond_signal(d->empty_queue_cond_ptr);
        if (packet_queue_get(&d->packetq, &pkt, &d->pkt_serial) < 0)
            goto fail;
        if (pkt.data == flush_pkt.data) {
            avcodec_flush_buffers(d->avctx);
            d->finished = 0;
            d->next_pts = AV_NOPTS_VALUE;
        }
    } while (pkt.data == flush_pkt.data || d->packetq.pq_serial != d->pkt_serial);
    partial_pkt = pkt;

    for (;;) {
        if (d->packetq.pq_abort)
            goto fail;

        Frame* fr = frame_queue_peek_writable(&d->frameq);
        // This only happens if we're closing the movie.
        if (!fr)
            goto fail;

        int got_frame = 0;
        int bytes_consumed = decoder_decode_single_frame_from_packet_into(d, &partial_pkt, &got_frame, fr);

        if (bytes_consumed < 0)
            break;

        partial_pkt.dts =
        partial_pkt.pts = AV_NOPTS_VALUE;
        if (partial_pkt.data) {
            if (d->avctx->codec_type != AVMEDIA_TYPE_AUDIO)
                bytes_consumed = partial_pkt.size;
            partial_pkt.data += bytes_consumed;
            partial_pkt.size -= bytes_consumed;
            if (partial_pkt.size <= 0)
                break;
        } else {
            if (!got_frame) {
                d->finished = d->pkt_serial;
                break;
            }
        }
    }
    goto out;

fail:
    ret = -1;
out:
    av_packet_unref(&pkt);
    return ret;
}

static int decoder_decode_single_frame_from_packet_into(Decoder *d, AVPacket *pkt, int *got_frame, Frame *fr)
{
    AVFrame *frame = d->tmp_frame;
    int ret = -1;
    switch (d->avctx->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
            ret = avcodec_decode_video2(d->avctx, frame, got_frame, pkt);
            if (*got_frame) {
                frame->pts = av_frame_get_best_effort_timestamp(frame);
            }
            break;
        case AVMEDIA_TYPE_AUDIO:
            ret = avcodec_decode_audio4(d->avctx, frame, got_frame, pkt);
            if (*got_frame) {
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

    if (*got_frame) {
        AVRational tb = { 0, 0 };
        if (d->avctx->codec_type == AVMEDIA_TYPE_VIDEO) tb = d->stream->time_base;
        else if (d->avctx->codec_type == AVMEDIA_TYPE_AUDIO) tb = (AVRational){ 1, frame->sample_rate };
        fr->frm_pts = frame->pts == AV_NOPTS_VALUE ? NAN : frame->pts * av_q2d(tb);
        fr->frm_serial = d->pkt_serial;
        av_frame_move_ref(fr->frm_frame, frame);
        frame_queue_push(&d->frameq);
    }

    return ret;
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
    avcodec_free_context(&d->avctx);

    packet_queue_destroy(&d->packetq);
    frame_queue_destroy(&d->frameq);

    av_frame_free(&d->tmp_frame);
    d->tmp_frame = NULL;
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

bool decoder_drop_frames_with_expired_serial(Decoder *d)
{
    // Skips any frames left over from before seeking.
    int i = 0;
    for(;;) {
        Frame *fr = decoder_peek_current_frame(d);
        if (!fr) return true;
        if (fr->frm_serial == d->packetq.pq_serial) break;
        decoder_advance_frame(d);
        ++i;
    }
    return false;
}

void decoder_thread(Decoder *d)
{
    for(;;) {
        int err = decoder_decode_next_packet(d);
        if (err < 0) break;
    }
}

void decoder_advance_frame(Decoder *d)
{
  frame_queue_next(&d->frameq);
}

Frame *decoder_peek_current_frame(Decoder *d)
{
  return frame_queue_peek(&d->frameq);
}

Frame *decoder_peek_next_frame(Decoder *d)
{
  return frame_queue_peek_next(&d->frameq);
}

Frame *decoder_peek_current_frame_blocking(Decoder *d)
{
  return frame_queue_peek_blocking(&d->frameq);
}
