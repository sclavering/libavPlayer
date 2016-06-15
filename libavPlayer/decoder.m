#import "lavp_common.h"

#import "packetqueue.h"


@implementation Decoder
@end

static void decoder_enqueue_frame_into(Decoder *d, AVFrame *frame, Frame *fr);
void decoder_thread(Decoder *d);

int decoder_init(Decoder *d, AVCodecContext *avctx, pthread_cond_t *empty_queue_cond_ptr, int frame_queue_max_size, AVStream *stream) {
    d->tmp_frame = av_frame_alloc();
    d->stream = stream;
    d->avctx = avctx;
    d->empty_queue_cond_ptr = empty_queue_cond_ptr;
    // Note: if we pass 0 for keep_last then audio is an unrecognisable mess (presumably we're relying on the frame-queue to keep the currentlly-being-played sample) alive, or somesuch.
    int err = frame_queue_init(&d->frameq, frame_queue_max_size, 1);
    if(err < 0) return err;
    d->abort = 0;
    packet_queue_init(&d->packetq);
    d->dispatch_queue = dispatch_queue_create(NULL, NULL);
    d->dispatch_group = dispatch_group_create();
    dispatch_group_async(d->dispatch_group, d->dispatch_queue, ^(void) {
        decoder_thread(d);
    });
    return 0;
}

int decoder_decode_next_packet(Decoder *d) {
    AVPacket pkt;

try_again:
    if (d->abort)
        return -1;

    do {
        if (d->packetq.pq_length == 0)
            pthread_cond_signal(d->empty_queue_cond_ptr);
        if (packet_queue_get(&d->packetq, &pkt, &d->pkt_serial, d) < 0)
            return -1;
        if (pkt.data == flush_pkt.data) {
            avcodec_flush_buffers(d->avctx);
            d->finished = 0;
            d->next_pts = AV_NOPTS_VALUE;
        }
    } while (pkt.data == flush_pkt.data || d->packetq.pq_serial != d->pkt_serial);

    int err = avcodec_send_packet(d->avctx, &pkt);
    av_packet_unref(&pkt);
    // xxx avcodec_send_packet() isn't documented as returning this error.  But I've observed it doing so for an audio stream after seeking, on an occasion where "[mp3 @ ...] Header missing" was also logged to the console.  Absent this special case, the decoder_thread would get shut down.
    if (err == AVERROR_INVALIDDATA)
        goto try_again;
    // Note: since we're looping over all frames from the packet, we shouldn't need to check for AVERROR(EAGAIN).
    if (err)
        return -1;

    for (;;) {
        if (d->abort)
            return -1;

        Frame* fr = frame_queue_peek_writable(&d->frameq, d);
        // This only happens if we're closing the movie.
        if (!fr)
            return -1;

        err = avcodec_receive_frame(d->avctx, d->tmp_frame);
        if (!err) {
            decoder_enqueue_frame_into(d, d->tmp_frame, fr);
        }
        // If we've consumed all frames from the current packet.
        if (err == AVERROR(EAGAIN))
            break;
        if (err == AVERROR_EOF) {
            d->finished = d->pkt_serial;
            break;
        }
    }

    return 0;
}

static void decoder_enqueue_frame_into(Decoder *d, AVFrame *frame, Frame *fr)
{
        switch (d->avctx->codec_type) {
            case AVMEDIA_TYPE_VIDEO:
                frame->pts = av_frame_get_best_effort_timestamp(frame);
                // The last video frame of an .avi file seems to always have av_frame_get_best_effort_timestamp() return AV_NOPTS_VALUE (->frm_pts and ->frm_dts are also AV_NOPTS_VALUE).  Ignore these frames, since video_refresh() doesn't know what to do with a frame with no pts, so we end up never advancing past them, which means we fail to detect EOF when playing (and so we fail to pause, and the clock runs past the end of the movie, and our CPU usage stays high).  Of course in theory theses could appear elsewhere, but we'd still not know what to do with frames with no pts.
                if (frame->pts == AV_NOPTS_VALUE) return;
                break;
            case AVMEDIA_TYPE_AUDIO: {
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
                break;
            }
            default:
                break;
        }

        AVRational tb = { 0, 0 };
        if (d->avctx->codec_type == AVMEDIA_TYPE_VIDEO) tb = d->stream->time_base;
        else if (d->avctx->codec_type == AVMEDIA_TYPE_AUDIO) tb = (AVRational){ 1, frame->sample_rate };
        fr->frm_pts = frame->pts == AV_NOPTS_VALUE ? NAN : frame->pts * av_q2d(tb);
        fr->frm_serial = d->pkt_serial;
        av_frame_move_ref(fr->frm_frame, frame);
        frame_queue_push(&d->frameq);
}

void decoder_destroy(Decoder *d)
{
    d->abort = 1;
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
    packet_queue_put(&d->packetq, pkt, d);
    return true;
}

void decoder_update_for_seek(Decoder *d)
{
    packet_queue_flush(&d->packetq);
    packet_queue_put(&d->packetq, &flush_pkt, d);
}

void decoder_update_for_eof(Decoder *d)
{
    packet_queue_put_nullpacket(&d->packetq, d->stream->index, d);
}

bool decoder_needs_more_packets(Decoder *d)
{
    return !d->abort && d->packetq.pq_length < MIN_FRAMES;
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
  return frame_queue_peek_blocking(&d->frameq, d);
}
