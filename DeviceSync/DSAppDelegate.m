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
#import "DSChannelDelegate.h"
#import "EKEvent+NSCoder.h"

@interface DSAppDelegate ()
@property (nonatomic, retain) DSChannelDelegate *channelDelegate;
@property (nonatomic, retain) NSDictionary *consoleStatusTextAttributes;
@property (nonatomic, retain) EKEventStore *eventStore;
@property (nonatomic, retain) ABAddressBook *addressBook;
@property (nonatomic, retain) EKCalendar *currentCalendar;
@end

@implementation DSAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    self.channelDelegate = [[DSChannelDelegate alloc] init];
    self.channelDelegate.appDelegate = self;

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
        self.channelDelegate.notConnectedQueue = dispatch_queue_create("DSCalSync.notConnectedQueue", DISPATCH_QUEUE_SERIAL);

        // start listening for device attached/detached notifications
        [self.channelDelegate startListeningForDevices];

        // start trying to connect to local IPv4 port (defined in DSCalSyncProtocol.h)
        [self.channelDelegate enqueueConnectToLocalIPv4Port];

        // start pinging
        [self.channelDelegate ping];

        [self displayMessage:@"WARNING: LOCAL DATA WILL BE OVERWRITTEN ON SYNCHRONIZATION!"];

        [self displayMessage:@"Plug in USB cable and launch 'DeviceSync for iOS' to start synchronization."];
    }
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

#pragma mark - permissions

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

#pragma mark - handle received data

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

@end
