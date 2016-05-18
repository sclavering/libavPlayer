/*
 *  Created by Takashi Mochizuki on 11/06/19.
 *  Copyright 2011 MyCometG3. All rights reserved.
 */
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

#include "lavp_core.h"
#include "lavp_video.h"
#import "packetqueue.h"
#include "lavp_audio.h"


static int synchronize_audio(VideoState *is, int nb_samples);
int audio_decode_frame(VideoState *is);

BOOL audio_isPitchChanged(VideoState *is);
void audio_updatePitch(VideoState *is);

/* SDL audio buffer size, in samples. Should be small to have precise
 A/V sync as SDL does not have hardware buffer fullness info. */
#define SDL_AUDIO_BUFFER_SIZE 1024


/* =========================================================== */

#pragma mark -

int audio_open(VideoState *is, int64_t wanted_channel_layout, int wanted_nb_channels, int wanted_sample_rate, struct AudioParams *audio_hw_params)
{
    /* LAVP: TODO Simple 48KHz stereo output by default */
    if (wanted_sample_rate <= 0) {
        wanted_sample_rate = 48000;
    }

    if (wanted_nb_channels <= 0) {
        wanted_nb_channels = 2;
    }

    if (!wanted_channel_layout || wanted_nb_channels != av_get_channel_layout_nb_channels(wanted_channel_layout)) {
        wanted_channel_layout = av_get_default_channel_layout(wanted_nb_channels);
        wanted_channel_layout &= ~AV_CH_LAYOUT_STEREO_DOWNMIX;
    }

    audio_hw_params->fmt = AV_SAMPLE_FMT_S16;
    audio_hw_params->freq = wanted_sample_rate;
    audio_hw_params->channel_layout = wanted_channel_layout;
    audio_hw_params->channels =  wanted_nb_channels;
    audio_hw_params->frame_size = av_samples_get_buffer_size(NULL, audio_hw_params->channels, 1, audio_hw_params->fmt, 1);
    audio_hw_params->bytes_per_sec = av_samples_get_buffer_size(NULL, audio_hw_params->channels, audio_hw_params->freq, audio_hw_params->fmt, 1);
    if (audio_hw_params->bytes_per_sec <= 0 || audio_hw_params->frame_size <= 0) {
        av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size failed\n");
        return -1;
    }
    return SDL_AUDIO_BUFFER_SIZE * audio_hw_params->channels * av_get_bytes_per_sample(audio_hw_params->fmt);
}

/* return the wanted number of samples to get better sync if sync_type is video */
static int synchronize_audio(VideoState *is, int nb_samples)
{
    // xxx this is vestigial from ffplay allowing for using the video or external clocks as the master clock.
    return nb_samples;
}

/**
 * Decode one audio frame and return its uncompressed size.
 *
 * The processed audio frame is decoded, converted if required, and
 * stored in is->audio_buf, with size in bytes given by the return
 * value.
 */
int audio_decode_frame(VideoState *is)
{
    int data_size, resampled_data_size;
    int64_t dec_channel_layout;
    av_unused double audio_clock0;
    int wanted_nb_samples;

    Frame *af;
    {
        if (is->paused)
            return -1;

        do {
            if (!(af = frame_queue_peek_readable(&is->sampq)))
                return -1;
            frame_queue_next(&is->sampq);
        } while (af->serial != is->audioq.serial);

        {
            data_size = av_samples_get_buffer_size(NULL, av_frame_get_channels(af->frame),
                                                   af->frame->nb_samples,
                                                   af->frame->format, 1);

            dec_channel_layout =
                (af->frame->channel_layout && av_frame_get_channels(af->frame) == av_get_channel_layout_nb_channels(af->frame->channel_layout)) ?
                af->frame->channel_layout : av_get_default_channel_layout(av_frame_get_channels(af->frame));
            wanted_nb_samples = synchronize_audio(is, af->frame->nb_samples);

            if (af->frame->format        != is->audio_src.fmt            ||
                dec_channel_layout       != is->audio_src.channel_layout ||
                af->frame->sample_rate   != is->audio_src.freq           ||
                (wanted_nb_samples       != af->frame->nb_samples && !is->swr_ctx)) {

                swr_free(&is->swr_ctx);
                is->swr_ctx = swr_alloc_set_opts(NULL,
                                                 is->audio_tgt.channel_layout, is->audio_tgt.fmt, is->audio_tgt.freq,
                                                 dec_channel_layout,           af->frame->format, af->frame->sample_rate,
                                                 0, NULL);
                if (!is->swr_ctx || swr_init(is->swr_ctx) < 0) {
                    av_log(NULL, AV_LOG_ERROR,
                           "Cannot create sample rate converter for conversion of %d Hz %s %d channels to %d Hz %s %d channels!\n",
                           af->frame->sample_rate, av_get_sample_fmt_name(af->frame->format), av_frame_get_channels(af->frame),
                           is->audio_tgt.freq, av_get_sample_fmt_name(is->audio_tgt.fmt), is->audio_tgt.channels);
                    swr_free(&is->swr_ctx);
                    return -1;
                }
                is->audio_src.channel_layout = dec_channel_layout;
                is->audio_src.channels       = av_frame_get_channels(af->frame);
                is->audio_src.freq = af->frame->sample_rate;
                is->audio_src.fmt = af->frame->format;
            }

            if (is->swr_ctx) {
                const uint8_t **in = (const uint8_t **)af->frame->extended_data;
                uint8_t **out = &is->audio_buf1;
                int out_count = (int64_t)wanted_nb_samples * is->audio_tgt.freq / af->frame->sample_rate + 256;
                int out_size  = av_samples_get_buffer_size(NULL, is->audio_tgt.channels, out_count, is->audio_tgt.fmt, 0);
                int len2;
                if (out_size < 0) {
                    av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size() failed\n");
                    return -1;
                }
                if (wanted_nb_samples != af->frame->nb_samples) {
                    if (swr_set_compensation(is->swr_ctx, (wanted_nb_samples - af->frame->nb_samples) * is->audio_tgt.freq / af->frame->sample_rate,
                                             wanted_nb_samples * is->audio_tgt.freq / af->frame->sample_rate) < 0) {
                        av_log(NULL, AV_LOG_ERROR, "swr_set_compensation() failed\n");
                        return -1;
                    }
                }
                av_fast_malloc(&is->audio_buf1, &is->audio_buf1_size, out_size);
                if (!is->audio_buf1)
                    return AVERROR(ENOMEM);
                len2 = swr_convert(is->swr_ctx, out, out_count, in, af->frame->nb_samples);
                if (len2 < 0) {
                    av_log(NULL, AV_LOG_ERROR, "swr_convert() failed\n");
                    return -1;
                }
                if (len2 == out_count) {
                    av_log(NULL, AV_LOG_WARNING, "audio buffer is probably too small\n");
                    if (swr_init(is->swr_ctx) < 0)
                        swr_free(&is->swr_ctx);
                }
                is->audio_buf = is->audio_buf1;
                resampled_data_size = len2 * is->audio_tgt.channels * av_get_bytes_per_sample(is->audio_tgt.fmt);
            } else {
                is->audio_buf = af->frame->data[0];
                resampled_data_size = data_size;
            }

            audio_clock0 = is->audio_clock;
            /* update the audio clock with the pts */
            if (!isnan(af->pts))
                is->audio_clock = af->pts + (double) af->frame->nb_samples / af->frame->sample_rate;
            else
                is->audio_clock = NAN;
            is->audio_clock_serial = af->serial;
            return resampled_data_size;
        }
    }
}

/* prepare a new audio buffer */
/* LAVP: original: sdl_audio_callback() */
static void audio_callback(VideoState *is, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer)
{
    @autoreleasepool {
        uint8_t *stream = inBuffer->mAudioData;
        int len = inBuffer->mAudioDataBytesCapacity;

        //
        int audio_size, len1;

        is->audio_callback_time = av_gettime_relative();

        while (len > 0) {
            if (is->audio_buf_index >= is->audio_buf_size) {
                audio_size = audio_decode_frame(is);
                if (audio_size < 0) {
                    /* if error, just output silence */
                    is->audio_buf = NULL;
                    is->audio_buf_size = SDL_AUDIO_BUFFER_SIZE / is->audio_tgt.frame_size * is->audio_tgt.frame_size;
                } else {
                    is->audio_buf_size = audio_size;
                }
                is->audio_buf_index = 0;
            }
            len1 = is->audio_buf_size - is->audio_buf_index;
            if (len1 > len)
                len1 = len;
            if (is->audio_buf)
                memcpy(stream, (uint8_t *)is->audio_buf + is->audio_buf_index, len1);
            len -= len1;
            stream += len1;
            is->audio_buf_index += len1;
        }
        is->audio_write_buf_size = is->audio_buf_size - is->audio_buf_index;

        /* Let's assume the audio driver that is used by SDL has two periods. */
        if (!isnan(is->audio_clock)) {
            set_clock_at(&is->audclk, is->audio_clock - (double)(2 * is->audio_hw_buf_size + is->audio_write_buf_size) / is->audio_tgt.bytes_per_sec, is->audio_clock_serial, is->audio_callback_time / 1000000.0);
        }

        /* LAVP: Enqueue LPCM result into Audio Queue */
        inBuffer->mAudioDataByteSize = stream - (UInt8 *)inBuffer->mAudioData;
        OSStatus err = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
        if (err) {
            NSString *errStr = @"kAudioQueueErr_???";
            switch (err) {
                case kAudioQueueErr_DisposalPending:
                    errStr = @"kAudioQueueErr_DisposalPending"; break;
                case kAudioQueueErr_InvalidDevice:
                    errStr = @"kAudioQueueErr_InvalidDevice"; break;
                case kAudioQueueErr_InvalidRunState:
                    errStr = @"kAudioQueueErr_InvalidRunState"; break;
                case kAudioQueueErr_QueueInvalidated:
                    errStr = @"kAudioQueueErr_QueueInvalidated"; break;
                case kAudioQueueErr_EnqueueDuringReset:
                    errStr = @"kAudioQueueErr_EnqueueDuringReset"; break;
            }
            NSLog(@"DEBUG: AudioQueueEnqueueBuffer() returned %d (%@)", err, errStr);
        }
    }
}

#pragma mark -

static void LAVPFillASBD(VideoState *is, AVCodecContext *avctx)
{
    Float64 inSampleRate = avctx->sample_rate;
    UInt32 inTotalBitsPerChannels = 16, inValidBitsPerChannel = 16;    // Packed
    UInt32 inChannelsPerFrame = avctx->channels;
    UInt32 inFramesPerPacket = 1;
    UInt32 inBytesPerFrame = inChannelsPerFrame * inTotalBitsPerChannels/8;
    UInt32 inBytesPerPacket = inBytesPerFrame * inFramesPerPacket;

    memset(&is->asbd, 0, sizeof(AudioStreamBasicDescription));
    is->asbd.mSampleRate = inSampleRate;
    is->asbd.mFormatID = kAudioFormatLinearPCM;
    is->asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    //is->asbd.mFormatFlags |= kAudioFormatFlagIsBigEndian;
    is->asbd.mBytesPerPacket = inBytesPerPacket;
    is->asbd.mFramesPerPacket = inFramesPerPacket;
    is->asbd.mBytesPerFrame = inBytesPerFrame;
    is->asbd.mChannelsPerFrame = inChannelsPerFrame;
    is->asbd.mBitsPerChannel = inValidBitsPerChannel;
}

/* LAVP: original: audio_open() */
void LAVPAudioQueueInit(VideoState *is, AVCodecContext *avctx)
{
    if (is->outAQ) return;

    //NSLog(@"DEBUG: LAVPAudioQueueInit");

    if (!avctx->sample_rate) {
        // NOTE: is->outAQ, is->audioDispatchQueue are left uninitialized

        // xxx abort here, in some fashion (since we need the sample_rate for the audio clock)
        return;
    }

    // prepare Audio stream basic description
    LAVPFillASBD(is, avctx);

    // prepare AudioQueue for Output
    OSStatus err = 0;
    AudioQueueRef outAQ = NULL;

    if (!is->audioDispatchQueue) {
        __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
        void (^audioCallbackBlock)() = ^(AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
            __strong VideoState* is = weakIs;
            /* AudioQueue Callback should be ignored when closing */
            if (!is || is->abort_request) return;
            audio_callback(is, inAQ, inBuffer);
        };

        dispatch_queue_t audioDispatchQueue = dispatch_queue_create("audio", DISPATCH_QUEUE_SERIAL);
        is->audioDispatchQueue = (__bridge_retained void*)audioDispatchQueue;
        err = AudioQueueNewOutputWithDispatchQueue(&outAQ, &is->asbd, 0, (__bridge dispatch_queue_t)is->audioDispatchQueue, audioCallbackBlock);
    }

    assert(err == 0 && outAQ != NULL);
    is->outAQ = outAQ;

    // Enable timepitch
    UInt32 propValue = 1;
    err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_EnableTimePitch, &propValue, sizeof(propValue));
    assert(err == 0);

    // Preserve original pitch (using FFT filter)
    propValue = kAudioQueueTimePitchAlgorithm_Spectral;
    err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_TimePitchAlgorithm, &propValue, sizeof(propValue));
    assert(err == 0);

    // prepare audio queue buffers for Output
    UInt32 inBufferByteSize = (is->asbd.mSampleRate / 50) * is->asbd.mBytesPerFrame;    // perform callback 50 times per sec
    for( int i = 0; i < 3; i++ ) {
        // Allocate Buffer
        AudioQueueBufferRef outBuffer = NULL;
        err = AudioQueueAllocateBuffer(is->outAQ, inBufferByteSize, &outBuffer);
        assert(err == 0 && outBuffer != NULL);

        // Nullify data
        memset(outBuffer->mAudioData, 0, outBuffer->mAudioDataBytesCapacity);

        // Enqueue dummy data to start queuing
        outBuffer->mAudioDataByteSize=8; // dummy data
        AudioQueueEnqueueBuffer(is->outAQ, outBuffer, 0, 0);
    }
}

void LAVPAudioQueueStart(VideoState *is)
{
    if (!is->outAQ) return;

    //NSLog(@"DEBUG: LAVPAudioQueueStart");

    // Update playback rate
    BOOL pitchDiff = audio_isPitchChanged(is);
    if ( pitchDiff ) {
        // NOTE: kAudioQueueParam_PlayRate and kAudioQueueProperty_TimePitchBypass
        // can be modified without LAVPAudioQueueStop(is);
        audio_updatePitch(is);
    }
    pitchDiff = audio_isPitchChanged(is);
    if ( pitchDiff ) {
        NSLog(@"ERROR: Failed to update pitch.");
        assert(!pitchDiff);
    }

    //
    OSStatus err = 0;
    UInt32 inNumberOfFramesToPrepare = is->asbd.mSampleRate / 60;    // Prepare for 1/60 sec

    err = AudioQueuePrime(is->outAQ, inNumberOfFramesToPrepare, 0);
    assert(err == 0);

    err = AudioQueueStart(is->outAQ, NULL);
    assert(err == 0);
}

void LAVPAudioQueuePause(VideoState *is)
{
    if (!is->outAQ) return;

    //NSLog(@"DEBUG: LAVPAudioQueuePause");

    //
    OSStatus err = 0;

    err = AudioQueueFlush(is->outAQ);
    assert(err == 0);

    err = AudioQueuePause(is->outAQ);
    assert(err == 0);
}

void LAVPAudioQueueStop(VideoState *is)
{
    if (!is->outAQ) return;

    //NSLog(@"DEBUG: LAVPAudioQueueStop");

    // Check AudioQueue is running or not
    OSStatus err = 0;
    UInt32 currentRunning = 0;
    UInt32 currentRunningSize = sizeof(currentRunning);

    err = AudioQueueGetProperty(is->outAQ, kAudioQueueProperty_IsRunning, &currentRunning, &currentRunningSize);
    assert(err == 0);

    // Stop AudioQueue
    if (currentRunning) {
        // Specifying YES with AudioQueueStop() to wait untill done
        err = AudioQueueStop(is->outAQ, YES);
        assert(err == 0);
    }

    //NSLog(@"DEBUG: LAVPAudioQueueStop done");
}

void LAVPAudioQueueDealloc(VideoState *is)
{
    if (!is->outAQ) return;

    //NSLog(@"DEBUG: LAVPAudioQueueDealloc");

    // stop AudioQueue
    OSStatus err = 0;

    err = AudioQueueReset(is->outAQ);
    assert(err == 0);

    err = AudioQueueDispose(is->outAQ, NO);
    assert(err == 0);

    is->outAQ = NULL;

    // stop dispatch queue
    if (is->audioDispatchQueue) {
        dispatch_queue_t audioDispatchQueue = (__bridge_transfer dispatch_queue_t)is->audioDispatchQueue;
        audioDispatchQueue = NULL; // ARC
        is->audioDispatchQueue = NULL;
    }

    //NSLog(@"DEBUG: LAVPAudioQueueDealloc done");
}

AudioQueueParameterValue getVolume(VideoState *is)
{
    if (!is->outAQ) return 0.0;

    OSStatus err = 0;
    AudioQueueParameterValue volume;

    err = AudioQueueGetParameter(is->outAQ, kAudioQueueParam_Volume, &volume);
    assert(!err);

    return volume;
}

void setVolume(VideoState *is, AudioQueueParameterValue volume)
{
    if (!is->outAQ) return;

    OSStatus err = 0;

    err = AudioQueueSetParameter(is->outAQ, kAudioQueueParam_Volume, volume);
    assert(!err);
}

BOOL audio_isPitchChanged(VideoState *is)
{
    if (!is->outAQ) return NO;

    OSStatus err = 0;

    // Compare current playrate b/w AudioQueue and VideoState
    float currentRate = 0;
    err = AudioQueueGetParameter(is->outAQ, kAudioQueueParam_PlayRate, &currentRate);    // acceleration
    assert(err == 0);

    if (currentRate == is->playRate) {
        return NO;
    } else {
        return YES;
    }
}

void audio_updatePitch(VideoState *is)
{
    if (!is->outAQ) return;

    OSStatus err = 0;

    assert(is->playRate > 0.0);

    //NSLog(@"DEBUG: is->playRate = %.1f", is->playRate);

    if (is->playRate == 1.0) {
        // Set playrate
        err = AudioQueueSetParameter(is->outAQ, kAudioQueueParam_PlayRate, is->playRate);
        assert(err == 0);

        // Bypass TimePitch
        UInt32 propValue = 1;
        err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
        assert(err == 0);
    } else {
        // Set playrate
        err = AudioQueueSetParameter(is->outAQ, kAudioQueueParam_PlayRate, is->playRate);
        assert(err == 0);

        // Use TimePitch (using FFT filter)
        UInt32 propValue = 0;
        err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
        assert(err == 0);
    }
}

int audio_thread(VideoState *is)
{
    AVFrame *frame = av_frame_alloc();
    Frame *af;
    int got_frame = 0;
    AVRational tb;
    int ret = 0;

    if (!frame)
        return AVERROR(ENOMEM);

    do {
        if ((got_frame = decoder_decode_frame(is->auddec, frame)) < 0)
            goto the_end;

        if (got_frame) {
            tb = (AVRational){1, frame->sample_rate};

            if (!(af = frame_queue_peek_writable(&is->sampq)))
                goto the_end;

            af->pts = (frame->pts == AV_NOPTS_VALUE) ? NAN : frame->pts * av_q2d(tb);
            af->pos = av_frame_get_pkt_pos(frame);
            af->serial = is->auddec->pkt_serial;
            af->duration = av_q2d((AVRational){frame->nb_samples, frame->sample_rate});

            av_frame_move_ref(af->frame, frame);
            frame_queue_push(&is->sampq);
        }
    } while (ret >= 0 || ret == AVERROR(EAGAIN) || ret == AVERROR_EOF);
the_end:
    av_frame_free(&frame);
    return ret;
}
