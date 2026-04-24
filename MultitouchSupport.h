/*
 *  MultitouchSupport.h
 *  Private framework header for Apple's MultitouchSupport.framework
 *
 *  Original by Nathan Vander Wilt, adapted for SiriRemote project.
 *  Used to access Siri Remote trackpad data on macOS.
 */

#ifndef MultitouchSupport_h
#define MultitouchSupport_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// Touch point structure
typedef struct {
    float x;
    float y;
} MTPoint;

// Touch vector (position + velocity)
typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

// Touch states
typedef enum {
    MTTouchStateNotTracking = 0,
    MTTouchStateStartInRange = 1,
    MTTouchStateHoverInRange = 2,
    MTTouchStateMakeTouch = 3,
    MTTouchStateTouching = 4,
    MTTouchStateBreakTouch = 5,
    MTTouchStateLingerInRange = 6,
    MTTouchStateOutOfRange = 7
} MTTouchState;

// Touch data structure - contains all touch information
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;          // transducer index
    MTTouchState state;
    int32_t fingerID;           // finger identity
    int32_t handID;             // hand identity (usually 1)
    MTVector normalizedVector;  // normalized position (0.0-1.0) and velocity
    float zTotal;               // touch quality (0-1)
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;    // absolute position in mm
    int32_t field14;
    int32_t field15;
    float zDensity;             // touch density
} MTTouch;

// Opaque device reference
typedef CFTypeRef MTDeviceRef;

// Device management
CFArrayRef MTDeviceCreateList(void);
MTDeviceRef MTDeviceCreateDefault(void);
MTDeviceRef MTDeviceCreateFromDeviceID(int64_t deviceID);
void MTDeviceRelease(MTDeviceRef device);

// Device lifecycle
OSStatus MTDeviceStart(MTDeviceRef device, int mode);
OSStatus MTDeviceStop(MTDeviceRef device);
bool MTDeviceIsRunning(MTDeviceRef device);

// Device properties
bool MTDeviceIsValid(MTDeviceRef device);
bool MTDeviceIsBuiltIn(MTDeviceRef device) __attribute__((weak_import));
bool MTDeviceIsOpaqueSurface(MTDeviceRef device);
OSStatus MTDeviceGetDeviceID(MTDeviceRef device, uint64_t *deviceID) __attribute__((weak_import));
OSStatus MTDeviceGetSensorSurfaceDimensions(MTDeviceRef device, int *width, int *height);
OSStatus MTDeviceGetFamilyID(MTDeviceRef device, int *familyID);
OSStatus MTDeviceGetDriverType(MTDeviceRef device, int *driverType);

// Callback function types
typedef void (*MTFrameCallbackFunction)(MTDeviceRef device,
                                        MTTouch touches[],
                                        size_t numTouches,
                                        double timestamp,
                                        size_t frame);

typedef void (*MTFrameCallbackRefconFunction)(MTDeviceRef device,
                                              MTTouch touches[],
                                              size_t numTouches,
                                              double timestamp,
                                              size_t frame,
                                              void *refcon);

// Callback registration
void MTRegisterContactFrameCallback(MTDeviceRef device, MTFrameCallbackFunction callback);
void MTRegisterContactFrameCallbackWithRefcon(MTDeviceRef device, MTFrameCallbackRefconFunction callback, void *refcon);
void MTUnregisterContactFrameCallback(MTDeviceRef device, MTFrameCallbackRefconFunction callback);

#endif /* MultitouchSupport_h */
