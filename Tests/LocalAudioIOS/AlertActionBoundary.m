#import "AlertActionBoundary.h"
#import <objc/runtime.h>

// Observe the callback supplied to UIKit's PUBLIC factory while retaining the
// real UIKit action, alert presentation and shipping handler. No private alert
// selectors, KVC handler lookup or shipping-module substitutes are used.
static char actionCallbackKey;
BOOL QAInstallAlertActionBoundary(void) {
    static dispatch_once_t once;
    static BOOL installed = NO;
    dispatch_once(&once, ^{
        SEL selector = @selector(actionWithTitle:style:handler:);
        Method method = class_getClassMethod(UIAlertAction.class, selector);
        if (!method) return;
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^id(Class cls, NSString *title, UIAlertActionStyle style,
                                                           void (^handler)(UIAlertAction *)) {
            id action = ((id (*)(id, SEL, NSString *, UIAlertActionStyle, id))original)(cls, selector, title, style, handler);
            if (handler) objc_setAssociatedObject(action, &actionCallbackKey, handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
            return action;
        });
        method_setImplementation(method, replacement);
        installed = YES;
    });
    return installed;
}

BOOL QAActivateAlertAction(UIAlertAction *action) {
    void (^callback)(UIAlertAction *) = objc_getAssociatedObject(action, &actionCallbackKey);
    if (!action.isEnabled || !callback) return NO;
    callback(action);
    return YES;
}
