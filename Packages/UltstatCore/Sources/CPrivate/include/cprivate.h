// Declarations for private-but-stable macOS SPI used by system monitors.
// Every symbol here is resolved at link time from IOKit; nothing is loaded dynamically.
#ifndef CPRIVATE_H
#define CPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: IOHIDEventSystem (thermal sensors on Apple Silicon)
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

enum {
    kUltIOHIDEventTypeTemperature = 15,
    kUltIOHIDEventTypePower = 25,
};
#define ULT_IOHID_EVENT_FIELD_BASE(type) ((type) << 16)

#ifdef __cplusplus
}
#endif
#endif
