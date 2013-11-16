//
//  DSProtocol.h
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

#ifndef DeviceSync_DSProtocol_h
#define DeviceSync_DSProtocol_h

#import <Foundation/Foundation.h>
#include <stdint.h>

// use tcp port 51515 which should be free according to
// https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml
// at time of writing
static const int DSProtocolIPv4PortNumber = 51515;

enum {
    DSDeviceSyncFrameTypeDeviceInfo = 100,
    DSDeviceSyncFrameTypePing = 101,
    DSDeviceSyncFrameTypePong = 102,
    DSDeviceSyncFrameTypeCalendar = 103,
    DSDeviceSyncFrameTypeEvent = 104,
};

typedef struct _DSDeviceSyncFrame {
    uint32_t length;
    uint8_t data[0];
} DSDeviceSyncFrame;

#endif /* ifndef DeviceSync_DSProtocol_h */
