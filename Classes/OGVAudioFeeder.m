//
//  OGVAudioFeeder.m
//  OGVKit
//
//  Created by Brion on 6/28/14.
//  Copyright (c) 2014-2015 Brion Vibber. All rights reserved.
//

#import "OGVKit.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface OGVAudioFeeder(Private)

-(void)handleQueue:(AudioQueueRef)queue buffer:(AudioQueueBufferRef)buffer;
-(void)handleQueue:(AudioQueueRef)queue propChanged:(AudioQueuePropertyID)prop;

-(void)queueInput:(OGVAudioBuffer *)buffer;
-(OGVAudioBuffer *)nextInput;

@end

static const int nBuffers = 2;
static const int circularBufferSize = 3200 * 16;

typedef OSStatus (^OSStatusWrapperBlock)(void);

static void OGVAudioFeederBufferHandler(void *data, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    OGVAudioFeeder *feeder = (__bridge OGVAudioFeeder *)data;
    @autoreleasepool {
        [feeder handleQueue:queue buffer:buffer];
    }
}

static void OGVAudioFeederPropListener(void *data, AudioQueueRef queue, AudioQueuePropertyID prop) {
    OGVAudioFeeder *feeder = (__bridge OGVAudioFeeder *)data;
    @autoreleasepool {
        [feeder handleQueue:queue propChanged:prop];
    }
}

@implementation OGVAudioFeeder {
    
    NSObject *timeLock;
    
    Float32 *circularBuffer;
    size_t circularHead;
    size_t circularTail;
    
    int samplesQueued;
    int samplesPlayed;
    
    AudioStreamBasicDescription formatDescription;
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[nBuffers];
    
    UInt32 sampleSize;
    UInt32 bufferSize;
    UInt32 bufferByteSize;
    
    BOOL isStarting;
    BOOL isRunning;
    BOOL isClosing;
    BOOL isClosed;
    BOOL shouldClose;
}

-(id)initWithFormat:(OGVAudioFormat *)format
{
    self = [self init];
    if (self) {
        timeLock = [[NSObject alloc] init];
        
        _format = format;
        isStarting = NO;
        isRunning = NO;
        isClosing = NO;
        isClosed = NO;
        shouldClose = NO;
        
        samplesQueued = 0;
        samplesPlayed = 0;
        
        sampleSize = sizeof(Float32);
        bufferSize = 1024;
        bufferByteSize = bufferSize * sampleSize * format.channels;
        
        circularBuffer = (Float32 *)malloc(circularBufferSize * sampleSize * format.channels);
        circularHead = 0;
        circularTail = 0;
        
        formatDescription.mSampleRate = format.sampleRate;
        formatDescription.mFormatID = kAudioFormatLinearPCM;
        formatDescription.mFormatFlags = kLinearPCMFormatFlagIsFloat;
        formatDescription.mBytesPerPacket = sampleSize * format.channels;
        formatDescription.mFramesPerPacket = 1;
        formatDescription.mBytesPerFrame = sampleSize * format.channels;
        formatDescription.mChannelsPerFrame = format.channels;
        formatDescription.mBitsPerChannel = sampleSize * 8;
        formatDescription.mReserved = 0;
        
        UInt8 status = AudioQueueNewOutput(&self->formatDescription,
                                           OGVAudioFeederBufferHandler,
                                           (__bridge void *)self,
                                           NULL,
                                           NULL,
                                           0,
                                           &self->queue);
        
        for (int i = 0; i < nBuffers; i++) {
            status = AudioQueueAllocateBuffer(self->queue,
                                              self->bufferByteSize,
                                              &self->buffers[i]);
        }
    }
    
    return self;
}


-(void)dealloc
{
    if (queue) {
        AudioQueueDispose(queue, true);
    }
    if (circularBuffer) {
        free(circularBuffer);
    }
}

-(BOOL)bufferData:(OGVAudioBuffer *)buffer
{
    @synchronized (timeLock) {
        if (isClosing || isClosed) {
            return NO;
        }
        if (buffer.samples > 0) {
            [self queueInput:buffer];
            if (!isStarting && !isRunning && !isClosing && !isClosed && samplesQueued >= circularBufferSize / 4) {
                [self startAudio];
            }
        }
        return YES;
    }
}

-(BOOL)isStarted
{
    @synchronized (timeLock) {
        return isStarting || isRunning;
    }
}

-(BOOL)isClosing;
{
    @synchronized (timeLock) {
        return isClosing;
    }
}

-(BOOL)isClosed;
{
    @synchronized (timeLock) {
        return isClosed;
    }
}


-(void)close
{
    @synchronized (timeLock) {
        isClosing = YES;
        shouldClose = YES;
    }
}

-(int)samplesQueued
{
    @synchronized (timeLock) {
        return samplesQueued - samplesPlayed;
    }
}

-(float)secondsQueued
{
    return (float)[self samplesQueued] / self.format.sampleRate;
}

-(float)timeAwaitingPlayback
{
    return [self bufferTailPosition] - [self playbackPosition];
}

-(float)playbackPosition
{
    @synchronized (timeLock) {
        if (isRunning && !isClosing) {
            __block AudioTimeStamp ts;
            
            UInt8 status = AudioQueueGetCurrentTime(self->queue, NULL, &ts, NULL);
            
            float samplesOutput = ts.mSampleTime;
            return samplesOutput / self.format.sampleRate;
        } else {
            return samplesPlayed / self.format.sampleRate;
        }
    }
}

-(float)bufferTailPosition
{
    @synchronized (timeLock) {
        return samplesQueued / self.format.sampleRate;
    }
}

#pragma mark - Private methods

-(size_t)circularCount
{
    return (circularTail + circularBufferSize - circularHead) % circularBufferSize;
}

-(void)handleQueue:(AudioQueueRef)_queue buffer:(AudioQueueBufferRef)buffer
{
    @synchronized (timeLock) {
        if (shouldClose) {
            AudioQueueStop(queue, NO);
            return;
        }
        
        size_t samplesAvailable = samplesQueued - samplesPlayed;
        if (samplesAvailable > 0) {
            size_t sampleCount = samplesAvailable;
            if (sampleCount > bufferSize) {
                sampleCount = bufferSize;
            }
            unsigned int channels = self.format.channels;
            size_t channelSize = sampleCount * sampleSize;
            size_t packetSize = channelSize * channels;
            
            Float32 *dest = (Float32 *)buffer->mAudioData;
            for (size_t i = 0; i < sampleCount * channels; i++) {
                dest[i] = circularBuffer[circularHead];
                circularHead = (circularHead + 1) % circularBufferSize;
            }
            samplesPlayed += sampleCount;
            
            buffer->mAudioDataByteSize = (UInt32)packetSize;
            
            self.status = AudioQueueEnqueueBuffer(self->queue, buffer, 0, NULL);
        } else {
            [OGVKit.singleton.logger warnWithFormat:@"starved for audio!"];
            // Close it out when ready
            isClosing = YES;
            //AudioQueueStop(queue, NO);
            shouldClose = YES;
        }
    }
}

-(void)handleQueue:(AudioQueueRef)_queue propChanged:(AudioQueuePropertyID)prop
{
    @synchronized (timeLock) {
        if (prop == kAudioQueueProperty_IsRunning) {
            __block UInt32 _isRunning = 0;
            __block UInt32 _size = sizeof(_isRunning);
            self.status = AudioQueueGetProperty(self->queue, prop, &_isRunning, &_size);
            isRunning = (BOOL)_isRunning;
            if (isStarting) {
                isStarting = NO;
            }
            if (isClosing) {
                isClosing = NO;
            }
            if (!isRunning) {
                isClosed = YES;
            }
        }
    }
}

-(void)startAudio
{
    @synchronized (timeLock) {
        if (isStarting) {
            // This... probably shouldn't happen.
            return;
        }
        assert(!isRunning);
        assert(samplesQueued >= nBuffers * bufferSize);
        
        // Prevent error 560557684
        if ([[AVAudioSession sharedInstance] isOtherAudioPlaying]) {
            return;
        }
        
        isStarting = YES;
        
        [self changeAudioSessionCategory];
        
        // Prime the buffers!
        for (int i = 0; i < nBuffers; i++) {
            [self handleQueue:queue buffer:buffers[i]];
        }
        
        // Set a listener to update isRunning
        self.status = AudioQueueAddPropertyListener(self->queue,
                                                    kAudioQueueProperty_IsRunning,
                                                    OGVAudioFeederPropListener,
                                                    (__bridge void *)self);
        
        self.status = AudioQueueStart(self->queue, NULL);
    }
}

-(void)changeAudioSessionCategory
{
    NSString *category = [[AVAudioSession sharedInstance] category];
    
    // if the current category is Playback or PlayAndRecord, we don't have to change anything
    if ([category isEqualToString:AVAudioSessionCategoryPlayback] || [category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        return;
    }
    
    NSError * err;
    
    // if the current category is Record, set it to PlayAndRecord
    if ([category isEqualToString:AVAudioSessionCategoryRecord]) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:&err];
        return;
    }
    
    // otherwise we just change it to Playback
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&err];
    
    if (err) {
        self.status = 1;
    }
}

-(void)queueInput:(OGVAudioBuffer *)buffer
{
    @synchronized (timeLock) {
        int samples = buffer.samples;
        int channels = self.format.channels;
        
        assert(samples * channels + [self circularCount] <= circularBufferSize * channels);
        samplesQueued += samples;
        
        // AudioToolbox wants interleaved
        const float *srcData[channels];
        for (int channel = 0; channel < channels; channel++) {
            srcData[channel] = [buffer PCMForChannel:channel];
        }
        for (int i = 0; i < buffer.samples; i++) {
            for (int channel = 0; channel < channels; channel++) {
                circularBuffer[circularTail] = srcData[channel][i];
                circularTail = (circularTail + 1) % circularBufferSize;
            }
        }
    }
}

@end
