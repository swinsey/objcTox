//
//  OCTAudioEngine.h
//  objcTox
//
//  Created by Chuong Vu on 5/24/15.
//  Copyright (c) 2015 dvor. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "OCTToxAV.h"

@interface OCTAudioEngine : NSObject

@property (strong, nonatomic, readonly) NSString *inputDeviceID;
@property (strong, nonatomic, readonly) NSString *outputDeviceID;

@property (weak, nonatomic) OCTToxAV *toxav;
@property (nonatomic, assign) OCTToxFriendNumber friendNumber;

/**
 * YES to send audio frames over to tox, otherwise NO.
 * Default is YES.
 */
@property (nonatomic, assign) BOOL enableMicrophone;

/**
 * Starts the Audio Processing Graph.
 * @param error Pointer to error object.
 * @return YES on success, otherwise NO.
 */
- (BOOL)startAudioFlow:(NSError **)error;

/**
 * Stops the Audio Processing Graph.
 * @param error Pointer to error object.
 * @return YES on success, otherwise NO.
 */
- (BOOL)stopAudioFlow:(NSError **)error;

/**
 * Set the input device (not available on Mac OS X).
 * @param inputDeviceID Core Audio's unique ID for the device. See
 * @param error If this method returns NO, contains more information on the
 *              underlying error.
 * @return YES on success, otherwise NO.
 */
- (BOOL)setInputDeviceID:(NSString *)inputDeviceID error:(NSError **)error;
- (BOOL)setOutputDeviceID:(NSString *)outputDeviceID error:(NSError **)error;

/**
 * Checks if the Audio Graph is processing.
 * @param error Pointer to error object.
 * @return YES if Audio Graph is running, otherwise NO.
 */
- (BOOL)isAudioRunning:(NSError **)error;

/**
 * Provide audio data that will be placed in buffer to be played in speaker.
 * @param pcm An array of audio samples (sample_count * channels elements).
 * @param sampleCount The number of audio samples per channel in the PCM array.
 * @param channels Number of audio channels.
 * @param sampleRate Sampling rate used in this frame.
 */
- (void)provideAudioFrames:(OCTToxAVPCMData *)pcm sampleCount:(OCTToxAVSampleCount)sampleCount channels:(OCTToxAVChannels)channels sampleRate:(OCTToxAVSampleRate)sampleRate fromFriend:(OCTToxFriendNumber)friendNumber;


@end
