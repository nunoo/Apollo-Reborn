#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloState.h"

static const void *kApolloDeletedCommentsFlairContainerKey = &kApolloDeletedCommentsFlairContainerKey;
static const void *kApolloDeletedCommentsFlairOriginalBackgroundKey = &kApolloDeletedCommentsFlairOriginalBackgroundKey;

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ApolloDeletedCommentsIsRecoveredFlairText(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;
    NSString *text = ApolloDeletedCommentsTrimmedString(attributedText.string);
    NSString *lower = [text lowercaseString];
    return [lower isEqualToString:@"deleted"] ||
           [lower isEqualToString:@"user deleted"] ||
           [lower isEqualToString:@"removed by mod"];
}

static UIColor *ApolloDeletedCommentsBadgeRed(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor systemRedColor];
    }
    return [UIColor redColor];
}

static NSAttributedString *ApolloDeletedCommentsStyledFlairText(NSAttributedString *attributedText) {
    if (!ApolloDeletedCommentsIsRecoveredFlairText(attributedText)) return attributedText;

    NSMutableAttributedString *styled = [attributedText mutableCopy];
    NSRange fullRange = NSMakeRange(0, styled.length);
    [styled addAttribute:NSForegroundColorAttributeName value:ApolloDeletedCommentsBadgeRed() range:fullRange];
    [styled removeAttribute:NSBackgroundColorAttributeName range:fullRange];
    return styled;
}

static id ApolloDeletedCommentsFlairContainerForTextNode(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(supernode)]) return nil;

    id current = nil;
    @try {
        current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(supernode));
    } @catch (__unused NSException *e) {
        current = nil;
    }

    for (NSUInteger i = 0; current && i < 3; i++) {
        const char *className = class_getName(object_getClass(current));
        if (className && strstr(className, "CommentCellNode")) return nil;
        if ([current respondsToSelector:@selector(setBackgroundColor:)]) return current;
        if (![current respondsToSelector:@selector(supernode)]) break;
        @try {
            current = ((id (*)(id, SEL))objc_msgSend)(current, @selector(supernode));
        } @catch (__unused NSException *e) {
            break;
        }
    }
    return nil;
}

static void ApolloDeletedCommentsRestoreFlairContainer(id textNode) {
    id container = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey);
    if (!container) return;

    UIColor *original = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFlairOriginalBackgroundKey);
    if ([container respondsToSelector:@selector(setBackgroundColor:)]) {
        @try {
            ((void (*)(id, SEL, UIColor *))objc_msgSend)(container, @selector(setBackgroundColor:), original);
        } @catch (__unused NSException *e) {}
    }

    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFlairOriginalBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDeletedCommentsApplyFlairContainerStyle(id textNode, NSAttributedString *attributedText) {
    if (!sShowDeletedComments || !ApolloDeletedCommentsIsRecoveredFlairText(attributedText)) {
        ApolloDeletedCommentsRestoreFlairContainer(textNode);
        return;
    }

    id container = ApolloDeletedCommentsFlairContainerForTextNode(textNode);
    if (!container) return;

    id previous = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey);
    if (previous && previous != container) ApolloDeletedCommentsRestoreFlairContainer(textNode);
    if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey)) {
        UIColor *original = nil;
        if ([container respondsToSelector:@selector(backgroundColor)]) {
            @try {
                original = ((UIColor *(*)(id, SEL))objc_msgSend)(container, @selector(backgroundColor));
            } @catch (__unused NSException *e) {
                original = nil;
            }
        }
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (original) objc_setAssociatedObject(textNode, kApolloDeletedCommentsFlairOriginalBackgroundKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIColor *background = [ApolloDeletedCommentsBadgeRed() colorWithAlphaComponent:0.24];
    @try {
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(container, @selector(setBackgroundColor:), background);
    } @catch (__unused NSException *e) {}
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *styledAttributedText = ApolloDeletedCommentsStyledFlairText(attributedText);
    %orig(styledAttributedText);
    ApolloDeletedCommentsApplyFlairContainerStyle((id)self, styledAttributedText);
}

- (void)didEnterDisplayState {
    %orig;
    NSAttributedString *attributedText = nil;
    @try {
        attributedText = ((NSAttributedString *(*)(id, SEL))objc_msgSend)((id)self, @selector(attributedText));
    } @catch (__unused NSException *e) {
        attributedText = nil;
    }
    ApolloDeletedCommentsApplyFlairContainerStyle((id)self, attributedText);
}

%end
