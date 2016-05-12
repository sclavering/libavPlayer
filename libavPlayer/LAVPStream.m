//
//  LAVPStream.m
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/06/18.
//  Copyright 2011 MyCometG3. All rights reserved.
//
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

#import "LAVPStream.h"
#import "LAVPDecoder.h"

#define AV_TIME_BASE            1000000

// class extension
@interface LAVPStream ()
@property (readwrite) BOOL busy;
@end

@implementation LAVPStream
@synthesize url;
@synthesize busy = _busy;

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
    self = [super init];
    if (self) {
        url = [sourceURL copy];
        currentVol = 1.0;

        //
        decoder = [[LAVPDecoder alloc] initWithURL:url error:errorPtr];
        if (!decoder) {
            return nil;
        }

        // Queue selector to make initial notification.
        [self performSelector:@selector(setRate:) withObject:NULL afterDelay:0.0];
    }

    return self;
}

+ (id) streamWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
    Class myClass = [self class];
    return [[myClass alloc] initWithURL:sourceURL error:errorPtr];
}

- (void) invalidate
{
    // perform clean up
    [timer invalidate];
    timer = nil;

    [decoder invalidate];
    decoder = nil;

    url = nil;
}

- (void) dealloc
{
    [self invalidate];
}

#pragma mark -

- (NSSize) frameSize
{
    NSSize size = [decoder frameSize];
    return size;
}

- (BOOL) readyForCurrent
{
    return [decoder readyForCurrent];
}

- (BOOL) readyForTime:(const CVTimeStamp*)ts
{
    double_t offset = (double)(ts->hostTime - CVGetCurrentHostTime()) / CVGetHostClockFrequency(); // in sec
    double_t position = (double)[decoder position]/AV_TIME_BASE + offset; // in sec
    double_t duration = (double)[decoder duration]/AV_TIME_BASE; // in sec

    // clipping
    position = (position < 0 ? 0 : position);
    position = (position > duration ? duration : position);

    //
    return [decoder readyForPTS:position];
}

- (CVPixelBufferRef) getCVPixelBuffer
{
    return [decoder getPixelBuffer];
}

- (QTTime) duration;
{
    int64_t    duration = [decoder duration];    //usec

    return QTMakeTime(duration, AV_TIME_BASE);
}

- (QTTime) currentTime
{
    int64_t position = [decoder position];    //usec

    return QTMakeTime(position, AV_TIME_BASE);
}

- (void) setCurrentTime:(QTTime)newTime
{
    QTTime timeInUsec = QTMakeTimeScaled(newTime, AV_TIME_BASE);

    [decoder setPosition:timeInUsec.timeValue blocking:YES];
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

    if(self.streamOutput) [self.streamOutput streamOutputNeedsSingleUpdate];
}

- (double_t) rate
{
    double_t rate = [decoder rate];
    return rate;
}

- (void) setRate:(double_t) newRate
{
    //NSLog(@"DEBUG: setRate: %.3f at %.3f", newRate, [decoder position]/1.0e6);

    if (!_htOffset) {
        // Inital call. Cancel remaining setRate: queued on mainthread if exists.
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(setRate:) object:NULL];
    }

    if (_htOffset && [decoder rate] == newRate) return;

    if (timer) {
        [timer invalidate];
        timer = nil;
    }

    // pause first
    if ([decoder rate]) [decoder setRate:0.0];

    if (newRate != 0.0) {
        //NSLog(@"DEBUG: movie started");

        [decoder setRate:newRate];

        // setup EndOfMovie Checker
        timer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                 target:self
                                               selector:@selector(checkEndOfMovie)
                                               userInfo:nil
                                                repeats:YES];
    }

    // current host time
    _htOffset = CVGetCurrentHostTime();
    _posOffset = (double)[decoder position] / [decoder duration];

    if(self.streamOutput) [self.streamOutput streamOutputNeedsContinuousUpdating: decoder.rate != 0.0];
}

- (void)checkEndOfMovie
{
    if ([decoder eof] && [decoder rate] == 0.0) {
        //NSLog(@"DEBUG: movie finished");

        if (timer) {
            [timer invalidate];
            timer = nil;
        }

        if(self.streamOutput) [self.streamOutput streamOutputNeedsContinuousUpdating:false];
    }

    return;
}

- (Float32) volume
{
    return currentVol;
}

- (void) setVolume:(Float32)volume
{
    currentVol = volume;
    [decoder setVolume:volume];
}

@end
