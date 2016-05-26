@protocol LAVPMovieOutput;

// LAVP: in ffplay.c, this is just a struct, but we want to have dispatch_queue_t members, and Xcode says ARC prohibits storing those in a struct.
@interface VideoState : NSObject {
@public
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

    Clock audclk;
    Clock vidclk;

    Decoder* auddec;
    Decoder* viddec;

    int width, height;
    bool is_temporarily_unpaused_to_handle_seeking;
    pthread_cond_t *continue_read_thread;

    int playbackSpeedPercent;
    double playRate; // derived from playbackSpeedPercent

    dispatch_queue_t parse_queue;
    dispatch_group_t parse_group;

    /* Extension; Obj-C Instance */
    __weak id<LAVPMovieOutput> weakOutput;
    NSThread* decoderThread;

    /* =========================================================== */

    // LAVPaudio

    int volume_percent;

    /* same order as original struct */
    double audio_clock;
    int audio_clock_serial;
    //
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

    /* LAVP: extension */
    AudioQueueRef outAQ;
    AudioStreamBasicDescription asbd;
    dispatch_queue_t audioDispatchQueue;

    /* =========================================================== */

    // LAVPvideo

    double frame_timer;
    //
    double max_frame_duration;      // maximum duration of a frame - above this, we consider the jump a timestamp discontinuity

    int eof;

    // LAVP: extras
    Frame* last_frame;
}
@end;
