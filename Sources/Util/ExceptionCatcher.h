#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Run `block`, converting any Objective-C NSException it raises into a returned NSError
/// (nil = no exception). Swift's `try` cannot catch ObjC exceptions — AVFAudio's
/// `installTapOnBus` raises one when the mic input format is invalid (no device / device
/// changed / already tapped), which would otherwise abort the whole app.
NSError * _Nullable zvonCatchNSException(void (NS_NOESCAPE ^ block)(void));

NS_ASSUME_NONNULL_END
