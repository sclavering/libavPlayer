@protocol LAVPMovieOutput;

// LAVP: in ffplay.c, this is just a struct, but we want to have dispatch_queue_t members, and Xcode says ARC prohibits storing those in a struct.
@interface VideoState : NSObject {
@public
    bool paused;
    int playback_speed_percent;
    int volume_percent;
    __weak id<LAVPMovieOutput> weak_output;

    bool abort_request;
    bool eof;
    bool seek_req;
    // xxx eliminate seek_from!
    int64_t seek_from;
    int64_t seek_to;
    bool is_temporarily_unpaused_to_handle_seeking;

    AVInputFormat *iformat;
    AVFormatContext *ic;

    Clock audclk;
    Decoder* auddec;
    Decoder* viddec;
    pthread_cond_t continue_read_thread;
    dispatch_queue_t parse_queue;
    dispatch_group_t parse_group;

    // Audio

    int64_t audio_callback_time;
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
    AudioQueueRef audio_queue;
    AudioStreamBasicDescription asbd;
    dispatch_queue_t audio_dispatch_queue;

    // Video

    int width, height;
    Frame* last_frame;
}
@end;
