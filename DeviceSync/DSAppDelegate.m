//
//  DSAppDelegate.m
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

#import <QuartzCore/QuartzCore.h>
#import <EventKit/EventKit.h>
#import <AddressBook/AddressBook.h>
#import <AddressBook/ABAddressBookC.h>
#import <PTUSBHub.h>
#import "DSAppDelegate.h"
#import "DSProtocol.h"
#import "EKEvent+NSCoder.h"

@interface DSAppDelegate ()
@property (nonatomic, retain) NSNumber *connectingToDeviceID;
@property (nonatomic, retain) NSNumber *connectedDeviceID;
@property (nonatomic, retain) NSDictionary *connectedDeviceProperties;
@property (nonatomic, retain) NSDictionary *remoteDeviceInfo;
@property (nonatomic, retain) dispatch_queue_t notConnectedQueue;
@property (nonatomic, assign) BOOL notConnectedQueueSuspended;
@property (nonatomic, retain) PTChannel *connectedChannel;
@property (nonatomic, retain) NSDictionary *consoleStatusTextAttributes;
@property (nonatomic, retain) NSMutableDictionary *pings;
@property (nonatomic, retain) EKEventStore *eventStore;
@property (nonatomic, retain) ABAddressBook *addressBook;
@property (nonatomic, retain) EKCalendar *currentCalendar;
@end

@implementation DSAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    self.outputTextView.textContainerInset = NSMakeSize(15.0, 10.0);
    self.consoleStatusTextAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSFont fontWithName:@"menlo" size:11.0], NSFontAttributeName,
                                        [NSColor lightGrayColor], NSForegroundColorAttributeName,
                                        nil];

    BOOL calendarPermissions = [self askForCalendarPermissions];
    BOOL contactsPermissions = [self askForContactsPermissions];

    if (calendarPermissions && contactsPermissions) {
        // use a serial queue that we toggle depending on if we are connected or
        // not. when we are not connected to a peer, the queue is running to handle
        // "connect" tries. when we are connected to a peer, the queue is suspended
        // thus no longer trying to connect.
        self.notConnectedQueue = dispatch_queue_create("DSCalSync.notConnectedQueue", DISPATCH_QUEUE_SERIAL);

        // start listening for device attached/detached notifications
        [self startListeningForDevices];

        // start trying to connect to local IPv4 port (defined in DSCalSyncProtocol.h)
        [self enqueueConnectToLocalIPv4Port];

        // start pinging
        [self ping];

        [self displayMessage:@"WARNING: LOCAL DATA WILL BE OVERWRITTEN ON SYNCHRONIZATION!"];

        [self displayMessage:@"Plug in USB cable and launch 'DeviceSync for iOS' to start calendar synchronization."];
    }
}

- (BOOL)askForCalendarPermissions
{
    self.eventStore = [[EKEventStore alloc] init];

    __block BOOL accessGranted = NO;
    if ([self.eventStore respondsToSelector:@selector(requestAccessToEntityType:completion:)]) {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [self.eventStore requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted, NSError *error) {
            accessGranted = granted;
            dispatch_semaphore_signal(semaphore);
        }];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    } else {
        // os x 10.8 or older
        accessGranted = YES;
    }

    if (!accessGranted) {
        [self displayMessage:@"No permissions to access calendar."];
        [self displayMessage:@"Please enable calendar access in OSX Settings -> Security -> Privacy"];
    } else {
        [self displayMessage:@"Access to calendar granted."];
    }
    return accessGranted;
}

- (BOOL)askForContactsPermissions
{
    self.addressBook = [ABAddressBook sharedAddressBook];
    BOOL accessGranted = NO;

    if (self.addressBook == nil) {
        [self displayMessage:@"No permissions to access contacts."];
        [self displayMessage:@"Please enable contacts access in OSX Settings -> Security -> Privacy."];
    } else {
        accessGranted = YES;
        [self displayMessage:@"Access to contacts granted."];
    }

    return accessGranted;
}

- (void)displayMessage:(NSString *)message
{
    DLog(@">> %@", message);

    BOOL scroll = (NSMaxY(self.outputTextView.visibleRect) == NSMaxY(self.outputTextView.bounds));

    message = [NSString stringWithFormat:@"%@\n\n", message];
    [self.outputTextView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:message attributes:self.consoleStatusTextAttributes]];

    if (scroll) {
        [self.outputTextView scrollRangeToVisible: NSMakeRange(self.outputTextView.string.length, 0)];

    }
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
    DLog(@"received channel=%@, type=%u, tag=%u, payload=%@", channel, type, tag, payload);

    if (type == DSDeviceSyncFrameTypeDeviceInfo) {
        NSDictionary *deviceInfo = [NSDictionary dictionaryWithContentsOfDispatchData:payload.dispatchData];
        [self displayMessage:[NSString stringWithFormat:@"Connected to '%@' running iOS %@. Press 'Sync' button on device to start.", deviceInfo[@"name"], deviceInfo[@"systemVersion"]]];
    } else if (type == DSDeviceSyncFrameTypeCalendar) {
        NSDictionary *calendar = [NSDictionary dictionaryWithContentsOfDispatchData:payload.dispatchData];
        [self didReceiveCalendarWithTitle:calendar[@"title"]];
    } else if (type == DSDeviceSyncFrameTypeEvent) {
        DSDeviceSyncFrame *deviceSyncFrame = (DSDeviceSyncFrame *)payload.data;
        deviceSyncFrame->length = ntohl(deviceSyncFrame->length);
        NSMutableData *data = [NSData dataWithBytes:deviceSyncFrame->data length:deviceSyncFrame->length];
        EKEvent *event = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        [self didReceiveEvent:event];
    } else if (type == DSDeviceSyncFrameTypePong) {
        [self pongWithTag:tag error:nil];
    } else if (type == DSDeviceSyncFrameTypeContact) {
        DSDeviceSyncFrame *deviceSyncFrame = (DSDeviceSyncFrame *)payload.data;
        deviceSyncFrame->length = ntohl(deviceSyncFrame->length);
        NSMutableData *data = [NSData dataWithBytes:deviceSyncFrame->data length:deviceSyncFrame->length];
        [self didReceiveContactData:data first:tag];
    } else {
        DLog(@"unexpected frame recieved");
    }
}

- (void)didReceiveCalendarWithTitle:(NSString *)title
{
    [self displayMessage:[NSString stringWithFormat:@"Importing events for calendar '%@'.", title]];

    NSArray *calendars = [self.eventStore calendarsForEntityType:EKEntityTypeEvent];
    self.currentCalendar = nil;
    NSError *error = nil;

    for (EKCalendar *calendar in calendars) {
        if ([calendar.title isEqualToString:title]) {
            if (![self.eventStore removeCalendar:calendar commit:YES error:&error]) {
                [self displayMessage:[NSString stringWithFormat:@"Error deleting calendar '%@': %@", calendar.title, error.localizedDescription]];
            }
        }
    }

    self.currentCalendar = [EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:self.eventStore];
    self.currentCalendar.title = title;

    for (EKSource *calendarSource in self.eventStore.sources) {
        if (calendarSource.sourceType == EKSourceTypeLocal) {
            self.currentCalendar.source = calendarSource;
            break;
        }
    }

    if (![self.eventStore saveCalendar:self.currentCalendar commit:YES error:&error]) {
        [self displayMessage:[NSString stringWithFormat:@"Error saving calendar '%@': %@", self.currentCalendar.title, error.localizedDescription]];
    }
}

- (void)didReceiveEvent:(EKEvent *)receivedEvent
{
    NSError *error = nil;

    EKEvent *newEvent = [EKEvent eventWithEventStore:self.eventStore];

    newEvent.calendar = self.currentCalendar;
    newEvent.title = receivedEvent.title;
    newEvent.location = receivedEvent.location;
    newEvent.notes = receivedEvent.notes;
    newEvent.allDay = receivedEvent.allDay;
    newEvent.startDate = receivedEvent.startDate;
    newEvent.endDate = receivedEvent.endDate;
    newEvent.availability = receivedEvent.availability;

    if (![self.eventStore saveEvent:newEvent span:EKSpanThisEvent commit:YES error:&error]) {
        [self displayMessage:[NSString stringWithFormat:@"Error saving event: %@", error.localizedDescription]];
    } else {
        NSDateFormatter *dateFormat = [[NSDateFormatter alloc] init];
        [dateFormat setDateStyle:NSDateFormatterShortStyle];
        [self displayMessage:[NSString stringWithFormat:@"Imported '%@' on %@.", receivedEvent.title, [dateFormat stringFromDate:receivedEvent.startDate]]];
    }
}

- (void)didReceiveContactData:(NSMutableData *)contactData first:(uint32_t)first
{
    NSError *error;

    if (first != PTFrameNoTag) {
        // is first contact of import. delete previous contacts.
        ABSearchElement *seachElement = [ABPerson searchElementForProperty:nil label:nil key:nil value:@"" comparison:kABNotEqual];
        NSArray *people = [self.addressBook recordsMatchingSearchElement:seachElement];

        for (NSInteger i = 0; i < people.count; i++)
        {
            ABPerson *person = people[i];
            error = nil;
            if (![self.addressBook removeRecord:person error:&error]) {
                [self displayMessage:[NSString stringWithFormat:@"Error deleting address book entry: %@", error.localizedDescription]];
            }
        }
        if (![self.addressBook save]) {
            [self displayMessage:@"Error saving address book."];
        }
    }

    ABPerson *person = [[ABPerson alloc] initWithVCardRepresentation:contactData];
    error = nil;
    if (![self.addressBook addRecord:person error:&error]) {
        [self displayMessage:[NSString stringWithFormat:@"Error adding address book entry: %@", error.localizedDescription]];
    } else {
        NSString *name;
        if ([person valueForProperty:kABFirstNameProperty] != nil &&
            [person valueForProperty:kABLastNameProperty] != nil) {
            name = [NSString stringWithFormat:@"%@ %@", [person valueForProperty:kABFirstNameProperty], [person valueForProperty:kABLastNameProperty]];
        } else if (!([person valueForProperty:kABFirstNameProperty] == nil)) {
            name = [person valueForProperty:kABFirstNameProperty];
        } else if (!([person valueForProperty:kABLastNameProperty] == nil)) {
            name = [person valueForProperty:kABLastNameProperty];
        }
        [self displayMessage:[NSString stringWithFormat:@"Imported contact '%@'", name]];
    }
    if (![self.addressBook save]) {
        [self displayMessage:@"Error saving address book."];
    }
}

- (void)ioFrameChannel:(PTChannel *)channel didEndWithError:(NSError *)error
{
    if (self.connectedDeviceID && [self.connectedDeviceID isEqualToNumber:channel.userInfo]) {
        [self didDisconnectFromDevice:self.connectedDeviceID];
    }

    if (self.connectedChannel == channel) {
        [self displayMessage:@"Disconnected."];
        self.connectedChannel = nil;
    }
}

#pragma mark - wired device connections

- (void)startListeningForDevices
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:PTUSBDeviceDidAttachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
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

    [nc addObserverForName:PTUSBDeviceDidDetachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
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
