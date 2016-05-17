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

#include "lavp_core.h"
#include "lavp_common.h"
#include "lavp_video.h"
#include "lavp_audio.h"


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
        toggle_pause(is);
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
    if (pb) CVPixelBufferRelease(pb);
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

- (double_t) position
{
    // position uses double value between 0.0 and 1.0

    int64_t position = [self _currentTimeInMicroseconds];
    int64_t duration = [self durationInMicroseconds];

    // check if no duration
    if (duration == 0) return 0;

    // clipping
    position = (position < 0 ? 0 : position);
    position = (position > duration ? duration : position);

    return (double_t)position/duration;
}

- (void) setPosition:(double_t)newPosition
{
    // If you seek without pausing the seeking takes ages (several seconds).
    bool wasPaused = self.paused;
    self.paused = true;
    [self _setPosition:newPosition];
    if(!wasPaused) self.paused = false;
}

- (void) _setPosition:(double_t)newPosition
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
    if(shouldPause ? !is->paused : is->paused) toggle_pause(is);
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

- (CVPixelBufferRef) getCVPixelBuffer {
    if (!hasImage(is)) return NULL;
    if (!pb) pb = [self createDummyCVPixelBufferWithSize:NSMakeSize(is->width, is->height)];
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t* data = CVPixelBufferGetBaseAddress(pb);
    int pitch = CVPixelBufferGetBytesPerRow(pb);
    int ret = copyImage(is, data, pitch);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    if (ret == 1 || ret == 2) return pb;
    return NULL;
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

- (void) allocPicture
{
    alloc_picture(is);
}

- (void) refreshPicture
{
    refresh_loop_wait_event(is);
}

- (CVPixelBufferRef) createDummyCVPixelBufferWithSize:(NSSize)size {
    OSType format = '2vuy';    //k422YpCbCr8CodecType
    size_t width = size.width, height = size.height;
    CFDictionaryRef attr = NULL;
    CVPixelBufferRef pixelbuffer = NULL;

    assert(width * height > 0);
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width, height, format, attr, &pixelbuffer);
    assert (result == kCVReturnSuccess && pixelbuffer);

    return pixelbuffer;
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

        if (is->seek_by_bytes || is->ic->duration <= 0) {
            double_t frac = (double_t)pos / (get_master_clock(is) * 1.0e6);

            int64_t size =  avio_size(is->ic->pb);

            int64_t target_b = 0; // in bytes
            int64_t current_b = -1;
            if (current_b < 0 && is->video_stream >= 0)
                current_b = frame_queue_last_pos(&is->pictq);
            if (current_b < 0 && is->audio_stream >= 0)
                current_b = frame_queue_last_pos(&is->sampq);
            if (current_b < 0)
                current_b = avio_tell(is->ic->pb);

            target_b = FFMIN(size, current_b * frac); // in byte
            stream_seek(is, target_b, 0, 1);
        } else {
            int64_t ts = FFMIN(is->ic->duration , FFMAX(0, pos));

            if (is->ic->start_time != AV_NOPTS_VALUE)
                ts += is->ic->start_time;

            stream_seek(is, ts, -10, 0);
        }

        // Without the following code, the video output doesn't consistently update if seeking while paused (sometimes it doesn't update at all, and sometimes it's showing not quite the right frame).

        int count = 0, limit = 200;
        // Wait till avformat_seek_file() is completed
        for ( ; limit > count; count++) {
            if (!is->seek_req) break;
            usleep(10000);
        }
        // wait till is->paused == true
        for ( ; limit > count; count++) {
            if (is->paused) break;
            usleep(10000);
        }
    }
}

- (void) haveReachedEOF
{
    if(self.movieOutput) [self.movieOutput movieOutputNeedsContinuousUpdating:false];
}

@end
