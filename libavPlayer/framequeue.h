#import "packetqueue.h"

/* Common struct for handling all types of decoded data and allocated render buffers. */
typedef struct Frame {
    AVFrame *frame;
    AVSubtitle sub;
    int serial;
    double pts;           /* presentation timestamp for the frame */
    double duration;      /* estimated duration of the frame */
    int64_t pos;          /* byte position of the frame in the input file */
    AVFrame *bmp; // lavp: SDL_Overlay* in ffplay
    int allocated;
    int reallocate;
    int width;
    int height;
    AVRational sar;
} Frame;

typedef struct FrameQueue {
    Frame queue[FRAME_QUEUE_SIZE];
    int rindex;
    int windex;
    int size;
    int max_size;
    int keep_last;
    int rindex_shown;
    LAVPmutex *mutex;
    LAVPcond *cond;
    PacketQueue *pktq;
} FrameQueue;

void frame_queue_unref_item(Frame *vp);
int frame_queue_init(FrameQueue *f, PacketQueue *pktq, int max_size, int keep_last);
void frame_queue_destory(FrameQueue *f);
void frame_queue_signal(FrameQueue *f);
Frame *frame_queue_peek(FrameQueue *f);
Frame *frame_queue_peek_next(FrameQueue *f);
Frame *frame_queue_peek_last(FrameQueue *f);
Frame *frame_queue_peek_readable(FrameQueue *f);
Frame *frame_queue_peek_writable(FrameQueue *f);
void frame_queue_push(FrameQueue *f);
void frame_queue_next(FrameQueue *f);
/* jump back to the previous frame if available by resetting rindex_shown */
int frame_queue_prev(FrameQueue *f);
/* return the number of undisplayed frames in the queue */
int frame_queue_nb_remaining(FrameQueue *f);
int64_t frame_queue_last_pos(FrameQueue *f);
