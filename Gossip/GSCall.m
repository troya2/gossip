//
//  GSCall.m
//  Gossip
//
//  Created by Chakrit Wichian on 7/9/12.
//

#import "GSCall.h"
#import "GSCall+Private.h"
#import "GSAccount+Private.h"
#import "GSDispatch.h"
#import "GSIncomingCall.h"
#import "GSOutgoingCall.h"
#import "GSRingback.h"
#import "GSUserAgent+Private.h"
#import "PJSIP.h"
#import "Util.h"


@implementation GSCall {
    pjsua_call_id _callId;
    float _volume;
    float _micVolume;
    float _volumeScaleTx;
    float _volumeScaleRx;
}

+ (id)outgoingCallToUri:(NSString *)remoteUri fromAccount:(GSAccount *)account {
    GSOutgoingCall *call = [GSOutgoingCall alloc];
    call = [call initWithRemoteUri:remoteUri fromAccount:account];
    
    return call;
}

+ (id)incomingCallWithId:(int)callId toAccount:(GSAccount *)account {
    GSIncomingCall *call = [GSIncomingCall alloc];
    call = [call initWithCallId:callId toAccount:account];

    return call;
}


- (id)init {
    return [self initWithAccount:nil];
}

- (id)initWithAccount:(GSAccount *)account {
    if (self = [super init]) {
        GSAccountConfiguration *config = account.configuration;

        _account = account;
        _status = GSCallStatusReady;
        _callId = PJSUA_INVALID_ID;
        _mediaState = GSCallMediaStateNone;
        
        _ringback = nil;
        if (config.enableRingback) {
            _ringback = [GSRingback ringbackWithSoundNamed:config.ringbackFilename];
        }

        _volumeScaleTx = [GSUserAgent sharedAgent].configuration.volumeScaleTx;
        _volumeScaleRx = [GSUserAgent sharedAgent].configuration.volumeScaleRx;
        _volume = 1.0 / _volumeScaleRx;
        _micVolume = 1.0 / _volumeScaleTx;

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(callStateDidChange:)
                       name:GSSIPCallStateDidChangeNotification
                     object:[GSDispatch class]];
        [center addObserver:self
                   selector:@selector(callMediaStateDidChange:)
                       name:GSSIPCallMediaStateDidChangeNotification
                     object:[GSDispatch class]];
    }
    return self;
}

- (void)dealloc {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self];

    if (_ringback && _ringback.isPlaying) {
        [_ringback stop];
        _ringback = nil;
    }

    if (_callId != PJSUA_INVALID_ID && pjsua_call_is_active(_callId)) {
        GSLogIfFails(pjsua_call_hangup(_callId, 0, NULL, NULL));
    }
    
    _account = nil;
    _callId = PJSUA_INVALID_ID;
    _ringback = nil;
}


- (int)callId {
    return _callId;
}

- (void)setCallId:(int)callId {
    [self willChangeValueForKey:@"callId"];
    _callId = callId;
    [self didChangeValueForKey:@"callId"];
}

- (void)setStatus:(GSCallStatus)status {
    [self willChangeValueForKey:@"status"];
    _status = status;
    [self didChangeValueForKey:@"status"];
}

- (void)setMediaState:(GSCallMediaState)mediaState {
    [self willChangeValueForKey:@"mediaState"];
    _mediaState = mediaState;
    [self didChangeValueForKey:@"mediaState"];
}


- (float)volume {
    return _volume;
}

- (BOOL)setVolume:(float)volume {
    [self willChangeValueForKey:@"volume"];
    BOOL result = [self adjustVolume:volume mic:_micVolume];
    [self didChangeValueForKey:@"volume"];
    
    return result;
}

- (float)micVolume {
    return _micVolume;
}

- (BOOL)setMicVolume:(float)micVolume {
    [self willChangeValueForKey:@"micVolume"];
    BOOL result = [self adjustVolume:_volume mic:micVolume];
    [self didChangeValueForKey:@"micVolume"];
    
    return result;
}


- (BOOL)begin {
    // for child overrides only
    return NO;
}

- (BOOL)end {
    // for child overrides only
    return NO;
}


- (BOOL)sendDTMFDigits:(NSString *)digits {
    pj_str_t pjDigits = [GSPJUtil PJStringWithString:digits];
    pjsua_call_dial_dtmf(_callId, &pjDigits);
}

- (BOOL)playWavFileDuringCall:(NSString *)filePath {
    pjsua_player_id player_id;
    pj_str_t pjFilePath = [GSPJUtil PJStringWithString:filePath];
    
    pj_status_t status = pjsua_player_create(&pjFilePath, 0, &player_id);
    
    if (status == PJ_SUCCESS) {
        pjmedia_port *player_media_port;
        status = pjsua_player_get_port(player_id, &player_media_port);

        if (status == PJ_SUCCESS) {
            pj_pool_t *pool = pjsua_pool_create("my_eof_data", 512, 512);
            struct pjsua_player_eof_data *eof_data = PJ_POOL_ZALLOC_T(pool, struct pjsua_player_eof_data);
            eof_data->pool = pool;
            eof_data->player_id = player_id;
            
            pjmedia_wav_player_set_eof_cb(player_media_port, eof_data, &on_pjsua_wav_file_end_callback);
            
            status = pjsua_conf_connect(pjsua_player_get_conf_port(player_id), 0);

        }
    }

    return status == PJ_SUCCESS;
}

struct pjsua_player_eof_data
{
    pj_pool_t          *pool;
    pjsua_player_id player_id;
};

static PJ_DEF(pj_status_t) on_pjsua_wav_file_end_callback(pjmedia_port* media_port, void* args)
{
    pj_status_t status;
    
    struct pjsua_player_eof_data *eof_data = (struct pjsua_player_eof_data *)args;
    
    status = pjsua_player_destroy(eof_data->player_id);
    
    if (status == PJ_SUCCESS)
    {
        return -1;// Here it is important to return value other than PJ_SUCCESS
                  // http://www.pjsip.org/pjmedia/docs/html/group__PJMEDIA__FILE__PLAY.htm#ga278007b67f63eaec515ae7163e5ec30b
    }
    
    return PJ_SUCCESS;
}

- (BOOL)hold {
    pjsua_call_set_hold(_callId, nil);
}

- (BOOL)releaseHold {
    pjsua_call_reinvite(_callId, PJSUA_CALL_UNHOLD,nil);
}

- (BOOL)updateContact {
    pjsua_call_reinvite(_callId, PJSUA_CALL_UPDATE_CONTACT, nil);
}

- (BOOL)disconnectAudioForGSMCall
{
    pj_status_t status = pjsua_set_no_snd_dev();
    
    return (status == PJ_SUCCESS)?YES:NO;
}

- (BOOL)reconnectAudioAfterGSMCall
{
    int capture_dev;
    int playback_dev;
    
    pjsua_get_snd_dev( &capture_dev, &playback_dev);
    
    pj_status_t status = pjsua_set_snd_dev(capture_dev, playback_dev);
    
    return (status == PJ_SUCCESS)?YES:NO;
}


- (void)startRingback {
    if (!_ringback || _ringback.isPlaying)
        return;

    [_ringback play];
}

- (void)stopRingback {
    if (!(_ringback && _ringback.isPlaying))
        return;

    [_ringback stop];
}

- (NSString *)remoteInfo {
    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);
    
    return [[GSPJUtil stringWithPJString:&callInfo.remote_info] copy];
}

- (NSString *)remoteContact {
    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);
    
    return [[GSPJUtil stringWithPJString:&callInfo.remote_contact] copy];
}

- (void)callStateDidChange:(NSNotification *)notif {
    pjsua_call_id callId = GSNotifGetInt(notif, GSSIPCallIdKey);
    pjsua_acc_id accountId = GSNotifGetInt(notif, GSSIPAccountIdKey);
    if (callId != _callId || accountId != _account.accountId)
        return;
    
    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);
    
    GSCallStatus callStatus;
    switch (callInfo.state) {
        case PJSIP_INV_STATE_NULL: {
            callStatus = GSCallStatusReady;
        } break;
            
        case PJSIP_INV_STATE_CALLING:
        case PJSIP_INV_STATE_INCOMING: {
            callStatus = GSCallStatusCalling;
        } break;
            
        case PJSIP_INV_STATE_EARLY:
        case PJSIP_INV_STATE_CONNECTING: {
            [self startRingback];
            callStatus = GSCallStatusConnecting;
        } break;
            
        case PJSIP_INV_STATE_CONFIRMED: {
            [self stopRingback];
            callStatus = GSCallStatusConnected;
        } break;
            
        case PJSIP_INV_STATE_DISCONNECTED: {
            [self stopRingback];
            callStatus = GSCallStatusDisconnected;
        } break;
    }
    
    __block id self_ = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [self_ setStatus:callStatus]; });
}

- (void)callMediaStateDidChange:(NSNotification *)notif {
    pjsua_call_id callId = GSNotifGetInt(notif, GSSIPCallIdKey);
    if (callId != _callId)
        return;

    pjsua_call_info callInfo;
    GSReturnIfFails(pjsua_call_get_info(_callId, &callInfo));
    
    GSCallMediaState mediaState = GSCallMediaStateNone;
    switch (callInfo.media_status) {
        case PJSUA_CALL_MEDIA_NONE:
            mediaState = GSCallMediaStateNone;
            break;
            
        case PJSUA_CALL_MEDIA_ACTIVE:
            mediaState = GSCallMediaStateActive;
            break;
            
        case PJSUA_CALL_MEDIA_LOCAL_HOLD:
            mediaState = GSCallMediaStateLocalHold;
            break;
            
        case PJSUA_CALL_MEDIA_REMOTE_HOLD:
            mediaState = GSCallMediaStateRemoteHold;
            break;
            
        case PJSUA_CALL_MEDIA_ERROR:
            mediaState = GSCallMediaStateError;
            break;
    }

    __block id self_ = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [self_ setMediaState:mediaState]; });

    if (callInfo.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        GSReturnIfFails(pjsua_conf_connect(callInfo.conf_slot, 0));
        GSReturnIfFails(pjsua_conf_connect(0, callInfo.conf_slot));

        [self adjustVolume:_volume mic:_micVolume];
    }
}


- (BOOL)adjustVolume:(float)volume mic:(float)micVolume {
    GSAssert(0.0 <= volume && volume <= 1.0, @"Volume value must be between 0.0 and 1.0");
    GSAssert(0.0 <= micVolume && micVolume <= 1.0, @"Mic Volume must be between 0.0 and 1.0");
    
    _volume = volume;
    _micVolume = micVolume;
    if (_callId == PJSUA_INVALID_ID)
        return YES;
    
    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);
    if (callInfo.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        
        // scale volume as per configured volume scale
        volume *= _volumeScaleRx;
        micVolume *= _volumeScaleTx;
        pjsua_conf_port_id callPort = pjsua_call_get_conf_port(_callId);
        GSReturnNoIfFails(pjsua_conf_adjust_rx_level(callPort, volume));
        GSReturnNoIfFails(pjsua_conf_adjust_tx_level(callPort, micVolume));
    }
    
    // send volume change notification
    NSDictionary *info = nil;
    info = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithFloat:volume], GSVolumeKey,
            [NSNumber numberWithFloat:micVolume], GSMicVolumeKey, nil];
    
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center postNotificationName:GSVolumeDidChangeNotification
                          object:self
                        userInfo:info];
    
    return YES;
}

- (void)send180Ringing {
    GSReturnNoIfFails(pjsua_call_answer(self.callId, 180, NULL, NULL));
}

@end
