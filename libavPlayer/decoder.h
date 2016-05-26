@class VideoState;

@interface Decoder : NSObject {
@public
    AVPacket pkt;
    AVPacket pkt_temp;
    AVCodecContext *avctx;
    int pkt_serial;
    int finished;
    int packet_pending;
    pthread_cond_t *empty_queue_cond;
    int64_t start_pts;
    AVRational start_pts_tb;
    int64_t next_pts;
    AVRational next_pts_tb;
    FrameQueue frameq;
    PacketQueue packetq;
    // LAVP: in ffplay there's just a single SDL_Thread* decoder_tid instead of these.
    dispatch_queue_t dispatch_queue;
    dispatch_group_t dispatch_group;
}
@end;

int decoder_init(Decoder *d, AVCodecContext *avctx, pthread_cond_t *empty_queue_cond, int frame_queue_max_size);
int decoder_decode_frame(Decoder *d, AVFrame *frame);
void decoder_destroy(Decoder *d);
void decoder_abort(Decoder *d, FrameQueue *fq);
void decoder_start(Decoder *d, int (*fn)(VideoState *), VideoState *is);
