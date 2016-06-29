@import AudioToolbox;

#include <pthread.h>

#include "avcodec.h"
#include "avformat.h"
#include "avutil.h"
#include "libavutil/time.h"
#include "libswresample/swresample.h"

#include "packetqueue.h"


@class Decoder;
@protocol LAVPMovieOutput;

// This is an object rather than a struct because ObjC ARC requires that for having dispatch_queue_t members.
@interface MovieState : NSObject {
@public
    bool paused;
    int playback_speed_percent;
    int volume_percent;
    __weak id<LAVPMovieOutput> weak_output;

    bool abort_request;
    bool seek_req;
    // xxx eliminate seek_from!
    int64_t seek_from;
    int64_t seek_to;
    bool is_temporarily_unpaused_to_handle_seeking;

    AVFormatContext *ic;
    Decoder* auddec;
    Decoder* viddec;
    pthread_cond_t continue_read_thread;
    dispatch_queue_t parse_queue;
    dispatch_group_t parse_group;

    // Serial numbers are use to flush out obsolete packets/frames after seeking.  We increment ->current_serial each time we seek.
    int current_serial;
    PacketQueue packetq;
    dispatch_queue_t decoder_queue;
    dispatch_group_t decoder_group;

    // Clock (i.e. the current time in a movie, in usec, based on audio playback time).

    int64_t clock_pts; // The pts of a recently-played audio frame.
    int64_t clock_last_updated; // The machine/wallclock time the clock was last set.
    int clock_serial; // The serial of the frame for which clock_pts was set.

    // Audio

    uint8_t *audio_buf;
    uint8_t *audio_buf1;
    unsigned int audio_buf_size; /* in bytes */
    unsigned int audio_buf1_size;

    enum AVSampleFormat audio_tgt_fmt;
    int audio_tgt_channels;
    struct SwrContext *swr_ctx;
    AudioChannelLayout *audio_channel_layout; // used if there's >2 channels
    AudioQueueRef audio_queue;
    unsigned int audio_queue_num_frames_to_prepare;
    dispatch_queue_t audio_dispatch_queue;

    // Video

    int width, height;
    int64_t last_shown_video_frame_pts;
}
@end;


// core

void stream_close(MovieState *mov);
MovieState* stream_open(NSURL *sourceURL);

void lavp_seek(MovieState *mov, int64_t pos, int64_t current_pos);

void lavp_set_paused(MovieState *mov, bool pause);

int lavp_get_playback_speed_percent(MovieState *mov);
void lavp_set_playback_speed_percent(MovieState *mov, int speed);


// video

int video_thread(MovieState *mov);
void video_refresh(MovieState *mov);
AVFrame* lavp_get_current_frame(MovieState *mov);


// audio

int audio_open(MovieState *mov, AVCodecContext *avctx);

void audio_queue_start(MovieState *mov);
void audio_queue_pause(MovieState *mov);
void audio_queue_destroy(MovieState *mov);

void lavp_audio_update_speed(MovieState *mov);
void lavp_set_volume_percent(MovieState *mov, int volume);


// clock

int64_t clock_get_usec(MovieState *mov);
void clock_set(MovieState *mov, int64_t pts, int serial);
void clock_preserve(MovieState *mov);
void clock_init(MovieState *mov);
