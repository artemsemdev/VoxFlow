#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Contains AVFAudio exceptions before they can unwind through Swift capture code.
BOOL VFInstallAudioTap(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount bufferSize,
                       AVAudioFormat * _Nullable format, AVAudioNodeTapBlock block,
                       NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
