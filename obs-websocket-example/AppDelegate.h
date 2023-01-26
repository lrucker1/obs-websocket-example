//
//  AppDelegate.h
//  obs-websocket-example
//
//  Created by Lee Ann Rucker on 1/24/23.
//

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource>
{
    dispatch_queue_t socketQueue;
}


@end

