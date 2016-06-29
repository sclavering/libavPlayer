#import "MovieState.h"


#define FRAME_QUEUE_SIZE 50

/* Common struct for handling all types of decoded data and allocated render buffers. */
typedef struct Frame {
    AVFrame *frm_frame;
    int frm_serial;
    int64_t frm_pts_usec;
} Frame;

typedef struct FrameQueue {
    Frame queue[FRAME_QUEUE_SIZE];
    int rindex;
    int windex;
    int size;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} FrameQueue;

void frame_queue_unref_item(Frame *vp);
int frame_queue_init(FrameQueue *f);
void frame_queue_destroy(FrameQueue *f);
void frame_queue_signal(FrameQueue *f);
Frame *frame_queue_peek_next(FrameQueue *f);
Frame *frame_queue_peek(FrameQueue *f);
Frame *frame_queue_peek_blocking(FrameQueue *f, Decoder *d);
Frame *frame_queue_peek_writable(FrameQueue *f, Decoder *d);
void frame_queue_push(FrameQueue *f);
void frame_queue_next(FrameQueue *f);
