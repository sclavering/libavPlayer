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

#import "LAVPMovie.h"
#import "LAVPDecoder.h"

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
    [decoder setPosition:newTime blocking:YES];
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
    // If you seek with rate != 0 the seeking takes ages (several seconds).
    double prevRate = self.rate;
    self.rate = 0.0;
    [self _setPosition:newPosition];
    self.rate = prevRate;
}

- (void) _setPosition:(double_t)newPosition
{
    // position uses double value between 0.0 and 1.0

    int64_t    duration = [decoder duration];    //usec

    // clipping
    newPosition = (newPosition<0.0 ? 0.0 : newPosition);
    newPosition = (newPosition>1.0 ? 1.0 : newPosition);

    self.busy = YES;

    double_t prevRate = [self rate];

    [decoder setPosition:newPosition*duration blocking:false];

    if (prevRate) [self setRate:prevRate];

    self.busy = NO;

    if(self.movieOutput) [self.movieOutput movieOutputNeedsSingleUpdate];
}

- (double_t) rate
{
    double_t rate = [decoder rate];
    return rate;
}

- (void) setRate:(double_t) newRate
{
    if (decoder.rate == newRate) return;
    // pause first
    if (decoder.rate) [decoder setRate:0.0];
    if (newRate != 0.0) [decoder setRate:newRate];
    if(self.movieOutput) [self.movieOutput movieOutputNeedsContinuousUpdating: decoder.rate != 0.0];
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
