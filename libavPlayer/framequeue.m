#import "framequeue.h"
#import "decoder.h"


void frame_queue_unref_item(Frame *vp)
{
    av_frame_unref(vp->frm_frame);
}

int frame_queue_init(FrameQueue *f)
{
    memset(f, 0, sizeof(FrameQueue));
    int err = pthread_mutex_init(&f->mutex, NULL);
    if (err) return AVERROR(ENOMEM);
    err = pthread_cond_init(&f->cond, NULL);
    if (err) return AVERROR(ENOMEM);
    for (int i = 0; i < FRAME_QUEUE_SIZE; ++i)
        if (!(f->queue[i].frm_frame = av_frame_alloc()))
            return AVERROR(ENOMEM);
    return 0;
}

void frame_queue_destroy(FrameQueue *f)
{
    for (int i = 0; i < FRAME_QUEUE_SIZE; ++i) {
        Frame *vp = &f->queue[i];
        frame_queue_unref_item(vp);
        av_frame_free(&vp->frm_frame);
    }
    pthread_mutex_destroy(&f->mutex);
    pthread_cond_destroy(&f->cond);
}

void frame_queue_signal(FrameQueue *f)
{
    pthread_mutex_lock(&f->mutex);
    pthread_cond_broadcast(&f->cond);
    pthread_mutex_unlock(&f->mutex);
}

Frame *frame_queue_peek_next(FrameQueue *f)
{
    return f->size > 1 ? &f->queue[(f->rindex + 1) % FRAME_QUEUE_SIZE] : NULL;
}

Frame *frame_queue_peek(FrameQueue *f)
{
    if (!f->size) return NULL;
    return &f->queue[f->rindex % FRAME_QUEUE_SIZE];
}

Frame *frame_queue_peek_blocking(FrameQueue *f, MovieState *mov)
{
    /* wait until we have a readable a new frame */
    pthread_mutex_lock(&f->mutex);
    while (f->size <= 0 && !mov->abort_request) {
        pthread_cond_wait(&f->cond, &f->mutex);
    }
    pthread_mutex_unlock(&f->mutex);
    if (mov->abort_request) return NULL;
    return &f->queue[f->rindex % FRAME_QUEUE_SIZE];
}

Frame *frame_queue_peek_writable(FrameQueue *f, MovieState *mov)
{
    /* wait until we have space to put a new frame */
    bool cancelled = false;
    pthread_mutex_lock(&f->mutex);
    for (;;) {
        if (f->size < FRAME_QUEUE_SIZE) break;
        if ((cancelled = decoders_should_stop_waiting(mov))) break;
        pthread_cond_wait(&f->cond, &f->mutex);
    }
    pthread_mutex_unlock(&f->mutex);
    if (cancelled) return NULL;
    return &f->queue[f->windex];
}

void frame_queue_push(FrameQueue *f)
{
    if (++f->windex == FRAME_QUEUE_SIZE)
        f->windex = 0;
    pthread_mutex_lock(&f->mutex);
    f->size++;
    pthread_cond_signal(&f->cond);
    pthread_mutex_unlock(&f->mutex);
}

void frame_queue_next(FrameQueue *f)
{
    frame_queue_unref_item(&f->queue[f->rindex]);
    if (++f->rindex == FRAME_QUEUE_SIZE)
        f->rindex = 0;
    pthread_mutex_lock(&f->mutex);
    f->size--;
    pthread_cond_signal(&f->cond);
    pthread_mutex_unlock(&f->mutex);
}
