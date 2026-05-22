#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

static NSString *const ApolloRevealDeletedCommentsToggleChangedNotification = @"ApolloRevealDeletedCommentsToggleChangedNotification";
static NSString *const ApolloRevealDeletedCommentsObservedThreadNotification = @"ApolloRevealDeletedCommentsObservedThreadNotification";

static const void *kApolloRevealOriginalAttributedTextKey = &kApolloRevealOriginalAttributedTextKey;
static const void *kApolloRevealOwnedTextNodeKey = &kApolloRevealOwnedTextNodeKey;
static const void *kApolloRevealTextNodeKey = &kApolloRevealTextNodeKey;
static const void *kApolloRevealRecoveredTextKey = &kApolloRevealRecoveredTextKey;
static const void *kApolloRevealRecoveredAuthorKey = &kApolloRevealRecoveredAuthorKey;
static const void *kApolloRevealAppliedFullNameKey = &kApolloRevealAppliedFullNameKey;
static const void *kApolloRevealRequestFullNameKey = &kApolloRevealRequestFullNameKey;
static const void *kApolloRevealReapplyScheduledKey = &kApolloRevealReapplyScheduledKey;
static const void *kApolloRevealRecentlyAppliedKey = &kApolloRevealRecentlyAppliedKey;
static const void *kApolloRevealMissingRepliesScanScheduledKey = &kApolloRevealMissingRepliesScanScheduledKey;
static const void *kApolloRevealObservedPlaceholderLogKey = &kApolloRevealObservedPlaceholderLogKey;
static const void *kApolloRevealDelayedTextHandleScheduledKey = &kApolloRevealDelayedTextHandleScheduledKey;
static const void *kApolloRevealMoreCommentsApplyScheduledKey = &kApolloRevealMoreCommentsApplyScheduledKey;
static const void *kApolloRevealLoggedMoreCommentsKey = &kApolloRevealLoggedMoreCommentsKey;
static const void *kApolloRevealDeletedFlairContainerKey = &kApolloRevealDeletedFlairContainerKey;
static const void *kApolloRevealDeletedFlairOriginalBackgroundKey = &kApolloRevealDeletedFlairOriginalBackgroundKey;

static NSCache<NSString *, NSString *> *sRecoveredCommentBodyByFullName = nil;
static NSCache<NSString *, NSDictionary *> *sRecoveredThreadTreeByLinkFullName = nil;
static NSMutableDictionary<NSString *, NSDate *> *sNegativeCacheByFullName = nil;
static NSMutableSet<NSString *> *sInFlightFullNames = nil;
static NSMutableSet<NSString *> *sInFlightThreadFullNames = nil;
static NSMutableSet<NSString *> *sLoggedRevealSkipFullNames = nil;
static NSMutableSet<NSString *> *sLoggedRevealPlaceholderFullNames = nil;
static NSHashTable *sOwnedRevealTextNodes = nil;
static __weak UIViewController *sVisibleRevealCommentsViewController = nil;
static NSString *sVisibleRevealLinkFullName = nil;
static BOOL sRevealLoggedMoreCommentsMethods = NO;

static NSTimeInterval const kApolloRevealNegativeCacheTTL = 300.0;
static NSUInteger const kApolloRevealMaxVisitedNodes = 256;

static id ApolloRevealIvarValueByName(id obj, const char *name) {
    if (!obj || !name) return nil;
    for (Class cls = object_getClass(obj); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;
        @try {
            return object_getIvar(obj, ivar);
        } @catch (__unused NSException *e) {
            return nil;
        }
    }
    return nil;
}

static void ApolloRevealLogMethodsForClassName(NSString *className) {
    if (className.length == 0) return;
    Class cls = NSClassFromString(className);
    if (!cls) {
        ApolloLog(@"[RevealDeleted] Methods %@: class missing", className);
        return;
    }

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (sel) [names addObject:NSStringFromSelector(sel)];
    }
    free(methods);
    ApolloLog(@"[RevealDeleted] Methods %@: %@", className, [names componentsJoinedByString:@", "]);
}

static void ApolloRevealLogMoreCommentsMethodsOnce(void) {
    if (sRevealLoggedMoreCommentsMethods) return;
    sRevealLoggedMoreCommentsMethods = YES;
    ApolloRevealLogMethodsForClassName(@"_TtC6Apollo20MoreCommentsCellNode");
    ApolloRevealLogMethodsForClassName(@"_TtC6Apollo29MoreCommentsSectionController");
}

static RDKComment *ApolloRevealCommentFromCellNode(id commentCellNode) {
    id comment = ApolloRevealIvarValueByName(commentCellNode, "comment");
    Class rdkCommentClass = NSClassFromString(@"RDKComment");
    if (!rdkCommentClass || ![comment isKindOfClass:rdkCommentClass]) return nil;
    return (RDKComment *)comment;
}

static NSString *ApolloRevealTrimmedString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ApolloRevealBodyLooksDeleted(NSString *body) {
    NSString *trimmed = [[ApolloRevealTrimmedString(body) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return YES;
    if ([trimmed isEqualToString:@"[deleted]"]) return YES;
    if ([trimmed isEqualToString:@"[removed]"]) return YES;
    if ([trimmed isEqualToString:@"deleted"]) return YES;
    if ([trimmed isEqualToString:@"removed"]) return YES;
    if ([trimmed isEqualToString:@"removed by moderator"]) return YES;
    if ([trimmed isEqualToString:@"removed by reddit"]) return YES;
    if ([trimmed isEqualToString:@"[removed by reddit]"]) return YES;
    if ([trimmed isEqualToString:@"deleted by user"]) return YES;
    if ([trimmed isEqualToString:@"comment removed by moderator"]) return YES;
    if ([trimmed isEqualToString:@"comment deleted by user"]) return YES;
    return NO;
}

static NSString *ApolloRevealFullNameForComment(RDKComment *comment) {
    if (!comment) return nil;
    SEL sels[] = { @selector(name), NSSelectorFromString(@"fullName"), NSSelectorFromString(@"identifier"), NSSelectorFromString(@"id") };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        SEL sel = sels[i];
        if (![(id)comment respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(comment, sel);
        } @catch (__unused NSException *e) {
            continue;
        }
        if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) continue;
        NSString *identifier = (NSString *)value;
        if ([identifier hasPrefix:@"t1_"]) return identifier;
        return [NSString stringWithFormat:@"t1_%@", identifier];
    }

    static const char *kIvarNames[] = { "name", "fullName", "identifier", "_name", "_fullName", "_identifier", NULL };
    for (size_t i = 0; kIvarNames[i]; i++) {
        id value = ApolloRevealIvarValueByName(comment, kIvarNames[i]);
        if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) continue;
        NSString *identifier = (NSString *)value;
        if ([identifier hasPrefix:@"t1_"]) return identifier;
        return [NSString stringWithFormat:@"t1_%@", identifier];
    }
    return nil;
}

static NSString *ApolloRevealArcticIDFromFullName(NSString *fullName) {
    NSString *trimmed = ApolloRevealTrimmedString(fullName);
    if (trimmed.length == 0) return nil;
    if ([trimmed hasPrefix:@"t1_"] && trimmed.length > 3) return [trimmed substringFromIndex:3];
    return trimmed;
}

static NSString *ApolloRevealCommentFullNameFromIdentifier(NSString *identifier) {
    NSString *trimmed = ApolloRevealTrimmedString(identifier);
    if (trimmed.length == 0) return nil;
    if ([trimmed hasPrefix:@"t1_"]) return trimmed;
    if ([trimmed hasPrefix:@"t3_"]) return trimmed;
    return [@"t1_" stringByAppendingString:trimmed];
}

static RDKLink *ApolloRevealLinkFromObject(id object) {
    if (!object) return nil;
    Class rdkLinkClass = NSClassFromString(@"RDKLink");
    if (!rdkLinkClass) return nil;
    static const char *kNames[] = {
        "link", "post", "thing", "currentLink", "currentPost", "_link", "_post",
        "model", "data", "headerLink", "linkModel", "postModel", NULL
    };
    for (Class cls = object_getClass(object); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; kNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, kNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(object, ivar); } @catch (__unused NSException *e) { continue; }
            if ([value isKindOfClass:rdkLinkClass]) return (RDKLink *)value;
        }
    }

    for (Class cls = object_getClass(object); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(object, ivars[i]); } @catch (__unused NSException *e) { continue; }
            if ([value isKindOfClass:rdkLinkClass]) {
                free(ivars);
                return (RDKLink *)value;
            }
        }
        free(ivars);
    }
    return nil;
}

static RDKLink *ApolloRevealLinkFromController(UIViewController *viewController) {
    return ApolloRevealLinkFromObject(viewController);
}

static void ApolloRevealFindLinkOrCommentInTree(id object, NSInteger depth, NSHashTable *visited, RDKLink **linkOut, RDKComment **commentOut) {
    if (!object || depth < 0) return;
    if ((*linkOut && *commentOut) || visited.count >= 512) return;
    if ([visited containsObject:object]) return;
    [visited addObject:object];

    if (!*linkOut) {
        RDKLink *link = ApolloRevealLinkFromObject(object);
        if (link) *linkOut = link;
    }
    if (!*commentOut) {
        RDKComment *comment = ApolloRevealCommentFromCellNode(object);
        if (comment) *commentOut = comment;
    }

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object) ApolloRevealFindLinkOrCommentInTree(node, depth - 1, visited, linkOut, commentOut);
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloRevealFindLinkOrCommentInTree(subnode, depth - 1, visited, linkOut, commentOut);
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        if ([object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id subview in subviews) ApolloRevealFindLinkOrCommentInTree(subview, depth - 1, visited, linkOut, commentOut);
            }
        }
    } @catch (__unused NSException *e) {}
}

static NSString *ApolloRevealLinkFullNameFromController(UIViewController *viewController) {
    RDKLink *link = ApolloRevealLinkFromController(viewController);
    NSString *fullName = link.fullName;
    if ([fullName isKindOfClass:[NSString class]] && fullName.length > 0) return fullName;

    RDKLink *treeLink = nil;
    RDKComment *treeComment = nil;
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:256];
    ApolloRevealFindLinkOrCommentInTree(viewController.view, 12, visited, &treeLink, &treeComment);
    fullName = treeLink.fullName;
    if ([fullName isKindOfClass:[NSString class]] && fullName.length > 0) return fullName;

    if (treeComment && [(id)treeComment respondsToSelector:@selector(linkIDWithoutTypePrefix)]) {
        id linkID = nil;
        @try { linkID = ((id (*)(id, SEL))objc_msgSend)(treeComment, @selector(linkIDWithoutTypePrefix)); }
        @catch (__unused NSException *e) {}
        if ([linkID isKindOfClass:[NSString class]] && [(NSString *)linkID length] > 0) {
            return [@"t3_" stringByAppendingString:(NSString *)linkID];
        }
    }

    if (sRevealLastObservedCommentsLinkFullName.length > 0 &&
        sRevealLastObservedCommentsLinkDate &&
        [[NSDate date] timeIntervalSinceDate:sRevealLastObservedCommentsLinkDate] < 45.0) {
        ApolloLog(@"[RevealDeleted] Using observed comments request link %@", sRevealLastObservedCommentsLinkFullName);
        return sRevealLastObservedCommentsLinkFullName;
    }
    return nil;
}

static BOOL ApolloRevealNegativeCacheHit(NSString *fullName) {
    if (fullName.length == 0) return YES;
    @synchronized (sNegativeCacheByFullName) {
        NSDate *date = sNegativeCacheByFullName[fullName];
        if (!date) return NO;
        if ([[NSDate date] timeIntervalSinceDate:date] < kApolloRevealNegativeCacheTTL) return YES;
        [sNegativeCacheByFullName removeObjectForKey:fullName];
        return NO;
    }
}

static void ApolloRevealMarkNegative(NSString *fullName) {
    if (fullName.length == 0) return;
    @synchronized (sNegativeCacheByFullName) {
        sNegativeCacheByFullName[fullName] = [NSDate date];
    }
}

static void ApolloRevealFlattenTreeChildren(NSArray *children,
                                            NSMutableDictionary<NSString *, NSDictionary *> *commentsByFullName,
                                            NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *childrenByParentFullName,
                                            NSMutableArray<NSDictionary *> *deletedOrRemovedComments,
                                            NSMutableArray<NSDictionary *> *deletedOrRemovedPlaceholders) {
    if (![children isKindOfClass:[NSArray class]]) return;
    for (id child in children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *entry = (NSDictionary *)child;
        NSString *kind = [entry[@"kind"] isKindOfClass:[NSString class]] ? entry[@"kind"] : nil;
        NSDictionary *data = [entry[@"data"] isKindOfClass:[NSDictionary class]] ? entry[@"data"] : nil;
        if (![kind isEqualToString:@"t1"] || !data) continue;

        NSString *name = [data[@"name"] isKindOfClass:[NSString class]] ? data[@"name"] : nil;
        NSString *identifier = [data[@"id"] isKindOfClass:[NSString class]] ? data[@"id"] : nil;
        NSString *fullName = name.length > 0 ? name : (identifier.length > 0 ? [@"t1_" stringByAppendingString:identifier] : nil);
        if (fullName.length == 0) continue;

        commentsByFullName[fullName] = data;
        NSString *body = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
        NSString *trimmed = ApolloRevealTrimmedString(body);
        if (trimmed.length > 0 && !ApolloRevealBodyLooksDeleted(trimmed)) {
            [sRecoveredCommentBodyByFullName setObject:trimmed forKey:fullName];
        }

        NSString *parentID = [data[@"parent_id"] isKindOfClass:[NSString class]] ? data[@"parent_id"] : nil;
        if (parentID.length > 0) {
            NSMutableArray *siblings = childrenByParentFullName[parentID];
            if (!siblings) {
                siblings = [NSMutableArray array];
                childrenByParentFullName[parentID] = siblings;
            }
            [siblings addObject:data];
        }

        NSDictionary *meta = [data[@"_meta"] isKindOfClass:[NSDictionary class]] ? data[@"_meta"] : nil;
        NSString *removalType = [meta[@"removal_type"] isKindOfClass:[NSString class]] ? [meta[@"removal_type"] lowercaseString] : nil;
        BOOL wasDeletedLater = [meta[@"was_deleted_later"] respondsToSelector:@selector(boolValue)] && [meta[@"was_deleted_later"] boolValue];
        BOOL wasInitiallyDeleted = [meta[@"was_initially_deleted"] respondsToSelector:@selector(boolValue)] && [meta[@"was_initially_deleted"] boolValue];
        BOOL removalMeta = wasDeletedLater || wasInitiallyDeleted || removalType.length > 0;
        BOOL bodyIsDeletedPlaceholder = ApolloRevealBodyLooksDeleted(trimmed);
        BOOL authorIsDeletedPlaceholder = [[data[@"author"] isKindOfClass:[NSString class]] ? [(NSString *)data[@"author"] lowercaseString] : @"" isEqualToString:@"[deleted]"];
        if (trimmed.length > 0 && !bodyIsDeletedPlaceholder) {
            if (removalMeta) [deletedOrRemovedComments addObject:data];
        } else if (bodyIsDeletedPlaceholder || authorIsDeletedPlaceholder) {
            [deletedOrRemovedPlaceholders addObject:data];
        }

        NSDictionary *replies = [data[@"replies"] isKindOfClass:[NSDictionary class]] ? data[@"replies"] : nil;
        NSDictionary *replyData = [replies[@"data"] isKindOfClass:[NSDictionary class]] ? replies[@"data"] : nil;
        NSArray *replyChildren = [replyData[@"children"] isKindOfClass:[NSArray class]] ? replyData[@"children"] : nil;
        ApolloRevealFlattenTreeChildren(replyChildren, commentsByFullName, childrenByParentFullName, deletedOrRemovedComments, deletedOrRemovedPlaceholders);
    }
}

static NSDictionary *ApolloRevealBuildThreadCacheFromRoot(id root, NSString *linkFullName) {
    NSArray *children = nil;
    if ([root isKindOfClass:[NSDictionary class]]) {
        id data = ((NSDictionary *)root)[@"data"];
        if ([data isKindOfClass:[NSArray class]]) {
            children = data;
        } else if ([data isKindOfClass:[NSDictionary class]]) {
            id listingChildren = ((NSDictionary *)data)[@"children"];
            if ([listingChildren isKindOfClass:[NSArray class]]) children = listingChildren;
        }
    }
    if (![children isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *commentsByFullName = [NSMutableDictionary dictionary];
    NSMutableDictionary *childrenByParentFullName = [NSMutableDictionary dictionary];
    NSMutableArray *deletedOrRemovedComments = [NSMutableArray array];
    NSMutableArray *deletedOrRemovedPlaceholders = [NSMutableArray array];
    ApolloRevealFlattenTreeChildren(children, commentsByFullName, childrenByParentFullName, deletedOrRemovedComments, deletedOrRemovedPlaceholders);
    if (commentsByFullName.count == 0) return nil;

    return @{
        @"link": linkFullName ?: @"",
        @"comments": commentsByFullName,
        @"children": childrenByParentFullName,
        @"deleted": deletedOrRemovedComments,
        @"deletedPlaceholders": deletedOrRemovedPlaceholders,
    };
}

static NSString *ApolloRevealFormattedCommentSummary(NSDictionary *comment) {
    if (![comment isKindOfClass:[NSDictionary class]]) return nil;
    NSString *author = [comment[@"author"] isKindOfClass:[NSString class]] ? comment[@"author"] : @"unknown";
    NSString *body = ApolloRevealTrimmedString([comment[@"body"] isKindOfClass:[NSString class]] ? comment[@"body"] : nil);
    if (body.length == 0 || ApolloRevealBodyLooksDeleted(body)) return nil;
    NSNumber *score = [comment[@"score"] respondsToSelector:@selector(integerValue)] ? comment[@"score"] : nil;
    if (score) {
        return [NSString stringWithFormat:@"%@ (%ld): %@", author, (long)[score integerValue], body];
    }
    return [NSString stringWithFormat:@"%@: %@", author, body];
}

static NSString *__attribute__((unused)) ApolloRevealMissingRepliesText(NSDictionary *threadCache, NSUInteger limit) {
    NSArray *deleted = [threadCache[@"deleted"] isKindOfClass:[NSArray class]] ? threadCache[@"deleted"] : nil;
    if (deleted.count == 0) {
        NSDictionary *comments = [threadCache[@"comments"] isKindOfClass:[NSDictionary class]] ? threadCache[@"comments"] : nil;
        deleted = comments.allValues;
    }
    if (deleted.count == 0) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger count = 0;
    for (NSDictionary *comment in deleted) {
        NSString *summary = ApolloRevealFormattedCommentSummary(comment);
        if (summary.length == 0) continue;
        [parts addObject:[NSString stringWithFormat:@"- %@", summary]];
        count++;
        if (limit > 0 && count >= limit) break;
        if (count >= 12) break;
    }
    if (parts.count == 0) return nil;
    return [NSString stringWithFormat:@"[Recovered deleted replies]\n%@", [parts componentsJoinedByString:@"\n\n"]];
}

static NSDictionary *ApolloRevealThreadCacheForVisibleLink(void) {
    if (sVisibleRevealLinkFullName.length == 0) return nil;
    return [sRecoveredThreadTreeByLinkFullName objectForKey:sVisibleRevealLinkFullName];
}

static BOOL ApolloRevealTextMentionsDeletedOrRemoved(NSString *text) {
    NSString *lower = [[ApolloRevealTrimmedString(text) ?: @"" lowercaseString] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return [lower containsString:@"deleted"] ||
           [lower containsString:@"removed"];
}

static BOOL ApolloRevealTextLooksLikeMoreRepliesPlaceholder(NSString *text, NSUInteger *countOut) {
    NSString *lower = [[ApolloRevealTrimmedString(text) ?: @"" lowercaseString] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (![lower containsString:@"more repl"]) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:lower];
    NSInteger parsed = 0;
    if (![scanner scanInteger:&parsed] || parsed <= 0) return NO;
    if (countOut) *countOut = (NSUInteger)parsed;
    return YES;
}

static BOOL ApolloRevealFindNodeInVisibleTree(id object,
                                              id target,
                                              NSInteger depth,
                                              NSHashTable *visited,
                                              RDKComment *nearestComment,
                                              RDKComment **commentOut,
                                              NSMutableArray<NSString *> *pathOut) {
    if (!object || !target || depth < 0) return NO;
    if (visited.count >= 4096) return NO;
    if ([visited containsObject:object]) return NO;
    [visited addObject:object];

    RDKComment *comment = ApolloRevealCommentFromCellNode(object);
    RDKComment *currentNearest = comment ?: nearestComment;
    const char *className = class_getName(object_getClass(object));
    if (pathOut && className) [pathOut addObject:[NSString stringWithUTF8String:className]];

    if (object == target) {
        if (commentOut) *commentOut = currentNearest;
        return YES;
    }

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object &&
                ApolloRevealFindNodeInVisibleTree(node, target, depth - 1, visited, currentNearest, commentOut, pathOut)) {
                return YES;
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) {
                    if (ApolloRevealFindNodeInVisibleTree(subnode, target, depth - 1, visited, currentNearest, commentOut, pathOut)) {
                        return YES;
                    }
                }
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        if ([object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id subview in subviews) {
                    if (ApolloRevealFindNodeInVisibleTree(subview, target, depth - 1, visited, currentNearest, commentOut, pathOut)) {
                        return YES;
                    }
                }
            }
        }
    } @catch (__unused NSException *e) {}

    if (pathOut && pathOut.count > 0) [pathOut removeLastObject];
    return NO;
}

static RDKComment *ApolloRevealNearestCommentForNode(id node, NSString **fullNameOut, NSMutableArray<NSString *> *classChain) {
    SEL supernodeSel = NSSelectorFromString(@"supernode");
    id current = node;
    for (NSUInteger i = 0; current && i < 16; i++) {
        const char *className = class_getName(object_getClass(current));
        if (className && classChain) [classChain addObject:[NSString stringWithUTF8String:className]];
        RDKComment *comment = ApolloRevealCommentFromCellNode(current);
        if (comment) {
            NSString *fullName = ApolloRevealFullNameForComment(comment);
            if (fullNameOut) *fullNameOut = fullName;
            return comment;
        }
        if (![current respondsToSelector:supernodeSel]) break;
        @try { current = ((id (*)(id, SEL))objc_msgSend)(current, supernodeSel); }
        @catch (__unused NSException *e) { break; }
    }

    UIViewController *vc = sVisibleRevealCommentsViewController;
    if (vc && vc.isViewLoaded) {
        RDKComment *foundComment = nil;
        NSMutableArray<NSString *> *path = [NSMutableArray array];
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:512];
        if (ApolloRevealFindNodeInVisibleTree(vc.view, node, 24, visited, nil, &foundComment, path)) {
            if (classChain) {
                [classChain removeAllObjects];
                [classChain addObjectsFromArray:path];
            }
            NSString *fullName = ApolloRevealFullNameForComment(foundComment);
            if (fullNameOut) *fullNameOut = fullName;
            return foundComment;
        }
    }
    return nil;
}

static void ApolloRevealCollectAttributedTextNodes(id object,
                                                   NSInteger depth,
                                                   NSHashTable *visited,
                                                   NSMutableArray *nodes) {
    if (!object || depth < 0) return;
    if (visited.count >= kApolloRevealMaxVisitedNodes) return;

    Class displayNodeCls = NSClassFromString(@"ASDisplayNode");
    BOOL isDisplayNode = displayNodeCls && [object isKindOfClass:displayNodeCls];
    BOOL isView = [object isKindOfClass:[UIView class]];
    if (!isDisplayNode && !isView) return;
    if ([visited containsObject:object]) return;
    [visited addObject:object];

    @try {
        if ([object respondsToSelector:@selector(attributedText)] &&
            [object respondsToSelector:@selector(setAttributedText:)]) {
            NSAttributedString *attr = ((id (*)(id, SEL))objc_msgSend)(object, @selector(attributedText));
            if ([attr isKindOfClass:[NSAttributedString class]] && attr.string.length > 0) {
                [nodes addObject:object];
            }
        }
    } @catch (__unused NSException *e) {}

    if (depth == 0) return;

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object) ApolloRevealCollectAttributedTextNodes(node, depth - 1, visited, nodes);
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) {
                    if (visited.count >= kApolloRevealMaxVisitedNodes) break;
                    ApolloRevealCollectAttributedTextNodes(subnode, depth - 1, visited, nodes);
                }
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        BOOL viewLoaded = isView;
        SEL isViewLoadedSel = NSSelectorFromString(@"isNodeLoaded");
        if (!viewLoaded && [object respondsToSelector:isViewLoadedSel]) {
            viewLoaded = ((BOOL (*)(id, SEL))objc_msgSend)(object, isViewLoadedSel);
        }
        if (viewLoaded && [object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id subview in subviews) {
                    if (visited.count >= kApolloRevealMaxVisitedNodes) break;
                    ApolloRevealCollectAttributedTextNodes(subview, depth - 1, visited, nodes);
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

static id ApolloRevealKnownBodyTextNode(id commentCellNode) {
    if (!commentCellNode) return nil;
    static const char *kCandidateNames[] = {
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
    for (Class cls = object_getClass(commentCellNode); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; kCandidateNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, kCandidateNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id node = nil;
            @try { node = object_getIvar(commentCellNode, ivar); } @catch (__unused NSException *e) { continue; }
            if ([node respondsToSelector:@selector(attributedText)] && [node respondsToSelector:@selector(setAttributedText:)]) return node;
        }
    }
    return nil;
}

static id ApolloRevealBestCommentTextNode(id commentCellNode, RDKComment *comment) {
    id known = ApolloRevealKnownBodyTextNode(commentCellNode);
    if (known) return known;

    NSString *placeholder = ApolloRevealTrimmedString(comment.body);
    NSMutableArray *nodes = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
    ApolloRevealCollectAttributedTextNodes(commentCellNode, 5, visited, nodes);

    id bestNode = nil;
    NSInteger bestScore = NSIntegerMin;
    for (id node in nodes) {
        NSAttributedString *attr = nil;
        @try { attr = ((id (*)(id, SEL))objc_msgSend)(node, @selector(attributedText)); }
        @catch (__unused NSException *e) { continue; }
        if (![attr isKindOfClass:[NSAttributedString class]]) continue;

        NSString *text = ApolloRevealTrimmedString(attr.string);
        if (text.length == 0) continue;
        NSInteger score = NSIntegerMin;
        if ([text isEqualToString:placeholder]) {
            score = 100000 + (NSInteger)text.length;
        } else if (ApolloRevealBodyLooksDeleted(text)) {
            score = 75000 + (NSInteger)text.length;
        }
        if (score > bestScore) {
            bestScore = score;
            bestNode = node;
        }
    }
    return bestNode;
}

static void ApolloRevealNudgeLayout(id owner, id textNode) {
    SEL invalidateSel = NSSelectorFromString(@"invalidateCalculatedLayout");
    SEL supernodeSel = NSSelectorFromString(@"supernode");
    SEL transitionSel = NSSelectorFromString(@"transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:");

    void (^nudge)(id) = ^(id object) {
        if (!object) return;
        @try {
            if ([object respondsToSelector:invalidateSel]) ((void (*)(id, SEL))objc_msgSend)(object, invalidateSel);
            if ([object respondsToSelector:@selector(setNeedsLayout)]) ((void (*)(id, SEL))objc_msgSend)(object, @selector(setNeedsLayout));
            if ([object respondsToSelector:@selector(setNeedsDisplay)]) ((void (*)(id, SEL))objc_msgSend)(object, @selector(setNeedsDisplay));
            if ([object isKindOfClass:[UIView class]]) {
                UIView *view = (UIView *)object;
                [view setNeedsLayout];
                [view layoutIfNeeded];
            }
        } @catch (__unused NSException *e) {}
    };

    nudge(textNode);
    nudge(owner);

    id current = textNode;
    id cellNode = nil;
    for (NSUInteger i = 0; current && i < 8; i++) {
        nudge(current);
        const char *className = class_getName(object_getClass(current));
        if (!cellNode && className && strstr(className, "CellNode")) cellNode = current;
        if (![current respondsToSelector:supernodeSel]) break;
        @try { current = ((id (*)(id, SEL))objc_msgSend)(current, supernodeSel); }
        @catch (__unused NSException *e) { break; }
    }
    if (!cellNode) cellNode = owner;

    @try {
        if ([cellNode respondsToSelector:transitionSel]) {
            NSMethodSignature *sig = [cellNode methodSignatureForSelector:transitionSel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = cellNode;
                inv.selector = transitionSel;
                BOOL animated = NO;
                BOOL async = NO;
                void (^completion)(void) = nil;
                [inv setArgument:&animated atIndex:2];
                [inv setArgument:&async atIndex:3];
                [inv setArgument:&completion atIndex:4];
                [inv invoke];
            }
        }
    } @catch (__unused NSException *e) {}
}

static NSAttributedString *ApolloRevealAttributedString(NSAttributedString *current, NSString *recoveredBody, __unused NSString *author) {
    NSDictionary *bodyAttrs = @{};
    if (current.length > 0) {
        bodyAttrs = [current attributesAtIndex:0 effectiveRange:nil] ?: @{};
    }
    return [[NSAttributedString alloc] initWithString:recoveredBody ?: @"" attributes:bodyAttrs];
}

static NSAttributedString *ApolloRevealStyledDeletedCommentFlair(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    NSString *text = ApolloRevealTrimmedString(attributedText.string);
    if (![[text lowercaseString] isEqualToString:@"deleted"]) return attributedText;

    UIColor *red = nil;
    if (@available(iOS 13.0, *)) {
        red = [UIColor systemRedColor];
    } else {
        red = [UIColor redColor];
    }

    NSMutableAttributedString *styled = [attributedText mutableCopy];
    NSRange fullRange = NSMakeRange(0, styled.length);
    [styled addAttribute:NSForegroundColorAttributeName value:red range:fullRange];
    [styled removeAttribute:NSBackgroundColorAttributeName range:fullRange];
    return styled;
}

static BOOL ApolloRevealAttributedTextIsDeletedCommentFlair(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;
    NSString *text = ApolloRevealTrimmedString(attributedText.string);
    return [[text lowercaseString] isEqualToString:@"deleted"];
}

static UIColor *ApolloRevealDeletedCommentFlairBackgroundColor(void) {
    UIColor *red = nil;
    if (@available(iOS 13.0, *)) {
        red = [UIColor systemRedColor];
    } else {
        red = [UIColor redColor];
    }
    return [red colorWithAlphaComponent:0.24];
}

static id ApolloRevealDeletedCommentFlairContainerForTextNode(id textNode) {
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

static void ApolloRevealRestoreDeletedCommentFlairContainer(id textNode) {
    id container = objc_getAssociatedObject(textNode, kApolloRevealDeletedFlairContainerKey);
    if (!container) return;
    UIColor *original = objc_getAssociatedObject(textNode, kApolloRevealDeletedFlairOriginalBackgroundKey);
    if ([container respondsToSelector:@selector(setBackgroundColor:)]) {
        @try {
            ((void (*)(id, SEL, UIColor *))objc_msgSend)(container, @selector(setBackgroundColor:), original);
        } @catch (__unused NSException *e) {}
    }
    objc_setAssociatedObject(textNode, kApolloRevealDeletedFlairContainerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloRevealDeletedFlairOriginalBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloRevealApplyDeletedCommentFlairContainerStyle(id textNode, NSAttributedString *attributedText) {
    if (!ApolloRevealAttributedTextIsDeletedCommentFlair(attributedText)) {
        ApolloRevealRestoreDeletedCommentFlairContainer(textNode);
        return;
    }

    id container = ApolloRevealDeletedCommentFlairContainerForTextNode(textNode);
    if (!container) return;
    id previous = objc_getAssociatedObject(textNode, kApolloRevealDeletedFlairContainerKey);
    if (previous && previous != container) ApolloRevealRestoreDeletedCommentFlairContainer(textNode);
    if (!objc_getAssociatedObject(textNode, kApolloRevealDeletedFlairContainerKey)) {
        UIColor *original = nil;
        if ([container respondsToSelector:@selector(backgroundColor)]) {
            @try {
                original = ((UIColor *(*)(id, SEL))objc_msgSend)(container, @selector(backgroundColor));
            } @catch (__unused NSException *e) {
                original = nil;
            }
        }
        objc_setAssociatedObject(textNode, kApolloRevealDeletedFlairContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (original) objc_setAssociatedObject(textNode, kApolloRevealDeletedFlairOriginalBackgroundKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    @try {
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(container, @selector(setBackgroundColor:), ApolloRevealDeletedCommentFlairBackgroundColor());
    } @catch (__unused NSException *e) {}
}

static NSAttributedString *__attribute__((unused)) ApolloRevealAttributedStringWithMarker(NSAttributedString *current, NSString *marker, NSString *body) {
    NSDictionary *bodyAttrs = current.length > 0 ? ([current attributesAtIndex:0 effectiveRange:nil] ?: @{}) : @{};
    NSMutableDictionary *markerAttrs = [bodyAttrs mutableCopy];
    UIFont *font = markerAttrs[NSFontAttributeName];
    markerAttrs[NSFontAttributeName] = [font isKindOfClass:[UIFont class]]
        ? [UIFont boldSystemFontOfSize:MAX(11.0, font.pointSize - 1.0)]
        : [UIFont boldSystemFontOfSize:12.0];
    if (@available(iOS 13.0, *)) {
        markerAttrs[NSForegroundColorAttributeName] = [UIColor systemOrangeColor];
    } else {
        markerAttrs[NSForegroundColorAttributeName] = [UIColor orangeColor];
    }

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:[marker stringByAppendingString:@"\n"] attributes:markerAttrs]];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:body attributes:bodyAttrs]];
    return result;
}

static BOOL ApolloRevealApplyRecoveredBody(id commentCellNode, RDKComment *comment, NSString *fullName, NSString *recoveredBody, NSString *author) {
    if (!sRevealDeletedComments) return NO;
    if (!commentCellNode || !comment || fullName.length == 0) return NO;
    if (!ApolloRevealBodyLooksDeleted(comment.body)) return NO;
    NSString *trimmed = ApolloRevealTrimmedString(recoveredBody);
    if (trimmed.length == 0 || ApolloRevealBodyLooksDeleted(trimmed)) return NO;

    NSString *currentFullName = ApolloRevealFullNameForComment(ApolloRevealCommentFromCellNode(commentCellNode));
    if (![currentFullName isEqualToString:fullName]) return NO;

    id textNode = ApolloRevealBestCommentTextNode(commentCellNode, comment);
    if (!textNode) {
        @synchronized (sLoggedRevealSkipFullNames) {
            if (![sLoggedRevealSkipFullNames containsObject:fullName]) {
                [sLoggedRevealSkipFullNames addObject:fullName];
                ApolloLog(@"[RevealDeleted] Skipping %@: could not find body text node", fullName);
            }
        }
        return NO;
    }

    NSAttributedString *current = nil;
    @try { current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText)); }
    @catch (__unused NSException *e) { return NO; }
    if (![current isKindOfClass:[NSAttributedString class]]) return NO;

    NSString *currentText = ApolloRevealTrimmedString(current.string);
    NSString *alreadyRecovered = objc_getAssociatedObject(textNode, kApolloRevealRecoveredTextKey);
    BOOL displaysPlaceholder = ApolloRevealBodyLooksDeleted(currentText);
    BOOL displaysSameRecoveredText = [alreadyRecovered isKindOfClass:[NSString class]] && [alreadyRecovered isEqualToString:trimmed];
    if (!displaysPlaceholder && !displaysSameRecoveredText) return NO;

    if (!objc_getAssociatedObject(textNode, kApolloRevealOriginalAttributedTextKey)) {
        objc_setAssociatedObject(textNode, kApolloRevealOriginalAttributedTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSAttributedString *recoveredAttr = ApolloRevealAttributedString(current, trimmed, author);
    objc_setAssociatedObject(textNode, kApolloRevealOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloRevealRecoveredTextKey, [trimmed copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloRevealRecoveredAuthorKey, [ApolloRevealTrimmedString(author) copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(commentCellNode, kApolloRevealTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(commentCellNode, kApolloRevealAppliedFullNameKey, [fullName copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    @synchronized (sOwnedRevealTextNodes) {
        [sOwnedRevealTextNodes addObject:textNode];
    }

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), recoveredAttr);
    } @catch (__unused NSException *e) {
        return NO;
    }
    ApolloLog(@"[RevealDeleted] Applied recovered body for %@ (author=%@)", fullName, author ?: @"nil");

    objc_setAssociatedObject(commentCellNode, kApolloRevealRecentlyAppliedKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakCell = commentCellNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongCell = weakCell;
        if (strongCell) objc_setAssociatedObject(strongCell, kApolloRevealRecentlyAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });

    ApolloRevealNudgeLayout(commentCellNode, textNode);
    return YES;
}

static void ApolloRevealRestoreCellNode(id commentCellNode) {
    if (!commentCellNode) return;
    RDKComment *comment = ApolloRevealCommentFromCellNode(commentCellNode);
    id textNode = ApolloRevealBestCommentTextNode(commentCellNode, comment);
    if (!textNode) textNode = objc_getAssociatedObject(commentCellNode, kApolloRevealTextNodeKey);

    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloRevealOriginalAttributedTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) return;

    NSString *currentRecovered = objc_getAssociatedObject(textNode, kApolloRevealRecoveredTextKey);
    NSAttributedString *current = nil;
    @try { current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText)); }
    @catch (__unused NSException *e) { return; }
    if ([currentRecovered isKindOfClass:[NSString class]] && current.string.length > 0 &&
        ![current.string containsString:currentRecovered]) {
        return;
    }

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), original);
    } @catch (__unused NSException *e) {
        return;
    }

    objc_setAssociatedObject(textNode, kApolloRevealOriginalAttributedTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloRevealOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloRevealRecoveredTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloRevealRecoveredAuthorKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(commentCellNode, kApolloRevealTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(commentCellNode, kApolloRevealAppliedFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloRevealNudgeLayout(commentCellNode, textNode);
}

static void ApolloRevealFetchBodyForFullName(NSString *fullName, void (^completion)(NSString *body, NSString *author)) {
    if (fullName.length == 0) {
        completion(nil, nil);
        return;
    }

    NSString *cached = [sRecoveredCommentBodyByFullName objectForKey:fullName];
    if (cached.length > 0) {
        completion(cached, nil);
        return;
    }

    if (ApolloRevealNegativeCacheHit(fullName)) {
        completion(nil, nil);
        return;
    }

    @synchronized (sInFlightFullNames) {
        if ([sInFlightFullNames containsObject:fullName]) {
            completion(nil, nil);
            return;
        }
        [sInFlightFullNames addObject:fullName];
    }

    NSString *commentID = ApolloRevealArcticIDFromFullName(fullName);
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://arctic-shift.photon-reddit.com/api/comments/ids"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"ids" value:commentID],
        [NSURLQueryItem queryItemWithName:@"fields" value:@"id,author,body,created_utc,link_id,parent_id,score"],
        [NSURLQueryItem queryItemWithName:@"md2html" value:@"false"],
    ];
    NSURL *url = components.URL;
    if (!url) {
        @synchronized (sInFlightFullNames) { [sInFlightFullNames removeObject:fullName]; }
        ApolloRevealMarkNegative(fullName);
        completion(nil, nil);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *body = nil;
        NSString *author = nil;
        if (!error && data.length > 0) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (!http || (http.statusCode >= 200 && http.statusCode < 300)) {
                id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray *items = [root isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)root)[@"data"] : nil;
                NSDictionary *item = [items isKindOfClass:[NSArray class]] && items.count > 0 && [items[0] isKindOfClass:[NSDictionary class]] ? items[0] : nil;
                NSString *candidate = [item[@"body"] isKindOfClass:[NSString class]] ? item[@"body"] : nil;
                author = [item[@"author"] isKindOfClass:[NSString class]] ? item[@"author"] : nil;
                NSString *trimmed = ApolloRevealTrimmedString(candidate);
                if (trimmed.length > 0 && !ApolloRevealBodyLooksDeleted(trimmed)) {
                    body = trimmed;
                    [sRecoveredCommentBodyByFullName setObject:body forKey:fullName];
                }
            }
        }

        if (body.length == 0) ApolloRevealMarkNegative(fullName);
        @synchronized (sInFlightFullNames) {
            [sInFlightFullNames removeObject:fullName];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(body, author);
        });
    }];
    [task resume];
}

static void ApolloRevealFetchThreadForLinkFullName(NSString *linkFullName, void (^completion)(NSDictionary *threadCache)) {
    if (linkFullName.length == 0) {
        if (completion) completion(nil);
        return;
    }

    NSDictionary *cached = [sRecoveredThreadTreeByLinkFullName objectForKey:linkFullName];
    if (cached) {
        if (completion) completion(cached);
        return;
    }

    @synchronized (sInFlightThreadFullNames) {
        if ([sInFlightThreadFullNames containsObject:linkFullName]) {
            if (completion) completion(nil);
            return;
        }
        [sInFlightThreadFullNames addObject:linkFullName];
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://arctic-shift.photon-reddit.com/api/comments/tree"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"link_id" value:linkFullName],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"25000"],
        [NSURLQueryItem queryItemWithName:@"start_depth" value:@"99"],
        [NSURLQueryItem queryItemWithName:@"start_breadth" value:@"99"],
        [NSURLQueryItem queryItemWithName:@"md2html" value:@"false"],
    ];
    NSURL *url = components.URL;
    if (!url) {
        @synchronized (sInFlightThreadFullNames) { [sInFlightThreadFullNames removeObject:linkFullName]; }
        if (completion) completion(nil);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *threadCache = nil;
        if (!error && data.length > 0) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (!http || (http.statusCode >= 200 && http.statusCode < 300)) {
                id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                threadCache = ApolloRevealBuildThreadCacheFromRoot(root, linkFullName);
                if (threadCache) {
                    [sRecoveredThreadTreeByLinkFullName setObject:threadCache forKey:linkFullName];
                    ApolloLog(@"[RevealDeleted] Cached Arctic tree for %@ (%lu comments, %lu deleted/removed)",
                              linkFullName,
                              (unsigned long)[threadCache[@"comments"] count],
                              (unsigned long)([threadCache[@"deleted"] count] + [threadCache[@"deletedPlaceholders"] count]));
                }
            }
        }

        @synchronized (sInFlightThreadFullNames) {
            [sInFlightThreadFullNames removeObject:linkFullName];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(threadCache);
        });
    }];
    [task resume];
}

static void ApolloRevealMaybeRevealCellNode(id commentCellNode) {
    if (!commentCellNode) return;
    if (!sRevealDeletedComments) {
        ApolloRevealRestoreCellNode(commentCellNode);
        return;
    }

    RDKComment *comment = ApolloRevealCommentFromCellNode(commentCellNode);
    if (!comment) {
        ApolloRevealRestoreCellNode(commentCellNode);
        return;
    }
    if (!ApolloRevealBodyLooksDeleted(comment.body)) return;

    NSString *fullName = ApolloRevealFullNameForComment(comment);
    if (fullName.length == 0) return;

    NSString *cached = [sRecoveredCommentBodyByFullName objectForKey:fullName];
    if (cached.length > 0) {
        NSDictionary *threadCache = ApolloRevealThreadCacheForVisibleLink();
        NSDictionary *comments = [threadCache[@"comments"] isKindOfClass:[NSDictionary class]] ? threadCache[@"comments"] : nil;
        NSDictionary *archivedComment = [comments[fullName] isKindOfClass:[NSDictionary class]] ? comments[fullName] : nil;
        NSString *cachedAuthor = [archivedComment[@"author"] isKindOfClass:[NSString class]] ? archivedComment[@"author"] : nil;
        ApolloRevealApplyRecoveredBody(commentCellNode, comment, fullName, cached, cachedAuthor);
        return;
    }

    NSDictionary *threadCache = ApolloRevealThreadCacheForVisibleLink();
    NSDictionary *comments = [threadCache[@"comments"] isKindOfClass:[NSDictionary class]] ? threadCache[@"comments"] : nil;
    NSDictionary *archivedComment = [comments[fullName] isKindOfClass:[NSDictionary class]] ? comments[fullName] : nil;
    NSString *archivedBody = ApolloRevealTrimmedString([archivedComment[@"body"] isKindOfClass:[NSString class]] ? archivedComment[@"body"] : nil);
    NSString *archivedAuthor = [archivedComment[@"author"] isKindOfClass:[NSString class]] ? archivedComment[@"author"] : nil;
    if (archivedBody.length > 0 && !ApolloRevealBodyLooksDeleted(archivedBody)) {
        [sRecoveredCommentBodyByFullName setObject:archivedBody forKey:fullName];
        ApolloRevealApplyRecoveredBody(commentCellNode, comment, fullName, archivedBody, archivedAuthor);
        return;
    }
    if (archivedComment) {
        @synchronized (sLoggedRevealPlaceholderFullNames) {
            if (![sLoggedRevealPlaceholderFullNames containsObject:fullName]) {
                [sLoggedRevealPlaceholderFullNames addObject:fullName];
                ApolloLog(@"[RevealDeleted] Arctic has no recovered body for %@ (archived author=%@ body=%@)",
                          fullName,
                          archivedAuthor ?: @"nil",
                          archivedBody ?: @"nil");
            }
        }
    }

    objc_setAssociatedObject(commentCellNode, kApolloRevealRequestFullNameKey, [fullName copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    __weak id weakCellNode = commentCellNode;
    ApolloRevealFetchBodyForFullName(fullName, ^(NSString *body, NSString *author) {
        if (body.length == 0) return;
        id strongCellNode = weakCellNode;
        if (!strongCellNode) return;
        NSString *currentRequestFullName = objc_getAssociatedObject(strongCellNode, kApolloRevealRequestFullNameKey);
        if (![currentRequestFullName isEqualToString:fullName]) return;
        RDKComment *strongComment = ApolloRevealCommentFromCellNode(strongCellNode);
        if (!strongComment) return;
        ApolloRevealApplyRecoveredBody(strongCellNode, strongComment, fullName, body, author);
    });
}

static void ApolloRevealScheduleReapplyForCellNode(id commentCellNode) {
    if (!commentCellNode || !sRevealDeletedComments) return;
    if ([objc_getAssociatedObject(commentCellNode, kApolloRevealReapplyScheduledKey) boolValue]) return;
    if ([objc_getAssociatedObject(commentCellNode, kApolloRevealRecentlyAppliedKey) boolValue]) return;
    objc_setAssociatedObject(commentCellNode, kApolloRevealReapplyScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakCell = commentCellNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongCell = weakCell;
        if (!strongCell) return;
        objc_setAssociatedObject(strongCell, kApolloRevealReapplyScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloRevealMaybeRevealCellNode(strongCell);
    });
}

static void ApolloRevealWalkCommentCells(id object, NSInteger depth, NSHashTable *visited, void (^block)(id cellNode)) {
    if (!object || depth < 0) return;
    if (visited.count >= 2048) return;
    if ([visited containsObject:object]) return;
    [visited addObject:object];

    Class displayNodeCls = NSClassFromString(@"ASDisplayNode");
    BOOL isDisplayNode = displayNodeCls && [object isKindOfClass:displayNodeCls];
    BOOL isView = [object isKindOfClass:[UIView class]];
    if (!isDisplayNode && !isView) return;

    if (isDisplayNode && ApolloRevealCommentFromCellNode(object)) {
        block(object);
    }

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object) ApolloRevealWalkCommentCells(node, depth - 1, visited, block);
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloRevealWalkCommentCells(subnode, depth - 1, visited, block);
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        if ([object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id subview in subviews) ApolloRevealWalkCommentCells(subview, depth - 1, visited, block);
            }
        }
    } @catch (__unused NSException *e) {}
}

static BOOL ApolloRevealTextLooksLikeMissingRepliesPlaceholder(NSString *text, NSUInteger *countOut) {
    NSString *lower = [[ApolloRevealTrimmedString(text) ?: @"" lowercaseString] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    BOOL deletedReplies = [lower containsString:@"repl"] && ([lower containsString:@"deleted"] || [lower containsString:@"removed"]);
    if (!deletedReplies) return NO;

    NSUInteger count = 0;
    NSScanner *scanner = [NSScanner scannerWithString:lower];
    NSInteger parsed = 0;
    if ([scanner scanInteger:&parsed] && parsed > 0) count = (NSUInteger)parsed;
    if (countOut) *countOut = count;
    return YES;
}

static void ApolloRevealApplyMissingRepliesToTextNode(id textNode, NSDictionary *threadCache, NSUInteger limit) {
    // Disabled: aggregating many archived replies into one placeholder creates a
    // fake mega-comment. Recovered replies should enter Apollo through the JSON
    // response/model path so they render as normal threaded comments.
}

static NSArray<NSDictionary *> *ApolloRevealRecoverableChildrenForParent(NSDictionary *threadCache, NSString *parentFullName) {
    if (parentFullName.length == 0) return nil;
    NSDictionary *childrenByParent = [threadCache[@"children"] isKindOfClass:[NSDictionary class]] ? threadCache[@"children"] : nil;
    NSArray *children = [childrenByParent[parentFullName] isKindOfClass:[NSArray class]] ? childrenByParent[parentFullName] : nil;
    if (children.count == 0) return nil;

    NSMutableArray<NSDictionary *> *recoverable = [NSMutableArray array];
    for (NSDictionary *child in children) {
        NSString *body = ApolloRevealTrimmedString([child[@"body"] isKindOfClass:[NSString class]] ? child[@"body"] : nil);
        if (body.length == 0 || ApolloRevealBodyLooksDeleted(body)) continue;
        [recoverable addObject:child];
    }
    return recoverable.count > 0 ? recoverable : nil;
}

static NSArray<NSDictionary *> *__attribute__((unused)) ApolloRevealRecoverableCommentsForMoreComments(NSDictionary *threadCache, id moreComments) {
    if (!threadCache || !moreComments) return nil;
    NSDictionary *comments = [threadCache[@"comments"] isKindOfClass:[NSDictionary class]] ? threadCache[@"comments"] : nil;
    if (comments.count == 0) return nil;

    NSMutableArray<NSDictionary *> *recoverable = [NSMutableArray array];
    id children = nil;
    @try {
        if ([moreComments respondsToSelector:@selector(children)]) {
            children = ((id (*)(id, SEL))objc_msgSend)(moreComments, @selector(children));
        }
    } @catch (__unused NSException *e) {}
    if (![children isKindOfClass:[NSArray class]]) {
        children = ApolloRevealIvarValueByName(moreComments, "_children");
    }

    if ([children isKindOfClass:[NSArray class]]) {
        for (id childID in (NSArray *)children) {
            NSString *fullName = nil;
            if ([childID isKindOfClass:[NSString class]]) {
                fullName = ApolloRevealCommentFullNameFromIdentifier(childID);
            } else if ([childID respondsToSelector:@selector(stringValue)]) {
                fullName = ApolloRevealCommentFullNameFromIdentifier([childID stringValue]);
            }
            NSDictionary *comment = [comments[fullName] isKindOfClass:[NSDictionary class]] ? comments[fullName] : nil;
            NSString *body = ApolloRevealTrimmedString([comment[@"body"] isKindOfClass:[NSString class]] ? comment[@"body"] : nil);
            if (body.length == 0 || ApolloRevealBodyLooksDeleted(body)) continue;
            [recoverable addObject:comment];
        }
    }

    if (recoverable.count > 0) return recoverable;

    NSString *parentID = nil;
    @try {
        if ([moreComments respondsToSelector:@selector(parentID)]) {
            parentID = ((id (*)(id, SEL))objc_msgSend)(moreComments, @selector(parentID));
        }
    } @catch (__unused NSException *e) {}
    if (![parentID isKindOfClass:[NSString class]]) {
        parentID = ApolloRevealIvarValueByName(moreComments, "_parentID");
    }
    NSString *parentFullName = ApolloRevealCommentFullNameFromIdentifier(parentID);
    return ApolloRevealRecoverableChildrenForParent(threadCache, parentFullName);
}

static NSString *__attribute__((unused)) ApolloRevealSummaryTextForComments(NSArray<NSDictionary *> *comments, NSUInteger limit) {
    if (comments.count == 0) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger count = 0;
    for (NSDictionary *comment in comments) {
        NSString *summary = ApolloRevealFormattedCommentSummary(comment);
        if (summary.length == 0) continue;
        [parts addObject:[NSString stringWithFormat:@"- %@", summary]];
        count++;
        if (limit > 0 && count >= limit) break;
        if (count >= 12) break;
    }
    return parts.count > 0 ? [parts componentsJoinedByString:@"\n\n"] : nil;
}

static BOOL ApolloRevealApplyArchivedChildrenToTextNode(id textNode, NSAttributedString *current, NSDictionary *threadCache, NSString *parentFullName, NSUInteger limit) {
    return NO;
}

static BOOL ApolloRevealApplyMoreCommentsCellNode(id cellNode, NSString *source) {
    return NO;
}

static void ApolloRevealScheduleMoreCommentsCellNode(id cellNode, NSString *source) {
    if (!cellNode || !sRevealDeletedComments) return;
    if ([objc_getAssociatedObject(cellNode, kApolloRevealMoreCommentsApplyScheduledKey) boolValue]) return;
    objc_setAssociatedObject(cellNode, kApolloRevealMoreCommentsApplyScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakCell = cellNode;
    NSString *sourceCopy = [source copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongCell = weakCell;
        if (!strongCell) return;
        objc_setAssociatedObject(strongCell, kApolloRevealMoreCommentsApplyScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloRevealApplyMoreCommentsCellNode(strongCell, sourceCopy);
    });
}

static BOOL ApolloRevealApplyDirectArchivedCommentToTextNode(id textNode, NSAttributedString *current, NSDictionary *threadCache, NSString *fullName) {
    if (!textNode || ![current isKindOfClass:[NSAttributedString class]] || !threadCache || fullName.length == 0) return NO;
    if (objc_getAssociatedObject(textNode, kApolloRevealOwnedTextNodeKey)) return NO;
    NSDictionary *comments = [threadCache[@"comments"] isKindOfClass:[NSDictionary class]] ? threadCache[@"comments"] : nil;
    NSDictionary *archivedComment = [comments[fullName] isKindOfClass:[NSDictionary class]] ? comments[fullName] : nil;
    NSString *body = ApolloRevealTrimmedString([archivedComment[@"body"] isKindOfClass:[NSString class]] ? archivedComment[@"body"] : nil);
    if (body.length == 0 || ApolloRevealBodyLooksDeleted(body)) return NO;
    NSString *author = [archivedComment[@"author"] isKindOfClass:[NSString class]] ? archivedComment[@"author"] : nil;

    objc_setAssociatedObject(textNode, kApolloRevealOriginalAttributedTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloRevealOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloRevealRecoveredTextKey, body, OBJC_ASSOCIATION_COPY_NONATOMIC);
    @synchronized (sOwnedRevealTextNodes) {
        [sOwnedRevealTextNodes addObject:textNode];
    }

    NSAttributedString *attr = ApolloRevealAttributedString(current, body, author);
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), attr);
    } @catch (__unused NSException *e) {
        return NO;
    }
    ApolloLog(@"[RevealDeleted] Replaced direct placeholder %@ via text node (author=%@)", fullName, author ?: @"nil");
    ApolloRevealNudgeLayout(nil, textNode);
    return YES;
}

static void ApolloRevealMaybeHandleTextNode(id textNode, NSAttributedString *attributedText, NSString *source) {
    if (!textNode || !sRevealDeletedComments) return;
    NSDictionary *threadCache = ApolloRevealThreadCacheForVisibleLink();
    if (!threadCache || ![attributedText isKindOfClass:[NSAttributedString class]]) return;
    if (objc_getAssociatedObject(textNode, kApolloRevealOwnedTextNodeKey)) return;

    NSString *text = attributedText.string ?: @"";
    NSUInteger moreRepliesCount = 0;
    BOOL looksMoreReplies = ApolloRevealTextLooksLikeMoreRepliesPlaceholder(text, &moreRepliesCount);
    BOOL mentionsDeletedOrRemoved = ApolloRevealTextMentionsDeletedOrRemoved(text);
    if (!looksMoreReplies && !mentionsDeletedOrRemoved) return;

    NSString *nearestFullName = nil;
    NSMutableArray<NSString *> *classChain = [NSMutableArray array];
    ApolloRevealNearestCommentForNode(textNode, &nearestFullName, classChain);

    if (looksMoreReplies && nearestFullName.length > 0 &&
        ApolloRevealApplyArchivedChildrenToTextNode(textNode, attributedText, threadCache, nearestFullName, moreRepliesCount)) {
        return;
    }

    NSString *trimmed = ApolloRevealTrimmedString(text);
    if (ApolloRevealBodyLooksDeleted(trimmed) && nearestFullName.length > 0 &&
        ApolloRevealApplyDirectArchivedCommentToTextNode(textNode, attributedText, threadCache, nearestFullName)) {
        return;
    }

    BOOL shouldLog = nearestFullName.length > 0;
    if (shouldLog && !objc_getAssociatedObject(textNode, kApolloRevealObservedPlaceholderLogKey)) {
        objc_setAssociatedObject(textNode, kApolloRevealObservedPlaceholderLogKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *oneLine = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (oneLine.length > 180) oneLine = [[oneLine substringToIndex:180] stringByAppendingString:@"..."];
        ApolloLog(@"[RevealDeleted] Saw text candidate via %@ on %s parent=%@ chain=%@: %@",
                  source ?: @"unknown",
                  class_getName(object_getClass(textNode)),
                  nearestFullName ?: @"nil",
                  [classChain componentsJoinedByString:@" > "],
                  oneLine);
    }

    NSUInteger count = 0;
    if (ApolloRevealTextLooksLikeMissingRepliesPlaceholder(text, &count)) {
        ApolloRevealApplyMissingRepliesToTextNode(textNode, threadCache, count);
    }
}

static void ApolloRevealScheduleTextNodeHandle(id textNode, NSString *source) {
    if (!textNode || !sRevealDeletedComments) return;
    if ([objc_getAssociatedObject(textNode, kApolloRevealDelayedTextHandleScheduledKey) boolValue]) return;
    objc_setAssociatedObject(textNode, kApolloRevealDelayedTextHandleScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakNode = textNode;
    NSString *sourceCopy = [source copy];

    void (^runPass)(NSTimeInterval, BOOL) = ^(NSTimeInterval delay, BOOL clearFlag) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id strongNode = weakNode;
            if (!strongNode) return;
            if (clearFlag) {
                objc_setAssociatedObject(strongNode, kApolloRevealDelayedTextHandleScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (objc_getAssociatedObject(strongNode, kApolloRevealOwnedTextNodeKey)) return;
            NSAttributedString *current = nil;
            @try {
                if ([strongNode respondsToSelector:@selector(attributedText)]) {
                    current = ((id (*)(id, SEL))objc_msgSend)(strongNode, @selector(attributedText));
                }
            } @catch (__unused NSException *e) {}
            ApolloRevealMaybeHandleTextNode(strongNode, current, [sourceCopy stringByAppendingFormat:@" +%.2fs", delay]);
        });
    };

    runPass(0.03, NO);
    runPass(0.20, YES);
}

static void ApolloRevealApplyMissingRepliesInTree(id object, NSInteger depth, NSHashTable *visited, NSDictionary *threadCache) {
    if (!object || depth < 0 || !threadCache) return;
    if (visited.count >= 2048) return;
    if ([visited containsObject:object]) return;
    [visited addObject:object];

    Class displayNodeCls = NSClassFromString(@"ASDisplayNode");
    BOOL isDisplayNode = displayNodeCls && [object isKindOfClass:displayNodeCls];
    BOOL isView = [object isKindOfClass:[UIView class]];
    if (!isDisplayNode && !isView) return;

    @try {
        if ([object respondsToSelector:@selector(attributedText)] &&
            [object respondsToSelector:@selector(setAttributedText:)]) {
            NSAttributedString *attr = ((id (*)(id, SEL))objc_msgSend)(object, @selector(attributedText));
            NSUInteger count = 0;
            if ([attr isKindOfClass:[NSAttributedString class]] &&
                ApolloRevealTextLooksLikeMissingRepliesPlaceholder(attr.string, &count)) {
                ApolloRevealApplyMissingRepliesToTextNode(object, threadCache, count);
                return;
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object) ApolloRevealApplyMissingRepliesInTree(node, depth - 1, visited, threadCache);
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloRevealApplyMissingRepliesInTree(subnode, depth - 1, visited, threadCache);
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        if ([object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id subview in subviews) ApolloRevealApplyMissingRepliesInTree(subview, depth - 1, visited, threadCache);
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ApolloRevealScheduleMissingRepliesScan(id displayNode) {
    if (!displayNode || !sRevealDeletedComments) return;
    NSDictionary *threadCache = ApolloRevealThreadCacheForVisibleLink();
    if (!threadCache) return;
    if ([objc_getAssociatedObject(displayNode, kApolloRevealMissingRepliesScanScheduledKey) boolValue]) return;
    objc_setAssociatedObject(displayNode, kApolloRevealMissingRepliesScanScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakNode = displayNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongNode = weakNode;
        if (!strongNode) return;
        objc_setAssociatedObject(strongNode, kApolloRevealMissingRepliesScanScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSDictionary *currentCache = ApolloRevealThreadCacheForVisibleLink();
        if (!currentCache) return;
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:128];
        ApolloRevealApplyMissingRepliesInTree(strongNode, 8, visited, currentCache);
    });
}

static void ApolloRevealApplyVisibleCommentsForController(UIViewController *viewController) {
    if (!viewController || !viewController.isViewLoaded) return;
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:512];
    ApolloRevealWalkCommentCells(viewController.view, 18, visited, ^(id cellNode) {
        ApolloRevealMaybeRevealCellNode(cellNode);
    });

    NSDictionary *threadCache = ApolloRevealThreadCacheForVisibleLink();
    if (threadCache) {
        NSHashTable *textVisited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:512];
        ApolloRevealApplyMissingRepliesInTree(viewController.view, 18, textVisited, threadCache);
    }
}

static void ApolloRevealRestoreVisibleCommentsForController(UIViewController *viewController) {
    if (!viewController || !viewController.isViewLoaded) return;
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:512];
    ApolloRevealWalkCommentCells(viewController.view, 18, visited, ^(id cellNode) {
        ApolloRevealRestoreCellNode(cellNode);
    });

    @synchronized (sOwnedRevealTextNodes) {
        for (id textNode in sOwnedRevealTextNodes) {
            NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloRevealOriginalAttributedTextKey);
            if (![original isKindOfClass:[NSAttributedString class]]) continue;
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), original);
            } @catch (__unused NSException *e) {}
            objc_setAssociatedObject(textNode, kApolloRevealOriginalAttributedTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(textNode, kApolloRevealOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(textNode, kApolloRevealRecoveredTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        [sOwnedRevealTextNodes removeAllObjects];
    }
}

static void ApolloRevealToggleChanged(__unused NSNotification *note) {
    sRevealDeletedComments = [[NSUserDefaults standardUserDefaults] boolForKey:@"RevealDeletedComments"];
    UIViewController *vc = sVisibleRevealCommentsViewController;
    if (sRevealDeletedComments) {
        ApolloRevealApplyVisibleCommentsForController(vc);
    } else {
        ApolloRevealRestoreVisibleCommentsForController(vc);
    }
}

static void ApolloRevealRefreshThreadForController(UIViewController *viewController, NSString *reason) {
    if (!viewController || !sRevealDeletedComments) return;
    NSString *linkFullName = ApolloRevealLinkFullNameFromController(viewController);
    if (linkFullName.length == 0) {
        ApolloLog(@"[RevealDeleted] No thread link found (%@)", reason ?: @"unknown");
        return;
    }
    sVisibleRevealLinkFullName = linkFullName;
    ApolloRevealFetchThreadForLinkFullName(linkFullName, ^(__unused NSDictionary *threadCache) {
        if ([sVisibleRevealLinkFullName isEqualToString:linkFullName]) {
            ApolloRevealApplyVisibleCommentsForController(viewController);
        }
    });
}

%hook _TtC6Apollo15CommentCellNode

- (void)setNeedsLayout {
    %orig;
    ApolloRevealScheduleReapplyForCellNode((id)self);
}

- (void)setNeedsDisplay {
    %orig;
    ApolloRevealScheduleReapplyForCellNode((id)self);
}

- (void)didLoad {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloRevealMaybeRevealCellNode((id)self);
    });
}

- (void)didEnterPreloadState {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloRevealMaybeRevealCellNode((id)self);
    });
}

- (void)didEnterDisplayState {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloRevealMaybeRevealCellNode((id)self);
    });
}

- (void)cellNodeVisibilityEvent:(NSInteger)event {
    %orig;
    if (event != 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloRevealMaybeRevealCellNode((id)self);
    });
}

%end

%hook _TtC6Apollo20MoreCommentsCellNode

- (id)init {
    id obj = %orig;
    ApolloRevealLogMoreCommentsMethodsOnce();
    ApolloRevealScheduleMoreCommentsCellNode(obj, @"init");
    return obj;
}

- (void)didLoad {
    %orig;
    ApolloRevealLogMoreCommentsMethodsOnce();
    ApolloRevealScheduleMoreCommentsCellNode((id)self, @"didLoad");
}

- (void)didEnterDisplayState {
    %orig;
    ApolloRevealScheduleMoreCommentsCellNode((id)self, @"didEnterDisplayState");
}

- (void)setNeedsLayout {
    %orig;
    ApolloRevealScheduleMoreCommentsCellNode((id)self, @"setNeedsLayout");
}

- (void)setNeedsDisplay {
    %orig;
    ApolloRevealScheduleMoreCommentsCellNode((id)self, @"setNeedsDisplay");
}

- (void)layout {
    %orig;
    ApolloRevealLogMoreCommentsMethodsOnce();
    ApolloRevealApplyMoreCommentsCellNode((id)self, @"layout");
    ApolloRevealScheduleMoreCommentsCellNode((id)self, @"layout delayed");
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig(highlighted);
    ApolloRevealScheduleMoreCommentsCellNode((id)self, @"setHighlighted:");
}

- (void)setSelected:(BOOL)selected {
    %orig(selected);
    ApolloRevealScheduleMoreCommentsCellNode((id)self, @"setSelected:");
}

%end

%hook ASDisplayNode

- (void)didEnterDisplayState {
    %orig;
    ApolloRevealScheduleMissingRepliesScan((id)self);
}

%end

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *styledAttributedText = ApolloRevealStyledDeletedCommentFlair(attributedText);
    %orig(styledAttributedText);
    ApolloRevealApplyDeletedCommentFlairContainerStyle((id)self, styledAttributedText);
    ApolloRevealScheduleTextNodeHandle((id)self, @"ASTextNode setAttributedText");
}

- (void)didEnterDisplayState {
    %orig;
    NSAttributedString *attributedText = nil;
    @try {
        attributedText = ((NSAttributedString *(*)(id, SEL))objc_msgSend)((id)self, @selector(attributedText));
    } @catch (__unused NSException *e) {
        attributedText = nil;
    }
    ApolloRevealApplyDeletedCommentFlairContainerStyle((id)self, attributedText);
    ApolloRevealScheduleTextNodeHandle((id)self, @"ASTextNode didEnterDisplayState");
}

%end

%hook ASEditableTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    %orig;
    ApolloRevealScheduleTextNodeHandle((id)self, @"ASEditableTextNode setAttributedText");
}

%end

%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    sVisibleRevealCommentsViewController = (UIViewController *)self;
    sVisibleRevealLinkFullName = ApolloRevealLinkFullNameFromController((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sVisibleRevealCommentsViewController = (UIViewController *)self;
    ApolloRevealRefreshThreadForController((UIViewController *)self, @"viewDidAppear");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloRevealRefreshThreadForController((UIViewController *)self, @"viewDidAppear+0.12");
        ApolloRevealApplyVisibleCommentsForController((UIViewController *)self);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloRevealRefreshThreadForController((UIViewController *)self, @"viewDidAppear+0.55");
        ApolloRevealApplyVisibleCommentsForController((UIViewController *)self);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloRevealRefreshThreadForController((UIViewController *)self, @"viewDidAppear+1.50");
        ApolloRevealApplyVisibleCommentsForController((UIViewController *)self);
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (sVisibleRevealCommentsViewController == (UIViewController *)self) {
        sVisibleRevealCommentsViewController = nil;
        sVisibleRevealLinkFullName = nil;
    }
}

%end

%ctor {
    sRecoveredCommentBodyByFullName = [NSCache new];
    sRecoveredCommentBodyByFullName.countLimit = 512;
    sRecoveredThreadTreeByLinkFullName = [NSCache new];
    sRecoveredThreadTreeByLinkFullName.countLimit = 24;
    sNegativeCacheByFullName = [NSMutableDictionary dictionary];
    sInFlightFullNames = [NSMutableSet set];
    sInFlightThreadFullNames = [NSMutableSet set];
    sLoggedRevealSkipFullNames = [NSMutableSet set];
    sLoggedRevealPlaceholderFullNames = [NSMutableSet set];
    sOwnedRevealTextNodes = [NSHashTable weakObjectsHashTable];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloRevealDeletedCommentsToggleChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        ApolloRevealToggleChanged(note);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloRevealDeletedCommentsObservedThreadNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        UIViewController *vc = sVisibleRevealCommentsViewController;
        if (vc) {
            ApolloRevealRefreshThreadForController(vc, @"observed-comments-request");
            ApolloRevealApplyVisibleCommentsForController(vc);
        }
    }];
}
