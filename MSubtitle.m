//
//  Movist
//
//  Copyright 2006 ~ 2008 Yong-Hoe Kim. All rights reserved.
//      Yong-Hoe Kim  <cocoable@gmail.com>
//
//  This file is part of Movist.
//
//  Movist is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  Movist is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "MSubtitle.h"
#import "MSubtitleItem.h"

@implementation MSubtitle

+ (NSArray*)fileExtensions
{
    static NSArray* exts = nil;
    if (exts == nil) {
        exts = [[NSApp supportedFileExtensionsWithPrefix:@"Subtitle-"] retain];
    }
    return exts;  // don't send autorelease. it should be alive forever.
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

- (id)initWithURL:(NSURL*)url type:(NSString*)type
{
    //TRACE(@"%s %@", __PRETTY_FUNCTION__, type);
    if (self = [super init]) {
        _url = [url retain];
        _type = [type retain];
        _name = [NSLocalizedString(@"Unnamed Subtitle", nil) retain];
        _enabled = TRUE;
        _items = [[NSMutableArray alloc] init];
        _indexCache = -1;     // for initial comparison

        _renderConditionLock = [[NSConditionLock alloc] initWithCondition:0];
        _forwardRenderInterval = 30.0;
        _backwardRenderInterval = 30.0;
        _lastPlayTime = 0;
        _seekIndex = 0;
        _playIndex = 0;
        [self initRenderInfo];
    }
    return self;
}

- (void)dealloc
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
    [self quitRenderThread];
    [_renderConditionLock release];

    [_items release];
    [_name release];
    [_type release];
    [super dealloc];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

- (NSURL*)url { return _url; }
- (NSString*)type { return _type; }
- (NSString*)name { return _name; }
- (void)setName:(NSString*)name { [name retain], [_name release], _name = name; }

- (BOOL)isEmpty { return ([_items count] == 0); }
- (float)beginTime { return [self isEmpty] ? 0 : [[_items objectAtIndex:0] beginTime]; }
- (float)endTime   { return [self isEmpty] ? 0 : [[_items lastObject] endTime]; }

- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)enabled
{
    if (_enabled != enabled) {
        _enabled = enabled;
        _indexCache = -1;

        [[NSNotificationCenter defaultCenter]
         postNotificationName:MSubtitleEnableChangeNotification object:self];
    }
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark loading

- (void)addString:(NSMutableAttributedString*)string time:(float)time
{
    int index;
    MSubtitleItem* item;
    for (index = [_items count] - 1; 0 <= index; index--) {
        item = [_items objectAtIndex:index];
        if ([item beginTime] < time) {
            if ([item endTime] < 0.0 || time < [item endTime]) {
                [item setEndTime:time];
            }
            break;
        }
        else if ([item beginTime] == time) {
            [item appendString:string];
            return;
        }
    }
    if (0 < [string length]) {
        item = [MSubtitleItem itemWithString:string beginTime:time endTime:-1.0];
        [_items insertObject:item atIndex:index + 1];
    }
}

- (void)addString:(NSMutableAttributedString*)string
        beginTime:(float)beginTime endTime:(float)endTime
{
    #define NEW_LINE    [[[NSAttributedString alloc] initWithString:@"\n"] autorelease]

    int index;
    MSubtitleItem* item;
    for (index = [_items count] - 1; 0 <= index; index--) {
        item = [_items objectAtIndex:index];
        if ([item beginTime] <= beginTime) {
            break;
        }
    }
    if (index < 0) {
        if (0 < [_items count]) {
            item = [_items objectAtIndex:0];
            if ([item beginTime] < endTime) {
                [item appendString:NEW_LINE];
                [item appendString:string];
                endTime = [item beginTime];
            }
        }
        item = [MSubtitleItem itemWithString:string beginTime:beginTime endTime:endTime];
        [_items insertObject:item atIndex:0];
    }
    else if ([item endTime] <= beginTime) {
        item = [MSubtitleItem itemWithString:string beginTime:beginTime endTime:endTime];
        [_items insertObject:item atIndex:index + 1];
    }
    else if ([item beginTime] == beginTime) {
        if (endTime == [item endTime]) {
            [item appendString:NEW_LINE];
            [item appendString:string];
        }
        else if (endTime < [item endTime]) {
            [item setBeginTime:endTime];

            item = [MSubtitleItem itemWithString:[[item string] copy]
                                       beginTime:beginTime endTime:endTime];
            [item appendString:NEW_LINE];
            [item appendString:string];
            [_items insertObject:item atIndex:index];
        }
        else {
            [item appendString:NEW_LINE];
            [item appendString:string];
            [self addString:string beginTime:[item endTime] endTime:endTime];
        }
    }
    else if ([item beginTime] < beginTime) {
        float bt = [item beginTime];
        [item setBeginTime:beginTime];
        item = [MSubtitleItem itemWithString:[[item string] copy]
                                   beginTime:bt endTime:beginTime];
        [_items insertObject:item atIndex:index];
        [self addString:string beginTime:beginTime endTime:endTime];
    }
}

- (void)addImage:(NSImage*)image beginTime:(float)beginTime endTime:(float)endTime
{
    [_items addObject:[MSubtitleItem itemWithImage:image
                                         beginTime:beginTime endTime:endTime]];
}

- (void)checkEndTimes
{
    MSubtitleItem* item;
    int i, count = [_items count];
    for (i = 0; i < count; i++) {
        item = [_items objectAtIndex:i];
        if ([item endTime] < 0.0) {
            if (i < count - 1) {
                [item setEndTime:[[_items objectAtIndex:i + 1] beginTime]];
            }
            else {
                [item setEndTime:[item beginTime] + 5.0];
            }
        }
    }
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark seeking

- (MSubtitleItem*)itemAtTime:(float)time direction:(int)direction
{
    int index = [self indexAtTime:time direction:direction];
    return (0 <= index) ? [_items objectAtIndex:index] : nil;
}

- (int)indexAtTime:(float)time direction:(int)direction
{
    int index = (_indexCache < 0) ? 0 : _indexCache;
    if (index < 0) {
        //TRACE(@"%s(\"%@\")[%.03f]: <none>", __PRETTY_FUNCTION__, _name, time);
        return _indexCache = (0 < direction) ? 0 : -1;
    }
    if ([_items count] <= index) {
        //TRACE(@"%s(\"%@\")[%.03f]: <none>", __PRETTY_FUNCTION__, _name, time);
        return _indexCache = (direction < 0) ? [_items count] - 1 : -1;
    }

    MSubtitleItem* si = (MSubtitleItem*)[_items objectAtIndex:index];
    if (time < [si beginTime]) {
        while (0 < --index) {         // find in previous items
            si = [_items objectAtIndex:index];
            if ([si beginTime] <= time) {
                break;
            }
        }
        if (index < 0) {
            //TRACE(@"%s(\"%@\")[%.03f]: <none>", __PRETTY_FUNCTION__, _name, time);
            return _indexCache = (0 < direction) ? 0 : -1;
        }
        else if ([si endTime] <= time) {
            //TRACE(@"%s(\"%@\")[%.03f]: <none>", __PRETTY_FUNCTION__, _name, time);
            return _indexCache = (0 < direction) ? (index + 1) : (direction < 0) ? index : -1;
        }
    }
    else if ([si endTime] < time) {
        int maxIndex = [_items count] - 1;
        while (++index < maxIndex) {  // find in next items
            si = [_items objectAtIndex:index];
            if (time < [si endTime]) {
                break;
            }
        }
        if (maxIndex < index) {
            //TRACE(@"%s(\"%@\")[%.03f]: <none>", __PRETTY_FUNCTION__, _name, time);
            return _indexCache = (direction < 0) ? maxIndex : -1;
        }
        else if (time < [si beginTime]) {
            //TRACE(@"%s(\"%@\")[%.03f]: <none>", __PRETTY_FUNCTION__, _name, time);
            return _indexCache = (direction < 0) ? (index - 1) : (0 < direction)  ? index : -1;
        }
    }
    //TRACE(@"%s(\"%@\")[%.03f:%d=>%d]:\"%@\"", __PRETTY_FUNCTION__, _name,
    //      time, _indexCache, index, [[si string] string]);
    return _indexCache = index;
}

- (float)prevSubtitleTime:(float)time
{
    int index = [self indexAtTime:time direction:-1];  // backward
    if (index < 0) {
        index = 0;
    }
    return [[_items objectAtIndex:index] beginTime] + 0.1;
}

- (float)nextSubtitleTime:(float)time
{
    int index = [self indexAtTime:time direction:+1];   // forward
    if (index < 0) {
        index = [_items count] - 1;
    }
    return [[_items objectAtIndex:index] beginTime] + 0.1;
}

@end
