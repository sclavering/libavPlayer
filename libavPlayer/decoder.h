typedef struct Decoder {
    AVPacket pkt;
    AVPacket pkt_temp;
    PacketQueue *queue;
    AVCodecContext *avctx;
    int pkt_serial;
    int finished;
    int flushed;
    int packet_pending;
    LAVPcond *empty_queue_cond;
    int64_t start_pts;
    AVRational start_pts_tb;
    int64_t next_pts;
    AVRational next_pts_tb;
} Decoder;

void decoder_init(Decoder *d, AVCodecContext *avctx, PacketQueue *queue, LAVPcond *empty_queue_cond);
int decoder_decode_frame(Decoder *d, AVFrame *frame, AVSubtitle *sub);
void decoder_destroy(Decoder *d);
