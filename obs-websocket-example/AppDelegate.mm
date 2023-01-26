//
//  AppDelegate.m
//  obs-websocket-example
//
//  Created by Lee Ann Rucker on 1/24/23.
//

// Credit: https://github.com/dhbaird/easywsclient
// Credit: https://stackoverflow.com/questions/69051106/c-or-c-websocket-client-working-example

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
// Yes, this could probably be replaced by dispatch_queue code.
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

/*
 
 EventSubscription::None
 EventSubscription::General
 EventSubscription::Config
 EventSubscription::Scenes
 EventSubscription::Inputs
 EventSubscription::Transitions
 EventSubscription::Filters
 EventSubscription::Outputs
 EventSubscription::SceneItems
 EventSubscription::MediaInputs
 EventSubscription::Vendors
 EventSubscription::Ui
 EventSubscription::All
 EventSubscription::InputVolumeMeters
 EventSubscription::InputActiveStateChanged
 EventSubscription::InputShowStateChanged
 EventSubscription::SceneItemTransformChanged
 */
typedef enum {
    ES_None = 0,
    ES_General = (1 << 0),
    ES_Config = (1 << 1),
    ES_Scenes = (1 << 2),
    ES_Inputs = (1 << 3),
    ES_Transition = (1 << 4),
    ES_Filters = (1 << 5),
    ES_Outputs = (1 << 6),
    ES_SceneItems = (1 << 7),
    ES_MediaInputs = (1 << 8),
    ES_Vendors = (1 << 9),
 // All non-high-volume events. (General | Config | Scenes | Inputs | Transitions | Filters | Outputs | SceneItems | MediaInputs | Vendors | Ui)
    
} EventSubscription;

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
@property NSString *requestId;
@property NSString *obsURL;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
    socketQueue = dispatch_queue_create("socketQueue", NULL);
    // A unique ID for requests when we don't care about matching request with reply.
    self.requestId = [[NSUUID new] UUIDString];
    self.obsURL = @"ws://localhost:4455";
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
    self.running = NO;
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
        [self writeToConsole:[NSString stringWithFormat:@"Error converting dictionary to JSON: %@", error] color:[NSColor redColor]];
        return nil;
    } else {
        return[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
}

- (NSString *)jsonHelloReply {
    // This is a simple app; it only listens to scene changes.
    NSDictionary *dict = @{@"op":@(1),
                           @"d":@{@"rpcVersion":@(1),
                                  @"eventSubscriptions":@(ES_General | ES_Scenes)}};
    return [self convertToJson:dict];
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
                                   @"requestId": self.requestId,
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
    // Column IDs: videoActive, videoShowing, inputName
    NSMutableArray *array = [NSMutableArray array];
    NSArray *inputs = dict[@"inputs"];
    for (NSDictionary *input in inputs) {
        NSString *name = input[@"inputName"];
        if (name) {
            [array addObject:[NSMutableDictionary dictionaryWithDictionary:@{@"inputName":name}]];
        }
    }
    self.obsInputs = array;
    [self getSourceActive];
    [self.tableView reloadData];
}

- (void)handleSourceActive:(NSDictionary *)dict {
    NSString *sourceName = dict[@"requestId"];
    NSDictionary *responseData = dict[@"responseData"];
    BOOL videoActive = [responseData[@"videoActive"] boolValue];
    BOOL videoShowing = [responseData[@"videoShowing"] boolValue];
    for (NSMutableDictionary *input in self.obsInputs) {
        if ([input[@"inputName"] isEqualToString:sourceName]) {
            input[@"videoActive"] = videoActive ? @"Y" : @"N";
            input[@"videoShowing"] = videoShowing ? @"Y" : @"N";
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
        NSString *json = [self jsonGetSourceActive:dict[@"inputName"]];
        [self sendString:json];
    }

}
- (void)handleEventResponse:(NSDictionary *)dict {
    NSDictionary *data = dict[@"d"];
    NSNumber *intentObj = data[@"eventIntent"];
    if (intentObj == nil) {
        [self writeToConsole:[NSString stringWithFormat:@"bad dictionary: %@", dict] color:[NSColor redColor]];
        return;
    }
    NSInteger intent = [intentObj integerValue];
    if (intent == ES_Scenes) {
        // Ignore SceneCreated, SceneRemoved, and SceneListChanged
        NSString *eventType = data[@"eventType"];
        if ([eventType isEqualToString:@"CurrentProgramSceneChanged"] ||
            [eventType isEqualToString:@"CurrentPreviewSceneChanged"]) {
            [self getSourceActive];
        }
    } else if (intent == ES_General) {
        // Ignore Vendor and Custom events.
        NSString *eventType = data[@"eventType"];
        if ([eventType isEqualToString:@"ExitStarted"]) {
            self.running = NO;
        }
    } else {
        [self writeToConsole:[NSString stringWithFormat:@"%@", dict] color:[NSColor redColor]];
    }
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
        default:
            [self writeToConsole:[NSString stringWithFormat:@"%@", dict] color:[NSColor redColor]];
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
    
    dispatch_async(socketQueue, ^() {
        using easywsclient::WebSocket;
        std::unique_ptr<WebSocket> ws(WebSocket::from_url([url UTF8String]));
        if (ws == NULL) {
            [self writeToConsole:[NSString stringWithFormat:@"Unable to connect to %@", url] color:[NSColor redColor]];
            return;
        }
        self.running = YES;
        while (self.running) {
            if (ws->getReadyState() == WebSocket::CLOSED)
                break;
            std::string data;
            if (self->outgoing.pop(data))
                ws->send(data);
            ws->poll();
            ws->dispatch([&](const std::string & message) {
//                std::cout << message << '\n';
                self->incoming.push(message);
                [self recvString];
            });
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        ws->close();
        ws->poll();
        self.connected = NO;
    });

}
- (IBAction)connectToServer:(id)sender {
    if (self.connected) {
        return;
    }
    [self runSocketFromURL:self.obsURL];
    [self writeToConsole:[NSString stringWithFormat:@"Connecting to %@...", self.obsURL]];
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
    dispatch_async(dispatch_get_main_queue(), ^{
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
    });
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
