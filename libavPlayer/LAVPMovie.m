//  Created by Takashi Mochizuki on 11/06/18.
//  Copyright 2011 MyCometG3. All rights reserved.
/*
 This file is part of libavPlayer.

 libavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 libavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "LAVPMovie.h"

#import "lavp_core.h"
#import "lavp_common.h"
#import "lavp_video.h"
#import "lavp_audio.h"


@implementation LAVPMovie

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
    self = [super init];
    if (self) {
        currentVol = 1.0;
        is = stream_open(self, sourceURL);
        if (!is) return nil;

        [NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];

        int msec = 10;
        int retry = 2000 / msec; // 2.0 sec max
        while(retry--) {
            usleep(msec * 1000);
            if (!isnan(get_master_clock(is)) && frame_queue_nb_remaining(&is->pictq)) break;
        }
        if (retry < 0) NSLog(@"ERROR: stream_open timeout detected.");
        lavp_set_paused(is, true);
    }

    return self;
}

- (void) dealloc {
    NSLog(@"dealloc!");
    // perform clean up
    if (is && is->decoderThread) {
        NSThread *dt = is->decoderThread;
        [dt cancel];
        while (![dt isFinished]) usleep(10*1000);
        stream_close(is);
    }
}

#pragma mark -

- (NSSize) frameSize {
    NSSize size = NSMakeSize(is->width, is->height);
    if (is->video_st && is->video_st->codec) {
        AVRational sRatio = is->video_st->sample_aspect_ratio;
        AVRational cRatio = is->video_st->codec->sample_aspect_ratio;
        if (sRatio.num * sRatio.den) {
            // Use stream aspect ratio
            size = NSMakeSize(is->width * sRatio.num / sRatio.den, is->height);
        } else if (cRatio.num * cRatio.den) {
            // Use codec aspect ratio
            size = NSMakeSize(is->width * cRatio.num / cRatio.den, is->height);
        }
    }
    return size;
}

- (int64_t) durationInMicroseconds {
    return is->ic ? is->ic->duration : 0;
}

- (int64_t) currentTimeInMicroseconds
{
    return [self _currentTimeInMicroseconds];
}

- (void) setCurrentTimeInMicroseconds:(int64_t)newTime
{
    [self _seek:newTime];
}

- (double) position
{
    // position uses double value between 0.0 and 1.0

    int64_t position = [self _currentTimeInMicroseconds];
    int64_t duration = [self durationInMicroseconds];

    // check if no duration
    if (duration == 0) return 0;

    // clipping
    position = (position < 0 ? 0 : position);
    position = (position > duration ? duration : position);

    return (double)position/duration;
}

- (void) setPosition:(double)newPosition
{
    // If you seek without pausing the seeking takes ages (several seconds).
    bool wasPaused = self.paused;
    self.paused = true;
    [self _setPosition:newPosition];
    if(!wasPaused) self.paused = false;
}

- (void) _setPosition:(double)newPosition
{
    // position uses double value between 0.0 and 1.0

    int64_t duration = [self durationInMicroseconds];

    // clipping
    newPosition = (newPosition<0.0 ? 0.0 : newPosition);
    newPosition = (newPosition>1.0 ? 1.0 : newPosition);

    self.busy = YES;

    [self _seek: newPosition * duration];

    self.busy = NO;

    if(self.movieOutput) [self.movieOutput movieOutputNeedsSingleUpdate];
}

- (BOOL) paused {
    return is->paused;
}

- (void) setPaused:(BOOL)shouldPause {
    lavp_set_paused(is, shouldPause);
    if(self.movieOutput) [self.movieOutput movieOutputNeedsContinuousUpdating:!self.paused];
}

- (double) rate {
    if (is->ic && is->ic->duration <= 0) return 0.0f;
    return stream_playRate(is);
}

- (void) setRate:(double)rate {
    if(!is || rate <= 0.0) return;
    if(self.rate == rate) return;
    stream_setPlayRate(is, rate);
}

- (float) volume {
    // Could use: is->audio_stream >= 0 ? getVolume(is) : 0
    return currentVol;
}

- (void) setVolume:(float)volume {
    currentVol = volume;
    AudioQueueParameterValue newVolume = volume;
    if (is->audio_stream >= 0) setVolume(is, newVolume);
}

- (Frame*) getCurrentFrame {
    return lavp_get_current_frame(is);
}

- (void) threadMain
{
    @autoreleasepool {
        // Prepare thread runloop
        NSRunLoop* runLoop = [NSRunLoop currentRunLoop];

        is->decoderThread = [NSThread currentThread];

        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0/120
                                                          target:self
                                                        selector:@selector(refreshPicture)
                                                        userInfo:nil
                                                         repeats:YES];
        [runLoop addTimer:timer forMode:NSRunLoopCommonModes];

        //
        NSThread *dt = [NSThread currentThread];
        while ( ![dt isCancelled] ) {
            @autoreleasepool {
                [runLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
        }

        [timer invalidate];
    }
}

- (void) refreshPicture
{
    refresh_loop_wait_event(is);
}

- (int64_t) _currentTimeInMicroseconds
{
    if (is && is->ic) {
        double pos = get_master_clock(is) * 1e6;
        if (!isnan(pos)) {
            lastPosition = pos;
        }
        return lastPosition;
    }
    return 0;
}

- (void) _seek:(int64_t)pos {
    // pos is in microseconds

    if (is && is->ic) {
        // This exists because get_master_clock() returns NAN after seeking while paused, and we need to mask that.
        lastPosition = pos;

        int64_t ts = FFMIN(is->ic->duration , FFMAX(0, pos));
        if (is->ic->start_time != AV_NOPTS_VALUE)
            ts += is->ic->start_time;
        stream_seek(is, ts, -10);
    }
}

- (void) haveReachedEOF
{
    if(self.movieOutput) [self.movieOutput movieOutputNeedsContinuousUpdating:false];
}

- (void) haveFinishedSeekingWhilePaused
{
    if(self.movieOutput) [self.movieOutput movieOutputNeedsSingleUpdate];
}

@end
