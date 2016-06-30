#import "framequeue.h"


@class MovieState;

@interface Decoder : NSObject {
@public
    AVFrame *tmp_frame;
    AVCodecContext *avctx;
    int finished;
    int64_t next_pts;
    AVRational next_pts_tb;
    FrameQueue frameq;
    AVStream *stream;
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
