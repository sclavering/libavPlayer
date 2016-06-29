#import "framequeue.h"


@class MovieState;

extern AVPacket flush_pkt;

@interface Decoder : NSObject {
@public
    AVFrame *tmp_frame;
    AVCodecContext *avctx;
    int finished;
    int abort;
    int64_t next_pts;
    AVRational next_pts_tb;
    FrameQueue frameq;
    AVStream *stream;
}
@end;

int decoder_init(Decoder *d, AVCodecContext *avctx, AVStream *stream);
void decoder_destroy(Decoder *d);

bool decoder_finished(Decoder *d, int current_serial);

void decoder_advance_frame(Decoder *d);
Frame *decoder_peek_current_frame(Decoder *d, MovieState *mov);
Frame *decoder_peek_next_frame(Decoder *d);
Frame *decoder_peek_current_frame_blocking(Decoder *d, MovieState *mov);

void decoders_update_for_seek(MovieState *d);
void decoders_update_for_eof(MovieState *mov);
void decoders_thread(MovieState *mov);
