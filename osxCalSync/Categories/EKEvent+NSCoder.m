//
//  EKEvent+NSCoder.h
//  osxCalSync
//
// Copyright (c) 2013 Jahn Bertsch
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

#import "EKEvent+NSCoder.h"

@implementation EKEvent (iCal)

- (id)initWithCoder:(NSCoder *)decoder
{
    self = [super init];

    if (!self) {
        return nil;
    }

    self.title = [decoder decodeObjectForKey:@"title"];
    self.location = [decoder decodeObjectForKey:@"location"];
    self.notes = [decoder decodeObjectForKey:@"notes"];
    self.allDay = [decoder decodeBoolForKey:@"allDay"];
    self.startDate = [decoder decodeObjectForKey:@"startDate"];
    self.endDate = [decoder decodeObjectForKey:@"endDate"];
    self.availability = [decoder decodeIntegerForKey:@"availability"];
    // self.recurrenceRules = [decoder decodeObjectForKey:@"recurrenceRules"];
    // self.alarms = [decoder decodeObjectForKey:@"alarms"];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)encoder
{
    [encoder encodeObject:self.title forKey:@"title"];
    [encoder encodeObject:self.location forKey:@"location"];
    [encoder encodeObject:self.notes forKey:@"notes"];
    [encoder encodeBool:self.allDay forKey:@"allDay"];
    [encoder encodeObject:self.startDate forKey:@"startDate"];
    [encoder encodeObject:self.endDate forKey:@"endDate"];
    [encoder encodeInteger:self.availability forKey:@"availability"];
    // [encoder encodeObject:self.recurrenceRules forKey:@"recurrenceRules"];
    // [encoder encodeObject:self.alarms forKey:@"alarms"];
}

@end
