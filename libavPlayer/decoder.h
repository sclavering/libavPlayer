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
} Decoder;

void decoder_init(Decoder *d, AVCodecContext *avctx, PacketQueue *queue, LAVPcond *empty_queue_cond);
int decoder_decode_frame(Decoder *d, void *fframe);
void decoder_destroy(Decoder *d);
