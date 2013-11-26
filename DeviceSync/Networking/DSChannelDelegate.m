//
//  DSChannelDelegate.m
//  DeviceSync
//
// Copyright (c) 2013 Jahn Bertsch
// Copyright (c) 2012 Rasmus Andersson <http://rsms.me/>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#import <EventKit/EventKit.h>
#import "DSAppDelegate.h"
#import "DSChannelDelegate.h"
#import "DSProtocol.h"

@interface DSChannelDelegate ()
@property (nonatomic, retain) NSMutableDictionary *pings;
@end

@implementation DSChannelDelegate

#pragma mark - device info

- (void)sendVersionNumber
{
    if (self.connectedChannel) {
        NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
        NSDictionary *info = @{@"version" : version};

        dispatch_data_t payload = [info createReferencingDispatchData];
        [self.connectedChannel sendFrameOfType:DSDeviceSyncFrameTypeDeviceInfo tag:PTFrameNoTag withPayload:payload callback:^(NSError *error) {
            if (error) {
                [self.appDelegate displayMessage:[NSString stringWithFormat:@"Failed to send device info: %@", error]];
            }
        }];
    }
}

#pragma mark - PTChannelDelegate

- (BOOL)ioFrameChannel:(PTChannel *)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize
{
    if (type != DSDeviceSyncFrameTypeDeviceInfo
        && type != DSDeviceSyncFrameTypePing
        && type != DSDeviceSyncFrameTypePong
        && type != DSDeviceSyncFrameTypeCalendar
        && type != DSDeviceSyncFrameTypeEvent
        && type != DSDeviceSyncFrameTypeContact
        && type != PTFrameTypeEndOfStream) {
        DLog(@"Unexpected frame of type %u", type);
        [channel close];
        return NO;
    } else {
        return YES;
    }
}

- (void)ioFrameChannel:(PTChannel *)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(PTData *)payload
{
    DLog(@"received frame. channel=%@, type=%u, tag=%u, payload=%@", channel, type, tag, payload);

    if (type == DSDeviceSyncFrameTypeDeviceInfo) {
        NSDictionary *deviceInfo = [NSDictionary dictionaryWithContentsOfDispatchData:payload.dispatchData];
        [self.appDelegate displayMessage:[NSString stringWithFormat:@"Connected to '%@' running iOS %@ and 'DeviceSync for iOS' version %@.", deviceInfo[@"name"], deviceInfo[@"systemVersion"], deviceInfo[@"version"]]];
        [self.appDelegate displayMessage:@"Press 'Sync' button on device to start."];
        [self sendVersionNumber];
    } else if (type == DSDeviceSyncFrameTypeCalendar) {
        NSDictionary *calendar = [NSDictionary dictionaryWithContentsOfDispatchData:payload.dispatchData];
        [self.appDelegate didReceiveCalendarWithTitle:calendar[@"title"]];
    } else if (type == DSDeviceSyncFrameTypeEvent) {
        DSDeviceSyncFrame *deviceSyncFrame = (DSDeviceSyncFrame *)payload.data;
        deviceSyncFrame->length = ntohl(deviceSyncFrame->length);
        NSMutableData *data = [NSData dataWithBytes:deviceSyncFrame->data length:deviceSyncFrame->length];
        EKEvent *event = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        [self.appDelegate didReceiveEvent:event];
    } else if (type == DSDeviceSyncFrameTypePong) {
        [self pongWithTag:tag error:nil];
    } else if (type == DSDeviceSyncFrameTypeContact) {
        DSDeviceSyncFrame *deviceSyncFrame = (DSDeviceSyncFrame *)payload.data;
        deviceSyncFrame->length = ntohl(deviceSyncFrame->length);
        NSMutableData *data = [NSData dataWithBytes:deviceSyncFrame->data length:deviceSyncFrame->length];
        [self.appDelegate didReceiveContactData:data first:tag];
    } else {
        DLog(@"unexpected frame recieved");
    }
}

- (void)ioFrameChannel:(PTChannel *)channel didEndWithError:(NSError *)error
{
    if (self.connectedDeviceID && [self.connectedDeviceID isEqualToNumber:channel.userInfo]) {
        [self didDisconnectFromDevice:self.connectedDeviceID];
    }

    if (self.connectedChannel == channel) {
        [self.appDelegate displayMessage:@"Disconnected."];
        self.connectedChannel = nil;
    }
}

#pragma mark - wired device connections

- (void)startListeningForDevices
{
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

    [notificationCenter addObserverForName:PTUSBDeviceDidAttachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
        NSNumber *deviceID = [note.userInfo objectForKey:@"DeviceID"];
        DLog(@"PTUSBDeviceDidAttachNotification: %@", deviceID);

        dispatch_async(self.notConnectedQueue, ^{
            if (!self.connectingToDeviceID || ![deviceID isEqualToNumber:self.connectingToDeviceID]) {
                [self disconnectFromCurrentChannel];
                self.connectingToDeviceID = deviceID;
                self.connectedDeviceProperties = [note.userInfo objectForKey:@"Properties"];
                [self enqueueConnectToUSBDevice];
            }
        });
    }];

    [notificationCenter addObserverForName:PTUSBDeviceDidDetachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
        NSNumber *deviceID = [note.userInfo objectForKey:@"DeviceID"];
        //DLog(@"PTUSBDeviceDidDetachNotification: %@", note.userInfo);
        DLog(@"PTUSBDeviceDidDetachNotification: %@", deviceID);

        if ([self.connectingToDeviceID isEqualToNumber:deviceID]) {
            self.connectedDeviceProperties = nil;
            self.connectingToDeviceID = nil;

            if (self.connectedChannel) {
                [self.connectedChannel close];
            }
        }
    }];
}

- (void)didDisconnectFromDevice:(NSNumber *)deviceID
{
    DLog(@"Disconnected from device");

    if ([self.connectedDeviceID isEqualToNumber:deviceID]) {
        [self willChangeValueForKey:@"connectedDeviceID"];
        self.connectedDeviceID = nil;
        [self didChangeValueForKey:@"connectedDeviceID"];
    }
}

- (void)disconnectFromCurrentChannel
{
    if (self.connectedDeviceID && self.connectedChannel) {
        [self.connectedChannel close];
        self.connectedChannel = nil;
    }
}

- (void)enqueueConnectToLocalIPv4Port
{
    dispatch_async(self.notConnectedQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectToLocalIPv4Port];
        });
    });
}

- (void)connectToLocalIPv4Port
{
    PTChannel *channel = [PTChannel channelWithDelegate:self];

    channel.userInfo = [NSString stringWithFormat:@"127.0.0.1:%d", DSProtocolIPv4PortNumber];
    [channel connectToPort:DSProtocolIPv4PortNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error, PTAddress *address) {
        if (error) {
            if (error.domain == NSPOSIXErrorDomain && (error.code == ECONNREFUSED || error.code == ETIMEDOUT)) {
                // this is an expected state
            } else {
                NSLog(@"Failed to connect to 127.0.0.1:%d: %@", DSProtocolIPv4PortNumber, error);
            }
        } else {
            [self disconnectFromCurrentChannel];
            self.connectedChannel = channel;
            channel.userInfo = address;
            DLog(@"Connected to %@", address);
        }

        [self performSelector:@selector(enqueueConnectToLocalIPv4Port) withObject:nil afterDelay:DSAppReconnectDelay];
    }];
}

- (void)enqueueConnectToUSBDevice
{
    dispatch_async(self.notConnectedQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectToUSBDevice];
        });
    });
}

- (void)connectToUSBDevice
{
    PTChannel *channel = [PTChannel channelWithDelegate:self];

    channel.userInfo = self.connectingToDeviceID;
    channel.delegate = self;

    [channel connectToPort:DSProtocolIPv4PortNumber overUSBHub:PTUSBHub.sharedHub deviceID:self.connectingToDeviceID callback:^(NSError *error) {
        if (error) {
            if (error.domain == PTUSBHubErrorDomain && error.code == PTUSBHubErrorConnectionRefused) {
                DLog(@"Failed to connect to device #%@: %@", channel.userInfo, error);
            } else {
                DLog(@"Failed to connect to device #%@: %@", channel.userInfo, error);
            }

            if (channel.userInfo == self.connectingToDeviceID) {
                [self performSelector:@selector(enqueueConnectToUSBDevice) withObject:nil afterDelay:DSAppReconnectDelay];
            }
        } else {
            self.connectedDeviceID = self.connectingToDeviceID;
            self.connectedChannel = channel;
        }
    }];
}

#pragma mark - ping

- (void)pongWithTag:(uint32_t)tagno error:(NSError *)error
{
    NSNumber *tag = [NSNumber numberWithUnsignedInt:tagno];
    NSMutableDictionary *pingInfo = [self.pings objectForKey:tag];

    if (pingInfo) {
        NSDate *now = [NSDate date];
        [pingInfo setObject:now forKey:@"date ended"];
        [self.pings removeObjectForKey:tag];
        DLog(@"Ping total roundtrip time: %.3f ms", [now timeIntervalSinceDate:[pingInfo objectForKey:@"date created"]] * 1000.0);
    }
}

- (void)ping
{
    if (self.connectedChannel) {
        if (!self.pings) {
            self.pings = [NSMutableDictionary dictionary];
        }

        uint32_t tagno = [self.connectedChannel.protocol newTag];
        NSNumber *tag = [NSNumber numberWithUnsignedInt:tagno];
        NSMutableDictionary *pingInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:[NSDate date], @"date created", nil];
        [self.pings setObject:pingInfo forKey:tag];
        [self.connectedChannel sendFrameOfType:DSDeviceSyncFrameTypePing tag:tagno withPayload:nil callback:^(NSError *error) {
            [self performSelector:@selector(ping) withObject:nil afterDelay:1.0];
            [pingInfo setObject:[NSDate date] forKey:@"date sent"];

            if (error) {
                [self.pings removeObjectForKey:tag];
            }
        }];
    } else {
        [self performSelector:@selector(ping) withObject:nil afterDelay:1.0];
    }
}

#pragma mark - custom setter

- (void)setConnectedChannel:(PTChannel *)aConnectedChannel
{
    _connectedChannel = aConnectedChannel;

    // toggle the notConnectedQueue depending on if we are connected or not
    if (!_connectedChannel && self.notConnectedQueueSuspended) {
        dispatch_resume(self.notConnectedQueue);
        self.notConnectedQueueSuspended = NO;
    } else if (_connectedChannel && !self.notConnectedQueueSuspended) {
        dispatch_suspend(self.notConnectedQueue);
        self.notConnectedQueueSuspended = YES;
    }

    if (!_connectedChannel && self.connectingToDeviceID) {
        [self enqueueConnectToUSBDevice];
    }
}


@end
