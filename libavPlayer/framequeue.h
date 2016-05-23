#import "packetqueue.h"

/* Common struct for handling all types of decoded data and allocated render buffers. */
typedef struct Frame {
    AVFrame *frm_frame;
    int frm_serial;
    double frm_pts;           /* presentation timestamp for the frame */
    double frm_duration;      /* estimated duration of the frame */
    int64_t frm_pos;          /* byte position of the frame in the input file */
    AVFrame *frm_bmp; // lavp: SDL_Overlay* in ffplay
} Frame;

typedef struct FrameQueue {
    Frame queue[FRAME_QUEUE_SIZE];
    int rindex;
    int windex;
    int size;
    int max_size;
    int keep_last;
    int rindex_shown;
    pthread_mutex_t *mutex;
    pthread_cond_t *cond;
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
