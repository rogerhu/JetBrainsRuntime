/*
 * Copyright (c) 2011, 2022, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

#include <objc/objc-runtime.h>
#import <Cocoa/Cocoa.h>

#include <java_awt_Window_CustomWindowDecoration.h>
#import "sun_lwawt_macosx_CPlatformWindow.h"
#import "com_apple_eawt_event_GestureHandler.h"
#import "com_apple_eawt_FullScreenHandler.h"
#import "ApplicationDelegate.h"

#import "AWTWindow.h"
#import "AWTView.h"
#import "GeomUtilities.h"
#import "ThreadUtilities.h"
#import "NSApplicationAWT.h"
#import "JNIUtilities.h"

#define MASK(KEY) \
    (sun_lwawt_macosx_CPlatformWindow_ ## KEY)

#define IS(BITS, KEY) \
    ((BITS & MASK(KEY)) != 0)

#define SET(BITS, KEY, VALUE) \
    BITS = VALUE ? BITS | MASK(KEY) : BITS & ~MASK(KEY)

static jclass jc_CPlatformWindow = NULL;
#define GET_CPLATFORM_WINDOW_CLASS() \
    GET_CLASS(jc_CPlatformWindow, "sun/lwawt/macosx/CPlatformWindow");

#define GET_CPLATFORM_WINDOW_CLASS_RETURN(ret) \
    GET_CLASS_RETURN(jc_CPlatformWindow, "sun/lwawt/macosx/CPlatformWindow", ret);

// Cocoa windowDidBecomeKey/windowDidResignKey notifications
// doesn't provide information about "opposite" window, so we
// have to do a bit of tracking. This variable points to a window
// which had been the key window just before a new key window
// was set. It would be nil if the new key window isn't an AWT
// window or the app currently has no key window.
static AWTWindow* lastKeyWindow = nil;

// This variable contains coordinates of a window's top left
// which was positioned via java.awt.Window.setLocationByPlatform.
// It would be NSZeroPoint if 'Location by Platform' is not used.
static NSPoint lastTopLeftPoint;

static BOOL ignoreResizeWindowDuringAnotherWindowEnd = NO;

static BOOL fullScreenTransitionInProgress = NO;
static BOOL orderingScheduled = NO;

// --------------------------------------------------------------
// NSWindow/NSPanel descendants implementation
#define AWT_NS_WINDOW_IMPLEMENTATION                            \
- (id) initWithDelegate:(AWTWindow *)delegate                   \
              frameRect:(NSRect)contectRect                     \
              styleMask:(NSUInteger)styleMask                   \
            contentView:(NSView *)view                          \
{                                                               \
    self = [super initWithContentRect:contectRect               \
                            styleMask:styleMask                 \
                              backing:NSBackingStoreBuffered    \
                                defer:NO];                      \
                                                                \
    if (self == nil) return nil;                                \
                                                                \
    [self setDelegate:delegate];                                \
    [self setContentView:view];                                 \
    [self setInitialFirstResponder:view];                       \
    [self setReleasedWhenClosed:NO];                            \
    [self setPreservesContentDuringLiveResize:YES];             \
    [[NSNotificationCenter defaultCenter] addObserver:self      \
         selector:@selector(windowDidChangeScreen)              \
         name:NSWindowDidChangeScreenNotification object:self]; \
    [[NSNotificationCenter defaultCenter] addObserver:self      \
         selector:@selector(windowDidChangeProfile)             \
         name:NSWindowDidChangeScreenProfileNotification        \
         object:self];                                          \
    return self;                                                \
}                                                               \
                                                                \
/* NSWindow overrides */                                        \
- (BOOL) canBecomeKeyWindow {                                   \
    return [(AWTWindow*)[self delegate] canBecomeKeyWindow];    \
}                                                               \
                                                                \
- (BOOL) canBecomeMainWindow {                                  \
    return [(AWTWindow*)[self delegate] canBecomeMainWindow];   \
}                                                               \
                                                                \
- (BOOL) worksWhenModal {                                       \
    return [(AWTWindow*)[self delegate] worksWhenModal];        \
}                                                               \
                                                                \
- (void)cursorUpdate:(NSEvent *)event {                         \
    /* Prevent cursor updates from OS side */                   \
}                                                               \
                                                                \
- (void)sendEvent:(NSEvent *)event {                            \
    [(AWTWindow*)[self delegate] sendEvent:event];              \
    [super sendEvent:event];                                    \
}                                                               \
                                                                \
- (void)becomeKeyWindow {                                       \
    [super becomeKeyWindow];                                    \
    [(AWTWindow*)[self delegate] becomeKeyWindow];              \
}                                                               \
                                                                \
- (NSWindowTabbingMode)tabbingMode {                            \
    return ((AWTWindow*)[self delegate]).javaWindowTabbingMode; \
}                                                               \
                                                                \
- (void)windowDidChangeScreen {                                 \
   [(AWTWindow*)[self delegate] _displayChanged:NO];           \
}                                                               \
                                                                \
- (void)windowDidChangeProfile {                                \
   [(AWTWindow*)[self delegate] _displayChanged:YES];            \
}                                                               \
                                                                \
- (void)dealloc {                                               \
   [[NSNotificationCenter defaultCenter] removeObserver:self    \
       name:NSWindowDidChangeScreenNotification object:self];   \
   [[NSNotificationCenter defaultCenter] removeObserver:self    \
       name:NSWindowDidChangeScreenProfileNotification          \
       object:self];                                            \
   [super dealloc];                                             \
}                                                               \

@implementation AWTWindow_Normal
AWT_NS_WINDOW_IMPLEMENTATION

// suppress exception (actually assertion) from [NSWindow _changeJustMain]
// workaround for https://youtrack.jetbrains.com/issue/JBR-2562
- (void)_changeJustMain {
    @try {
        // NOTE: we can't use [super _changeJustMain] directly because of the warning ('may not perform to selector')
        // And [super performSelector:@selector(_changeJustMain)] will invoke this method (not a base method).
        // So do it with objc-runtime.h (see stackoverflow.com/questions/14635024/using-objc-msgsendsuper-to-invoke-a-class-method)
        Class superClass = [self superclass];
        struct objc_super mySuper = {
            self,
            class_isMetaClass(object_getClass(self))        //check if we are an instance or Class
                            ? object_getClass(superClass)   //if we are a Class, we need to send our metaclass (our Class's Class)
                            : superClass                    //if we are an instance, we need to send our Class (which we already have)
        };
        void (*_objc_msgSendSuper)(struct objc_super *, SEL) = (void *)&objc_msgSendSuper; //cast our pointer so the compiler can sort out the ABI
        (*_objc_msgSendSuper)(&mySuper, @selector(_changeJustMain));
    } @catch (NSException *ex) {
        NSLog(@"WARNING: suppressed exception from _changeJustMain (workaround for JBR-2562)");
        NSProcessInfo *processInfo = [NSProcessInfo processInfo];
        [NSApplicationAWT logException:ex forProcess:processInfo];
    }
}

// Gesture support
- (void)postGesture:(NSEvent *)event as:(jint)type a:(jdouble)a b:(jdouble)b {
    AWT_ASSERT_APPKIT_THREAD;

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, ((AWTWindow *)self.delegate).javaPlatformWindow);
    if (platformWindow != NULL) {
        // extract the target AWT Window object out of the CPlatformWindow
        GET_CPLATFORM_WINDOW_CLASS();
        DECLARE_FIELD(jf_target, jc_CPlatformWindow, "target", "Ljava/awt/Window;");
        jobject awtWindow = (*env)->GetObjectField(env, platformWindow, jf_target);
        if (awtWindow != NULL) {
            // translate the point into Java coordinates
            NSPoint loc = [event locationInWindow];
            loc.y = [self frame].size.height - loc.y;

            // send up to the GestureHandler to recursively dispatch on the AWT event thread
            DECLARE_CLASS(jc_GestureHandler, "com/apple/eawt/event/GestureHandler");
            DECLARE_STATIC_METHOD(sjm_handleGestureFromNative, jc_GestureHandler,
                            "handleGestureFromNative", "(Ljava/awt/Window;IDDDD)V");
            (*env)->CallStaticVoidMethod(env, jc_GestureHandler, sjm_handleGestureFromNative,
                               awtWindow, type, (jdouble)loc.x, (jdouble)loc.y, (jdouble)a, (jdouble)b);
            CHECK_EXCEPTION();
            (*env)->DeleteLocalRef(env, awtWindow);
        }
        (*env)->DeleteLocalRef(env, platformWindow);
    }
}

- (BOOL)postPhaseEvent:(NSEvent *)event {
    // Consider changing API to reflect MacOS api
    // Gesture event should come with phase field
    // PhaseEvent should be removed
    const unsigned int NSEventPhaseBegan = 0x1 << 0;
    const unsigned int NSEventPhaseEnded = 0x1 << 3;
    const unsigned int NSEventPhaseCancelled = 0x1 << 4;

    if (event.phase == NSEventPhaseBegan) {
        [self postGesture:event
                       as:com_apple_eawt_event_GestureHandler_PHASE
                        a:-1.0
                        b:0.0];
        return true;
    } else if (event.phase == NSEventPhaseEnded ||
               event.phase == NSEventPhaseCancelled) {
        [self postGesture:event
                       as:com_apple_eawt_event_GestureHandler_PHASE
                        a:1.0
                        b:0.0];
        return true;
    }
    return false;
}

- (void)magnifyWithEvent:(NSEvent *)event {
    if ([self postPhaseEvent:event]) {
        return;
    }
    [self postGesture:event
                   as:com_apple_eawt_event_GestureHandler_MAGNIFY
                    a:[event magnification]
                    b:0.0];
}

- (void)rotateWithEvent:(NSEvent *)event {
    if ([self postPhaseEvent:event]) {
        return;
    }
    [self postGesture:event
                   as:com_apple_eawt_event_GestureHandler_ROTATE
                    a:[event rotation]
                    b:0.0];
}

- (void)swipeWithEvent:(NSEvent *)event {
    [self postGesture:event
                   as:com_apple_eawt_event_GestureHandler_SWIPE
                    a:[event deltaX]
                    b:[event deltaY]];
}

- (void)pressureChangeWithEvent:(NSEvent *)event {
    float pressure = event.pressure;
    [self postGesture:event
                       as:com_apple_eawt_event_GestureHandler_PRESSURE
                        a:pressure
                        b:(([event respondsToSelector:@selector(stage)]) ? ((NSInteger)[event stage]) : -1)
    ];
}

- (void)moveTabToNewWindow:(id)sender {
    AWT_ASSERT_APPKIT_THREAD;

    [super moveTabToNewWindow:sender];

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, ((AWTWindow *)self.delegate).javaPlatformWindow);
    if (platformWindow != NULL) {
        // extract the target AWT Window object out of the CPlatformWindow
        GET_CPLATFORM_WINDOW_CLASS();
        DECLARE_FIELD(jf_target, jc_CPlatformWindow, "target", "Ljava/awt/Window;");
        jobject awtWindow = (*env)->GetObjectField(env, platformWindow, jf_target);
        if (awtWindow != NULL) {
            DECLARE_CLASS(jc_Window, "java/awt/Window");
            DECLARE_METHOD(jm_runMoveTabToNewWindowCallback, jc_Window, "runMoveTabToNewWindowCallback", "()V");
            (*env)->CallVoidMethod(env, awtWindow, jm_runMoveTabToNewWindowCallback);
            CHECK_EXCEPTION();
            (*env)->DeleteLocalRef(env, awtWindow);
        }
        (*env)->DeleteLocalRef(env, platformWindow);
    }

#ifdef DEBUG
    NSLog(@"=== Move Tab to new Window ===");
#endif
}

// Call over Foundation from Java
- (CGFloat) getTabBarVisibleAndHeight {
    if (@available(macOS 10.13, *)) {
        id tabGroup = [self tabGroup];
#ifdef DEBUG
        NSLog(@"=== Window tabBar: %@ ===", tabGroup);
#endif
        if ([tabGroup isTabBarVisible]) {
            if ([tabGroup respondsToSelector:@selector(_tabBar)]) { // private member
                CGFloat height = [[tabGroup _tabBar] frame].size.height;
#ifdef DEBUG
                NSLog(@"=== Window tabBar visible: %f ===", height);
#endif
                return height;
            }
#ifdef DEBUG
            NSLog(@"=== NsWindow.tabGroup._tabBar not found ===");
#endif
            return -1; // if we don't get height return -1 and use default value in java without change native code
        }
#ifdef DEBUG
        NSLog(@"=== Window tabBar not visible ===");
#endif
    } else {
#ifdef DEBUG
        NSLog(@"=== Window tabGroup not supported before macOS 10.13 ===");
#endif
    }
    return 0;
}

- (void)orderOut:(id)sender {
    ignoreResizeWindowDuringAnotherWindowEnd = YES;
    [super orderOut:sender];
}

@end
@implementation AWTWindow_Panel
AWT_NS_WINDOW_IMPLEMENTATION
@end
// END of NSWindow/NSPanel descendants implementation
// --------------------------------------------------------------


@implementation AWTWindow

@synthesize nsWindow;
@synthesize javaPlatformWindow;
@synthesize javaMenuBar;
@synthesize javaMinSize;
@synthesize javaMaxSize;
@synthesize styleBits;
@synthesize isEnabled;
@synthesize ownerWindow;
@synthesize preFullScreenLevel;
@synthesize standardFrame;
@synthesize isMinimizing;
@synthesize isJustCreated;
@synthesize javaWindowTabbingMode;
@synthesize isEnterFullScreen;
@synthesize currentDisplayID;

- (void) updateMinMaxSize:(BOOL)resizable {
    if (resizable) {
        [self.nsWindow setMinSize:self.javaMinSize];
        [self.nsWindow setMaxSize:self.javaMaxSize];
    } else {
        NSRect currentFrame = [self.nsWindow frame];
        [self.nsWindow setMinSize:currentFrame.size];
        [self.nsWindow setMaxSize:currentFrame.size];
    }
}

// creates a new NSWindow style mask based on the _STYLE_PROP_BITMASK bits
+ (NSUInteger) styleMaskForStyleBits:(jint)styleBits {
    NSUInteger type = 0;
    if (IS(styleBits, DECORATED)) {
        type |= NSTitledWindowMask;
        if (IS(styleBits, CLOSEABLE))            type |= NSWindowStyleMaskClosable;
        if (IS(styleBits, RESIZABLE))            type |= NSWindowStyleMaskResizable;
        if (IS(styleBits, FULL_WINDOW_CONTENT))  type |= NSWindowStyleMaskFullSizeContentView;
    } else {
        type |= NSWindowStyleMaskBorderless;
    }

    if (IS(styleBits, MINIMIZABLE))   type |= NSWindowStyleMaskMiniaturizable;
    if (IS(styleBits, TEXTURED))      type |= NSWindowStyleMaskTexturedBackground;
    if (IS(styleBits, UNIFIED))       type |= NSWindowStyleMaskUnifiedTitleAndToolbar;
    if (IS(styleBits, UTILITY))       type |= NSWindowStyleMaskUtilityWindow;
    if (IS(styleBits, HUD))           type |= NSWindowStyleMaskHUDWindow;
    if (IS(styleBits, SHEET))         type |= NSWindowStyleMaskDocModalWindow;

    return type;
}

// updates _METHOD_PROP_BITMASK based properties on the window
- (void) setPropertiesForStyleBits:(jint)bits mask:(jint)mask {
    if (IS(mask, RESIZABLE)) {
        BOOL resizable = IS(bits, RESIZABLE);
        [self updateMinMaxSize:resizable];
        [self.nsWindow setShowsResizeIndicator:resizable];
        // Zoom button should be disabled, if the window is not resizable,
        // otherwise button should be restored to initial state.
        BOOL zoom = resizable && IS(bits, ZOOMABLE);
        [[self.nsWindow standardWindowButton:NSWindowZoomButton] setEnabled:zoom];
    }

    if (IS(mask, HAS_SHADOW)) {
        [self.nsWindow setHasShadow:IS(bits, HAS_SHADOW)];
    }

    if (IS(mask, ZOOMABLE)) {
        [[self.nsWindow standardWindowButton:NSWindowZoomButton] setEnabled:IS(bits, ZOOMABLE)];
    }

    if (IS(mask, ALWAYS_ON_TOP)) {
        [self.nsWindow setLevel:IS(bits, ALWAYS_ON_TOP) ? NSFloatingWindowLevel : NSNormalWindowLevel];
    }

    if (IS(mask, HIDES_ON_DEACTIVATE)) {
        [self.nsWindow setHidesOnDeactivate:IS(bits, HIDES_ON_DEACTIVATE)];
    }

    if (IS(mask, DRAGGABLE_BACKGROUND)) {
        [self.nsWindow setMovableByWindowBackground:IS(bits, DRAGGABLE_BACKGROUND)];
    }

    if (IS(mask, DOCUMENT_MODIFIED)) {
        [self.nsWindow setDocumentEdited:IS(bits, DOCUMENT_MODIFIED)];
    }

    if (IS(mask, FULLSCREENABLE) && [self.nsWindow respondsToSelector:@selector(toggleFullScreen:)]) {
        if (IS(bits, FULLSCREENABLE)) {
            self.nsWindow.collectionBehavior = self.nsWindow.collectionBehavior |
                                               NSWindowCollectionBehaviorFullScreenPrimary;
        } else {
            self.nsWindow.collectionBehavior = self.nsWindow.collectionBehavior &
                                               ~NSWindowCollectionBehaviorFullScreenPrimary;
        }
    }

    if (IS(mask, TRANSPARENT_TITLE_BAR) && [self.nsWindow respondsToSelector:@selector(setTitlebarAppearsTransparent:)]) {
        [self.nsWindow setTitlebarAppearsTransparent:IS(bits, TRANSPARENT_TITLE_BAR)];
    }

    if (IS(mask, TITLE_VISIBLE) && [self.nsWindow respondsToSelector:@selector(setTitleVisibility:)]) {
        [self.nsWindow setTitleVisibility:(IS(bits, TITLE_VISIBLE) ? NSWindowTitleVisible : NSWindowTitleHidden)];
    }

}

- (id) initWithPlatformWindow:(jobject)platformWindow
                  ownerWindow:owner
                    styleBits:(jint)bits
                    frameRect:(NSRect)rect
                  contentView:(NSView *)view
    transparentTitleBarHeight:(CGFloat)transparentTitleBarHeight
{
AWT_ASSERT_APPKIT_THREAD;

    NSUInteger newBits = bits;
    if (IS(bits, SHEET) && owner == nil) {
        newBits = bits & ~NSWindowStyleMaskDocModalWindow;
    }
    NSUInteger styleMask = [AWTWindow styleMaskForStyleBits:newBits];

    NSRect contentRect = rect; //[NSWindow contentRectForFrameRect:rect styleMask:styleMask];
    if (contentRect.size.width <= 0.0) {
        contentRect.size.width = 1.0;
    }
    if (contentRect.size.height <= 0.0) {
        contentRect.size.height = 1.0;
    }

    self = [super init];

    if (self == nil) return nil; // no hope

    if (IS(bits, UTILITY) ||
        IS(bits, HUD) ||
        IS(bits, HIDES_ON_DEACTIVATE) ||
        IS(bits, SHEET))
    {
        self.nsWindow = [[AWTWindow_Panel alloc] initWithDelegate:self
                            frameRect:contentRect
                            styleMask:styleMask
                          contentView:view];
    }
    else
    {
        // These windows will appear in the window list in the dock icon menu
        self.nsWindow = [[AWTWindow_Normal alloc] initWithDelegate:self
                            frameRect:contentRect
                            styleMask:styleMask
                          contentView:view];
    }

    if (self.nsWindow == nil) return nil; // no hope either
    [self.nsWindow release]; // the property retains the object already

    self.isEnabled = YES;
    self.isMinimizing = NO;
    self.javaPlatformWindow = platformWindow;
    self.styleBits = bits;
    self.ownerWindow = owner;
    [self setPropertiesForStyleBits:styleBits mask:MASK(_METHOD_PROP_BITMASK)];

    if (IS(bits, SHEET) && owner != nil) {
        [self.nsWindow setStyleMask: NSWindowStyleMaskDocModalWindow];
    }

    self.isJustCreated = YES;

    self.javaWindowTabbingMode = [self getJavaWindowTabbingMode];
    self.nsWindow.collectionBehavior = NSWindowCollectionBehaviorManaged;
    self.isEnterFullScreen = NO;

    _transparentTitleBarHeight = transparentTitleBarHeight;
    if (transparentTitleBarHeight != 0.0 && !self.isFullScreen) {
        [self setUpTransparentTitleBar];
    }

    currentDisplayID = nil;
    return self;
}

+ (BOOL) isAWTWindow:(NSWindow *)window {
    return [window isKindOfClass: [AWTWindow_Panel class]] || [window isKindOfClass: [AWTWindow_Normal class]];
}

// returns id for the topmost window under mouse
+ (NSInteger) getTopmostWindowUnderMouseID {
    return [NSWindow windowNumberAtPoint:[NSEvent mouseLocation] belowWindowWithWindowNumber:kCGNullWindowID];
}

// checks that this window is under the mouse cursor and this point is not overlapped by others windows
- (BOOL) isTopmostWindowUnderMouse {
    return [self.nsWindow windowNumber] == [AWTWindow getTopmostWindowUnderMouseID];
}

- (NSWindowTabbingMode) getJavaWindowTabbingMode {
    AWT_ASSERT_APPKIT_THREAD;

    BOOL result = NO;

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        // extract the target AWT Window object out of the CPlatformWindow
        GET_CPLATFORM_WINDOW_CLASS_RETURN(NSWindowTabbingModeDisallowed);
        DECLARE_FIELD_RETURN(jf_target, jc_CPlatformWindow, "target", "Ljava/awt/Window;", NSWindowTabbingModeDisallowed);
        jobject awtWindow = (*env)->GetObjectField(env, platformWindow, jf_target);
        if (awtWindow != NULL) {
            DECLARE_CLASS_RETURN(jc_Window, "java/awt/Window", NSWindowTabbingModeDisallowed);
            DECLARE_METHOD_RETURN(jm_hasTabbingMode, jc_Window, "hasTabbingMode", "()Z", NSWindowTabbingModeDisallowed);
            result = (*env)->CallBooleanMethod(env, awtWindow, jm_hasTabbingMode) == JNI_TRUE ? YES : NO;
            CHECK_EXCEPTION();
            (*env)->DeleteLocalRef(env, awtWindow);
        }
        (*env)->DeleteLocalRef(env, platformWindow);
    }

#ifdef DEBUG
    NSLog(@"=== getJavaWindowTabbingMode: %d ===", result);
#endif

    return result ? NSWindowTabbingModeAutomatic : NSWindowTabbingModeDisallowed;
}

+ (AWTWindow *) getTopmostWindowUnderMouse {
    NSEnumerator *windowEnumerator = [[NSApp windows] objectEnumerator];
    NSWindow *window;

    NSInteger topmostWindowUnderMouseID = [AWTWindow getTopmostWindowUnderMouseID];

    while ((window = [windowEnumerator nextObject]) != nil) {
        if ([window windowNumber] == topmostWindowUnderMouseID) {
            BOOL isAWTWindow = [AWTWindow isAWTWindow: window];
            return isAWTWindow ? (AWTWindow *) [window delegate] : nil;
        }
    }
    return nil;
}

+ (void) synthesizeMouseEnteredExitedEvents:(NSWindow*)window withType:(NSEventType)eventType {

    NSPoint screenLocation = [NSEvent mouseLocation];
    NSPoint windowLocation = [window convertScreenToBase: screenLocation];
    int modifierFlags = (eventType == NSMouseEntered) ? NSMouseEnteredMask : NSMouseExitedMask;

    NSEvent *mouseEvent = [NSEvent enterExitEventWithType: eventType
                                                 location: windowLocation
                                            modifierFlags: modifierFlags
                                                timestamp: 0
                                             windowNumber: [window windowNumber]
                                                  context: nil
                                              eventNumber: 0
                                           trackingNumber: 0
                                                 userData: nil
                           ];

    [[window contentView] deliverJavaMouseEvent: mouseEvent];
}

+ (void) synthesizeMouseEnteredExitedEventsForAllWindows {

    NSInteger topmostWindowUnderMouseID = [AWTWindow getTopmostWindowUnderMouseID];
    NSArray *windows = [NSApp windows];
    NSWindow *window;

    NSEnumerator *windowEnumerator = [windows objectEnumerator];
    while ((window = [windowEnumerator nextObject]) != nil) {
        if ([AWTWindow isAWTWindow: window]) {
            BOOL isUnderMouse = ([window windowNumber] == topmostWindowUnderMouseID);
            BOOL mouseIsOver = [[window contentView] mouseIsOver];
            if (isUnderMouse && !mouseIsOver) {
                [AWTWindow synthesizeMouseEnteredExitedEvents:window withType:NSMouseEntered];
            } else if (!isUnderMouse && mouseIsOver) {
                [AWTWindow synthesizeMouseEnteredExitedEvents:window withType:NSMouseExited];
            }
        }
    }
}

+ (NSNumber *) getNSWindowDisplayID_AppKitThread:(NSWindow *)window {
    AWT_ASSERT_APPKIT_THREAD;
    NSScreen *screen = [window screen];
    NSDictionary *deviceDescription = [screen deviceDescription];
    return [deviceDescription objectForKey:@"NSScreenNumber"];
}

- (void) dealloc {
AWT_ASSERT_APPKIT_THREAD;

    JNIEnv *env = [ThreadUtilities getJNIEnvUncached];
    (*env)->DeleteWeakGlobalRef(env, self.javaPlatformWindow);
    self.javaPlatformWindow = nil;
    self.nsWindow = nil;
    self.ownerWindow = nil;
    self.currentDisplayID = nil;
    [super dealloc];
}

// Test whether window is simple window and owned by embedded frame
- (BOOL) isSimpleWindowOwnedByEmbeddedFrame {
    BOOL isSimpleWindowOwnedByEmbeddedFrame = NO;

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        GET_CPLATFORM_WINDOW_CLASS_RETURN(NO);
        DECLARE_METHOD_RETURN(jm_isBlocked, jc_CPlatformWindow, "isSimpleWindowOwnedByEmbeddedFrame", "()Z", NO);
        isSimpleWindowOwnedByEmbeddedFrame = (*env)->CallBooleanMethod(env, platformWindow, jm_isBlocked) == JNI_TRUE ? YES : NO;
        CHECK_EXCEPTION();
        (*env)->DeleteLocalRef(env, platformWindow);
    }

    return isSimpleWindowOwnedByEmbeddedFrame;
}

// Tests whether the corresponding Java platform window is visible or not
+ (BOOL) isJavaPlatformWindowVisible:(NSWindow *)window {
    BOOL isVisible = NO;

    if ([AWTWindow isAWTWindow:window] && [window delegate] != nil) {
        AWTWindow *awtWindow = (AWTWindow *)[window delegate];
        [AWTToolkit eventCountPlusPlus];

        JNIEnv *env = [ThreadUtilities getJNIEnv];
        jobject platformWindow = (*env)->NewLocalRef(env, awtWindow.javaPlatformWindow);
        if (platformWindow != NULL) {
            GET_CPLATFORM_WINDOW_CLASS_RETURN(isVisible);
            DECLARE_METHOD_RETURN(jm_isVisible, jc_CPlatformWindow, "isVisible", "()Z", isVisible)
            isVisible = (*env)->CallBooleanMethod(env, platformWindow, jm_isVisible) == JNI_TRUE ? YES : NO;
            CHECK_EXCEPTION();
            (*env)->DeleteLocalRef(env, platformWindow);

        }
    }
    return isVisible;
}

- (BOOL) delayShowing {
    AWT_ASSERT_APPKIT_THREAD;

    return ownerWindow != nil &&
           ([ownerWindow delayShowing] || !ownerWindow.nsWindow.onActiveSpace) &&
           !nsWindow.visible;
}

- (BOOL) checkBlockingAndOrder {
    AWT_ASSERT_APPKIT_THREAD;

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        GET_CPLATFORM_WINDOW_CLASS_RETURN(NO);
        DECLARE_METHOD_RETURN(jm_checkBlockingAndOrder, jc_CPlatformWindow, "checkBlockingAndOrder", "()V", NO);
        (*env)->CallVoidMethod(env, platformWindow, jm_checkBlockingAndOrder);
        CHECK_EXCEPTION();
        (*env)->DeleteLocalRef(env, platformWindow);
    }
    return YES;
}

+ (void)activeSpaceDidChange {
    AWT_ASSERT_APPKIT_THREAD;

    if (fullScreenTransitionInProgress) {
        orderingScheduled = YES;
        return;
    }

    // show delayed windows
    for (NSWindow *window in NSApp.windows) {
        if ([AWTWindow isJavaPlatformWindowVisible:window] && !window.visible) {
            AWTWindow *awtWindow = (AWTWindow *)[window delegate];
            while (awtWindow.ownerWindow != nil) {
                awtWindow = awtWindow.ownerWindow;
            }
            if (awtWindow.nsWindow.visible && awtWindow.nsWindow.onActiveSpace) {
                [awtWindow checkBlockingAndOrder];
            }
        }
    }
}

- (void) processVisibleChildren:(void(^)(AWTWindow*))action {
    NSEnumerator *windowEnumerator = [[NSApp windows]objectEnumerator];
    NSWindow *window;
    while ((window = [windowEnumerator nextObject]) != nil) {
        if ([AWTWindow isJavaPlatformWindowVisible:window]) {
            AWTWindow *awtWindow = (AWTWindow *)[window delegate];
            AWTWindow *parent = awtWindow.ownerWindow;
            while (parent != nil) {
                if (parent == self) {
                    action(awtWindow);
                    break;
                }
                parent = parent.ownerWindow;
            }
        }
    }
}

// Orders window children based on the current focus state
- (void) orderChildWindows:(BOOL)focus {
AWT_ASSERT_APPKIT_THREAD;

    if (self.isMinimizing) {
        // Do not perform any ordering, if iconify is in progress
        return;
    }

    [self processVisibleChildren:^void(AWTWindow* child){
        // Do not order 'always on top' windows
        if (!IS(child.styleBits, ALWAYS_ON_TOP)) {
            NSWindow *window = child.nsWindow;
            NSWindow *owner = child.ownerWindow.nsWindow;
            if (focus) {
                // Move the childWindow to floating level
                // so it will appear in front of its
                // parent which owns the focus
                [window setLevel:NSFloatingWindowLevel];
            } else {
                // Focus owner has changed, move the childWindow
                // back to normal window level
                [window setLevel:NSNormalWindowLevel];
            }
        }
    }];
}

// NSWindow overrides
- (BOOL) canBecomeKeyWindow {
AWT_ASSERT_APPKIT_THREAD;
    return self.isEnabled && (IS(self.styleBits, SHOULD_BECOME_KEY) || [self isSimpleWindowOwnedByEmbeddedFrame]);
}

- (void) becomeKeyWindow {
    AWT_ASSERT_APPKIT_THREAD;

    // Reset current cursor in CCursorManager such that any following mouse update event
    // restores the correct cursor to the frame context specific one.
    JNIEnv *env = [ThreadUtilities getJNIEnv];
    DECLARE_CLASS(jc_CCursorManager, "sun/lwawt/macosx/CCursorManager");
    DECLARE_STATIC_METHOD(sjm_resetCurrentCursor, jc_CCursorManager, "resetCurrentCursor", "()V");
    (*env)->CallStaticVoidMethod(env, jc_CCursorManager, sjm_resetCurrentCursor);
    CHECK_EXCEPTION();
}

- (BOOL) canBecomeMainWindow {
AWT_ASSERT_APPKIT_THREAD;
    if (!self.isEnabled) {
        // Native system can bring up the NSWindow to
        // the top even if the window is not main.
        // We should bring up the modal dialog manually
        [AWTToolkit eventCountPlusPlus];

        if (![self checkBlockingAndOrder]) return NO;
    }

    return self.isEnabled && IS(self.styleBits, SHOULD_BECOME_MAIN);
}

- (BOOL) worksWhenModal {
AWT_ASSERT_APPKIT_THREAD;
    return IS(self.styleBits, MODAL_EXCLUDED);
}


// NSWindowDelegate methods

- (void)_displayChanged:(BOOL)profileOnly {
    AWT_ASSERT_APPKIT_THREAD;
    if (!profileOnly) {
        NSNumber* newDisplayID = [AWTWindow getNSWindowDisplayID_AppKitThread:nsWindow];
        if (self.currentDisplayID == nil) {
            self.currentDisplayID = newDisplayID;
            return;
        }
        if ([currentDisplayID isEqualToNumber: newDisplayID]) {
            return;
        }
        self.currentDisplayID = newDisplayID;
    }

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow == NULL) {
        NSLog(@"[AWTWindow _displayChanged]: platformWindow == NULL");
        return;
    }
    GET_CPLATFORM_WINDOW_CLASS();
    DECLARE_METHOD(jm_displayChanged, jc_CPlatformWindow, "displayChanged", "(Z)V");
    (*env)->CallVoidMethod(env, platformWindow, jm_displayChanged, profileOnly);
    CHECK_EXCEPTION();
    (*env)->DeleteLocalRef(env, platformWindow);
}

- (void) _deliverMoveResizeEvent {
    AWT_ASSERT_APPKIT_THREAD;

    // deliver the event if this is a user-initiated live resize or as a side-effect
    // of a Java initiated resize, because AppKit can override the bounds and force
    // the bounds of the window to avoid the Dock or remain on screen.
    [AWTToolkit eventCountPlusPlus];
    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow == NULL) {
        NSLog(@"[AWTWindow _deliverMoveResizeEvent]: platformWindow == NULL");
        return;
    }
    NSRect frame;
    @try {
        frame = ConvertNSScreenRect(env, [self.nsWindow frame]);
    } @catch (NSException *e) {
        NSLog(@"WARNING: suppressed exception from ConvertNSScreenRect() in [AWTWindow _deliverMoveResizeEvent]");
        NSProcessInfo *processInfo = [NSProcessInfo processInfo];
        [NSApplicationAWT logException:e forProcess:processInfo];
        return;
    }

    GET_CPLATFORM_WINDOW_CLASS();
    DECLARE_METHOD(jm_deliverMoveResizeEvent, jc_CPlatformWindow, "deliverMoveResizeEvent", "(IIIIZ)V");
    (*env)->CallVoidMethod(env, platformWindow, jm_deliverMoveResizeEvent,
                      (jint)frame.origin.x,
                      (jint)frame.origin.y,
                      (jint)frame.size.width,
                      (jint)frame.size.height,
                      (jboolean)[self.nsWindow inLiveResize]);
    CHECK_EXCEPTION();
    (*env)->DeleteLocalRef(env, platformWindow);

    [AWTWindow synthesizeMouseEnteredExitedEventsForAllWindows];
}

- (void)windowDidMove:(NSNotification *)notification {
AWT_ASSERT_APPKIT_THREAD;

    [self _deliverMoveResizeEvent];
}

- (void)windowDidResize:(NSNotification *)notification {
AWT_ASSERT_APPKIT_THREAD;
    if (self.isEnterFullScreen && ignoreResizeWindowDuringAnotherWindowEnd) {
#ifdef DEBUG
        NSLog(@"=== Native.windowDidResize: %@ | ignored in transition to fullscreen ===", self.nsWindow.title);
#endif
        return;
    }

    [self _deliverMoveResizeEvent];
}

- (void)windowDidExpose:(NSNotification *)notification {
AWT_ASSERT_APPKIT_THREAD;

    [AWTToolkit eventCountPlusPlus];
    // TODO: don't see this callback invoked anytime so we track
    // window exposing in _setVisible:(BOOL)
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)window
                        defaultFrame:(NSRect)newFrame {

    return NSEqualSizes(NSZeroSize, [self standardFrame].size)
                ? newFrame
                : [self standardFrame];
}

// Hides/shows window children during iconify/de-iconify operation
- (void) iconifyChildWindows:(BOOL)iconify {
AWT_ASSERT_APPKIT_THREAD;

    [self processVisibleChildren:^void(AWTWindow* child){
        NSWindow *window = child.nsWindow;
        if (iconify) {
            [window orderOut:window];
        } else {
            [window orderFront:window];
        }
    }];
}

- (void) _deliverIconify:(BOOL)iconify {
AWT_ASSERT_APPKIT_THREAD;

    [AWTToolkit eventCountPlusPlus];
    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        GET_CPLATFORM_WINDOW_CLASS();
        DECLARE_METHOD(jm_deliverIconify, jc_CPlatformWindow, "deliverIconify", "(Z)V");
        (*env)->CallVoidMethod(env, platformWindow, jm_deliverIconify, iconify);
        CHECK_EXCEPTION();
        (*env)->DeleteLocalRef(env, platformWindow);
    }
}

- (void)windowWillMiniaturize:(NSNotification *)notification {
AWT_ASSERT_APPKIT_THREAD;

    self.isMinimizing = YES;

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        GET_CPLATFORM_WINDOW_CLASS();
        DECLARE_METHOD(jm_windowWillMiniaturize, jc_CPlatformWindow, "windowWillMiniaturize", "()V");
        (*env)->CallVoidMethod(env, platformWindow, jm_windowWillMiniaturize);
        CHECK_EXCEPTION();
        (*env)->DeleteLocalRef(env, platformWindow);
    }
    // Explicitly make myself a key window to avoid possible
    // negative visual effects during iconify operation
    [self.nsWindow makeKeyAndOrderFront:self.nsWindow];
    [self iconifyChildWindows:YES];
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
AWT_ASSERT_APPKIT_THREAD;

    [self _deliverIconify:JNI_TRUE];
    self.isMinimizing = NO;
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
AWT_ASSERT_APPKIT_THREAD;

    [self _deliverIconify:JNI_FALSE];
    [self iconifyChildWindows:NO];
}

- (void) _deliverWindowFocusEvent:(BOOL)focused oppositeWindow:(AWTWindow *)opposite {
//AWT_ASSERT_APPKIT_THREAD;
    JNIEnv *env = [ThreadUtilities getJNIEnvUncached];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        jobject oppositeWindow = (*env)->NewLocalRef(env, opposite.javaPlatformWindow);
        GET_CPLATFORM_WINDOW_CLASS();
        DECLARE_METHOD(jm_deliverWindowFocusEvent, jc_CPlatformWindow, "deliverWindowFocusEvent", "(ZLsun/lwawt/macosx/CPlatformWindow;)V");
        (*env)->CallVoidMethod(env, platformWindow, jm_deliverWindowFocusEvent, (jboolean)focused, oppositeWindow);
        CHECK_EXCEPTION();
        (*env)->DeleteLocalRef(env, platformWindow);
        (*env)->DeleteLocalRef(env, oppositeWindow);
    }
}

- (void) windowDidBecomeMain: (NSNotification *) notification {
AWT_ASSERT_APPKIT_THREAD;
    [AWTToolkit eventCountPlusPlus];
#ifdef DEBUG
    NSLog(@"became main: %d %@ %@", [self.nsWindow isKeyWindow], [self.nsWindow title], [self menuBarForWindow]);
#endif

    [self activateWindowMenuBar];

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        GET_CPLATFORM_WINDOW_CLASS();
        DECLARE_METHOD(jm_windowDidBecomeMain, jc_CPlatformWindow, "windowDidBecomeMain", "()V");
        (*env)->CallVoidMethod(env, platformWindow, jm_windowDidBecomeMain);
        CHECK_EXCEPTION();
        (*env)->DeleteLocalRef(env, platformWindow);
    }

    [self orderChildWindows:YES];
}

- (void) windowDidBecomeKey: (NSNotification *) notification {
AWT_ASSERT_APPKIT_THREAD;
    [AWTToolkit eventCountPlusPlus];
#ifdef DEBUG
    NSLog(@"became key: %d %@ %@", [self.nsWindow isMainWindow], [self.nsWindow title], [self menuBarForWindow]);
#endif
    AWTWindow *opposite = [AWTWindow lastKeyWindow];

    if (![self.nsWindow isMainWindow]) {
        [self makeRelevantAncestorMain];
    }

    [AWTWindow setLastKeyWindow:nil];

    [self _deliverWindowFocusEvent:YES oppositeWindow: opposite];
}

- (void) makeRelevantAncestorMain {
    NSWindow *nativeWindow;
    AWTWindow *awtWindow = self;

    do {
        nativeWindow = awtWindow.nsWindow;
        if ([nativeWindow canBecomeMainWindow]) {
            [nativeWindow makeMainWindow];
            break;
        }
        awtWindow = awtWindow.ownerWindow;
    } while (awtWindow);
}

- (void) activateWindowMenuBar {
AWT_ASSERT_APPKIT_THREAD;
    // Finds appropriate menubar in our hierarchy
    AWTWindow *awtWindow = self;
    while (awtWindow.ownerWindow != nil) {
        awtWindow = awtWindow.ownerWindow;
    }

    CMenuBar *menuBar = nil;
    BOOL isDisabled = NO;
    if ([awtWindow.nsWindow isVisible]){
        menuBar = awtWindow.javaMenuBar;
        isDisabled = !awtWindow.isEnabled;
    }

    if (menuBar == nil) {
        menuBar = [[ApplicationDelegate sharedDelegate] defaultMenuBar];
        isDisabled = NO;
    }

    [CMenuBar activate:menuBar modallyDisabled:isDisabled];
}

#ifdef DEBUG
- (CMenuBar *) menuBarForWindow {
AWT_ASSERT_APPKIT_THREAD;
    AWTWindow *awtWindow = self;
    while (awtWindow.ownerWindow != nil) {
        awtWindow = awtWindow.ownerWindow;
    }
    return awtWindow.javaMenuBar;
}
#endif

- (void) windowDidResignKey: (NSNotification *) notification {
    // TODO: check why sometimes at start is invoked *not* on AppKit main thread.
AWT_ASSERT_APPKIT_THREAD;
    [AWTToolkit eventCountPlusPlus];
#ifdef DEBUG
    NSLog(@"resigned key: %d %@ %@", [self.nsWindow isMainWindow], [self.nsWindow title], [self menuBarForWindow]);
#endif
    if (![self.nsWindow isMainWindow] || [NSApp keyWindow] == self.nsWindow) {
        [self deactivateWindow];
    }
}

- (void) windowDidResignMain: (NSNotification *) notification {
AWT_ASSERT_APPKIT_THREAD;
    [AWTToolkit eventCountPlusPlus];
#ifdef DEBUG
    NSLog(@"resigned main: %d %@ %@", [self.nsWindow isKeyWindow], [self.nsWindow title], [self menuBarForWindow]);
#endif
    if (![self.nsWindow isKeyWindow]) {
        [self deactivateWindow];
    }

    [self.javaMenuBar deactivate];
    [self orderChildWindows:NO];
}

- (void) deactivateWindow {
AWT_ASSERT_APPKIT_THREAD;
#ifdef DEBUG
    NSLog(@"deactivating window: %@", [self.nsWindow title]);
#endif

    // the new key window
    NSWindow *keyWindow = [NSApp keyWindow];
    AWTWindow *opposite = nil;
    if ([AWTWindow isAWTWindow: keyWindow]) {
        if (keyWindow != self.nsWindow) {
            opposite = (AWTWindow *)[keyWindow delegate];
        }
        [AWTWindow setLastKeyWindow: self];
    } else {
        [AWTWindow setLastKeyWindow: nil];
    }

    [self _deliverWindowFocusEvent:NO oppositeWindow: opposite];
}

- (BOOL)windowShouldClose:(id)sender {
AWT_ASSERT_APPKIT_THREAD;
    [AWTToolkit eventCountPlusPlus];
    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        GET_CPLATFORM_WINDOW_CLASS_RETURN(NO);
        DECLARE_METHOD_RETURN(jm_deliverWindowClosingEvent, jc_CPlatformWindow, "deliverWindowClosingEvent", "()V", NO);
        (*env)->CallVoidMethod(env, platformWindow, jm_deliverWindowClosingEvent);
        CHECK_EXCEPTION();
        (*env)->DeleteLocalRef(env, platformWindow);
    }
    // The window will be closed (if allowed) as result of sending Java event
    return NO;
}

- (void)_notifyFullScreenOp:(jint)op withEnv:(JNIEnv *)env {
    DECLARE_CLASS(jc_FullScreenHandler, "com/apple/eawt/FullScreenHandler");
    DECLARE_STATIC_METHOD(jm_notifyFullScreenOperation, jc_FullScreenHandler,
                           "handleFullScreenEventFromNative", "(Ljava/awt/Window;I)V");
    GET_CPLATFORM_WINDOW_CLASS();
    DECLARE_FIELD(jf_target, jc_CPlatformWindow, "target", "Ljava/awt/Window;");
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        jobject awtWindow = (*env)->GetObjectField(env, platformWindow, jf_target);
        if (awtWindow != NULL) {
            (*env)->CallStaticVoidMethod(env, jc_FullScreenHandler, jm_notifyFullScreenOperation, awtWindow, op);
            CHECK_EXCEPTION();
            (*env)->DeleteLocalRef(env, awtWindow);
        }
        (*env)->DeleteLocalRef(env, platformWindow);
    }
}

// this is required to move owned windows to the full-screen space when owner goes to full-screen mode
- (void)allowMovingChildrenBetweenSpaces:(BOOL)allow {
    [self processVisibleChildren:^void(AWTWindow* child){
        NSWindow *window = child.nsWindow;
        NSWindowCollectionBehavior behavior = window.collectionBehavior;
        behavior &= ~(NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorTransient);
        behavior |= allow ? NSWindowCollectionBehaviorTransient : NSWindowCollectionBehaviorManaged;
        window.collectionBehavior = behavior;
    }];
}

- (void) fullScreenTransitionStarted {
    fullScreenTransitionInProgress = YES;
}

- (void) fullScreenTransitionFinished {
    fullScreenTransitionInProgress = NO;
    if (orderingScheduled) {
        orderingScheduled = NO;
        [self checkBlockingAndOrder];
    }
}

- (BOOL) isTransparentTitleBarEnabled
{
    return _transparentTitleBarHeight != 0.0;
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    [self fullScreenTransitionStarted];
    [self allowMovingChildrenBetweenSpaces:YES];

    self.isEnterFullScreen = YES;

    if ([self isTransparentTitleBarEnabled]) {
        [self resetTitleBar];
    }

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    GET_CPLATFORM_WINDOW_CLASS();
    DECLARE_METHOD(jm_windowWillEnterFullScreen, jc_CPlatformWindow, "windowWillEnterFullScreen", "()V");
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        (*env)->CallVoidMethod(env, platformWindow, jm_windowWillEnterFullScreen);
        CHECK_EXCEPTION();
        [self _notifyFullScreenOp:com_apple_eawt_FullScreenHandler_FULLSCREEN_WILL_ENTER withEnv:env];
        (*env)->DeleteLocalRef(env, platformWindow);
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    self.isEnterFullScreen = YES;

    [self allowMovingChildrenBetweenSpaces:NO];
    [self fullScreenTransitionFinished];

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    GET_CPLATFORM_WINDOW_CLASS();
    DECLARE_METHOD(jm_windowDidEnterFullScreen, jc_CPlatformWindow, "windowDidEnterFullScreen", "()V");
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        (*env)->CallVoidMethod(env, platformWindow, jm_windowDidEnterFullScreen);
        CHECK_EXCEPTION();
        [self _notifyFullScreenOp:com_apple_eawt_FullScreenHandler_FULLSCREEN_DID_ENTER withEnv:env];
        (*env)->DeleteLocalRef(env, platformWindow);
    }
    [AWTWindow synthesizeMouseEnteredExitedEventsForAllWindows];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
    self.isEnterFullScreen = NO;

    [self fullScreenTransitionStarted];

    if ([self isTransparentTitleBarEnabled]) {
        [self setWindowControlsHidden:YES];
    }

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    GET_CPLATFORM_WINDOW_CLASS();
    DECLARE_METHOD(jm_windowWillExitFullScreen, jc_CPlatformWindow, "windowWillExitFullScreen", "()V");
    if (jm_windowWillExitFullScreen == NULL) {
        GET_CPLATFORM_WINDOW_CLASS();
        jm_windowWillExitFullScreen = (*env)->GetMethodID(env, jc_CPlatformWindow, "windowWillExitFullScreen", "()V");
    }
    CHECK_NULL(jm_windowWillExitFullScreen);
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        (*env)->CallVoidMethod(env, platformWindow, jm_windowWillExitFullScreen);
        CHECK_EXCEPTION();
        [self _notifyFullScreenOp:com_apple_eawt_FullScreenHandler_FULLSCREEN_WILL_EXIT withEnv:env];
        (*env)->DeleteLocalRef(env, platformWindow);
    }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    self.isEnterFullScreen = NO;

    [self fullScreenTransitionFinished];

    if ([self isTransparentTitleBarEnabled]) {
        [self setUpTransparentTitleBar];
        [self setWindowControlsHidden:NO];
    }

    JNIEnv *env = [ThreadUtilities getJNIEnv];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        GET_CPLATFORM_WINDOW_CLASS();
        DECLARE_METHOD(jm_windowDidExitFullScreen, jc_CPlatformWindow, "windowDidExitFullScreen", "()V");
        (*env)->CallVoidMethod(env, platformWindow, jm_windowDidExitFullScreen);
        CHECK_EXCEPTION();
        [self _notifyFullScreenOp:com_apple_eawt_FullScreenHandler_FULLSCREEN_DID_EXIT withEnv:env];
        (*env)->DeleteLocalRef(env, platformWindow);
    }
    [AWTWindow synthesizeMouseEnteredExitedEventsForAllWindows];
}

- (void)sendEvent:(NSEvent *)event {
        if ([event type] == NSLeftMouseDown || [event type] == NSRightMouseDown || [event type] == NSOtherMouseDown) {
            NSPoint p = [NSEvent mouseLocation];
            NSRect frame = [self.nsWindow frame];
            NSRect contentRect = [self.nsWindow contentRectForFrameRect:frame];

            // Check if the click happened in the non-client area (title bar)
            if (p.y >= (frame.origin.y + contentRect.size.height)) {
                JNIEnv *env = [ThreadUtilities getJNIEnvUncached];
                jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
                if (platformWindow != NULL) {
                    // Currently, no need to deliver the whole NSEvent.
                    GET_CPLATFORM_WINDOW_CLASS();
                    DECLARE_METHOD(jm_deliverNCMouseDown, jc_CPlatformWindow, "deliverNCMouseDown", "()V");
                    (*env)->CallVoidMethod(env, platformWindow, jm_deliverNCMouseDown);
                    CHECK_EXCEPTION();
                    (*env)->DeleteLocalRef(env, platformWindow);
                }
            }
        }
}

- (void)constrainSize:(NSSize*)size {
    float minWidth = 0.f, minHeight = 0.f;

    if (IS(self.styleBits, DECORATED)) {
        NSRect frame = [self.nsWindow frame];
        NSRect contentRect = [NSWindow contentRectForFrameRect:frame styleMask:[self.nsWindow styleMask]];

        float top = frame.size.height - contentRect.size.height;
        float left = contentRect.origin.x - frame.origin.x;
        float bottom = contentRect.origin.y - frame.origin.y;
        float right = frame.size.width - (contentRect.size.width + left);

        // Speculative estimation: 80 - enough for window decorations controls
        minWidth += left + right + 80;
        minHeight += top + bottom;
    }

    minWidth = MAX(1.f, minWidth);
    minHeight = MAX(1.f, minHeight);

    size->width = MAX(size->width, minWidth);
    size->height = MAX(size->height, minHeight);
}

- (void) setEnabled: (BOOL)flag {
    self.isEnabled = flag;

    if (IS(self.styleBits, CLOSEABLE)) {
        [[self.nsWindow standardWindowButton:NSWindowCloseButton] setEnabled: flag];
    }

    if (IS(self.styleBits, MINIMIZABLE)) {
        [[self.nsWindow standardWindowButton:NSWindowMiniaturizeButton] setEnabled: flag];
    }

    if (IS(self.styleBits, ZOOMABLE)) {
        [[self.nsWindow standardWindowButton:NSWindowZoomButton] setEnabled: flag];
    }

    if (IS(self.styleBits, RESIZABLE)) {
        [self updateMinMaxSize:flag];
        [self.nsWindow setShowsResizeIndicator:flag];
    }
}

+ (void) setLastKeyWindow:(AWTWindow *)window {
    [window retain];
    [lastKeyWindow release];
    lastKeyWindow = window;
}

+ (AWTWindow *) lastKeyWindow {
    return lastKeyWindow;
}

static const CGFloat DefaultHorizontalTitleBarButtonOffset = 20.0;

- (CGFloat) getTransparentTitleBarButtonShrinkingFactor
{
    CGFloat minimumHeightWithoutShrinking = 28.0; // This is the smallest macOS title bar availabe with public APIs as of Monterey
    CGFloat shrinkingFactor = fmin(_transparentTitleBarHeight / minimumHeightWithoutShrinking, 1.0);
    return shrinkingFactor;
}

- (void) setUpTransparentTitleBar
{

    /**
     * The view hierarchy normally looks as follows:
     * NSThemeFrame
     * ├─NSView (content view)
     * └─NSTitlebarContainerView
     *   ├─_NSTitlebarDecorationView (only on Mojave 10.14 and newer)
     *   └─NSTitlebarView
     *     ├─NSVisualEffectView (only on Big Sur 11 and newer)
     *     ├─NSView (only on Big Sur and newer)
     *     ├─_NSThemeCloseWidget - Close
     *     ├─_NSThemeZoomWidget - Full Screen
     *     ├─_NSThemeWidget - Minimize (note the different order compared to their layout)
     *     └─AWTWindowDragView (we will create this)
     *
     * But the order and presence of decorations and effects has been unstable across different macOS versions,
     * even patch upgrades, which is why the code below uses scans instead of indexed access
     */
    NSView* closeButtonView = [self.nsWindow standardWindowButton:NSWindowCloseButton];
    NSView* zoomButtonView = [self.nsWindow standardWindowButton:NSWindowZoomButton];
    NSView* miniaturizeButtonView = [self.nsWindow standardWindowButton:NSWindowMiniaturizeButton];
    if (!closeButtonView || !zoomButtonView || !miniaturizeButtonView) {
        NSLog(@"WARNING: setUpTransparentTitleBar closeButtonView=%@, zoomButtonView=%@, miniaturizeButtonView=%@",
              closeButtonView, zoomButtonView, miniaturizeButtonView);
        return;
    }
    NSView* titlebar = closeButtonView.superview;
    NSView* titlebarContainer = titlebar.superview;
    NSView* themeFrame = titlebarContainer.superview;
    if (!themeFrame) {
        NSLog(@"WARNING: setUpTransparentTitleBar titlebar=%@, titlebarContainer=%@, themeFrame=%@",
              titlebar, titlebarContainer, themeFrame);
        return;
    }

    _transparentTitleBarConstraints = [[NSMutableArray alloc] init];
    titlebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _transparentTitleBarHeightConstraint = [titlebarContainer.heightAnchor constraintEqualToConstant:_transparentTitleBarHeight];
    [_transparentTitleBarConstraints addObjectsFromArray:@[
        [titlebarContainer.leftAnchor constraintEqualToAnchor:themeFrame.leftAnchor],
        [titlebarContainer.widthAnchor constraintEqualToAnchor:themeFrame.widthAnchor],
        [titlebarContainer.topAnchor constraintEqualToAnchor:themeFrame.topAnchor],
        _transparentTitleBarHeightConstraint,
    ]];

    AWTWindowDragView* windowDragView = [[AWTWindowDragView alloc] initWithPlatformWindow:self.javaPlatformWindow];
    [titlebar addSubview:windowDragView positioned:NSWindowBelow relativeTo:closeButtonView];

    NSArray* viewsToStretch = [titlebarContainer.subviews arrayByAddingObject:windowDragView];
    for (NSView* view in viewsToStretch)
    {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [_transparentTitleBarConstraints addObjectsFromArray:@[
            [view.leftAnchor constraintEqualToAnchor:titlebarContainer.leftAnchor],
            [view.rightAnchor constraintEqualToAnchor:titlebarContainer.rightAnchor],
            [view.topAnchor constraintEqualToAnchor:titlebarContainer.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:titlebarContainer.bottomAnchor],
        ]];
    }

    for(NSView* view in titlebar.subviews)
    {
        view.translatesAutoresizingMaskIntoConstraints = NO;
    }

    CGFloat shrinkingFactor = [self getTransparentTitleBarButtonShrinkingFactor];
    CGFloat horizontalButtonOffset = shrinkingFactor * DefaultHorizontalTitleBarButtonOffset;
    _transparentTitleBarButtonCenterXConstraints = [[NSMutableArray alloc] initWithCapacity:3];
    [@[closeButtonView, miniaturizeButtonView, zoomButtonView] enumerateObjectsUsingBlock:^(NSView* button, NSUInteger index, BOOL* stop)
    {
        NSLayoutConstraint* buttonCenterXConstraint = [button.centerXAnchor constraintEqualToAnchor:titlebarContainer.leftAnchor constant:(_transparentTitleBarHeight/2.0 + (index * horizontalButtonOffset))];
        [_transparentTitleBarButtonCenterXConstraints addObject:buttonCenterXConstraint];
        [_transparentTitleBarConstraints addObjectsFromArray:@[
            [button.widthAnchor constraintLessThanOrEqualToAnchor:titlebarContainer.heightAnchor multiplier:0.5],
            // Those corrections are required to keep the icons perfectly round because macOS adds a constant 2 px in resulting height to their frame
            [button.heightAnchor constraintEqualToAnchor: button.widthAnchor multiplier:14.0/12.0 constant:-2.0],
            [button.centerYAnchor constraintEqualToAnchor:titlebarContainer.centerYAnchor],
            buttonCenterXConstraint,
        ]];
    }];

    [NSLayoutConstraint activateConstraints:_transparentTitleBarConstraints];
}

- (void) updateTransparentTitleBarConstraints
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        _transparentTitleBarHeightConstraint.constant = _transparentTitleBarHeight;
        CGFloat shrinkingFactor = [self getTransparentTitleBarButtonShrinkingFactor];
        CGFloat horizontalButtonOffset = shrinkingFactor * DefaultHorizontalTitleBarButtonOffset;
        [_transparentTitleBarButtonCenterXConstraints enumerateObjectsUsingBlock:^(NSLayoutConstraint* buttonConstraint, NSUInteger index, BOOL *stop)
        {
            buttonConstraint.constant = (_transparentTitleBarHeight/2.0 + (index * horizontalButtonOffset));
        }];
    });
}

- (void) resetTitleBar
{
    // See [setUpTransparentTitleBar] for the view hierarchy we're working with
    NSView* closeButtonView = [self.nsWindow standardWindowButton:NSWindowCloseButton];
    NSView* titlebar = closeButtonView.superview;
    NSView* titlebarContainer = titlebar.superview;
    if (!titlebarContainer) {
        NSLog(@"WARNING: resetTitleBar closeButtonView=%@, titlebar=%@, titlebarContainer=%@",
              closeButtonView, titlebar, titlebarContainer);
        return;
    }

    [NSLayoutConstraint deactivateConstraints:_transparentTitleBarConstraints];

    AWTWindowDragView* windowDragView = nil;
    for (NSView* view in [titlebar.subviews arrayByAddingObjectsFromArray:titlebarContainer.subviews]) {
        if ([view isMemberOfClass:[AWTWindowDragView class]]) {
            windowDragView = view;
        }
        if (view.translatesAutoresizingMaskIntoConstraints == NO) {
            view.translatesAutoresizingMaskIntoConstraints = YES;
        }
    }

    if (windowDragView != nil) {
        [windowDragView removeFromSuperview];
    }

    titlebarContainer.translatesAutoresizingMaskIntoConstraints = YES;
    titlebar.translatesAutoresizingMaskIntoConstraints = YES;

    _transparentTitleBarConstraints = nil;
    _transparentTitleBarHeightConstraint = nil;
    _transparentTitleBarButtonCenterXConstraints = nil;
}

- (void) setWindowControlsHidden: (BOOL) hidden
{
    [self.nsWindow standardWindowButton:NSWindowCloseButton].superview.hidden = hidden;
}

- (BOOL) isFullScreen
{
    NSUInteger masks = [self.nsWindow styleMask];
    return (masks & NSWindowStyleMaskFullScreen) != 0;
}

- (void) setTransparentTitleBarHeight: (CGFloat) transparentTitleBarHeight
{
    if (_transparentTitleBarHeight == transparentTitleBarHeight) return;

    if (_transparentTitleBarHeight != 0.0f) {
        _transparentTitleBarHeight = transparentTitleBarHeight;
        if (transparentTitleBarHeight == 0.0f) {
            if (!self.isFullScreen) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self resetTitleBar];
                });
            }
        } else if (_transparentTitleBarHeightConstraint != nil || _transparentTitleBarButtonCenterXConstraints != nil) {
            [self updateTransparentTitleBarConstraints];
        }
    } else {
        _transparentTitleBarHeight = transparentTitleBarHeight;
        if (!self.isFullScreen) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self setUpTransparentTitleBar];
            });
        }
    }
}

@end // AWTWindow

@implementation AWTWindowDragView {
    CGFloat _accumulatedDragDelta;
    enum WindowDragState {
        NO_DRAG,   // Mouse not dragging
        SKIP_DRAG, // Mouse dragging in non-draggable area
        DRAG,      // Mouse is dragging window
    } _draggingWindow;
}

- (id) initWithPlatformWindow:(jobject)javaPlatformWindow {
    self = [super init];
    if (self == nil) return nil; // no hope

    self.javaPlatformWindow = javaPlatformWindow;
    return self;
}

- (BOOL)mouseDownCanMoveWindow
{
    return NO;
}

- (jint)hitTestCustomDecoration:(NSPoint)point
{
    jint returnValue = java_awt_Window_CustomWindowDecoration_NO_HIT_SPOT;
    JNIEnv *env = [ThreadUtilities getJNIEnvUncached];
    jobject platformWindow = (*env)->NewLocalRef(env, self.javaPlatformWindow);
    if (platformWindow != NULL) {
        GET_CPLATFORM_WINDOW_CLASS_RETURN(YES);
        DECLARE_FIELD_RETURN(jf_target, jc_CPlatformWindow, "target", "Ljava/awt/Window;", YES);
        DECLARE_CLASS_RETURN(jc_Window, "java/awt/Window", YES);
        DECLARE_METHOD_RETURN(jm_hitTestCustomDecoration, jc_Window, "hitTestCustomDecoration", "(II)I", YES);
        jobject awtWindow = (*env)->GetObjectField(env, platformWindow, jf_target);
        if (awtWindow != NULL) {
            NSRect frame = [self.window frame];
            float windowHeight = frame.size.height;
            returnValue = (*env)->CallIntMethod(env, awtWindow, jm_hitTestCustomDecoration, (jint) point.x,  (jint) (windowHeight - point.y));
            CHECK_EXCEPTION();
            (*env)->DeleteLocalRef(env, awtWindow);
        }
        (*env)->DeleteLocalRef(env, platformWindow);
    }
    return returnValue;
}

- (void)mouseDown:(NSEvent *)event
{
    _draggingWindow = NO_DRAG;
    _accumulatedDragDelta = 0.0;
    // We don't follow the regular responder chain here since the native window swallows events in some cases
    [[self.window contentView] deliverJavaMouseEvent:event];
}

- (void)mouseDragged:(NSEvent *)event
{
    if (_draggingWindow == NO_DRAG) {
        jint hitSpot = [self hitTestCustomDecoration:event.locationInWindow];
        switch (hitSpot) {
            case java_awt_Window_CustomWindowDecoration_DRAGGABLE_AREA:
                // Start drag only after 4px threshold inside DRAGGABLE_AREA
                if ((_accumulatedDragDelta += fabs(event.deltaX) + fabs(event.deltaY)) <= 4.0) break;
            case java_awt_Window_CustomWindowDecoration_NO_HIT_SPOT:
                [self.window performWindowDragWithEvent:event];
                _draggingWindow = DRAG;
                break;
            default:
                _draggingWindow = SKIP_DRAG;
        }
    }
}

- (void)mouseUp:(NSEvent *)event
{
    if (_draggingWindow == DRAG) {
        _draggingWindow = NO_DRAG;
    } else {
        jint hitSpot = [self hitTestCustomDecoration:event.locationInWindow];
        if (event.clickCount == 2 && hitSpot == java_awt_Window_CustomWindowDecoration_NO_HIT_SPOT) {
            if ([[[NSUserDefaults standardUserDefaults] stringForKey:@"AppleActionOnDoubleClick"] isEqualToString:@"Maximize"]) {
                [self.window performZoom:nil];
            } else {
                [self.window performMiniaturize:nil];
            }
        }

        // We don't follow the regular responder chain here since the native window swallows events in some cases
        [[self.window contentView] deliverJavaMouseEvent:event];
    }
}

@end

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetAllAllowAutomaticTabbingProperty
 * Signature: (Z)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetAllowAutomaticTabbingProperty
        (JNIEnv *env, jclass clazz, jboolean allowAutomaticTabbing)
{
    JNI_COCOA_ENTER(env);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        if (allowAutomaticTabbing) {
            [NSWindow setAllowsAutomaticWindowTabbing:YES];
        } else {
            [NSWindow setAllowsAutomaticWindowTabbing:NO];
        }
    }];
    JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeCreateNSWindow
 * Signature: (JJIDDDDD)J
 */
JNIEXPORT jlong JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeCreateNSWindow
(JNIEnv *env, jobject obj, jlong contentViewPtr, jlong ownerPtr, jlong styleBits, jdouble x, jdouble y, jdouble w, jdouble h, jdouble transparentTitleBarHeight)
{
    __block AWTWindow *window = nil;

JNI_COCOA_ENTER(env);

    jobject platformWindow = (*env)->NewWeakGlobalRef(env, obj);
    NSView *contentView = OBJC(contentViewPtr);
    NSRect frameRect = NSMakeRect(x, y, w, h);
    AWTWindow *owner = [OBJC(ownerPtr) delegate];

    BOOL isIgnoreMouseEvents = NO;
    GET_CPLATFORM_WINDOW_CLASS_RETURN(0);
    DECLARE_FIELD_RETURN(jf_target, jc_CPlatformWindow, "target", "Ljava/awt/Window;", 0);
    jobject awtWindow = (*env)->GetObjectField(env, obj, jf_target);
    if (awtWindow != NULL) {
        DECLARE_CLASS_RETURN(jc_Window, "java/awt/Window", 0);
        DECLARE_METHOD_RETURN(jm_isIgnoreMouseEvents, jc_Window, "isIgnoreMouseEvents", "()Z", 0);
        isIgnoreMouseEvents = (*env)->CallBooleanMethod(env, awtWindow, jm_isIgnoreMouseEvents) == JNI_TRUE ? YES : NO;
        (*env)->DeleteLocalRef(env, awtWindow);
    }
    [ThreadUtilities performOnMainThreadWaiting:YES block:^(){

        window = [[AWTWindow alloc] initWithPlatformWindow:platformWindow
                                               ownerWindow:owner
                                                 styleBits:styleBits
                                                 frameRect:frameRect
                                               contentView:contentView
                                 transparentTitleBarHeight:(CGFloat)transparentTitleBarHeight];
        // the window is released is CPlatformWindow.nativeDispose()

        if (window) {
            [window.nsWindow retain];
            if (isIgnoreMouseEvents) {
                [window.nsWindow setIgnoresMouseEvents:YES];
            }
        }
    }];

JNI_COCOA_EXIT(env);

    return ptr_to_jlong(window ? window.nsWindow : nil);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowStyleBits
 * Signature: (JII)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowStyleBits
(JNIEnv *env, jclass clazz, jlong windowPtr, jint mask, jint bits)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);

    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){

        AWTWindow *window = (AWTWindow*)[nsWindow delegate];

        // scans the bit field, and only updates the values requested by the mask
        // (this implicitly handles the _CALLBACK_PROP_BITMASK case, since those are passive reads)
        jint newBits = window.styleBits & ~mask | bits & mask;

        BOOL resized = NO;

        // Check for a change to the full window content view option.
        // The content view must be resized first, otherwise the window will be resized to fit the existing
        // content view.
        if (IS(mask, FULL_WINDOW_CONTENT)) {
            if (IS(newBits, FULL_WINDOW_CONTENT) != IS(window.styleBits, FULL_WINDOW_CONTENT)) {
                NSRect frame = [nsWindow frame];
                NSUInteger styleMask = [AWTWindow styleMaskForStyleBits:newBits];
                NSRect screenContentRect = [NSWindow contentRectForFrameRect:frame styleMask:styleMask];
                NSRect contentFrame = NSMakeRect(screenContentRect.origin.x - frame.origin.x,
                    screenContentRect.origin.y - frame.origin.y,
                    screenContentRect.size.width,
                    screenContentRect.size.height);
                nsWindow.contentView.frame = contentFrame;
                resized = YES;
            }
            if (window.isJustCreated) {
                // Perform Move/Resize event for just created windows
                resized = YES;
                window.isJustCreated = NO;
            }
        }

        // resets the NSWindow's style mask if the mask intersects any of those bits
        if (mask & MASK(_STYLE_PROP_BITMASK)) {
            NSWindowStyleMask styleMask = [AWTWindow styleMaskForStyleBits:newBits];
            NSWindowStyleMask curMask = nsWindow.styleMask;
            // NSWindowStyleMaskFullScreen bit shouldn't be updated directly
            [nsWindow setStyleMask:(styleMask & ~NSWindowStyleMaskFullScreen | curMask & NSWindowStyleMaskFullScreen)];
        }

        // calls methods on NSWindow to change other properties, based on the mask
        if (mask & MASK(_METHOD_PROP_BITMASK)) {
            [window setPropertiesForStyleBits:newBits mask:mask];
        }

        window.styleBits = newBits;

        NSString *uiStyle = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];

        if (resized) {
            [window _deliverMoveResizeEvent];
        }
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowAppearance
 * Signature: (JLjava/lang/String;)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowAppearance
        (JNIEnv *env, jclass clazz, jlong windowPtr,  jstring appearanceName)
{
    JNI_COCOA_ENTER(env);

        NSWindow *nsWindow = OBJC(windowPtr);
        // create a global-ref around the appearanceName, so it can be safely passed to Main thread
        jobject appearanceNameRef= (*env)->NewGlobalRef(env, appearanceName);

        [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
           // attach the dispatch thread to the JVM if necessary, and get an env
            JNIEnv*      blockEnv = [ThreadUtilities getJNIEnvUncached];
            NSAppearance* appearance = [NSAppearance appearanceNamed:
                                        JavaStringToNSString(blockEnv, appearanceNameRef)];
            if (appearance != NULL) {
                [nsWindow setAppearance:appearance];
            }
            (*blockEnv)->DeleteGlobalRef(blockEnv, appearanceNameRef);
        }];

    JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowMenuBar
 * Signature: (JJ)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowMenuBar
(JNIEnv *env, jclass clazz, jlong windowPtr, jlong menuBarPtr)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    CMenuBar *menuBar = OBJC(menuBarPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){

        AWTWindow *window = (AWTWindow*)[nsWindow delegate];

        if ([nsWindow isMainWindow]) {
            [window.javaMenuBar deactivate];
        }

        window.javaMenuBar = menuBar;

        CMenuBar* actualMenuBar = menuBar;
        if (actualMenuBar == nil) {
            actualMenuBar = [[ApplicationDelegate sharedDelegate] defaultMenuBar];
        }

        if ([nsWindow isMainWindow]) {
            [CMenuBar activate:actualMenuBar modallyDisabled:NO];
        }
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeGetNSWindowInsets
 * Signature: (J)Ljava/awt/Insets;
 */
JNIEXPORT jobject JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeGetNSWindowInsets
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
    jobject ret = NULL;

JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    __block NSRect contentRect = NSZeroRect;
    __block NSRect frame = NSZeroRect;

    [ThreadUtilities performOnMainThreadWaiting:YES block:^(){

        frame = [nsWindow frame];
        contentRect = [NSWindow contentRectForFrameRect:frame styleMask:[nsWindow styleMask]];
    }];

    jint top = (jint)(frame.size.height - contentRect.size.height);
    jint left = (jint)(contentRect.origin.x - frame.origin.x);
    jint bottom = (jint)(contentRect.origin.y - frame.origin.y);
    jint right = (jint)(frame.size.width - (contentRect.size.width + left));

    DECLARE_CLASS_RETURN(jc_Insets, "java/awt/Insets", NULL);
    DECLARE_METHOD_RETURN(jc_Insets_ctor, jc_Insets, "<init>", "(IIII)V", NULL);
    ret = (*env)->NewObject(env, jc_Insets, jc_Insets_ctor, top, left, bottom, right);

JNI_COCOA_EXIT(env);
    return ret;
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowBounds
 * Signature: (JDDDD)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowBounds
(JNIEnv *env, jclass clazz, jlong windowPtr, jdouble originX, jdouble originY, jdouble width, jdouble height)
{
JNI_COCOA_ENTER(env);

    NSRect jrect = NSMakeRect(originX, originY, width, height);

    // TODO: not sure we need displayIfNeeded message in our view
    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){

        AWTWindow *window = (AWTWindow*)[nsWindow delegate];

        NSRect rect = ConvertNSScreenRect(NULL, jrect);
        [window constrainSize:&rect.size];

        [nsWindow setFrame:rect display:YES];

        // only start tracking events if pointer is above the toplevel
        // TODO: should post an Entered event if YES.
        NSPoint mLocation = [NSEvent mouseLocation];
        [nsWindow setAcceptsMouseMovedEvents:NSPointInRect(mLocation, rect)];

        // ensure we repaint the whole window after the resize operation
        // (this will also re-enable screen updates, which were disabled above)
        // TODO: send PaintEvent

        // the macOS may ignore our "setFrame" request, in this, case the
        // windowDidMove() will not come and we need to manually resync the
        // "java.awt.Window" and NSWindow locations, because "java.awt.Window"
        // already uses location ignored by the macOS.
        // see sun.lwawt.LWWindowPeer#notifyReshape()
        if (!NSEqualRects(rect, [nsWindow frame])) {
            [window _deliverMoveResizeEvent];
        }
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowStandardFrame
 * Signature: (JDDDD)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowStandardFrame
(JNIEnv *env, jclass clazz, jlong windowPtr, jdouble originX, jdouble originY,
     jdouble width, jdouble height)
{
    JNI_COCOA_ENTER(env);

    NSRect jrect = NSMakeRect(originX, originY, width, height);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){

        NSRect rect = ConvertNSScreenRect(NULL, jrect);
        AWTWindow *window = (AWTWindow*)[nsWindow delegate];
        window.standardFrame = rect;
    }];

    JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowLocationByPlatform
 * Signature: (J)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowLocationByPlatform
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
    JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){

        if (NSEqualPoints(lastTopLeftPoint, NSZeroPoint)) {
            // This is the first usage of lastTopLeftPoint. So invoke cascadeTopLeftFromPoint
            // twice to avoid positioning the window's top left to zero-point, since it may
            // cause negative user experience.
            lastTopLeftPoint = [nsWindow cascadeTopLeftFromPoint:lastTopLeftPoint];
        }
        lastTopLeftPoint = [nsWindow cascadeTopLeftFromPoint:lastTopLeftPoint];
    }];

    JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowMinMax
 * Signature: (JDDDD)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowMinMax
(JNIEnv *env, jclass clazz, jlong windowPtr, jdouble minW, jdouble minH, jdouble maxW, jdouble maxH)
{
JNI_COCOA_ENTER(env);

    if (minW < 1) minW = 1;
    if (minH < 1) minH = 1;
    if (maxW < 1) maxW = 1;
    if (maxH < 1) maxH = 1;

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){

        AWTWindow *window = (AWTWindow*)[nsWindow delegate];

        NSSize min = { minW, minH };
        NSSize max = { maxW, maxH };

        [window constrainSize:&min];
        [window constrainSize:&max];

        window.javaMinSize = min;
        window.javaMaxSize = max;
        [window updateMinMaxSize:IS(window.styleBits, RESIZABLE)];
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativePushNSWindowToBack
 * Signature: (J)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativePushNSWindowToBack
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        [nsWindow orderBack:nil];
        // Order parent windows
        AWTWindow *awtWindow = (AWTWindow*)[nsWindow delegate];
        while (awtWindow.ownerWindow != nil) {
            awtWindow = awtWindow.ownerWindow;
            if ([AWTWindow isJavaPlatformWindowVisible:awtWindow.nsWindow]) {
                [awtWindow.nsWindow orderBack:nil];
            }
        }
        // Order child windows
        [(AWTWindow*)[nsWindow delegate] orderChildWindows:NO];
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativePushNSWindowToFront
 * Signature: (JZ)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativePushNSWindowToFront
(JNIEnv *env, jclass clazz, jlong windowPtr, jboolean wait)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:(BOOL)wait block:^(){

        if (![nsWindow isKeyWindow]) {
            [nsWindow makeKeyAndOrderFront:nsWindow];
        } else {
            [nsWindow orderFront:nsWindow];
        }
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeHideWindow
 * Signature: (JZ)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeHideWindow
(JNIEnv *env, jclass clazz, jlong windowPtr, jboolean wait)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:(BOOL)wait block:^(){
        if (nsWindow.keyWindow) {
            // When 'windowDidResignKey' is called during 'orderOut', current key window
            // is reported as 'nil', so it's impossible to create WINDOW_FOCUS_LOST event
            // with correct 'opposite' window.
            // So, as a workaround, we perform focus transfer to a parent window explicitly here.
            NSWindow *parentWindow = nsWindow;
            while ((parentWindow = ((AWTWindow*)parentWindow.delegate).ownerWindow.nsWindow) != nil) {
                if (parentWindow.canBecomeKeyWindow) {
                    [parentWindow makeKeyWindow];
                    break;
                }
            }
        }
        [nsWindow orderOut:nsWindow];
        [nsWindow close];
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowTitle
 * Signature: (JLjava/lang/String;)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowTitle
(JNIEnv *env, jclass clazz, jlong windowPtr, jstring jtitle)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [nsWindow performSelectorOnMainThread:@selector(setTitle:)
                              withObject:JavaStringToNSString(env, jtitle)
                           waitUntilDone:NO];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeRevalidateNSWindowShadow
 * Signature: (J)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeRevalidateNSWindowShadow
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        [nsWindow invalidateShadow];
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeScreenOn_AppKitThread
 * Signature: (J)I
 */
JNIEXPORT jint JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeScreenOn_1AppKitThread
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
    jint ret = 0;

JNI_COCOA_ENTER(env);
AWT_ASSERT_APPKIT_THREAD;

    NSWindow *nsWindow = OBJC(windowPtr);
    NSDictionary *props = [[nsWindow screen] deviceDescription];
    ret = [[props objectForKey:@"NSScreenNumber"] intValue];

JNI_COCOA_EXIT(env);

    return ret;
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowMinimizedIcon
 * Signature: (JJ)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowMinimizedIcon
(JNIEnv *env, jclass clazz, jlong windowPtr, jlong nsImagePtr)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    NSImage *image = OBJC(nsImagePtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        [nsWindow setMiniwindowImage:image];
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSetNSWindowRepresentedFilename
 * Signature: (JLjava/lang/String;)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetNSWindowRepresentedFilename
(JNIEnv *env, jclass clazz, jlong windowPtr, jstring filename)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    NSURL *url = (filename == NULL) ? nil : [NSURL fileURLWithPath:NormalizedPathNSStringFromJavaString(env, filename)];
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        [nsWindow setRepresentedURL:url];
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeGetTopmostPlatformWindowUnderMouse
 * Signature: (J)V
 */
JNIEXPORT jobject
JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeGetTopmostPlatformWindowUnderMouse
(JNIEnv *env, jclass clazz)
{
    __block jobject topmostWindowUnderMouse = nil;

    JNI_COCOA_ENTER(env);

    [ThreadUtilities performOnMainThreadWaiting:YES block:^{
        AWTWindow *awtWindow = [AWTWindow getTopmostWindowUnderMouse];
        if (awtWindow != nil) {
            topmostWindowUnderMouse = awtWindow.javaPlatformWindow;
        }
    }];

    JNI_COCOA_EXIT(env);

    return topmostWindowUnderMouse;
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSynthesizeMouseEnteredExitedEvents
 * Signature: ()V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSynthesizeMouseEnteredExitedEvents__
(JNIEnv *env, jclass clazz)
{
    JNI_COCOA_ENTER(env);

    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        [AWTWindow synthesizeMouseEnteredExitedEventsForAllWindows];
    }];

    JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeSynthesizeMouseEnteredExitedEvents
 * Signature: (JI)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSynthesizeMouseEnteredExitedEvents__JI
(JNIEnv *env, jclass clazz, jlong windowPtr, jint eventType)
{
JNI_COCOA_ENTER(env);

    if (eventType == NSMouseEntered || eventType == NSMouseExited) {
        NSWindow *nsWindow = OBJC(windowPtr);

        [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
            [AWTWindow synthesizeMouseEnteredExitedEvents:nsWindow withType:eventType];
        }];
    } else {
        JNU_ThrowIllegalArgumentException(env, "unknown event type");
    }

JNI_COCOA_EXIT(env);
}

// undocumented approach which avoids focus stealing
// and can be used full screen switch is in progress for another window
void enableFullScreenSpecial(NSWindow *nsWindow) {
    NSKeyedArchiver *coder = [[NSKeyedArchiver alloc] init];
    [nsWindow encodeRestorableStateWithCoder:coder];
    [coder encodeBool:YES forKey:@"NSIsFullScreen"];
    NSKeyedUnarchiver *decoder = [[NSKeyedUnarchiver alloc] initForReadingWithData:coder.encodedData];
    [nsWindow restoreStateWithCoder:decoder];
    [decoder finishDecoding];
    [decoder release];
    [coder release];
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    _toggleFullScreenMode
 * Signature: (J)V
 */
JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow__1toggleFullScreenMode
(JNIEnv *env, jobject peer, jlong windowPtr)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    SEL toggleFullScreenSelector = @selector(toggleFullScreen:);
    if (![nsWindow respondsToSelector:toggleFullScreenSelector]) return;

    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        static BOOL inProgress = NO;
        if ((nsWindow.styleMask & NSWindowStyleMaskFullScreen) != NSWindowStyleMaskFullScreen &&
            (inProgress || !NSApp.active)) {
            enableFullScreenSpecial(nsWindow);
            if ((nsWindow.styleMask & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen) return; // success
            // otherwise fall back to standard approach
        }
        BOOL savedValue = inProgress;
        inProgress = YES;
        [nsWindow performSelector:toggleFullScreenSelector withObject:nil];
        inProgress = savedValue;
    }];

JNI_COCOA_EXIT(env);
}

JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetEnabled
(JNIEnv *env, jclass clazz, jlong windowPtr, jboolean isEnabled)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        AWTWindow *window = (AWTWindow*)[nsWindow delegate];

        [window setEnabled: isEnabled];
    }];

JNI_COCOA_EXIT(env);
}

JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeDispose
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        AWTWindow *window = (AWTWindow*)[nsWindow delegate];

        if ([AWTWindow lastKeyWindow] == window) {
            [AWTWindow setLastKeyWindow: nil];
        }

        // AWTWindow holds a reference to the NSWindow in its nsWindow
        // property. Unsetting the delegate allows it to be deallocated
        // which releases the reference. This, in turn, allows the window
        // itself be deallocated.
        [nsWindow setDelegate: nil];

        [window release];

        ignoreResizeWindowDuringAnotherWindowEnd = NO;
    }];

JNI_COCOA_EXIT(env);
}

JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeEnterFullScreenMode
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        AWTWindow *window = (AWTWindow*)[nsWindow delegate];
        NSNumber* screenID = [AWTWindow getNSWindowDisplayID_AppKitThread: nsWindow];
        CGDirectDisplayID aID = [screenID intValue];

        if (CGDisplayCapture(aID) == kCGErrorSuccess) {
            // remove window decoration
            NSUInteger styleMask = [AWTWindow styleMaskForStyleBits:window.styleBits];
            [nsWindow setStyleMask:(styleMask & ~NSTitledWindowMask) | NSWindowStyleMaskBorderless];

            int shieldLevel = CGShieldingWindowLevel();
            window.preFullScreenLevel = [nsWindow level];
            [nsWindow setLevel: shieldLevel];

            NSRect screenRect = [[nsWindow screen] frame];
            [nsWindow setFrame:screenRect display:YES];
        } else {
            [NSException raise:@"Java Exception" reason:@"Failed to enter full screen." userInfo:nil];
        }
    }];

JNI_COCOA_EXIT(env);
}

JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeExitFullScreenMode
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        AWTWindow *window = (AWTWindow*)[nsWindow delegate];
        NSNumber* screenID = [AWTWindow getNSWindowDisplayID_AppKitThread: nsWindow];
        CGDirectDisplayID aID = [screenID intValue];

        if (CGDisplayRelease(aID) == kCGErrorSuccess) {
            NSUInteger styleMask = [AWTWindow styleMaskForStyleBits:window.styleBits];
            [nsWindow setStyleMask:styleMask];
            [nsWindow setLevel: window.preFullScreenLevel];

            // GraphicsDevice takes care of restoring pre full screen bounds
        } else {
            [NSException raise:@"Java Exception" reason:@"Failed to exit full screen." userInfo:nil];
        }
    }];

JNI_COCOA_EXIT(env);
}

JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeRaiseLevel
(JNIEnv *env, jclass clazz, jlong windowPtr, jboolean popup, jboolean onlyIfParentIsActive)
{
JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = OBJC(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        AWTWindow *window = (AWTWindow*)[nsWindow delegate];
        if (onlyIfParentIsActive) {
            AWTWindow *parent = window;
            do {
                parent = parent.ownerWindow;
            } while (parent != nil && !parent.nsWindow.isMainWindow);
            if (parent == nil) {
                return;
            }
        }
        [nsWindow setLevel: popup ? NSPopUpMenuWindowLevel : NSFloatingWindowLevel];
    }];

JNI_COCOA_EXIT(env);
}

/*
 * Class:     sun_lwawt_macosx_CPlatformWindow
 * Method:    nativeDelayShowing
 * Signature: (J)Z
 */
JNIEXPORT jboolean JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeDelayShowing
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
    __block jboolean result = JNI_FALSE;

    JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = (NSWindow *)jlong_to_ptr(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:YES block:^(){
        AWTWindow *window = (AWTWindow*)[nsWindow delegate];
        result = [window delayShowing];
    }];

    JNI_COCOA_EXIT(env);

    return result;
}


JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetTransparentTitleBarHeight
(JNIEnv *env, jclass clazz, jlong windowPtr, jfloat transparentTitleBarHeight)
{
    JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = (NSWindow *)jlong_to_ptr(windowPtr);
    AWTWindow *window = (AWTWindow*)[nsWindow delegate];
    [window setTransparentTitleBarHeight:((CGFloat) transparentTitleBarHeight)];

    JNI_COCOA_EXIT(env);
}

JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeCallDeliverMoveResizeEvent
(JNIEnv *env, jclass clazz, jlong windowPtr)
{
    JNI_COCOA_ENTER(env);

    NSWindow *nsWindow = (NSWindow *)jlong_to_ptr(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        AWTWindow *window = (AWTWindow*)[nsWindow delegate];
        [window _deliverMoveResizeEvent];
    }];

    JNI_COCOA_EXIT(env);
}

JNIEXPORT void JNICALL Java_sun_lwawt_macosx_CPlatformWindow_nativeSetRoundedCorners
(JNIEnv *env, jclass clazz, jlong windowPtr, jfloat radius)
{
    JNI_COCOA_ENTER(env);

    NSWindow *w = (NSWindow *)jlong_to_ptr(windowPtr);
    [ThreadUtilities performOnMainThreadWaiting:NO block:^(){
        w.hasShadow = YES;
        w.contentView.wantsLayer = YES;
        w.contentView.layer.cornerRadius = radius;
        w.contentView.layer.masksToBounds = YES;
        w.backgroundColor = NSColor.clearColor;
        w.opaque = NO;
        // remove corner radius animation
        [w.contentView.layer removeAllAnimations];
        [w invalidateShadow];
    }];

    JNI_COCOA_EXIT(env);
}
