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

#import "lavp_core.h"
#import "lavp_video.h"
#import "packetqueue.h"
#import "lavp_audio.h"


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
    int wanted_nb_samples;

    Frame *af;
    {
        if (is->paused)
            return -1;

        do {
            if (!(af = frame_queue_peek_readable(&is->auddec->frameq)))
                return -1;
            frame_queue_next(&is->auddec->frameq);
        } while (af->frm_serial != is->auddec->packetq.serial);

        {
            data_size = av_samples_get_buffer_size(NULL, av_frame_get_channels(af->frm_frame),
                                                   af->frm_frame->nb_samples,
                                                   af->frm_frame->format, 1);

            dec_channel_layout =
                (af->frm_frame->channel_layout && av_frame_get_channels(af->frm_frame) == av_get_channel_layout_nb_channels(af->frm_frame->channel_layout)) ?
                af->frm_frame->channel_layout : av_get_default_channel_layout(av_frame_get_channels(af->frm_frame));
            wanted_nb_samples = synchronize_audio(is, af->frm_frame->nb_samples);

            if (af->frm_frame->format        != is->audio_src.fmt            ||
                dec_channel_layout       != is->audio_src.channel_layout ||
                af->frm_frame->sample_rate   != is->audio_src.freq           ||
                (wanted_nb_samples       != af->frm_frame->nb_samples && !is->swr_ctx)) {

                swr_free(&is->swr_ctx);
                is->swr_ctx = swr_alloc_set_opts(NULL,
                                                 is->audio_tgt.channel_layout, is->audio_tgt.fmt, is->audio_tgt.freq,
                                                 dec_channel_layout,           af->frm_frame->format, af->frm_frame->sample_rate,
                                                 0, NULL);
                if (!is->swr_ctx || swr_init(is->swr_ctx) < 0) {
                    av_log(NULL, AV_LOG_ERROR,
                           "Cannot create sample rate converter for conversion of %d Hz %s %d channels to %d Hz %s %d channels!\n",
                           af->frm_frame->sample_rate, av_get_sample_fmt_name(af->frm_frame->format), av_frame_get_channels(af->frm_frame),
                           is->audio_tgt.freq, av_get_sample_fmt_name(is->audio_tgt.fmt), is->audio_tgt.channels);
                    swr_free(&is->swr_ctx);
                    return -1;
                }
                is->audio_src.channel_layout = dec_channel_layout;
                is->audio_src.channels       = av_frame_get_channels(af->frm_frame);
                is->audio_src.freq = af->frm_frame->sample_rate;
                is->audio_src.fmt = af->frm_frame->format;
            }

            if (is->swr_ctx) {
                const uint8_t **in = (const uint8_t **)af->frm_frame->extended_data;
                uint8_t **out = &is->audio_buf1;
                int out_count = (int64_t)wanted_nb_samples * is->audio_tgt.freq / af->frm_frame->sample_rate + 256;
                int out_size  = av_samples_get_buffer_size(NULL, is->audio_tgt.channels, out_count, is->audio_tgt.fmt, 0);
                int len2;
                if (out_size < 0) {
                    av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size() failed\n");
                    return -1;
                }
                if (wanted_nb_samples != af->frm_frame->nb_samples) {
                    if (swr_set_compensation(is->swr_ctx, (wanted_nb_samples - af->frm_frame->nb_samples) * is->audio_tgt.freq / af->frm_frame->sample_rate,
                                             wanted_nb_samples * is->audio_tgt.freq / af->frm_frame->sample_rate) < 0) {
                        av_log(NULL, AV_LOG_ERROR, "swr_set_compensation() failed\n");
                        return -1;
                    }
                }
                av_fast_malloc(&is->audio_buf1, &is->audio_buf1_size, out_size);
                if (!is->audio_buf1)
                    return AVERROR(ENOMEM);
                len2 = swr_convert(is->swr_ctx, out, out_count, in, af->frm_frame->nb_samples);
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
                is->audio_buf = af->frm_frame->data[0];
                resampled_data_size = data_size;
            }

            /* update the audio clock with the pts */
            if (!isnan(af->frm_pts))
                is->audio_clock = af->frm_pts + (double) af->frm_frame->nb_samples / af->frm_frame->sample_rate;
            else
                is->audio_clock = NAN;
            is->audio_clock_serial = af->frm_serial;
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
    double inSampleRate = avctx->sample_rate;
    unsigned int inTotalBitsPerChannels = 16, inValidBitsPerChannel = 16;    // Packed
    unsigned int inChannelsPerFrame = avctx->channels;
    unsigned int inFramesPerPacket = 1;
    unsigned int inBytesPerFrame = inChannelsPerFrame * inTotalBitsPerChannels/8;
    unsigned int inBytesPerPacket = inBytesPerFrame * inFramesPerPacket;

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
            __strong VideoState* strongIs = weakIs;
            /* AudioQueue Callback should be ignored when closing */
            if (!strongIs || strongIs->abort_request) return;
            audio_callback(strongIs, inAQ, inBuffer);
        };

        is->audioDispatchQueue = dispatch_queue_create("audio", DISPATCH_QUEUE_SERIAL);
        err = AudioQueueNewOutputWithDispatchQueue(&outAQ, &is->asbd, 0, is->audioDispatchQueue, audioCallbackBlock);
    }

    assert(err == 0 && outAQ != NULL);
    is->outAQ = outAQ;

    // Enable timepitch
    unsigned int propValue = 1;
    err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_EnableTimePitch, &propValue, sizeof(propValue));
    assert(err == 0);

    // Preserve original pitch (using FFT filter)
    propValue = kAudioQueueTimePitchAlgorithm_Spectral;
    err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_TimePitchAlgorithm, &propValue, sizeof(propValue));
    assert(err == 0);

    // prepare audio queue buffers for Output
    unsigned int inBufferByteSize = (is->asbd.mSampleRate / 50) * is->asbd.mBytesPerFrame;    // perform callback 50 times per sec
    for( int i = 0; i < 3; i++ ) {
        // Allocate Buffer
        AudioQueueBufferRef outBuffer = NULL;
        err = AudioQueueAllocateBuffer(is->outAQ, inBufferByteSize, &outBuffer);
        assert(err == 0 && outBuffer != NULL);

        memset(outBuffer->mAudioData, 0, outBuffer->mAudioDataBytesCapacity);

        // Enqueue dummy data to start queuing
        outBuffer->mAudioDataByteSize=8; // dummy data
        AudioQueueEnqueueBuffer(is->outAQ, outBuffer, 0, 0);
    }
}

void LAVPAudioQueueStart(VideoState *is)
{
    if (!is->outAQ) return;

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

    unsigned int inNumberOfFramesToPrepare = is->asbd.mSampleRate / 60;    // Prepare for 1/60 sec
    OSStatus err = AudioQueuePrime(is->outAQ, inNumberOfFramesToPrepare, 0);
    assert(err == 0);
    err = AudioQueueStart(is->outAQ, NULL);
    assert(err == 0);
}

void LAVPAudioQueuePause(VideoState *is)
{
    if (!is->outAQ) return;
    OSStatus err = AudioQueueFlush(is->outAQ);
    assert(err == 0);
    err = AudioQueuePause(is->outAQ);
    assert(err == 0);
}

void LAVPAudioQueueStop(VideoState *is)
{
    if (!is->outAQ) return;

    OSStatus err = 0;
    unsigned int currentRunning = 0;
    unsigned int currentRunningSize = sizeof(currentRunning);
    err = AudioQueueGetProperty(is->outAQ, kAudioQueueProperty_IsRunning, &currentRunning, &currentRunningSize);
    assert(err == 0);

    // Stop AudioQueue
    if (currentRunning) {
        // Specifying YES with AudioQueueStop() to wait until done
        err = AudioQueueStop(is->outAQ, YES);
        assert(err == 0);
    }
}

void LAVPAudioQueueDealloc(VideoState *is)
{
    if (!is->outAQ) return;

    // stop AudioQueue
    OSStatus err = 0;
    err = AudioQueueReset(is->outAQ);
    assert(err == 0);
    err = AudioQueueDispose(is->outAQ, NO);
    assert(err == 0);
    is->outAQ = NULL;

    // stop dispatch queue
    if (is->audioDispatchQueue) is->audioDispatchQueue = NULL;
}

void setVolume(VideoState *is, AudioQueueParameterValue volume)
{
    if (!is->outAQ) return;
    OSStatus err = AudioQueueSetParameter(is->outAQ, kAudioQueueParam_Volume, volume);
    assert(!err);
}

BOOL audio_isPitchChanged(VideoState *is)
{
    if (!is->outAQ) return NO;
    // Compare current playrate b/w AudioQueue and VideoState
    float currentRate = 0;
    OSStatus err = AudioQueueGetParameter(is->outAQ, kAudioQueueParam_PlayRate, &currentRate);    // acceleration
    assert(err == 0);
    return currentRate != is->playRate;
}

void audio_updatePitch(VideoState *is)
{
    if (!is->outAQ) return;
    OSStatus err = AudioQueueSetParameter(is->outAQ, kAudioQueueParam_PlayRate, is->playRate);
    assert(err == 0);
    unsigned int propValue = (is->playbackSpeedPercent == 100);
    err = AudioQueueSetProperty(is->outAQ, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
    assert(err == 0);
}

int audio_thread(VideoState *is)
{
    AVFrame *frame = av_frame_alloc();
    if (!frame)
        return AVERROR(ENOMEM);
    for(;;) {
        int err = decoder_decode_frame(is->auddec, frame);
        if (err < 0) break;
        if (err == 0) continue;
        AVRational tb = (AVRational){1, frame->sample_rate};
        if(!decoder_push_frame(is->auddec, frame,
                /* pts */ frame->pts == AV_NOPTS_VALUE ? NAN : frame->pts * av_q2d(tb),
                /* duration */ av_q2d((AVRational){ frame->nb_samples, frame->sample_rate })
                ))
            break;
    }
    av_frame_free(&frame);
    return 0;
}


int lavp_get_volume_percent(VideoState *is) {
    return is ? is->volume_percent : 100;
}

void lavp_set_volume_percent(VideoState *is, int volume) {
    if (!is) return;
    is->volume_percent = volume;
    AudioQueueParameterValue newVolume = (AudioQueueParameterValue)volume / 100.0;
    if (is->auddec->stream) setVolume(is, newVolume);
}
