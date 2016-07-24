#import "MovieState.h"


#define FRAME_QUEUE_SIZE 50

typedef struct Frame {
    AVFrame *frm_frame;
    int frm_serial;
    int64_t frm_pts_usec;
} Frame;

@interface Decoder : NSObject {
@public
    AVStream *stream;
    AVCodecContext *avctx;
    int finished;
    int64_t next_pts;
    AVRational next_pts_tb;
    AVFrame *tmp_frame;

    Frame frameq[FRAME_QUEUE_SIZE];
    int frameq_head;
    int frameq_tail;
    int frameq_size;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
}
@end;

int decoder_init(Decoder *d, AVCodecContext *avctx, AVStream *stream);
void decoder_destroy(Decoder *d);

void decoder_flush(Decoder *d);
bool decoder_finished(Decoder *d, int current_serial);

bool decoder_send_packet(Decoder *d, AVPacket *pkt);
bool decoder_receive_frame(Decoder *d, int pkt_serial, MovieState *mov);

void decoder_advance_frame(Decoder *d, MovieState *mov);
Frame *decoder_peek_current_frame(Decoder *d, MovieState *mov);
Frame *decoder_peek_next_frame(Decoder *d);
Frame *decoder_peek_current_frame_blocking(Decoder *d, MovieState *mov);

void frame_queue_unref_item(Frame *vp);
int frame_queue_init(Decoder *d);
void frame_queue_destroy(Decoder *d);
void frame_queue_signal(Decoder *d);
Frame *frame_queue_peek_next(Decoder *d);
Frame *frame_queue_peek(Decoder *d);
Frame *frame_queue_peek_blocking(Decoder *d, MovieState *mov);
Frame *frame_queue_peek_writable(Decoder *d, MovieState *mov);
void frame_queue_push(Decoder *d);
void frame_queue_next(Decoder *d);
