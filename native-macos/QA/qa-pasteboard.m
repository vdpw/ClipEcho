#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <fcntl.h>
#import <unistd.h>

// Loaded only into the separately identified original QA process. Clipboard
// reads and writes both use an isolated named pasteboard, never the user's one.
static id qaGeneralPasteboard(id self, SEL selector) {
    const char *name = getenv("CLIPECHO_QA_PASTEBOARD_NAME");
    NSString *pasteboardName = name ? [NSString stringWithUTF8String:name] : @"com.copy-stack.desktop.qa.synthetic";
    return [NSPasteboard pasteboardWithName:pasteboardName];
}

__attribute__((constructor)) static void installQAPasteboard(void) {
    if (!getenv("COPY_STACK_QA_DATA_DIR") || !getenv("CLIPECHO_QA_PASTEBOARD_NAME")) return;
    if (strcmp(getprogname(), "clip_echo") != 0) return;
    Method method = class_getClassMethod([NSPasteboard class], @selector(generalPasteboard));
    if (method) {
        method_setImplementation(method, (IMP)qaGeneralPasteboard);
        NSString *directory = [[NSString stringWithUTF8String:getenv("COPY_STACK_QA_DATA_DIR")] stringByDeletingLastPathComponent];
        NSString *marker = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"runtime/shim-active-%d", getpid()]];
        int descriptor = open(marker.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (descriptor >= 0) { write(descriptor, "named-pasteboard-only\n", sizeof("named-pasteboard-only\n") - 1); close(descriptor); }
    }
}
