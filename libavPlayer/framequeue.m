#import "lavp_common.h"
#import "lavp_video.h"

void frame_queue_unref_item(Frame *vp)
{
    av_frame_unref(vp->frm_frame);
}

int frame_queue_init(FrameQueue *f, int max_size, int keep_last)
{
    int i;
    memset(f, 0, sizeof(FrameQueue));
    int err = pthread_mutex_init(&f->mutex, NULL);
    if (err) return AVERROR(ENOMEM);
    err = pthread_cond_init(&f->cond, NULL);
    if (err) return AVERROR(ENOMEM);
    f->max_size = FFMIN(max_size, FRAME_QUEUE_SIZE);
    f->keep_last = !!keep_last;
    for (i = 0; i < f->max_size; i++)
        if (!(f->queue[i].frm_frame = av_frame_alloc()))
            return AVERROR(ENOMEM);
    return 0;
}

void frame_queue_destroy(FrameQueue *f)
{
    int i;
    for (i = 0; i < f->max_size; i++) {
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
    pthread_cond_signal(&f->cond);
    pthread_mutex_unlock(&f->mutex);
}

Frame *frame_queue_peek_next(FrameQueue *f)
{
    return frame_queue_nb_remaining(f) > 1 ? &f->queue[(f->rindex + f->rindex_shown + 1) % f->max_size] : NULL;
}

Frame *frame_queue_peek(FrameQueue *f)
{
    if (!frame_queue_nb_remaining(f)) return NULL;
    return &f->queue[(f->rindex + f->rindex_shown) % f->max_size];
}

Frame *frame_queue_peek_blocking(FrameQueue *f, Decoder *d)
{
    /* wait until we have a readable a new frame */
    pthread_mutex_lock(&f->mutex);
    while (f->size - f->rindex_shown <= 0 && !d->abort) {
        pthread_cond_wait(&f->cond, &f->mutex);
    }
    pthread_mutex_unlock(&f->mutex);
    if (d->abort) return NULL;
    return &f->queue[(f->rindex + f->rindex_shown) % f->max_size];
}

Frame *frame_queue_peek_writable(FrameQueue *f, Decoder *d)
{
    /* wait until we have space to put a new frame */
    pthread_mutex_lock(&f->mutex);
    while (f->size >= f->max_size && !d->abort) {
        pthread_cond_wait(&f->cond, &f->mutex);
    }
    pthread_mutex_unlock(&f->mutex);
    if (d->abort) return NULL;
    return &f->queue[f->windex];
}

void frame_queue_push(FrameQueue *f)
{
    if (++f->windex == f->max_size)
        f->windex = 0;
    pthread_mutex_lock(&f->mutex);
    f->size++;
    pthread_cond_signal(&f->cond);
    pthread_mutex_unlock(&f->mutex);
}

void frame_queue_next(FrameQueue *f)
{
    if (f->keep_last && !f->rindex_shown) {
        f->rindex_shown = 1;
        return;
    }
    frame_queue_unref_item(&f->queue[f->rindex]);
    if (++f->rindex == f->max_size)
        f->rindex = 0;
    pthread_mutex_lock(&f->mutex);
    f->size--;
    pthread_cond_signal(&f->cond);
    pthread_mutex_unlock(&f->mutex);
}

/* return the number of undisplayed frames in the queue */
int frame_queue_nb_remaining(FrameQueue *f)
{
    return f->size - f->rindex_shown;
}
