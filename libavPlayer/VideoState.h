@class LAVPDecoder;

// LAVP: in ffplay.c, this is just a struct, but we want to have dispatch_queue_t members, and Xcode says ARC prohibits storing those in a struct.
@interface VideoState : NSObject {
@public
    /* moved from global parameter */
    int seek_by_bytes;     /* static int seek_by_bytes = -1; */
    int infinite_buffer;            /* static int infinite_buffer = -1; */
    double rdftspeed;               /* double rdftspeed = 0.02; */

    int64_t audio_callback_time;    /* static int64_t audio_callback_time; */

    /* moved from local valuable */
    double remaining_time;

    // LAVPcore

    /* same order as original struct */
    AVInputFormat *iformat;
    //
    int abort_request;
    int paused;
    int last_paused;
    int queue_attachments_req;
    int seek_req;
    int seek_flags;
    int64_t seek_pos;
    int64_t seek_rel;
    int read_pause_return;
    AVFormatContext *ic;
    int realtime;

    Clock audclk;
    Clock vidclk;
    Clock extclk;

    FrameQueue pictq;
    FrameQueue subpq;
    FrameQueue sampq;

    Decoder auddec;
    Decoder viddec;
    Decoder subdec;

    int av_sync_type;
    //
    char* filename; /* LAVP: char filename[1024] */
    int width, height, xleft, ytop;
    int step;
    //
    LAVPcond *continue_read_thread;

    /* stream index */
    int video_stream, audio_stream, subtitle_stream;
    int last_video_stream, last_audio_stream, last_subtitle_stream;

    /* AVStream */
    AVStream *audio_st;
    AVStream *video_st;
    AVStream *subtitle_st;

    /* PacketQueue */
    PacketQueue audioq;
    PacketQueue videoq;
    PacketQueue subtitleq;

    /* Extension; playRate */
    double_t playRate;
    int eof_flag;

    /* Extension; Sub thread */
    dispatch_queue_t parse_queue;
    dispatch_group_t parse_group;
    dispatch_queue_t video_queue;
    dispatch_group_t video_group;
    dispatch_queue_t subtitle_queue;
    dispatch_group_t subtitle_group;
    dispatch_queue_t audio_queue;
    dispatch_group_t audio_group;

    /* Extension; Obj-C Instance */
    __weak LAVPDecoder* decoder;
    NSThread* decoderThread;

    /* =========================================================== */

    // LAVPaudio

    /* same order as original struct */
    double audio_clock;
    int audio_clock_serial;
    double audio_diff_cum; /* used for AV difference average computation */
    double audio_diff_avg_coef;
    double audio_diff_threshold;
    int audio_diff_avg_count;
    //
    int audio_hw_buf_size;
    uint8_t silence_buf[SDL_AUDIO_BUFFER_SIZE];
    uint8_t *audio_buf;
    uint8_t *audio_buf1;
    unsigned int audio_buf_size; /* in bytes */
    unsigned int audio_buf1_size;
    int audio_buf_index; /* in bytes */
    int audio_write_buf_size;
    struct AudioParams audio_src;
    struct AudioParams audio_tgt;
    struct SwrContext *swr_ctx;

    /* LAVP: extension */
    AudioQueueRef outAQ;
    AudioStreamBasicDescription asbd;
    void* audioDispatchQueue; // dispatch_queue_t

    /* =========================================================== */

    // LAVPvideo

    double frame_timer;
    double frame_last_returned_time;
    double frame_last_filter_delay;
    //
    double max_frame_duration;      // maximum duration of a frame - above this, we consider the jump a timestamp discontinuity

    struct SwsContext *img_convert_ctx;

    /* LAVP: extension */
    double lastPTScopied;
    struct SwsContext *sws420to422;
}
@end;
