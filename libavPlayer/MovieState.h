@import AudioToolbox;

#include <pthread.h>

#include "avcodec.h"
#include "avformat.h"
#include "avutil.h"
#include "libavutil/time.h"
#include "libswresample/swresample.h"


@class Decoder;
@protocol LAVPMovieOutput;

// This is an object rather than a struct because ObjC ARC requires that for having dispatch_queue_t members.
@interface MovieState : NSObject {
@public
    bool paused;
    // Pausing/unpausing is async.  It works by setting this to the desired value, and then the decoders_thread noticing the discrepancy and making the actual change.
    bool requested_paused;

    int playback_speed_percent;
    int volume_percent;
    __weak id<LAVPMovieOutput> weak_output;

    bool abort_request;
    bool seek_req;
    // xxx eliminate seek_from!
    int64_t seek_from;
    int64_t seek_to;
    bool paused_for_eof;

    AVFormatContext *ic;
    Decoder* auddec;
    Decoder* viddec;

    // Serial numbers are use to flush out obsolete packets/frames after seeking.  We increment ->current_serial each time we seek.
    int current_serial;
    dispatch_queue_t decoder_queue;
    dispatch_group_t decoder_group;

    pthread_mutex_t decoders_mutex;
    pthread_cond_t decoders_cond;

    // Clock (i.e. the current time in a movie, in usec, based on audio playback time).

    int64_t clock_pts; // The pts of a recently-played audio frame.
    int64_t clock_last_updated; // The machine/wallclock time the clock was last set.

    // Audio

    bool audio_needs_interleaving;
    enum AVSampleFormat audio_tgt_fmt;
    int64_t current_audio_frame_pts;
    size_t current_audio_frame_buffer_offset;
    AudioChannelLayout *audio_channel_layout; // used if there's >2 channels
    AudioQueueRef audio_queue;
    dispatch_queue_t audio_dispatch_queue;
    dispatch_group_t audio_dispatch_group;

    // Video

    int width, height;
    int last_shown_frame_serial;
}
@end;


// core

MovieState* movie_open(NSURL *sourceURL);
void movie_close(MovieState *mov);

void lavp_seek(MovieState *mov, int64_t pos, int64_t current_pos);

void lavp_set_paused(MovieState *mov, bool pause);

int lavp_get_playback_speed_percent(MovieState *mov);
void lavp_set_playback_speed_percent(MovieState *mov, int speed);

void decoders_thread(MovieState *mov);
void decoders_wake_thread(MovieState *mov);


// video

void lavp_if_new_video_frame_is_available_then_run(MovieState *mov, void (^func)(AVFrame *));


// audio

int audio_open(MovieState *mov, AVCodecContext *avctx);
void audio_queue_destroy(MovieState *mov);

void audio_queue_set_paused(MovieState *mov, bool pause);
void lavp_audio_update_speed(MovieState *mov);
void lavp_set_volume_percent(MovieState *mov, int volume);


// clock

int64_t clock_get_usec(MovieState *mov);
void clock_set(MovieState *mov, int64_t pts);
void clock_preserve(MovieState *mov);
