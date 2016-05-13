//  Created by Takashi Mochizuki on 11/06/18.
//  Copyright 2011 MyCometG3. All rights reserved.
/*
 This file is part of livavPlayer.

 livavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "LAVPDecoder.h"

#import "framequeue.h"

extern double get_master_clock(VideoState *is);
extern double get_clock(Clock *c);
extern void stream_seek(VideoState *is, int64_t pos, int64_t rel, int seek_by_bytes);
extern void stream_pause(VideoState *is);
extern void stream_close(VideoState *is);
extern VideoState* stream_open(/* LAVPDecoder* */ id is, NSURL *sourceURL);
extern void alloc_picture(VideoState *is);
extern void refresh_loop_wait_event(VideoState *is);
extern int hasImage(VideoState *is);
extern int copyImage(VideoState *is, uint8_t* data, const int pitch);
extern AudioQueueParameterValue getVolume(VideoState *is);
extern void setVolume(VideoState *is, AudioQueueParameterValue volume);
extern double_t stream_playRate(VideoState *is);
extern void stream_setPlayRate(VideoState *is, double_t newRate);

#pragma mark -

@interface LAVPDecoder (internal)

- (void) allocPicture;

@end


@implementation LAVPDecoder

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
    self = [super init];
    if (self) {
        is = stream_open(self, sourceURL);
        if (is) {
            [NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];

            int msec = 10;
            int retry = 2000/msec;    // 2.0 sec max
            while(retry--) {
                usleep(msec*1000);
                if (!isnan(get_master_clock(is)) && frame_queue_nb_remaining(&is->pictq))
                    break;
            }
            if (retry < 0)
                NSLog(@"ERROR: stream_open timeout detected.");
            stream_pause(is);
        } else {
            return nil;
        }
    }

    return self;
}

- (void) invalidate
{
    // perform clean up
    if (is && is->decoderThread) {
        NSThread *dt = is->decoderThread;
        [dt cancel];
        while (![dt isFinished]) {
            usleep(10*1000);
        }
        dt = NULL;

        stream_close(is);
        is = NULL;
    }
    if (pb) {
        CVPixelBufferRelease(pb);
        pb = NULL;
    }
}

- (void) dealloc
{
    [self invalidate];
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

- (CVPixelBufferRef) getPixelBuffer
{
    if(!hasImage(is)) return NULL;
    if (!pb) {
        pb = [self createDummyCVPixelBufferWithSize:NSMakeSize(is->width, is->height)];
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t* data = CVPixelBufferGetBaseAddress(pb);
    int pitch = CVPixelBufferGetBytesPerRow(pb);
    int ret = copyImage(is, data, pitch);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    if (ret == 1 || ret == 2) return pb;
    return NULL;
}

- (NSSize) frameSize
{
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

- (CGFloat) rate
{
    if (!is)
        return 0.0f;
    else if (is->ic && is->ic->duration <= 0)
        return 0.0f;

    if (is->paused)
        return 0.0f;
    else
        return stream_playRate(is);
}

- (void) setRate:(CGFloat)rate
{
    /* note: only accept 0.0 and positive */
    if (!is || rate < 0.0) {
        return;
    }

    if (rate > 0) {
        stream_setPlayRate(is, rate);
        if (is && is->paused) {
            stream_pause(is);
        }
    } else {
        stream_setPlayRate(is, 1.0);
        if (is && !is->paused) {
            stream_pause(is);
        }
    }
}

- (int64_t) duration
{
    // duration is in AV_TIME_BASE value.
    // avutil.h defines timebase for AVFormatContext - in usec.

    if (is && is->ic) {
        return is->ic->duration;
    }
    return 0;
}

- (int64_t) position
{
    // position is in AV_TIME_BASE value.
    // avutil.h defines timebase for AVFormatContext - in usec.

    if (is && is->ic) {
        double pos = get_master_clock(is) * 1e6;
        if (!isnan(pos)) {
            lastPosition = pos;
        }
        return lastPosition;
    }
    return 0;
}

- (int64_t) setPosition:(int64_t)pos blocking:(BOOL)blocking;
{
    // position is in AV_TIME_BASE value.
    // avutil.h defines timebase for AVFormatContext - in usec.

    if (is && is->ic) {
        double_t (^now_s)() = ^(void) {
            double_t now_s = get_master_clock(is); // in sec
            //now_s =  isnan(now_s) ? get_clock(&is->vidclk) : now_s; // in sec
            return now_s;
        };

        if (is->seek_by_bytes || is->ic->duration <= 0) {
            double_t frac = (double_t)pos / (now_s() * 1.0e6);

            int64_t size =  avio_size(is->ic->pb);

            int64_t target_b = 0; // in bytes
            int64_t current_b = -1;
            if (current_b < 0 && is->video_stream >= 0)
                current_b = frame_queue_last_pos(&is->pictq);
            if (current_b < 0 && is->audio_stream >= 0 && is->frame)
                current_b = av_frame_get_pkt_pos(is->frame);
            if (current_b < 0)
                current_b = avio_tell(is->ic->pb);

            target_b = FFMIN(size, current_b * frac); // in byte
            stream_seek(is, target_b, 0, 1);

            {
                int count = 0, limit = 100, unit = 10;

                // Wait till avformat_seek_file() is completed
                for ( ; limit > count; count++) {
                    if (!is->seek_req) break;
                    usleep(unit*1000);
                }

                // wait till is->paused == true
                for ( ; limit > count; count++) {
                    if (is->paused) break;
                    usleep(unit*1000);
                }
            }
        } else {
            int64_t ts = FFMIN(is->ic->duration , FFMAX(0, pos));

            if (is->ic->start_time != AV_NOPTS_VALUE)
                ts += is->ic->start_time;

            stream_seek(is, ts, -10, 0);

            {
                int count = 0, limit = 200, unit = 10;

                // Wait till avformat_seek_file() is completed
                for (; limit > count; count++) {
                    if (!is->seek_req) break;
                    usleep(unit*1000);
                }

                // wait till is->paused == true
                if (ts) // LAVP: if ts == 0 is->paused is not updated...
                    for ( ; limit > count; count++) {
                        if (is->paused) break;
                        usleep(unit*1000);
                    }

                if (count >= limit) {
                    int64_t diff = (now_s() * 1.0e6) - ts; // in usec
                    NSLog(@"NOTE: seek1 timeout detected. (delta=%8.3f)", diff/1.0e6);

                    //NSLog(@"DEBUG: seek diff1 = %8.3f ts1 = %8.3f, now1 = %8.3f %d %@",
                    //diff/1.0e6, ts/1.0e6, now_s(), count, ((limit > count) ? @"" : @"timeout")); // in sec
                }
            }

            // seek wait - blocking
            if (ts) {
                double_t posNow = now_s(); // in sec
                if (isnan(posNow) || (!isnan(posNow) && posNow * 1.0e6 < pos))
                {
                    /* TODO seems to be NAN always while in pause. Why? */
                    //NSLog(@"DEBUG: %@", isnan(posNow) ? @"NAN" : @"-");

                    if (blocking) {
                        double_t accelarate = 5.0;
                        [self setRate:accelarate];

                        int count = 0, limit = 200, unit = 10;
                        for (;count<limit;count++) {
                            double_t posNow = now_s(); // in sec
                            if (!isnan(posNow) && posNow * 1.0e6 >= pos) {
                                lastPosition = posNow*1.0e6; // in usec
                                break;
                            }
                            usleep(unit*1000);
                        }

                        if (count >= limit) {
                            double_t diff = (now_s() * 1.0e6) - ts; // in usec
                            NSLog(@"NOTE: seek2 timeout detected. (delta=%8.3f)", diff/1.0e6);

                            //NSLog(@"DEBUG: seek diff2 = %8.3f ts1 = %8.3f, now1 = %8.3f %d %@",
                            //diff/1.0e6, ts/1.0e6, now_s(), count, ((limit > count) ? @"" : @"timeout")); // in sec
                        }
                        [self setRate:0.0];
                    }
                }
            } else {
                usleep(0.1e6);
            }
        }

        // Workaround - Not strict
        double_t posFinal = now_s(); // in sec
        //NSLog(@"DEBUG: pos=%.3f, lastPosition=%.3f", posFinal/1.0e6, lastPosition/1.0e6); // in sec
        lastPosition = isnan(posFinal) ? pos : posFinal*1.0e6; // in usec

        return lastPosition;
    }
    return 0;
}

- (Float32) volume
{
    Float32 volume = 0.0;
    if (is && is->audio_stream >= 0) {
        volume = getVolume(is);
    }
    return volume;
}

- (void) setVolume:(Float32)volume
{
    AudioQueueParameterValue newVolume = volume;
    if (is && is->audio_stream >= 0) {
        setVolume(is, newVolume);
    }
}

- (BOOL) eof
{
    return (is->eof_flag ? YES : NO);
}

@end
