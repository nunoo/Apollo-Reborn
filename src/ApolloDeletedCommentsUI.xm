#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloDeletedCommentsData.h"
#import "ApolloState.h"
#import "Tweak.h"

static const void *kApolloDeletedCommentsFlairContainerKey = &kApolloDeletedCommentsFlairContainerKey;
static const void *kApolloDeletedCommentsFlairOriginalBackgroundKey = &kApolloDeletedCommentsFlairOriginalBackgroundKey;
static const void *kApolloDeletedCommentsHiddenOriginalTextKey = &kApolloDeletedCommentsHiddenOriginalTextKey;
static const void *kApolloDeletedCommentsHiddenFullNameKey = &kApolloDeletedCommentsHiddenFullNameKey;
static const void *kApolloDeletedCommentsHiddenTextNodeKey = &kApolloDeletedCommentsHiddenTextNodeKey;
static const void *kApolloDeletedCommentsSuppressNextCollapseKey = &kApolloDeletedCommentsSuppressNextCollapseKey;
static const void *kApolloDeletedCommentsProseAttributedTextKey = &kApolloDeletedCommentsProseAttributedTextKey;
static const void *kApolloDeletedCommentsChipAttributedTextKey = &kApolloDeletedCommentsChipAttributedTextKey;
static const void *kApolloDeletedCommentsFadeTimerKey = &kApolloDeletedCommentsFadeTimerKey;
static const void *kApolloDeletedCommentsFadeStartDateKey = &kApolloDeletedCommentsFadeStartDateKey;
static const void *kApolloDeletedCommentsFadeAccentKey = &kApolloDeletedCommentsFadeAccentKey;
static const void *kApolloDeletedCommentsFadeProseKey = &kApolloDeletedCommentsFadeProseKey;

static NSString *const ApolloDeletedCommentsTapPlaceholderText = @"SHOW";
static NSString *const ApolloDeletedCommentsRevealURLString = @"apollo-deleted-comments://reveal";
static NSString *const ApolloDeletedCommentsRevealAttributeName = @"ApolloDeletedCommentsRevealAttribute";

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

static NSString *ApolloDeletedCommentsNormalizeCommentFullName(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return nil;
    if ([value hasPrefix:@"t1_"]) return value;
    if ([value rangeOfString:@"_"].location != NSNotFound) return nil;
    return [@"t1_" stringByAppendingString:value];
}

static NSString *ApolloDeletedCommentsFullNameForComment(RDKComment *comment) {
    if (!comment) return nil;
    SEL selectors[] = {
        @selector(name),
        NSSelectorFromString(@"fullName"),
        NSSelectorFromString(@"identifier"),
        NSSelectorFromString(@"id"),
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if (![(id)comment respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)((id)comment, sel);
        } @catch (__unused NSException *e) {
            value = nil;
        }
        NSString *fullName = ApolloDeletedCommentsNormalizeCommentFullName([value isKindOfClass:[NSString class]] ? value : nil);
        if (fullName.length > 0) return fullName;
    }

    static const char *ivarNames[] = {
        "name",
        "_name",
        "fullName",
        "_fullName",
        "identifier",
        "_identifier",
        "commentID",
        "_commentID",
        "id",
        "_id",
        NULL,
    };
    for (Class cls = [(id)comment class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; ivarNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, ivarNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try {
                value = object_getIvar(comment, ivar);
            } @catch (__unused NSException *e) {
                value = nil;
            }
            NSString *fullName = ApolloDeletedCommentsNormalizeCommentFullName([value isKindOfClass:[NSString class]] ? value : nil);
            if (fullName.length > 0) return fullName;
        }
    }
    return nil;
}

static RDKComment *ApolloDeletedCommentsCommentFromCellNode(id commentCellNode) {
    if (!commentCellNode) return nil;
    Ivar commentIvar = class_getInstanceVariable([commentCellNode class], "comment");
    if (!commentIvar) return nil;
    id comment = nil;
    @try {
        comment = object_getIvar(commentCellNode, commentIvar);
    } @catch (__unused NSException *e) {
        comment = nil;
    }
    Class rdkCommentClass = NSClassFromString(@"RDKComment");
    if (!rdkCommentClass || ![comment isKindOfClass:rdkCommentClass]) return nil;
    return (RDKComment *)comment;
}

static id ApolloDeletedCommentsKnownBodyTextNode(id commentCellNode) {
    if (!commentCellNode) return nil;
    static const char *candidateNames[] = {
        "bodyTextNode",
        "commentTextNode",
        "commentBodyNode",
        "bodyNode",
        "markdownNode",
        "commentMarkdownNode",
        "attributedTextNode",
        "textNode",
        "commentBodyTextNode",
        "bodyMarkdownNode",
        NULL,
    };
    for (Class cls = [commentCellNode class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; candidateNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, candidateNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id node = nil;
            @try {
                node = object_getIvar(commentCellNode, ivar);
            } @catch (__unused NSException *e) {
                node = nil;
            }
            if (node && [node respondsToSelector:@selector(attributedText)] && [node respondsToSelector:@selector(setAttributedText:)]) {
                return node;
            }
        }
    }
    return nil;
}

static void ApolloDeletedCommentsRelayoutCellAndTextNode(id cellNode, id textNode) {
    SEL selectors[] = {
        @selector(setNeedsLayout),
        @selector(setNeedsDisplay),
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if ([textNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(textNode, sel); } @catch (__unused NSException *e) {}
        }
        if ([cellNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(cellNode, sel); } @catch (__unused NSException *e) {}
        }
    }
}

static UIImage *ApolloDeletedCommentsSpoilerStyleImage(NSString *text, UIFont *font) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    if (![font isKindOfClass:[UIFont class]]) font = [UIFont boldSystemFontOfSize:15.0];

    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor blackColor],
    };
    CGSize textSize = [text sizeWithAttributes:attributes];
    CGFloat horizontalPadding = 4.0;
    CGFloat verticalPadding = 0.5;
    CGSize imageSize = CGSizeMake(ceil(textSize.width + horizontalPadding * 2.0),
                                  ceil(textSize.height + verticalPadding * 2.0));

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:imageSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect bounds = CGRectMake(0.0, 0.0, imageSize.width, imageSize.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:6.0];
        [[UIColor colorWithWhite:0.84 alpha:1.0] setFill];
        [path fill];

        CGRect textRect = CGRectMake(horizontalPadding,
                                     floor((imageSize.height - textSize.height) / 2.0),
                                     textSize.width,
                                     textSize.height);
        [text drawInRect:textRect withAttributes:attributes];
    }];
}

static NSAttributedString *ApolloDeletedCommentsPlaceholderAttributedText(NSAttributedString *original) {
    NSDictionary *attributes = @{};
    if ([original isKindOfClass:[NSAttributedString class]] && original.length > 0) {
        attributes = [original attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    }
    UIFont *font = attributes[NSFontAttributeName];
    if (![font isKindOfClass:[UIFont class]]) {
        font = [UIFont boldSystemFontOfSize:15.0];
    } else {
        font = [UIFont boldSystemFontOfSize:MAX(12.0, font.pointSize - 2.5)];
    }

    NSMutableParagraphStyle *paragraphStyle = [NSMutableParagraphStyle new];
    paragraphStyle.lineSpacing = 0.0;
    paragraphStyle.paragraphSpacing = 0.0;
    paragraphStyle.minimumLineHeight = ceil(font.lineHeight + 2.0);
    paragraphStyle.maximumLineHeight = ceil(font.lineHeight + 2.0);

    UIImage *image = ApolloDeletedCommentsSpoilerStyleImage(ApolloDeletedCommentsTapPlaceholderText, font);
    if (![image isKindOfClass:[UIImage class]]) {
        return [[NSAttributedString alloc] initWithString:ApolloDeletedCommentsTapPlaceholderText attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [UIColor blackColor],
            NSParagraphStyleAttributeName: paragraphStyle,
            ApolloDeletedCommentsRevealAttributeName: ApolloDeletedCommentsRevealURLString,
        }];
    }

    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    attachment.bounds = CGRectMake(0.0, -1.0, image.size.width, image.size.height);
    NSMutableAttributedString *result = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    [result addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:NSMakeRange(0, result.length)];
    [result addAttribute:ApolloDeletedCommentsRevealAttributeName value:ApolloDeletedCommentsRevealURLString range:NSMakeRange(0, result.length)];
    return result;
}

static BOOL ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;
    if ([attributedText.string isEqualToString:ApolloDeletedCommentsTapPlaceholderText]) return YES;

    __block BOOL hasRevealLink = NO;
    [attributedText enumerateAttribute:NSLinkAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        NSString *urlString = nil;
        if ([value isKindOfClass:[NSURL class]]) {
            urlString = [(NSURL *)value absoluteString];
        } else if ([value isKindOfClass:[NSString class]]) {
            urlString = value;
        }
        if ([urlString isEqualToString:ApolloDeletedCommentsRevealURLString]) {
            hasRevealLink = YES;
            *stop = YES;
        }
    }];
    if (hasRevealLink) return YES;

    [attributedText enumerateAttribute:ApolloDeletedCommentsRevealAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        if ([value isEqual:ApolloDeletedCommentsRevealURLString]) {
            hasRevealLink = YES;
            *stop = YES;
        }
    }];
    return hasRevealLink;
}

static NSString *ApolloDeletedCommentsNormalizeTextForCompare(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    return [regex stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@" "];
}

static BOOL ApolloDeletedCommentsTextQualifiesAsBodyCandidate(NSString *candidate, NSString *body) {
    NSString *candidateNorm = ApolloDeletedCommentsNormalizeTextForCompare(candidate);
    NSString *bodyNorm = ApolloDeletedCommentsNormalizeTextForCompare(body);
    if (candidateNorm.length == 0 || bodyNorm.length == 0) return NO;
    if ([candidateNorm isEqualToString:bodyNorm]) return YES;
    NSUInteger minLen = MIN(candidateNorm.length, bodyNorm.length);
    if (minLen < 24) return NO;
    NSString *candidatePrefix = [candidateNorm substringToIndex:minLen];
    NSString *bodyPrefix = [bodyNorm substringToIndex:minLen];
    return [candidatePrefix isEqualToString:bodyPrefix];
}

static void ApolloDeletedCommentsCollectAttributedTextNodes(id object, NSInteger depth, NSHashTable *visited, NSMutableArray *nodes) {
    if (!object || depth < 0 || [visited containsObject:object]) return;
    [visited addObject:object];

    @try {
        if ([object respondsToSelector:@selector(attributedText)] && [object respondsToSelector:@selector(setAttributedText:)]) {
            NSAttributedString *text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(object, @selector(attributedText));
            if ([text isKindOfClass:[NSAttributedString class]] && text.length > 0) {
                [nodes addObject:object];
            }
        }

        if ([object respondsToSelector:@selector(subnodes)]) {
            NSArray *subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(object, @selector(subnodes));
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloDeletedCommentsCollectAttributedTextNodes(subnode, depth - 1, visited, nodes);
            }
        }
    } @catch (__unused NSException *e) {}
}

static id ApolloDeletedCommentsBestBodyTextNode(id cellNode, RDKComment *comment) {
    NSString *body = comment.body;
    id known = ApolloDeletedCommentsKnownBodyTextNode(cellNode);
    if (known) {
        NSAttributedString *text = nil;
        @try {
            text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(known, @selector(attributedText));
        } @catch (__unused NSException *e) {
            text = nil;
        }
        if (ApolloDeletedCommentsTextQualifiesAsBodyCandidate(text.string, body)) return known;
    }

    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
    ApolloDeletedCommentsCollectAttributedTextNodes(cellNode, 6, visited, candidates);

    id bestNode = nil;
    NSUInteger bestLength = 0;
    for (id candidate in candidates) {
        NSAttributedString *text = nil;
        @try {
            text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(candidate, @selector(attributedText));
        } @catch (__unused NSException *e) {
            text = nil;
        }
        if (!ApolloDeletedCommentsTextQualifiesAsBodyCandidate(text.string, body)) continue;
        if (text.length > bestLength) {
            bestLength = text.length;
            bestNode = candidate;
        }
    }
    return bestNode;
}

static void ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(id cellNode, id textNode) {
    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) return;

    NSAttributedString *current = nil;
    @try {
        current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        current = nil;
    }
    if (![current isKindOfClass:[NSAttributedString class]] ||
        ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current)) {
        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), original);
        } @catch (__unused NSException *e) {}
    }
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey) == textNode) {
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
}

static void ApolloDeletedCommentsEnsureRevealAttributeIsTappable(id textNode) {
    if (!textNode) return;

    if ([textNode respondsToSelector:@selector(setUserInteractionEnabled:)]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(textNode, @selector(setUserInteractionEnabled:), YES);
        } @catch (__unused NSException *e) {}
    }

    if ([textNode respondsToSelector:@selector(view)]) {
        @try {
            UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
            if ([view isKindOfClass:[UIView class]]) view.userInteractionEnabled = YES;
        } @catch (__unused NSException *e) {}
    }

    if (![textNode respondsToSelector:@selector(setLinkAttributeNames:)]) return;

    NSMutableSet *names = [NSMutableSet setWithObjects:NSLinkAttributeName, ApolloDeletedCommentsRevealAttributeName, nil];
    if ([textNode respondsToSelector:@selector(linkAttributeNames)]) {
        @try {
            id existing = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(linkAttributeNames));
            if ([existing isKindOfClass:[NSArray class]]) {
                [names addObjectsFromArray:(NSArray *)existing];
            } else if ([existing isKindOfClass:[NSSet class]]) {
                [names unionSet:(NSSet *)existing];
            }
        } @catch (__unused NSException *e) {}
    }

    NSArray *orderedNames = names.allObjects;
    @try {
        ((void (*)(id, SEL, NSArray *))objc_msgSend)(textNode, @selector(setLinkAttributeNames:), orderedNames);
    } @catch (__unused NSException *e) {}
}

static void __attribute__((unused)) ApolloDeletedCommentsApplyTapToRevealIfNeeded(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *author = comment.author;
    NSString *body = comment.body;
    id textNode = ApolloDeletedCommentsBestBodyTextNode(cellNode, comment);
    if (!textNode) return;

    BOOL recovered = ApolloDeletedCommentsIsRecoveredComment(fullName) ||
                     ApolloDeletedCommentsIsRecoveredCommentBody(author, body);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(author, body);
    BOOL shouldHide = sShowDeletedComments &&
                      sTapToRevealDeletedComments &&
                      recovered &&
                      !revealed;
    if (!shouldHide) {
        ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(cellNode, textNode);
        return;
    }

    NSAttributedString *existingOriginal = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    NSAttributedString *existingCurrent = nil;
    @try {
        existingCurrent = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        existingCurrent = nil;
    }
    if ([existingOriginal isKindOfClass:[NSAttributedString class]] &&
        ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(existingCurrent)) {
        ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
        return;
    }

    NSString *hiddenFullName = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey);
    if ([hiddenFullName isEqualToString:fullName]) {
        ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
        return;
    }

    ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(cellNode, textNode);

    NSAttributedString *current = nil;
    @try {
        current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        current = nil;
    }
    if (![current isKindOfClass:[NSAttributedString class]] || current.length == 0) return;
    if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current)) return;

    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSAttributedString *placeholder = ApolloDeletedCommentsPlaceholderAttributedText(current);
    @try {
        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), placeholder);
    } @catch (__unused NSException *e) {}
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
}

static BOOL ApolloDeletedCommentsTouchHitsTextNode(id textNode, UITouch *touch) {
    if (!textNode || !touch || ![textNode respondsToSelector:@selector(view)]) return NO;
    UIView *nodeView = nil;
    @try {
        nodeView = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
    } @catch (__unused NSException *e) {
        nodeView = nil;
    }
    if (![nodeView isKindOfClass:[UIView class]] || nodeView.hidden || nodeView.alpha < 0.01) return NO;
    CGPoint point = [touch locationInView:nodeView];
    return CGRectContainsPoint(CGRectInset(nodeView.bounds, -8.0, -8.0), point);
}

static void ApolloDeletedCommentsForceCommentExpanded(RDKComment *comment, id cellNode) {
    if (!comment) return;

    if ([(id)comment respondsToSelector:@selector(setCollapsed:)]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)((id)comment, @selector(setCollapsed:), NO);
        } @catch (__unused NSException *e) {}
    }

    Ivar collapsedIvar = class_getInstanceVariable([(id)comment class], "_collapsed");
    if (collapsedIvar) {
        @try {
            ptrdiff_t offset = ivar_getOffset(collapsedIvar);
            if (offset > 0) {
                BOOL *slot = (BOOL *)((uint8_t *)(__bridge void *)comment + offset);
                *slot = NO;
            }
        } @catch (__unused NSException *e) {}
    }

    SEL selectors[] = {
        @selector(setNeedsLayout),
        @selector(setNeedsDisplay),
    };
    for (size_t i = 0; i < 2; i++) {
        SEL sel = selectors[i];
        if ([cellNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(cellNode, sel); } @catch (__unused NSException *e) {}
        }
    }
}

static void ApolloDeletedCommentsScheduleForceExpanded(RDKComment *comment, id cellNode) {
    if (!comment) return;
    NSArray<NSNumber *> *delays = @[@0.0, @0.03, @0.12, @0.30];
    for (NSNumber *delayNumber in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloDeletedCommentsForceCommentExpanded(comment, cellNode);
        });
    }
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsTouchHitsHiddenBody(id cellNode, UITouch *touch) {
    id textNode = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey);
    if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) return NO;
    return ApolloDeletedCommentsTouchHitsTextNode(textNode, touch);
}

// Forward declarations for theme-accent + reveal-fade helpers defined further down.
static UIColor *ApolloDeletedCommentsThemeAccentFromTextNode(id textNode);
static NSAttributedString *ApolloDeletedCommentsBuildProseAttributedText(NSString *prose, NSAttributedString *chipText);
static void ApolloDeletedCommentsStartRevealFade(id textNode, UIColor *accent);

static void ApolloDeletedCommentsRevealHiddenBodyForCell(id cellNode) {
    id textNode = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey);
    if (!textNode) return;
    NSAttributedString *prose = objc_getAssociatedObject(textNode, kApolloDeletedCommentsProseAttributedTextKey);

    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);

    if (![prose isKindOfClass:[NSAttributedString class]]) {
        // Recover prose lazily if a fresh chip render landed before we cached it.
        NSString *proseString = ApolloDeletedCommentsProseBodyForFullName(fullName);
        if (proseString.length == 0 && comment) {
            proseString = ApolloDeletedCommentsProseBodyForAuthorBody(comment.author, comment.body);
        }
        if (proseString.length == 0 && comment.body.length > 0) {
            proseString = ApolloDeletedCommentsUnwrapSpoilerMarkdownBody(comment.body);
        }
        NSAttributedString *chipText = objc_getAssociatedObject(textNode, kApolloDeletedCommentsChipAttributedTextKey);
        if (![chipText isKindOfClass:[NSAttributedString class]]) {
            @try {
                chipText = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
            } @catch (__unused NSException *e) { chipText = nil; }
        }
        prose = ApolloDeletedCommentsBuildProseAttributedText(proseString, chipText);
    }
    if (![prose isKindOfClass:[NSAttributedString class]] || prose.length == 0) {
        ApolloLog(@"[deleted-comments] reveal aborted: no prose body for %@", fullName);
        return;
    }

    // Mark revealed at the data layer so subsequent fetches won't re-wrap.
    ApolloDeletedCommentsMarkCommentRevealed(fullName);
    if (comment) {
        ApolloDeletedCommentsMarkCommentBodyRevealed(comment.author, comment.body);
        NSString *proseString = prose.string;
        if (proseString.length > 0) {
            @try { comment.body = proseString; } @catch (__unused NSException *e) {}
        }
    }
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIColor *accent = ApolloDeletedCommentsThemeAccentFromTextNode(textNode);
    // Apply prose, then start the 10s fade (the fade applies its highlight
    // on top of the prose attributed text each tick).
    @try {
        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), prose);
    } @catch (__unused NSException *e) {}

    // Clear association state — we're no longer hiding anything.
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsChipAttributedTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey) == textNode) {
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
    ApolloDeletedCommentsStartRevealFade(textNode, accent);
    ApolloDeletedCommentsScheduleForceExpanded(comment, cellNode);
}

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(supernode)]) return nil;
    id current = textNode;
    for (NSUInteger i = 0; current && i < 10; i++) {
        const char *className = class_getName(object_getClass(current));
        if (className && strstr(className, "CommentCellNode")) return current;
        if (![current respondsToSelector:@selector(supernode)]) break;
        @try {
            current = ((id (*)(id, SEL))objc_msgSend)(current, @selector(supernode));
        } @catch (__unused NSException *e) {
            break;
        }
    }
    return nil;
}

static BOOL ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(id textNode) {
    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsRecoveredComment(fullName) ||
           ApolloDeletedCommentsIsRecoveredCommentBody(comment.author, comment.body);
}

static BOOL ApolloDeletedCommentsIsRevealLink(id attribute, id value) {
    if ([attribute isKindOfClass:[NSString class]] &&
        [(NSString *)attribute isEqualToString:ApolloDeletedCommentsRevealAttributeName]) {
        return YES;
    }

    NSString *urlString = nil;
    if ([value isKindOfClass:[NSURL class]]) {
        urlString = [(NSURL *)value absoluteString];
    } else if ([value isKindOfClass:[NSString class]]) {
        urlString = value;
    }
    return [urlString isEqualToString:ApolloDeletedCommentsRevealURLString];
}

#pragma mark - Theme accent + chip retint

static const NSTimeInterval kApolloDeletedCommentsRevealFadeDuration = 10.0;
static const CGFloat kApolloDeletedCommentsRevealFadePeakAlpha = 0.35;

static UIColor *ApolloDeletedCommentsThemeAccentFromTextNode(id textNode) {
    UIView *nodeView = nil;
    if ([textNode respondsToSelector:@selector(view)]) {
        @try {
            nodeView = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
        } @catch (__unused NSException *e) {
            nodeView = nil;
        }
    }
    if ([nodeView isKindOfClass:[UIView class]]) {
        UIWindow *window = nodeView.window;
        if (window.tintColor) return window.tintColor;
    }
    // Fall back: key window's tintColor (Apollo themes the window globally).
    UIWindow *keyWindow = nil;
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow && windows.count > 0) keyWindow = windows.firstObject;
    if (keyWindow.tintColor) return keyWindow.tintColor;
    if ([nodeView isKindOfClass:[UIView class]] && nodeView.tintColor) return nodeView.tintColor;
    if (@available(iOS 13.0, *)) return [UIColor systemBlueColor];
    return [UIColor blueColor];
}

// Heuristic: is this background color one of Apollo's default spoiler-pill greys?
static BOOL ApolloDeletedCommentsIsLikelySpoilerFillColor(UIColor *color) {
    if (![color isKindOfClass:[UIColor class]]) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0, alpha = 0;
        if (![color getWhite:&white alpha:&alpha]) return NO;
        r = g = b = white;
        a = alpha;
    }
    if (a < 0.05) return NO;
    // Accept any near-grey (low chroma) tone — covers Apollo light + dark spoiler fills.
    CGFloat maxC = MAX(r, MAX(g, b));
    CGFloat minC = MIN(r, MIN(g, b));
    return (maxC - minC) < 0.08;
}

// Rewrite the chip's grey background to a theme-accent tint while preserving every
// other attribute Apollo set (font, foreground color, link/tap attributes, etc.).
static NSMutableAttributedString *ApolloDeletedCommentsRetintSpoilerChip(NSAttributedString *attributedText, UIColor *accent) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return nil;
    NSMutableAttributedString *out = [attributedText mutableCopy];
    UIColor *tint = [accent colorWithAlphaComponent:kApolloDeletedCommentsRevealFadePeakAlpha];
    __block BOOL anyChange = NO;
    NSRange fullRange = NSMakeRange(0, out.length);
    [out enumerateAttribute:NSBackgroundColorAttributeName inRange:fullRange options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        UIColor *bg = [value isKindOfClass:[UIColor class]] ? (UIColor *)value : nil;
        if (bg && ApolloDeletedCommentsIsLikelySpoilerFillColor(bg)) {
            [out addAttribute:NSBackgroundColorAttributeName value:tint range:range];
            anyChange = YES;
        }
    }];
    // Fallback: if no grey ranges were detected (theme variation), tint the whole range.
    if (!anyChange) {
        [out addAttribute:NSBackgroundColorAttributeName value:tint range:fullRange];
    }
    return out;
}

// Stamp our reveal link attribute across the chip range and register it on the
// text node so MarkdownNode's tap delegate dispatches to our handler.
static void ApolloDeletedCommentsStampRevealLinkOnChip(NSMutableAttributedString *chip, id textNode) {
    if (chip.length == 0) return;
    NSRange fullRange = NSMakeRange(0, chip.length);
    [chip addAttribute:ApolloDeletedCommentsRevealAttributeName value:ApolloDeletedCommentsRevealURLString range:fullRange];
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
}

#pragma mark - Reveal fade animator

static void ApolloDeletedCommentsCancelRevealFade(id textNode) {
    NSTimer *timer = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFadeTimerKey);
    if ([timer isKindOfClass:[NSTimer class]]) {
        [timer invalidate];
    }
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFadeTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFadeStartDateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFadeAccentKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFadeProseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDeletedCommentsApplyFadeFrame(id textNode, CGFloat alpha) {
    if (!textNode || ![textNode respondsToSelector:@selector(attributedText)]) return;
    NSAttributedString *current = nil;
    @try {
        current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) { return; }
    if (![current isKindOfClass:[NSAttributedString class]] || current.length == 0) return;

    // If the text node has been reused for a different comment, the displayed
    // string will no longer match the prose we're fading — bail out.
    NSString *expectedProse = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFadeProseKey);
    if ([expectedProse isKindOfClass:[NSString class]] &&
        ![current.string isEqualToString:expectedProse]) {
        ApolloDeletedCommentsCancelRevealFade(textNode);
        return;
    }

    UIColor *accent = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFadeAccentKey);
    if (![accent isKindOfClass:[UIColor class]]) return;

    NSMutableAttributedString *frame = [current mutableCopy];
    NSRange fullRange = NSMakeRange(0, frame.length);
    if (alpha <= 0.001) {
        [frame removeAttribute:NSBackgroundColorAttributeName range:fullRange];
    } else {
        [frame addAttribute:NSBackgroundColorAttributeName value:[accent colorWithAlphaComponent:alpha] range:fullRange];
    }
    @try {
        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), frame);
    } @catch (__unused NSException *e) {}
}

@interface ApolloDeletedCommentsFadeTickHelper : NSObject
+ (void)tick:(NSTimer *)timer;
@end

@implementation ApolloDeletedCommentsFadeTickHelper
+ (void)tick:(NSTimer *)timer {
    id textNode = timer.userInfo;
    if (!textNode) { [timer invalidate]; return; }
    NSDate *start = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFadeStartDateKey);
    if (![start isKindOfClass:[NSDate class]]) { [timer invalidate]; return; }
    NSTimeInterval elapsed = -[start timeIntervalSinceNow];
    CGFloat progress = (CGFloat)MIN(1.0, MAX(0.0, elapsed / kApolloDeletedCommentsRevealFadeDuration));
    // Hold full alpha for the first 1.5s then ease out.
    CGFloat alpha;
    if (progress < 0.15) {
        alpha = kApolloDeletedCommentsRevealFadePeakAlpha;
    } else {
        CGFloat eased = (progress - 0.15) / 0.85;
        eased = eased * eased; // ease-in fade-out feels gentle
        alpha = kApolloDeletedCommentsRevealFadePeakAlpha * (1.0 - eased);
    }
    ApolloDeletedCommentsApplyFadeFrame(textNode, alpha);
    if (progress >= 1.0) {
        ApolloDeletedCommentsApplyFadeFrame(textNode, 0.0);
        ApolloDeletedCommentsCancelRevealFade(textNode);
    }
}
@end

static void ApolloDeletedCommentsStartRevealFade(id textNode, UIColor *accent) {
    if (!textNode || ![accent isKindOfClass:[UIColor class]]) return;
    ApolloDeletedCommentsCancelRevealFade(textNode);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFadeStartDateKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFadeAccentKey, accent, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSAttributedString *current = nil;
    @try {
        current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) { current = nil; }
    if ([current isKindOfClass:[NSAttributedString class]]) {
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsFadeProseKey, [current.string copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Render the first frame immediately.
    ApolloDeletedCommentsApplyFadeFrame(textNode, kApolloDeletedCommentsRevealFadePeakAlpha);
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                       target:[ApolloDeletedCommentsFadeTickHelper class]
                                                     selector:@selector(tick:)
                                                     userInfo:textNode
                                                      repeats:YES];
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFadeTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - SPOILER chip → SHOW retint + reveal swap

// Build a prose attributed string for the recovered body using the same paragraph
// style + foreground color as the chip, with a body-sized font derived from the
// chip's font.
static NSAttributedString *ApolloDeletedCommentsBuildProseAttributedText(NSString *prose, NSAttributedString *chipText) {
    if (![prose isKindOfClass:[NSString class]] || prose.length == 0) return nil;
    NSDictionary *chipAttrs = @{};
    if ([chipText isKindOfClass:[NSAttributedString class]] && chipText.length > 0) {
        chipAttrs = [chipText attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    }
    UIFont *chipFont = chipAttrs[NSFontAttributeName];
    UIFont *bodyFont = nil;
    if ([chipFont isKindOfClass:[UIFont class]]) {
        // Apollo's body font is typically the chip font without the bold/condensed treatment.
        bodyFont = [UIFont systemFontOfSize:MAX(13.0, chipFont.pointSize)];
    } else {
        bodyFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    }
    UIColor *fg = chipAttrs[NSForegroundColorAttributeName];
    if (![fg isKindOfClass:[UIColor class]]) {
        if (@available(iOS 13.0, *)) fg = [UIColor labelColor];
        else fg = [UIColor blackColor];
    }
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.lineBreakMode = NSLineBreakByWordWrapping;
    return [[NSAttributedString alloc] initWithString:prose attributes:@{
        NSFontAttributeName: bodyFont,
        NSForegroundColorAttributeName: fg,
        NSParagraphStyleAttributeName: para,
    }];
}

static NSAttributedString *ApolloDeletedCommentsStyleRecoveredSpoilerChip(id textNode, NSAttributedString *attributedText) {
    if (!sShowDeletedComments || !sTapToRevealDeletedComments) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(attributedText.string);
    if (![trimmed isEqualToString:@"SPOILER"]) return attributedText;
    if (!ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(textNode)) return attributedText;

    UIColor *accent = ApolloDeletedCommentsThemeAccentFromTextNode(textNode);
    NSMutableAttributedString *out = ApolloDeletedCommentsRetintSpoilerChip(attributedText, accent);
    if (out.length == 0) return attributedText;
    // Rename the visible label from "SPOILER" to "SHOW" while preserving the
    // attribute run at the chip's start (Apollo's own link attributes survive
    // because replaceCharactersInRange propagates them).
    [out replaceCharactersInRange:NSMakeRange(0, out.length) withString:@" SHOW "];
    // Stamp our reveal attribute so MarkdownNode's tap delegate routes to us.
    ApolloDeletedCommentsStampRevealLinkOnChip(out, textNode);

    // Stash the chip + look up the prose body so the tap handler can swap.
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsChipAttributedTextKey, [out copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *prose = ApolloDeletedCommentsProseBodyForFullName(fullName);
    if (prose.length == 0 && comment) {
        prose = ApolloDeletedCommentsProseBodyForAuthorBody(comment.author, comment.body);
    }
    if (prose.length == 0 && comment.body.length > 0) {
        // Last-ditch fallback: unwrap >!...!< from the comment body itself.
        prose = ApolloDeletedCommentsUnwrapSpoilerMarkdownBody(comment.body);
    }
    if (prose.length > 0) {
        NSAttributedString *proseText = ApolloDeletedCommentsBuildProseAttributedText(prose, attributedText);
        if (proseText) {
            objc_setAssociatedObject(textNode, kApolloDeletedCommentsProseAttributedTextKey, proseText, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    // Mark the textNode as the cell's hidden-body text node so the existing
    // tap handler in -textNode:tappedLinkAttribute:value:atPoint:textRange:
    // finds it and calls ApolloDeletedCommentsRevealHiddenBodyForCell.
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, [out copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (cellNode) {
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return out;
}

// Backwards-compat alias used by existing call sites in -setAttributedText:/
// -didEnterDisplayState. Returns the styled chip (rename + retint + reveal link).
static NSAttributedString *ApolloDeletedCommentsRenameRecoveredSpoilerLabel(id textNode, NSAttributedString *attributedText) {
    return ApolloDeletedCommentsStyleRecoveredSpoilerChip(textNode, attributedText);
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *styledAttributedText = ApolloDeletedCommentsStyledFlairText(
        ApolloDeletedCommentsRenameRecoveredSpoilerLabel((id)self, attributedText)
    );
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
    NSAttributedString *renamedAttributedText = ApolloDeletedCommentsRenameRecoveredSpoilerLabel((id)self, attributedText);
    if (renamedAttributedText != attributedText) {
        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)((id)self, @selector(setAttributedText:), renamedAttributedText);
            attributedText = renamedAttributedText;
        } @catch (__unused NSException *e) {}
    }
    ApolloDeletedCommentsApplyFlairContainerStyle((id)self, attributedText);
}

%end

@interface _TtC6Apollo15CommentCellNode
- (void)didLoad;
- (void)didEnterDisplayState;
- (void)layout;
@end

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
}

- (void)didEnterDisplayState {
    %orig;
}

- (void)layout {
    %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return %orig;
}

%end

%hook RDKComment

- (void)setCollapsed:(BOOL)collapsed {
    if (collapsed && [objc_getAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey) boolValue]) {
        objc_setAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    %orig;
}

%end

%hook _TtC6Apollo12MarkdownNode

- (BOOL)textNode:(id)textNode shouldHighlightLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value) &&
        objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
        return YES;
    }
    return %orig(textNode, attribute, value, point);
}

- (BOOL)textNode:(id)textNode shouldLongPressLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value)) {
        return NO;
    }
    return %orig(textNode, attribute, value, point);
}

- (void)textNode:(id)textNode tappedLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point textRange:(NSRange)range {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value) &&
        objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
        id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
        ApolloDeletedCommentsRevealHiddenBodyForCell(cellNode);
        return;
    }
    %orig(textNode, attribute, value, point, range);
}

%end
