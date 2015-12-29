//
//  OCTCallSubmanager.m
//  objcTox
//
//  Created by Chuong Vu on 5/8/15.
//  Copyright (c) 2015 dvor. All rights reserved.
//

#import "OCTSubmanagerCalls+Private.h"

const OCTToxAVAudioBitRate kDefaultAudioBitRate = OCTToxAVAudioBitRate48;
const OCTToxAVVideoBitRate kDefaultVideoBitRate = 2000;

@interface OCTSubmanagerCalls () <OCTToxAVDelegate>

@property (weak, nonatomic) id<OCTSubmanagerDataSource> dataSource;

@property (strong, nonatomic) OCTToxAV *toxAV;
@property (strong, nonatomic) OCTAudioEngine *audioEngine;
@property (strong, nonatomic) OCTVideoEngine *videoEngine;
@property (strong, nonatomic) OCTCallTimer *timer;
@property (nonatomic, assign) dispatch_once_t setupOnceToken;

@end

@implementation OCTSubmanagerCalls : NSObject

- (instancetype)initWithTox:(OCTTox *)tox
{
    self = [super init];

    if (! self) {
        return nil;
    }

    _toxAV = [[OCTToxAV alloc] initWithTox:tox error:nil];
    _toxAV.delegate = self;
    [_toxAV start];

    return self;
}

- (BOOL)setupWithError:(NSError **)error
{
    NSAssert(self.dataSource, @"dataSource is needed before setup of OCTSubmanagerCalls");
    __block BOOL status = NO;
    dispatch_once(&_setupOnceToken, ^{
        OCTRealmManager *realmManager = [self.dataSource managerGetRealmManager];
        self.timer = [[OCTCallTimer alloc] initWithRealmManager:realmManager];

        self.audioEngine = [OCTAudioEngine new];
        self.audioEngine.toxav = self.toxAV;
        self.videoEngine = [OCTVideoEngine new];
        self.videoEngine.toxav = self.toxAV;

        status = [self.videoEngine setupWithError:error];
    });

    return status;
}

- (BOOL)switchToCameraFront:(BOOL)front error:(NSError **)error
{
    return [self.videoEngine switchToCameraFront:front error:error];
}

- (OCTCall *)callToChat:(OCTChat *)chat enableAudio:(BOOL)enableAudio enableVideo:(BOOL)enableVideo error:(NSError **)error
{
    OCTToxAVAudioBitRate audioBitRate = (enableAudio) ? kDefaultAudioBitRate : OCTToxAVAudioBitRateDisabled;
    OCTToxAVVideoBitRate videoBitRate = (enableVideo) ? kDefaultVideoBitRate : kOCTToxAVVideoBitRateDisable;


    if (chat.friends.count == 1) {
        OCTFriend *friend = chat.friends.lastObject;
        self.audioEngine.friendNumber = friend.friendNumber;

        if (! [self.toxAV callFriendNumber:friend.friendNumber
                              audioBitRate:audioBitRate
                              videoBitRate:videoBitRate
                                     error:error]) {
            return nil;
        }

        [self checkForCurrentActiveCallAndPause];

        OCTCall *call = [self createCallWithFriendNumber:friend.friendNumber status:OCTCallStatusDialing];

        OCTRealmManager *manager = [self.dataSource managerGetRealmManager];
        [manager updateObject:call withBlock:^(OCTCall *callToUpdate) {
            callToUpdate.status = OCTCallStatusDialing;
            callToUpdate.videoIsEnabled = enableVideo;
        }];

        self.enableMicrophone = YES;

        return call;
    }
    else {
        // TO DO: Group Calls
        return nil;
    }
    return nil;
}

- (BOOL)enableVideoSending:(BOOL)enable forCall:(OCTCall *)call error:(NSError **)error
{
    OCTToxAVVideoBitRate bitrate = (enable) ? kDefaultVideoBitRate : kOCTToxAVVideoBitRateDisable;
    if (! [self setVideoBitrate:bitrate forCall:call error:error]) {
        return NO;
    }

    if (enable && (! [call isPaused])) {
        OCTFriend *friend = [call.chat.friends firstObject];
        self.videoEngine.friendNumber = friend.friendNumber;
        [self.videoEngine startSendingVideo];
    }
    else {
        [self.videoEngine stopSendingVideo];
    }

    OCTRealmManager *manager = [self.dataSource managerGetRealmManager];
    [manager updateObject:call withBlock:^(OCTCall *callToUpdate) {
        callToUpdate.videoIsEnabled = enable;
    }];

    return YES;
}

- (BOOL)answerCall:(OCTCall *)call enableAudio:(BOOL)enableAudio enableVideo:(BOOL)enableVideo error:(NSError **)error
{
    OCTToxAVAudioBitRate audioBitRate = (enableAudio) ? kDefaultAudioBitRate : OCTToxAVAudioBitRateDisabled;
    OCTToxAVVideoBitRate videoBitRate = (enableVideo) ? kDefaultVideoBitRate : kOCTToxAVVideoBitRateDisable;

    if (call.chat.friends.count == 1) {

        OCTFriend *friend = call.chat.friends.firstObject;

        if (! [self.toxAV answerIncomingCallFromFriend:friend.friendNumber
                                          audioBitRate:audioBitRate
                                          videoBitRate:videoBitRate
                                                 error:error]) {
            return NO;
        }

        [self checkForCurrentActiveCallAndPause];

        [self startEnginesAndTimer:YES forCall:call];

        OCTRealmManager *manager = [self.dataSource managerGetRealmManager];
        [manager updateObject:call withBlock:^(OCTCall *callToUpdate) {
            call.status = OCTCallStatusActive;
            callToUpdate.videoIsEnabled = enableVideo;
        }];

        self.enableMicrophone = YES;

        return YES;
    }
    else {
        // TO DO: Group Calls
        return NO;
    }
}

- (BOOL)routeAudioToSpeaker:(BOOL)speaker error:(NSError **)error
{
    return [self.audioEngine routeAudioToSpeaker:speaker error:error];
}

- (BOOL)enableMicrophone
{
    return self.audioEngine.enableMicrophone;
}

- (void)setEnableMicrophone:(BOOL)enableMicrophone
{
    self.audioEngine.enableMicrophone = enableMicrophone;
}

- (BOOL)sendCallControl:(OCTToxAVCallControl)control toCall:(OCTCall *)call error:(NSError **)error
{
    if (call.chat.friends.count == 1) {

        OCTFriend *friend = call.chat.friends.firstObject;

        if (! [self.toxAV sendCallControl:control toFriendNumber:friend.friendNumber error:error]) {
            return NO;
        }

        switch (control) {
            case OCTToxAVCallControlResume:
                [self checkForCurrentActiveCallAndPause];
                [self putOnPause:NO call:call];
                break;
            case OCTToxAVCallControlCancel:
                [self addMessageAndDeleteCall:call];

                if ((self.audioEngine.friendNumber == friend.friendNumber) &&
                    ([self.audioEngine isAudioRunning:nil])) {
                    [self startEnginesAndTimer:NO forCall:call];
                }

                break;
            case OCTToxAVCallControlPause:
                [self putOnPause:YES call:call];
                break;
            case OCTToxAVCallControlUnmuteAudio:
                break;
            case OCTToxAVCallControlMuteAudio:
                break;
            case OCTToxAVCallControlHideVideo:
                break;
            case OCTToxAVCallControlShowVideo:
                break;
        }
        return YES;
    }
    else {
        return NO;
    }
}

- (OCTView *)videoFeed
{
    return [self.videoEngine videoFeed];
}

- (void)getVideoCallPreview:(void (^)(CALayer *))completionBlock
{
    [self.videoEngine getVideoCallPreview:completionBlock];
}

- (BOOL)setAudioBitrate:(int)bitrate forCall:(OCTCall *)call error:(NSError **)error
{
    if (call.chat.friends.count == 1) {

        OCTFriend *friend = call.chat.friends.firstObject;

        return [self.toxAV setAudioBitRate:bitrate force:NO forFriend:friend.friendNumber error:error];
    }
    else {
        // TO DO: Group Calls
        return NO;
    }
}

#pragma mark Private methods
- (OCTCall *)createCallWithFriendNumber:(OCTToxFriendNumber)friendNumber status:(OCTCallStatus)status
{
    OCTRealmManager *realmManager = [self.dataSource managerGetRealmManager];

    OCTFriend *friend = [realmManager friendWithFriendNumber:friendNumber];
    OCTChat *chat = [realmManager getOrCreateChatWithFriend:friend];

    return [realmManager createCallWithChat:chat status:status];
}

- (OCTCall *)getCurrentCallForFriendNumber:(OCTToxFriendNumber)friendNumber
{
    OCTRealmManager *realmManager = [self.dataSource managerGetRealmManager];

    OCTFriend *friend = [realmManager friendWithFriendNumber:friendNumber];
    OCTChat *chat = [realmManager getOrCreateChatWithFriend:friend];

    return [realmManager getCurrentCallForChat:chat];
}

- (void)updateCall:(OCTCall *)call withStatus:(OCTCallStatus)status
{
    OCTRealmManager *realmManager = [self.dataSource managerGetRealmManager];

    [realmManager updateObject:call withBlock:^(OCTCall *callToUpdate) {
        callToUpdate.status = status;
    }];
}

- (void)putOnPause:(BOOL)pause call:(OCTCall *)call
{
    OCTRealmManager *realmManager = [self.dataSource managerGetRealmManager];
    BOOL wasPaused = call.pausedStatus != OCTCallPausedStatusNone;

    if (pause) {
        if (! wasPaused) {
            [self startEnginesAndTimer:NO forCall:call];
        }
    }
    else {
        OCTFriend *friend = [call.chat.friends firstObject];
        self.audioEngine.friendNumber = friend.friendNumber;

        if (call.pausedStatus == OCTCallPausedStatusByUser) {
            [self startEnginesAndTimer:YES forCall:call];
        }
    }

    [realmManager updateObject:call withBlock:^(OCTCall *callToUpdate) {
        if (pause) {
            callToUpdate.pausedStatus |= OCTCallPausedStatusByUser;
            callToUpdate.onHoldStartInterval = callToUpdate.onHoldStartInterval ?: [[NSDate date] timeIntervalSince1970];
        }
        else {
            callToUpdate.pausedStatus &= ~OCTCallPausedStatusByUser;
            callToUpdate.onHoldStartInterval = 0;
        }
    }];
}

- (void)addMessageAndDeleteCall:(OCTCall *)call
{
    OCTRealmManager *realmManager = [self.dataSource managerGetRealmManager];
    [realmManager addMessageCall:call];

    if (! [call isPaused]) {
        [self.timer stopTimer];
    }

    [realmManager deleteObject:call];
}

- (void)updateCall:(OCTCall *)call withState:(OCTToxAVCallState)state pausedStatus:(OCTCallPausedStatus)pausedStatus
{
    BOOL sendingAudio = NO, sendingVideo = NO, acceptingAudio = NO, acceptingVideo = NO;

    if (state & OCTToxAVFriendCallStateAcceptingAudio) {
        acceptingAudio = YES;
    }

    if (state & OCTToxAVFriendCallStateAcceptingVideo) {
        acceptingVideo = YES;
    }

    if (state & OCTToxAVFriendCallStateSendingAudio) {
        sendingAudio = YES;
    }

    if (state & OCTToxAVFriendCallStateSendingVideo) {
        sendingVideo = YES;
    }

    BOOL wasPaused = call.pausedStatus != OCTCallPausedStatusNone;

    OCTRealmManager *realmManager = [self.dataSource managerGetRealmManager];
    [realmManager updateObject:call withBlock:^(OCTCall *callToUpdate) {
        callToUpdate.friendAcceptingAudio = acceptingAudio;
        callToUpdate.friendAcceptingVideo = acceptingVideo;
        callToUpdate.friendSendingAudio = sendingAudio;
        callToUpdate.friendSendingVideo = sendingVideo;
        callToUpdate.pausedStatus = pausedStatus;

        if (! wasPaused && (state == OCTToxAVFriendCallStatePaused)) {
            callToUpdate.onHoldStartInterval = [[NSDate date] timeIntervalSince1970];
        }
    }];
}

- (void)checkForCurrentActiveCallAndPause
{
    if ([self.audioEngine isAudioRunning:nil] || [self.videoEngine isSendingVideo]) {
        OCTCall *call = [self getCurrentCallForFriendNumber:self.audioEngine.friendNumber];
        [self sendCallControl:OCTToxAVCallControlPause toCall:call error:nil];
    }
}

- (BOOL)setVideoBitrate:(int)bitrate forCall:(OCTCall *)call error:(NSError **)error
{
    if (call.chat.friends.count == 1) {

        OCTFriend *friend = call.chat.friends.firstObject;

        return [self.toxAV setVideoBitRate:bitrate force:NO forFriend:friend.friendNumber error:error];
    }
    else {
        // TO DO: Group Calls
        return NO;
    }
}

- (void)startEnginesAndTimer:(BOOL)start forCall:(OCTCall *)call
{
    if (start) {
        OCTFriend *friend = [call.chat.friends firstObject];

        NSError *error;
        if (! [self.audioEngine startAudioFlow:&error]) {
            NSLog(@"Error starting audio flow %@", error);
        }



        if (call.videoIsEnabled) {
            [self.videoEngine startSendingVideo];
        }

        self.audioEngine.friendNumber = friend.friendNumber;
        self.videoEngine.friendNumber = friend.friendNumber;

        [self.timer startTimerForCall:call];
    }
    else {
        [self.audioEngine stopAudioFlow:nil];
        [self.videoEngine stopSendingVideo];
        [self.timer stopTimer];
    }
}

#pragma mark OCTToxAV delegate methods

- (void)toxAV:(OCTToxAV *)toxAV receiveCallAudioEnabled:(BOOL)audio videoEnabled:(BOOL)video friendNumber:(OCTToxFriendNumber)friendNumber
{
    OCTCall *call = [self createCallWithFriendNumber:friendNumber status:OCTCallStatusRinging];

    OCTRealmManager *realmManager = [self.dataSource managerGetRealmManager];
    OCTFriend *friend = [realmManager friendWithFriendNumber:friendNumber];

    [realmManager updateObject:call withBlock:^(OCTCall *callToUpdate) {
        callToUpdate.status = OCTCallStatusRinging;
        callToUpdate.caller = friend;
        callToUpdate.friendSendingAudio = audio;
        callToUpdate.friendAcceptingAudio = audio;
        callToUpdate.friendSendingVideo = video;
        callToUpdate.friendAcceptingVideo = video;
    }];

    if ([self.delegate respondsToSelector:@selector(callSubmanager:receiveCall:audioEnabled:videoEnabled:)]) {
        [self.delegate callSubmanager:self receiveCall:call audioEnabled:audio videoEnabled:video];
    }
}

- (void)toxAV:(OCTToxAV *)toxAV callStateChanged:(OCTToxAVCallState)state friendNumber:(OCTToxFriendNumber)friendNumber
{
    OCTCall *call = [self getCurrentCallForFriendNumber:friendNumber];

    if ((state & OCTToxAVFriendCallStateFinished) || (state & OCTToxAVFriendCallStateError)) {

        [self addMessageAndDeleteCall:call];

        if ((self.audioEngine.friendNumber == friendNumber) && [self.audioEngine isAudioRunning:nil]) {
            [self.audioEngine stopAudioFlow:nil];
        }

        if ((self.videoEngine.friendNumber == friendNumber) && [self.videoEngine isSendingVideo]) {
            [self.videoEngine stopSendingVideo];
        }

        return;
    }

    if (call.status == OCTCallStatusDialing) {
        [self updateCall:call withStatus:OCTCallStatusActive];
        [self startEnginesAndTimer:YES forCall:call];
    }

    OCTCallPausedStatus pauseStatus = call.pausedStatus;

    if ((pauseStatus == OCTCallPausedStatusNone) && (state == OCTToxAVFriendCallStatePaused)) {
        [self startEnginesAndTimer:NO forCall:call];
    }

    if ((pauseStatus == OCTCallPausedStatusByFriend) && (state != OCTToxAVFriendCallStatePaused)) {
        [self startEnginesAndTimer:YES forCall:call];
    }

    if (state == OCTToxAVFriendCallStatePaused) {
        pauseStatus |= OCTCallPausedStatusByFriend;
    }
    else {
        pauseStatus &= ~OCTCallPausedStatusByFriend;
    }

    [self updateCall:call withState:state pausedStatus:pauseStatus];
}

- (void)   toxAV:(OCTToxAV *)toxAV
    receiveAudio:(OCTToxAVPCMData *)pcm
     sampleCount:(OCTToxAVSampleCount)sampleCount
        channels:(OCTToxAVChannels)channels
      sampleRate:(OCTToxAVSampleRate)sampleRate
    friendNumber:(OCTToxFriendNumber)friendNumber
{
    [self.audioEngine provideAudioFrames:pcm sampleCount:sampleCount channels:channels sampleRate:sampleRate fromFriend:friendNumber];
}

- (void)   toxAV:(OCTToxAV *)toxAV bitrateStatusForFriendNumber:(OCTToxFriendNumber)friendNumber
    audioBitRate:(OCTToxAVAudioBitRate)audioBitrate
    videoBitRate:(OCTToxAVVideoBitRate)videoBitrate
{
    // TODO https://github.com/Antidote-for-Tox/objcTox/issues/88
}

- (void)                 toxAV:(OCTToxAV *)toxAV
    receiveVideoFrameWithWidth:(OCTToxAVVideoWidth)width height:(OCTToxAVVideoHeight)height
                        yPlane:(OCTToxAVPlaneData *)yPlane uPlane:(OCTToxAVPlaneData *)uPlane
                        vPlane:(OCTToxAVPlaneData *)vPlane
                       yStride:(OCTToxAVStrideData)yStride uStride:(OCTToxAVStrideData)uStride
                       vStride:(OCTToxAVStrideData)vStride
                  friendNumber:(OCTToxFriendNumber)friendNumber
{
    [self.videoEngine receiveVideoFrameWithWidth:width
                                          height:height
                                          yPlane:yPlane
                                          uPlane:uPlane
                                          vPlane:vPlane
                                         yStride:yStride
                                         uStride:uStride
                                         vStride:vStride
                                    friendNumber:friendNumber];
}

@end