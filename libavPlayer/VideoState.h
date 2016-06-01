@protocol LAVPMovieOutput;

// LAVP: in ffplay.c, this is just a struct, but we want to have dispatch_queue_t members, and Xcode says ARC prohibits storing those in a struct.
@interface VideoState : NSObject {
@public
    int64_t audio_callback_time;    /* static int64_t audio_callback_time; */

    AVInputFormat *iformat;
    int abort_request;
    int eof;
    int paused;
    bool seek_req;
    // xxx eliminate seek_from!
    int64_t seek_from;
    int64_t seek_to;
    AVFormatContext *ic;

    Clock audclk;

    Decoder* auddec;
    Decoder* viddec;

    bool is_temporarily_unpaused_to_handle_seeking;
    pthread_cond_t continue_read_thread;

    int playbackSpeedPercent;

    dispatch_queue_t parse_queue;
    dispatch_group_t parse_group;

    __weak id<LAVPMovieOutput> weakOutput;

    // Audio

    int volume_percent;
    double audio_clock;
    int audio_clock_serial;
    int audio_hw_buf_size;
    uint8_t *audio_buf;
    uint8_t *audio_buf1;
    unsigned int audio_buf_size; /* in bytes */
    unsigned int audio_buf1_size;
    int audio_buf_index; /* in bytes */
    int audio_write_buf_size;
    struct AudioParams audio_src;
    struct AudioParams audio_tgt;
    struct SwrContext *swr_ctx;
    AudioQueueRef outAQ;
    AudioStreamBasicDescription asbd;
    dispatch_queue_t audioDispatchQueue;

    // Video

    int width, height;
    Frame* last_frame;
}
@end;
