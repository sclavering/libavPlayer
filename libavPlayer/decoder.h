@class VideoState;

extern AVPacket flush_pkt;

@interface Decoder : NSObject {
@public
    AVFrame *tmp_frame;
    AVCodecContext *avctx;
    // Serial numbers are use to flush out obsolete packets/frames after seeking.  We increment ->current_serial each time we seek.
    int current_serial;
    int finished;
    int abort;
    pthread_cond_t *empty_queue_cond_ptr;
    int64_t next_pts;
    AVRational next_pts_tb;
    FrameQueue frameq;
    PacketQueue packetq;
    AVStream *stream;
    dispatch_queue_t dispatch_queue;
    dispatch_group_t dispatch_group;
}
@end;

int decoder_init(Decoder *d, AVCodecContext *avctx, pthread_cond_t *empty_queue_cond, int frame_queue_max_size, AVStream *stream);
void decoder_destroy(Decoder *d);

bool decoder_maybe_handle_packet(Decoder *d, AVPacket *pkt);
void decoder_update_for_seek(Decoder *d);
void decoder_update_for_eof(Decoder *d);

bool decoder_needs_more_packets(Decoder *d);
bool decoder_finished(Decoder *d);

bool decoder_drop_frames_with_expired_serial(Decoder *d);

void decoder_advance_frame(Decoder *d);
Frame *decoder_peek_current_frame(Decoder *d);
Frame *decoder_peek_next_frame(Decoder *d);
Frame *decoder_peek_current_frame_blocking(Decoder *d);
