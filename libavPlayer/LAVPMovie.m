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
#import "LAVPDecoder.h"

#include "lavp_core.h"

@implementation LAVPMovie

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
    self = [super init];
    if (self) {
        currentVol = 1.0;
        decoder = [[LAVPDecoder alloc] initWithURL:[sourceURL copy] error:errorPtr];
        if (!decoder) return nil;
        decoder.owningStream = self;
    }

    return self;
}

#pragma mark -

- (NSSize) frameSize
{
    NSSize size = [decoder frameSize];
    return size;
}

- (CVPixelBufferRef) getCVPixelBuffer
{
    return [decoder getPixelBuffer];
}

- (int64_t) durationInMicroseconds;
{
    return [decoder duration];
}

- (int64_t) currentTimeInMicroseconds
{
    return [decoder position];
}

- (void) setCurrentTimeInMicroseconds:(int64_t)newTime
{
    [decoder setPosition:newTime];
}

- (double_t) position
{
    // position uses double value between 0.0 and 1.0

    int64_t position = [decoder position];    //usec
    int64_t    duration = [decoder duration];    //usec

    // check if no duration
    if (duration == 0) return 0;

    // clipping
    position = (position < 0 ? 0 : position);
    position = (position > duration ? duration : position);

    //
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

    int64_t    duration = [decoder duration];    //usec

    // clipping
    newPosition = (newPosition<0.0 ? 0.0 : newPosition);
    newPosition = (newPosition>1.0 ? 1.0 : newPosition);

    self.busy = YES;

    [decoder setPosition: newPosition * duration];

    self.busy = NO;

    if(self.movieOutput) [self.movieOutput movieOutputNeedsSingleUpdate];
}

- (BOOL) paused {
    return decoder->is->paused;
}

- (void) setPaused:(BOOL)shouldPause {
    if(shouldPause ? !decoder->is->paused : decoder->is->paused) toggle_pause(decoder->is);
    if(self.movieOutput) [self.movieOutput movieOutputNeedsContinuousUpdating:!self.paused];
}

- (double) rate {
    if (decoder->is->ic && decoder->is->ic->duration <= 0) return 0.0f;
    return stream_playRate(decoder->is);
}

- (void) setRate:(double)rate {
    if(!decoder->is || rate <= 0.0) return;
    if(self.rate == rate) return;
    stream_setPlayRate(decoder->is, rate);
}

- (float) volume
{
    return currentVol;
}

- (void) setVolume:(float)volume
{
    currentVol = volume;
    [decoder setVolume:volume];
}

@end
