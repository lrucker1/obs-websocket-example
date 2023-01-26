//
//  AppDelegate.m
//  obs-websocket-example
//
//  Created by Lee Ann Rucker on 1/24/23.
//

#import "AppDelegate.h"
#include "easywsclient.hpp"
#include <iostream>
#include <string>
#include <memory>
#include <mutex>
#include <deque>
#include <thread>
#include <chrono>
#include <atomic>

// a simple, thread-safe queue with (mostly) non-blocking reads and writes
namespace non_blocking {
template <class T>
class Queue {
    mutable std::mutex m;
    std::deque<T> data;
public:
    void push(T const &input) {
        std::lock_guard<std::mutex> L(m);
        data.push_back(input);
    }

    bool pop(T &output) {
        std::lock_guard<std::mutex> L(m);
        if (data.empty())
            return false;
        output = data.front();
        data.pop_front();
        return true;
    }
};
}
/*
 Hello (OpCode 0)
 Identify (OpCode 1)
 Identified (OpCode 2)
 Reidentify (OpCode 3)
 Event (OpCode 5)
 Request (OpCode 6)
 RequestResponse (OpCode 7)
 RequestBatch (OpCode 8)
 RequestBatchResponse (OpCode 9)
 */
typedef enum  {
    Op_Hello = 0,
    Op_Identify = 1,
    Op_Identified = 2,
    Op_Reidentify = 3,
    Op_Event = 5,
    Op_Request = 6,
    Op_RequestResponse = 7,
    Op_RequestBatch = 8,
    Op_RequestBatchResponse = 9
} OpCode;


@interface AppDelegate () {
    non_blocking::Queue<std::string> outgoing;
    non_blocking::Queue<std::string> incoming;
}

@property (strong) IBOutlet NSWindow *window;
@property (strong) IBOutlet NSTextView *console;
@property BOOL connected;
@property NSString *command;
@property BOOL running;
@property NSArray *obsInputs;
@property IBOutlet NSTableView *tableView;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
    socketQueue = dispatch_queue_create("socketQueue", NULL);
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}


- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (NSString *)convertToJson:(id)dictionaryOrArrayToOutput {
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionaryOrArrayToOutput
                                                       options:NSJSONWritingPrettyPrinted // Pass 0 if you don't care about the readability of the generated string
                                                         error:&error];

    if (! jsonData) {
        NSLog(@"Got an error: %@", error);
        return nil;
    } else {
        return[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
}

- (NSString *)jsonHelloReply {
    NSDictionary *dict = @{@"op":@(1),
                           @"d":@{@"rpcVersion":@(1),
                                  @"eventSubscriptions":@(31)}};
    return [self convertToJson:dict];
}

- (NSString *)requestID {
    // TODO: Should be different so we can tell which response goes with which request.
    return @"f819dcf0-89cc-11eb-8f0e-382c4ac93b9c";
}

- (NSString *)jsonGetSourceActive:(NSString *)sourceName {
    // {   "op": 6,   "d": {     "requestType": "GetSourceActive",     "requestId": "f819dcf0-89cc-11eb-8f0e-382c4ac93b9c",     "requestData": {       "sourceName": "Video Capture Device 2"     }   } }
    NSDictionary *dict = @{@"op":@(6),
                           @"d": @{@"requestType": @"GetSourceActive",
                                   @"requestId": sourceName,
                                   @"requestData": @{@"sourceName": sourceName}}};
    return [self convertToJson:dict];
}

- (NSString *)jsonGetInputList {
   // {   "op": 6,   "d": {     "requestType": "GetInputList",     "requestId": "f819dcf0-89cc-11eb-8f0e-382c4ac93b9c",     "requestData": {     }   } }
    NSDictionary *dict = @{@"op":@(6),
                           @"d": @{@"requestType": @"GetInputList",
                                   @"requestId": self.requestID,
                                   @"requestData": @{}}};
    return [self convertToJson:dict];
}

/*
 {
   "requestType": string,
   "requestId": string,
   "requestStatus": object,
   "responseData": object(optional)
 }
 The requestType and requestId are simply mirrors of what was sent by the client.
 requestStatus object:

 {
   "result": bool,
   "code": number,
   "comment": string(optional)
 }
 */
/*
 [{"inputKind":"coreaudio_input_capture","inputName":"Audio Input Capture","unversionedInputKind":"coreaudio_input_capture"},{"inputKind":"av_capture_input_v2","inputName":"Video Capture Device","unversionedInputKind":"av_capture_input"},{"inputKind":"av_capture_input_v2","inputName":"Video Capture Device 2","unversionedInputKind":"av_capture_input"},{"inputKind":"screen_capture","inputName":"macOS Screen Capture","unversionedInputKind":"screen_capture"},{"inputKind":"coreaudio_input_capture","inputName":"Mic/Aux","unversionedInputKind":"coreaudio_input_capture"}]}},"op":7}

 */
- (void)handleInputList:(NSDictionary *)dict {
    // Preview, Program, Source
    NSMutableArray *array = [NSMutableArray array];
    NSArray *inputs = dict[@"inputs"];
    for (NSDictionary *input in inputs) {
        NSString *name = input[@"inputName"];
        if (name) {
            [array addObject:[NSMutableDictionary dictionaryWithDictionary:@{@"Source":name}]];
        }
    }
    self.obsInputs = array;
    [self getSourceActive];
    [self.tableView reloadData];
}

- (void)handleSourceActive:(NSDictionary *)dict {
    NSString *sourceName = dict[@"requestId"];
    NSDictionary *responseData = dict[@"responseData"];
    BOOL preview = [responseData[@"videoActive"] boolValue];
    BOOL program = [responseData[@"videoShowing"] boolValue];
    for (NSMutableDictionary *input in self.obsInputs) {
        if ([input[@"Source"] isEqualToString:sourceName]) {
            input[@"Preview"] = preview ? @"Y" : @"N";
            input[@"Program"] = program ? @"Y" : @"N";
            [self.tableView reloadData];
            break;
        }
    }
}

- (void)handleRequestResponse:(NSDictionary *)dict {
    NSDictionary *data = dict[@"d"];
    NSString *type = data[@"requestType"];
    if ([type isEqualToString:@"GetInputList"]) {
        [self handleInputList:data[@"responseData"]];
    } else if ([type isEqualToString:@"GetSourceActive"]) {
        [self handleSourceActive:data];
    }
}

- (void)getSourceActive {
    for (NSDictionary *dict in self.obsInputs) {
        NSString *json = [self jsonGetSourceActive:dict[@"Source"]];
        [self sendString:json];
    }

}
- (void)handleEventResponse:(NSDictionary *)dict {
    // Whatever the event, we need to ask all the cameras about their current state.
    [self getSourceActive];
}


- (void)handleJSON:(id)jsonObj {
    if (![jsonObj isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary *dict = (NSDictionary *)jsonObj;
    NSNumber *opObj = dict[@"op"];
    if (opObj == nil) {
        return;
    }
    switch ([opObj integerValue]) {
        case Op_Hello:
            self.connected = YES;
            [self sendString:self.jsonHelloReply];
            break;
        case Op_Identified:
            [self sendString:self.jsonGetInputList];
            break;
        case Op_Event:
            [self handleEventResponse:dict];
            break;
        case Op_RequestResponse:
            [self handleRequestResponse:dict];
            break;
    }
}

- (void)sendString:(NSString *)str {
    outgoing.push([str UTF8String]);
}

- (void)recvString {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::string s;
        if (self->incoming.pop(s)) {
            const char *msg = s.c_str();
            [self writeToConsole:[NSString stringWithUTF8String:msg]];
            NSData *data = [NSData dataWithBytes:msg length:strlen(msg)];
            NSError *error;
            id msgObj = [NSJSONSerialization JSONObjectWithData:data
                             options:0
                               error:&error];
            [self handleJSON:msgObj];
        }
    });
}

- (void)runSocketFromURL:(NSString *)url {
    self.running = YES;
    
    dispatch_async(socketQueue, ^() {
        using easywsclient::WebSocket;
        std::unique_ptr<WebSocket> ws(WebSocket::from_url([url UTF8String]));
        while (self.running) {
            if (ws->getReadyState() == WebSocket::CLOSED)
                break;
            std::string data;
            if (self->outgoing.pop(data))
                ws->send(data);
            ws->poll();
            ws->dispatch([&](const std::string & message) {
                std::cout << message << '\n';
                self->incoming.push(message);
                [self recvString];
            });
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        ws->close();
        ws->poll();
    });

}
- (IBAction)connectToServer:(id)sender {
    if (self.connected) {
        return;
    }
    [self runSocketFromURL:@"ws://localhost:4455"];
    [self writeToConsole:@"Connecting..."];
}

- (IBAction)sendCommand:(id)sender {
    if ([self.command length] > 0) {
        [self sendString:self.command];
    }
    self.command = @"";
}

- (void)writeToConsole:(NSString *)string {
    [self writeToConsole:string color:nil];
}

- (void)writeToConsole:(NSString *)inString color:(NSColor *)color
{
    NSTextStorage *textStorage = [self.console textStorage];
    [textStorage beginEditing];
    NSString *string = [inString stringByAppendingString:@"\n"];
    NSAttributedString *attributedString = [[NSAttributedString alloc] initWithString:string attributes:
                                            @{NSFontAttributeName:[NSFont userFixedPitchFontOfSize:[NSFont systemFontSize]],
                                              NSForegroundColorAttributeName:(color ?: [NSColor systemGreenColor])}];
    
    [textStorage appendAttributedString:attributedString];
    [textStorage endEditing];
    NSRange range = NSMakeRange([[self.console string] length], 0);
    [self.console scrollRangeToVisible:range];
}

#pragma mark tableview
#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [self.obsInputs count];
}

#pragma mark - NSTableViewDelegate

//- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
//    return <#height#>;
//}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row {
    
    NSDictionary *source = [self.obsInputs objectAtIndex:row];
    // Return the result
    return source[tableColumn.identifier] ?: @"X";
}
@end
