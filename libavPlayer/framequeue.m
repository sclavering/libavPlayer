#import "decoder.h"


void frame_queue_unref_item(Frame *vp)
{
    av_frame_unref(vp->frm_frame);
}

int frame_queue_init(Decoder *d)
{
    int err = pthread_mutex_init(&d->mutex, NULL);
    if (err) return AVERROR(ENOMEM);
    err = pthread_cond_init(&d->cond, NULL);
    if (err) return AVERROR(ENOMEM);
    for (int i = 0; i < FRAME_QUEUE_SIZE; ++i)
        if (!(d->frameq[i].frm_frame = av_frame_alloc()))
            return AVERROR(ENOMEM);
    return 0;
}

void frame_queue_destroy(Decoder *d)
{
    for (int i = 0; i < FRAME_QUEUE_SIZE; ++i) {
        Frame *vp = &d->frameq[i];
        frame_queue_unref_item(vp);
        av_frame_free(&vp->frm_frame);
    }
    pthread_mutex_destroy(&d->mutex);
    pthread_cond_destroy(&d->cond);
}

void frame_queue_signal(Decoder *d)
{
    pthread_mutex_lock(&d->mutex);
    pthread_cond_broadcast(&d->cond);
    pthread_mutex_unlock(&d->mutex);
}

Frame *frame_queue_peek_next(Decoder *d)
{
    return d->frameq_size > 1 ? &d->frameq[(d->frameq_head + 1) % FRAME_QUEUE_SIZE] : NULL;
}

Frame *frame_queue_peek(Decoder *d)
{
    if (!d->frameq_size) return NULL;
    return &d->frameq[d->frameq_head % FRAME_QUEUE_SIZE];
}

Frame *frame_queue_peek_blocking(Decoder *d, MovieState *mov)
{
    /* wait until we have a readable a new frame */
    pthread_mutex_lock(&d->mutex);
    while (d->frameq_size <= 0 && !mov->abort_request) {
        pthread_cond_wait(&d->cond, &d->mutex);
    }
    pthread_mutex_unlock(&d->mutex);
    if (mov->abort_request) return NULL;
    return &d->frameq[d->frameq_head % FRAME_QUEUE_SIZE];
}

Frame *frame_queue_peek_writable(Decoder *d, MovieState *mov)
{
    /* wait until we have space to put a new frame */
    bool cancelled = false;
    pthread_mutex_lock(&d->mutex);
    for (;;) {
        if (d->frameq_size < FRAME_QUEUE_SIZE) break;
        if ((cancelled = decoders_should_stop_waiting(mov))) break;
        pthread_cond_wait(&d->cond, &d->mutex);
    }
    pthread_mutex_unlock(&d->mutex);
    if (cancelled) return NULL;
    return &d->frameq[d->frameq_tail];
}

void frame_queue_push(Decoder *d)
{
    if (++d->frameq_tail == FRAME_QUEUE_SIZE)
        d->frameq_tail = 0;
    pthread_mutex_lock(&d->mutex);
    d->frameq_size++;
    pthread_cond_signal(&d->cond);
    pthread_mutex_unlock(&d->mutex);
}

void frame_queue_next(Decoder *d)
{
    frame_queue_unref_item(&d->frameq[d->frameq_head]);
    if (++d->frameq_head == FRAME_QUEUE_SIZE)
        d->frameq_head = 0;
    pthread_mutex_lock(&d->mutex);
    d->frameq_size--;
    pthread_cond_signal(&d->cond);
    pthread_mutex_unlock(&d->mutex);
}
