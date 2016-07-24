#import "decoder.h"


@implementation Decoder
@end

static void decoder_enqueue_frame_into(Decoder *d, AVFrame *frame, Frame *fr);

int decoder_init(Decoder *d, AVCodecContext *avctx, AVStream *stream) {
    d->finished = -1;
    d->tmp_frame = av_frame_alloc();
    d->stream = stream;
    d->avctx = avctx;
    return frame_queue_init(d);
}

void decoder_flush(Decoder *d)
{
    avcodec_flush_buffers(d->avctx);
    d->finished = -1;
    d->next_pts = AV_NOPTS_VALUE;
}

bool decoder_send_packet(Decoder *d, AVPacket *pkt)
{
    int err = avcodec_send_packet(d->avctx, pkt);
    if (pkt) av_packet_unref(pkt);
    // xxx avcodec_send_packet() isn't documented as returning this error.  But I've observed it doing so for an audio stream after seeking, on an occasion where "[mp3 @ ...] Header missing" was also logged to the console.  Absent this special case, the decoders_thread would get shut down.
    if (err == AVERROR_INVALIDDATA)
        return false;
    // Note: since we'll loop over all frames from the packet before sending another, we shouldn't need to check for AVERROR(EAGAIN).
    if (err) {
        NSLog(@"libavPlayer: error from avcodec_send_packet(): %d", err);
        return false;
    }
    return true;
}

// Returns true if there are more frames to decode (including if we just stopped early); false otherwise.
bool decoder_receive_frame(Decoder *d, int pkt_serial, MovieState *mov)
{
    Frame* fr = frame_queue_peek_writable(d, mov);
    if (!fr)
        return true;
    int err = avcodec_receive_frame(d->avctx, d->tmp_frame);
    if (!err) {
        fr->frm_serial = pkt_serial;
        decoder_enqueue_frame_into(d, d->tmp_frame, fr);
        return true;
    }
    // If we've consumed all frames from the current packet.
    if (err == AVERROR(EAGAIN))
        return false;
    if (err == AVERROR_EOF) {
        d->finished = pkt_serial;
        return false;
    }
    NSLog(@"libavPlayer: error from avcodec_receive_frame(): %d", err);
    // Not sure what's best here.
    return false;
}

static void decoder_enqueue_frame_into(Decoder *d, AVFrame *frame, Frame *fr)
{
    switch (d->avctx->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
            frame->pts = av_frame_get_best_effort_timestamp(frame);
            // The last video frame of an .avi file seems to always have av_frame_get_best_effort_timestamp() return AV_NOPTS_VALUE (->pkt_pts and ->pkt_dts are also AV_NOPTS_VALUE).  Ignore these frames, since video_refresh() doesn't know what to do with a frame with no pts, so we end up never advancing past them, which means we fail to detect EOF when playing (and so we fail to pause, and the clock runs past the end of the movie, and our CPU usage stays high).  Of course in theory theses could appear elsewhere, but we'd still not know what to do with frames with no pts.
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
    fr->frm_pts_usec = frame->pts == AV_NOPTS_VALUE ? -1 : frame->pts * 1000000 * tb.num / tb.den;
    av_frame_move_ref(fr->frm_frame, frame);
    frame_queue_push(d);
}

void decoder_destroy(Decoder *d)
{
    frame_queue_signal(d);

    d->stream->discard = AVDISCARD_ALL;
    d->stream = NULL;
    avcodec_free_context(&d->avctx);

    frame_queue_destroy(d);

    av_frame_free(&d->tmp_frame);
    d->tmp_frame = NULL;
}

bool decoder_finished(Decoder *d, int current_serial)
{
    return d->finished == current_serial && !d->frameq_size;
}

void decoder_advance_frame(Decoder *d, MovieState *mov)
{
    frame_queue_next(d);
    decoders_pause_if_finished(mov);
}

Frame *decoder_peek_current_frame(Decoder *d, MovieState *mov)
{
    Frame *fr = NULL;
    // Skip any frames left over from before seeking.
    for (;;) {
        fr = frame_queue_peek(d);
        if (!fr) break;
        if (fr->frm_serial == mov->current_serial) break;
        decoder_advance_frame(d, mov);
    }
    return fr;
}

Frame *decoder_peek_next_frame(Decoder *d)
{
    return frame_queue_peek_next(d);
}

Frame *decoder_peek_current_frame_blocking(Decoder *d, MovieState *mov)
{
    Frame *fr = NULL;
    for (;;) {
        if (!(fr = frame_queue_peek_blocking(d, mov)))
            return NULL;
        if (fr->frm_serial == mov->current_serial) break;
        decoder_advance_frame(d, mov);
    }
    return fr;
}
