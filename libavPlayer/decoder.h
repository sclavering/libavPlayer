@class VideoState;

@interface Decoder : NSObject {
@public
    AVPacket pkt;
    AVPacket pkt_temp;
    AVCodecContext *avctx;
    int pkt_serial;
    int finished;
    int packet_pending;
    pthread_cond_t *empty_queue_cond_ptr;
    int64_t start_pts;
    AVRational start_pts_tb;
    int64_t next_pts;
    AVRational next_pts_tb;
    FrameQueue frameq;
    PacketQueue packetq;
    AVStream *stream;
    // LAVP: in ffplay there's just a single SDL_Thread* decoder_tid instead of these.
    dispatch_queue_t dispatch_queue;
    dispatch_group_t dispatch_group;
}
@end;

int decoder_init(Decoder *d, AVCodecContext *avctx, pthread_cond_t *empty_queue_cond, int frame_queue_max_size, AVStream *stream);
int decoder_decode_frame(Decoder *d, AVFrame *frame);
void decoder_destroy(Decoder *d);
void decoder_start(Decoder *d, int (*fn)(VideoState *), VideoState *is);

bool decoder_maybe_handle_packet(Decoder *d, AVPacket *pkt);
void decoder_update_for_seek(Decoder *d);
void decoder_update_for_eof(Decoder *d);

bool decoder_needs_more_packets(Decoder *d);
bool decoder_finished(Decoder *d);

bool decoder_push_frame(Decoder *d, AVFrame *frame, double pts);
Frame* decoder_get_current_frame_or_null(Decoder *d);

bool decoder_drop_frames_with_expired_serial(Decoder *d);
