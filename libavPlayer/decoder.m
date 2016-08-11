#import "decoder.h"


@implementation Decoder
@end

static int64_t decoder_calculate_pts(Decoder *d, AVFrame *frame, Frame *fr);

int decoder_init(Decoder *d, AVCodecContext *avctx, AVStream *stream) {
    d->finished = -1;
    d->tmp_frame = av_frame_alloc();
    d->stream = stream;
    d->avctx = avctx;
    int err = pthread_mutex_init(&d->mutex, NULL);
    if (err) return AVERROR(ENOMEM);
    err = pthread_cond_init(&d->not_empty_cond, NULL);
    if (err) return AVERROR(ENOMEM);
    for (int i = 0; i < FRAME_QUEUE_SIZE; ++i)
        if (!(d->frameq[i].frm_frame = av_frame_alloc()))
            return AVERROR(ENOMEM);
    return 0;
}

static bool decoder_frameq_is_empty(Decoder *d)
{
    return d->frameq_head == d->frameq_tail;
}

bool decoder_frameq_is_full(Decoder *d)
{
    return d->frameq_head == (d->frameq_tail + 1) % FRAME_QUEUE_SIZE;
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

// The caller MUST ensure there is space in the frameq to decode into.
// Returns true if there are more frames to decode (including if we just stopped early); false otherwise.
bool decoder_receive_frame(Decoder *d, int pkt_serial, MovieState *mov)
{
    Frame *fr = &d->frameq[d->frameq_tail];

    int err = avcodec_receive_frame(d->avctx, d->tmp_frame);
    if (!err) {
        fr->frm_serial = pkt_serial;
        int64_t pts = decoder_calculate_pts(d, d->tmp_frame, fr);
        // The last video frame of an .avi file seems to always have av_frame_get_best_effort_timestamp() return AV_NOPTS_VALUE (.pkt_pts and .pkt_dts are also AV_NOPTS_VALUE).  Ignore these frames, since video_refresh() doesn't know what to do with a frame with no pts, so we end up never advancing past them, which means we fail to detect EOF when playing (and so we fail to pause, and the clock runs past the end of the movie, and our CPU usage stays high).  Of course in theory these could appear elsewhere, but we'd still not know what to do with frames with no pts.
        if (pts != AV_NOPTS_VALUE) {
            fr->frm_pts_usec = pts;
            av_frame_move_ref(fr->frm_frame, d->tmp_frame);

            pthread_mutex_lock(&d->mutex);
            d->frameq_tail = (d->frameq_tail + 1) % FRAME_QUEUE_SIZE;
            pthread_cond_signal(&d->not_empty_cond);
            pthread_mutex_unlock(&d->mutex);
        }
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

static int64_t decoder_calculate_pts(Decoder *d, AVFrame *frame, Frame *fr)
{
    switch (d->avctx->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
            frame->pts = av_frame_get_best_effort_timestamp(frame);
            if (frame->pts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
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
    return frame->pts == AV_NOPTS_VALUE ? -1 : frame->pts * 1000000 * tb.num / tb.den;
}

void decoder_destroy(Decoder *d)
{
    d->stream->discard = AVDISCARD_ALL;
    d->stream = NULL;
    avcodec_free_context(&d->avctx);

    for (int i = 0; i < FRAME_QUEUE_SIZE; ++i) {
        Frame *vp = &d->frameq[i];
        av_frame_unref(vp->frm_frame);
        av_frame_free(&vp->frm_frame);
    }
    pthread_mutex_destroy(&d->mutex);
    pthread_cond_destroy(&d->not_empty_cond);

    av_frame_free(&d->tmp_frame);
    d->tmp_frame = NULL;
}

bool decoder_finished(Decoder *d, int current_serial)
{
    return d->finished == current_serial && decoder_frameq_is_empty(d);
}

void decoder_advance_frame_already_locked(Decoder *d, MovieState *mov)
{
    av_frame_unref(d->frameq[d->frameq_head].frm_frame);
    d->frameq_head = (d->frameq_head + 1) % FRAME_QUEUE_SIZE;
    pthread_cond_signal(&mov->decoders_cond);

    decoders_pause_if_finished(mov);
}

void decoder_advance_frame(Decoder *d, MovieState *mov)
{
    pthread_mutex_lock(&d->mutex);
    decoder_advance_frame_already_locked(d, mov);
    pthread_mutex_unlock(&d->mutex);
}

Frame *decoder_peek_current_frame_already_locked(Decoder *d, MovieState *mov)
{
    Frame *fr = NULL;
    // Skip any frames left over from before seeking.
    for (;;) {
        if (decoder_frameq_is_empty(d)) return NULL;
        fr = &d->frameq[d->frameq_head];
        if (fr->frm_serial == mov->current_serial) break;
        decoder_advance_frame_already_locked(d, mov);
    }
    return fr;
}

Frame *decoder_peek_current_frame(Decoder *d, MovieState *mov)
{
    pthread_mutex_lock(&d->mutex);
    Frame *fr = decoder_peek_current_frame_already_locked(d, mov);
    pthread_mutex_unlock(&d->mutex);
    return fr;
}

Frame *decoder_peek_next_frame(Decoder *d)
{
    int index = (d->frameq_head + 1) % FRAME_QUEUE_SIZE;
    return index != d->frameq_tail ? &d->frameq[index] : NULL;
}

Frame *decoder_peek_current_frame_blocking_already_locked(Decoder *d, MovieState *mov)
{
    Frame *fr = NULL;
    for (;;) {
        // Wait until we have a new frame
        while (decoder_frameq_is_empty(d) && !mov->abort_request) pthread_cond_wait(&d->not_empty_cond, &d->mutex);
        if (mov->abort_request)
            return NULL;
        fr = &d->frameq[d->frameq_head];
        if (fr->frm_serial == mov->current_serial) break;
        decoder_advance_frame_already_locked(d, mov);
    }
    return fr;
}
