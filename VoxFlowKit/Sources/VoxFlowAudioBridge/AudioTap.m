#import "VoxFlowAudioBridge.h"

BOOL VFInstallAudioTap(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount bufferSize,
                       AVAudioFormat *format, AVAudioNodeTapBlock block, NSError **error) {
    @try {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
        if (@available(macOS 27.0, *)) {
            return [node installTapOnBus:bus bufferSize:bufferSize format:format error:error block:block];
        }
#endif
        // Keep the macOS 15-compatible entry point when building with newer SDKs.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
#pragma clang diagnostic pop
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"dev.artemsem.voxflow.audio-tap" code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Microphone tap failed (%@): %@",
                        exception.name, exception.reason ?: @"Unknown audio engine exception"]}];
        }
        return NO;
    }
}
