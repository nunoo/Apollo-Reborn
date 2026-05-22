#import "ApolloDeletedCommentsData.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

NSString *const ApolloDeletedCommentsObservedThreadNotification = @"ApolloDeletedCommentsObservedThreadNotification";

static const void *kApolloDeletedCommentsResponseDataKey = &kApolloDeletedCommentsResponseDataKey;
static NSMutableSet<NSString *> *sApolloDeletedCommentsDelegateTransformerInstalledClasses = nil;

static BOOL ApolloDeletedCommentsIsRedditHost(NSString *host) {
    NSString *lowerHost = [host lowercaseString];
    return [lowerHost isEqualToString:@"oauth.reddit.com"] ||
           [lowerHost isEqualToString:@"www.reddit.com"] ||
           [lowerHost isEqualToString:@"old.reddit.com"] ||
           [lowerHost isEqualToString:@"reddit.com"] ||
           [lowerHost hasSuffix:@".reddit.com"];
}

static NSString *ApolloDeletedCommentsNormalizeLinkID(NSString *identifier) {
    NSString *trimmed = [identifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    if ([trimmed rangeOfString:@","].location != NSNotFound) return nil;
    if ([trimmed hasPrefix:@"t3_"] && trimmed.length > 3) return trimmed;
    if ([trimmed hasPrefix:@"t1_"] ||
        [trimmed hasPrefix:@"t2_"] ||
        [trimmed hasPrefix:@"t4_"] ||
        [trimmed hasPrefix:@"t5_"] ||
        [trimmed hasPrefix:@"t6_"]) return nil;
    return [@"t3_" stringByAppendingString:trimmed];
}

NSString *ApolloDeletedCommentsLinkFullNameFromRedditURL(NSURL *url) {
    if (!url || !ApolloDeletedCommentsIsRedditHost(url.host)) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = [item.name lowercaseString];
        if (![name isEqualToString:@"id"] &&
            ![name isEqualToString:@"link_id"] &&
            ![name isEqualToString:@"article"] &&
            ![name isEqualToString:@"link"]) {
            continue;
        }
        NSString *fullName = ApolloDeletedCommentsNormalizeLinkID(item.value);
        if (fullName.length > 0) return fullName;
    }

    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = [parts[i] lowercaseString];
        if (![part isEqualToString:@"comments"] && ![part isEqualToString:@"comments.json"]) continue;
        if (i + 1 >= parts.count) continue;
        NSString *candidate = parts[i + 1];
        if ([candidate hasSuffix:@".json"]) candidate = [candidate stringByDeletingPathExtension];
        NSString *fullName = ApolloDeletedCommentsNormalizeLinkID(candidate);
        if (fullName.length > 0) return fullName;
    }
    return nil;
}

BOOL ApolloDeletedCommentsIsCommentsListingTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) return NO;
    return ApolloDeletedCommentsShouldTransformRequest(task.originalRequest) ||
           ApolloDeletedCommentsShouldTransformRequest(task.currentRequest);
}

static NSString *ApolloDeletedCommentsRecentObservedLinkFullName(void) {
    if (sDeletedCommentsLastObservedLinkFullName.length == 0 || !sDeletedCommentsLastObservedLinkDate) return nil;
    if ([[NSDate date] timeIntervalSinceDate:sDeletedCommentsLastObservedLinkDate] > 45.0) return nil;
    return sDeletedCommentsLastObservedLinkFullName;
}

static NSString *ApolloDeletedCommentsLinkFullNameForRequest(NSURLRequest *request) {
    NSString *fullName = ApolloDeletedCommentsLinkFullNameFromRedditURL(request.URL);
    if (fullName.length > 0) return fullName;
    if (!ApolloDeletedCommentsIsRedditHost(request.URL.host)) return nil;
    return ApolloDeletedCommentsRecentObservedLinkFullName();
}

static BOOL ApolloDeletedCommentsRequestLooksLikeCommentsPayload(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url) return NO;

    NSString *path = [[url path] lowercaseString] ?: @"";
    if ([path rangeOfString:@"/comments/"].location != NSNotFound ||
        [path hasSuffix:@"/comments.json"] ||
        [path rangeOfString:@"/api/morechildren"].location != NSNotFound) {
        return YES;
    }

    return NO;
}

BOOL ApolloDeletedCommentsShouldTransformRequest(NSURLRequest *request) {
    if (!sShowDeletedComments || !request.URL || !ApolloDeletedCommentsIsRedditHost(request.URL.host)) return NO;
    if (!ApolloDeletedCommentsRequestLooksLikeCommentsPayload(request)) return NO;
    return ApolloDeletedCommentsLinkFullNameForRequest(request).length > 0;
}

void ApolloDeletedCommentsObserveRequest(NSURLRequest *request, NSString *source) {
    if (!sShowDeletedComments) return;
    NSString *fullName = ApolloDeletedCommentsLinkFullNameFromRedditURL(request.URL);
    if (fullName.length == 0) return;

    BOOL changed = ![sDeletedCommentsLastObservedLinkFullName isEqualToString:fullName];
    sDeletedCommentsLastObservedLinkFullName = [fullName copy];
    sDeletedCommentsLastObservedLinkDate = [NSDate date];
    if (changed) {
        ApolloLog(@"[DeletedComments] Observed Reddit comments request %@ (%@)", fullName, source ?: @"unknown");
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloDeletedCommentsObservedThreadNotification
                                                            object:nil
                                                          userInfo:@{@"fullName": fullName}];
    });
}

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ApolloDeletedCommentsBodyLooksDeleted(NSString *body) {
    NSString *trimmed = [[ApolloDeletedCommentsTrimmedString(body) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return YES;
    if ([trimmed isEqualToString:@"[deleted]"]) return YES;
    if ([trimmed isEqualToString:@"[removed]"]) return YES;
    if ([trimmed isEqualToString:@"deleted"]) return YES;
    if ([trimmed isEqualToString:@"removed"]) return YES;
    if ([trimmed isEqualToString:@"removed by moderator"]) return YES;
    if ([trimmed isEqualToString:@"removed by reddit"]) return YES;
    if ([trimmed isEqualToString:@"user deleted comment :("]) return YES;
    return NO;
}

static NSString *ApolloDeletedCommentsCommentFullName(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = [data[@"name"] isKindOfClass:[NSString class]] ? data[@"name"] : nil;
    if ([name hasPrefix:@"t1_"]) return name;
    NSString *identifier = [data[@"id"] isKindOfClass:[NSString class]] ? data[@"id"] : nil;
    if (identifier.length == 0) return nil;
    return [identifier hasPrefix:@"t1_"] ? identifier : [@"t1_" stringByAppendingString:identifier];
}

static NSString *ApolloDeletedCommentsEscapeHTML(NSString *s) {
    NSMutableString *escaped = [s ?: @"" mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSString *ApolloDeletedCommentsUnescapedHTMLText(NSString *s) {
    NSMutableString *text = [s ?: @"" mutableCopy];
    [text replaceOccurrencesOfString:@"&lt;" withString:@"<" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&gt;" withString:@">" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&quot;" withString:@"\"" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&#39;" withString:@"'" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, text.length)];
    return text;
}

static BOOL ApolloDeletedCommentsBodyLooksUserDeleted(NSString *body) {
    NSString *trimmed = [[ApolloDeletedCommentsTrimmedString(body) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed isEqualToString:@"[deleted]"]) return YES;
    if ([trimmed isEqualToString:@"deleted"]) return YES;
    if ([trimmed isEqualToString:@"user deleted comment :("]) return YES;
    if ([trimmed rangeOfString:@"user deleted comment"].location != NSNotFound) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsArchivedWasDeleted(NSDictionary *archived) {
    if (![archived isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *metadata = [archived[@"_meta"] isKindOfClass:[NSDictionary class]] ? archived[@"_meta"] : nil;
    if ([metadata[@"was_deleted_later"] respondsToSelector:@selector(boolValue)] && [metadata[@"was_deleted_later"] boolValue]) return YES;
    NSString *removalType = [metadata[@"removal_type"] isKindOfClass:[NSString class]] ? metadata[@"removal_type"] : nil;
    if (removalType.length > 0) return YES;
    NSString *removedByCategory = [archived[@"removed_by_category"] isKindOfClass:[NSString class]] ? archived[@"removed_by_category"] : nil;
    if (removedByCategory.length > 0) return YES;
    if (archived[@"banned_by"] && archived[@"banned_by"] != (id)[NSNull null]) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsArchivedLooksDeletedOrUnavailable(NSDictionary *archived) {
    if (![archived isKindOfClass:[NSDictionary class]]) return NO;
    if (ApolloDeletedCommentsArchivedWasDeleted(archived)) return YES;
    NSString *body = [archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil;
    return ApolloDeletedCommentsBodyLooksDeleted(body);
}

static NSString *ApolloDeletedCommentsBadgeLabelForCurrentBody(NSString *body, NSString *bodyHTML) {
    if (ApolloDeletedCommentsBodyLooksUserDeleted(body)) return @"user deleted";
    if (ApolloDeletedCommentsBodyLooksUserDeleted(ApolloDeletedCommentsUnescapedHTMLText(bodyHTML))) return @"user deleted";
    return @"removed by mod";
}

static NSString *ApolloDeletedCommentsBadgeLabelForArchived(NSDictionary *archived) {
    NSDictionary *metadata = [archived[@"_meta"] isKindOfClass:[NSDictionary class]] ? archived[@"_meta"] : nil;
    NSString *removalType = [metadata[@"removal_type"] isKindOfClass:[NSString class]] ? [metadata[@"removal_type"] lowercaseString] : nil;
    if ([removalType rangeOfString:@"delete"].location != NSNotFound) return @"user deleted";
    return @"removed by mod";
}

static NSString *ApolloDeletedCommentsRedditBodyHTML(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return nil;

    NSMutableArray<NSString *> *htmlParagraphs = [NSMutableArray array];
    for (NSString *paragraph in [trimmed componentsSeparatedByString:@"\n\n"]) {
        NSString *p = ApolloDeletedCommentsTrimmedString(paragraph);
        if (p.length == 0) continue;
        NSString *escaped = ApolloDeletedCommentsEscapeHTML(p);
        escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>"];
        [htmlParagraphs addObject:[NSString stringWithFormat:@"<p>%@</p>", escaped]];
    }
    if (htmlParagraphs.count == 0) return nil;

    NSString *html = [NSString stringWithFormat:@"<div class=\"md\">%@\n</div>", [htmlParagraphs componentsJoinedByString:@"\n"]];
    return ApolloDeletedCommentsEscapeHTML(html);
}

static void ApolloDeletedCommentsApplyNeutralVoteMetadata(NSMutableDictionary *data) {
    data[@"likes"] = [NSNull null];
    data[@"vote"] = [NSNull null];
    data[@"user_vote"] = @0;
    data[@"voted"] = @NO;
}

static void ApolloDeletedCommentsApplyRecoveredMetadata(NSMutableDictionary *data, NSString *label) {
    data[@"author_flair_text"] = label.length > 0 ? label : @"removed by mod";
    data[@"author_flair_css_class"] = @"recovered-deleted";
    data[@"author_flair_type"] = @"text";
    data[@"author_flair_richtext"] = @[];
    ApolloDeletedCommentsApplyNeutralVoteMetadata(data);
}

static void ApolloDeletedCommentsClearRemovalMetadata(NSMutableDictionary *data) {
    [data removeObjectForKey:@"removed_by_category"];
    [data removeObjectForKey:@"banned_by"];
    [data removeObjectForKey:@"approved_by"];
    [data removeObjectForKey:@"mod_note"];
    [data removeObjectForKey:@"mod_reason_by"];
    [data removeObjectForKey:@"mod_reason_title"];
    [data removeObjectForKey:@"removal_reason"];
    [data removeObjectForKey:@"ban_note"];
    [data removeObjectForKey:@"ban_info"];

    data[@"collapsed"] = @NO;
    data[@"collapsed_because_crowd_control"] = @NO;
    data[@"collapsed_reason"] = [NSNull null];
    data[@"collapsed_reason_code"] = [NSNull null];
}

static void ApolloDeletedCommentsFlattenArcticChildren(NSArray *children, NSMutableDictionary<NSString *, NSDictionary *> *commentsByFullName) {
    if (![children isKindOfClass:[NSArray class]]) return;
    for (id child in children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *entry = (NSDictionary *)child;
        NSString *kind = [entry[@"kind"] isKindOfClass:[NSString class]] ? entry[@"kind"] : nil;
        NSDictionary *data = [entry[@"data"] isKindOfClass:[NSDictionary class]] ? entry[@"data"] : nil;
        if (![kind isEqualToString:@"t1"] || !data) continue;

        NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
        if (fullName.length > 0) commentsByFullName[fullName] = data;

        NSDictionary *replies = [data[@"replies"] isKindOfClass:[NSDictionary class]] ? data[@"replies"] : nil;
        NSDictionary *replyData = [replies[@"data"] isKindOfClass:[NSDictionary class]] ? replies[@"data"] : nil;
        NSArray *replyChildren = [replyData[@"children"] isKindOfClass:[NSArray class]] ? replyData[@"children"] : nil;
        ApolloDeletedCommentsFlattenArcticChildren(replyChildren, commentsByFullName);
    }
}

static NSDictionary<NSString *, NSDictionary *> *ApolloDeletedCommentsArcticCommentMapFromRoot(id root) {
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

    NSMutableDictionary *comments = [NSMutableDictionary dictionary];
    ApolloDeletedCommentsFlattenArcticChildren(children, comments);
    return comments.count > 0 ? comments : nil;
}

static void ApolloDeletedCommentsFetchArcticComments(NSString *linkFullName, void (^completion)(NSDictionary<NSString *, NSDictionary *> *comments)) {
    if (linkFullName.length == 0) {
        completion(nil);
        return;
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
        completion(nil);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *comments = nil;
        if (!error && data.length > 0) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (!http || (http.statusCode >= 200 && http.statusCode < 300)) {
                id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                comments = ApolloDeletedCommentsArcticCommentMapFromRoot(root);
            }
        }
        completion(comments);
    }];
    [task resume];
}

static void ApolloDeletedCommentsCollectVisibleCommentNames(id node, NSMutableSet<NSString *> *names) {
    if (!node || !names) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
        NSDictionary *data = [dict[@"data"] isKindOfClass:[NSDictionary class]] ? dict[@"data"] : nil;
        if ([kind isEqualToString:@"t1"] && data) {
            NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
            if (fullName.length > 0) [names addObject:fullName];
        }
        for (id value in [dict allValues]) ApolloDeletedCommentsCollectVisibleCommentNames(value, names);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) ApolloDeletedCommentsCollectVisibleCommentNames(value, names);
    }
}

static NSMutableDictionary *ApolloDeletedCommentsThingFromArchived(NSDictionary *archived, NSString *label) {
    if (![archived isKindOfClass:[NSDictionary class]]) return nil;
    NSString *fullName = ApolloDeletedCommentsCommentFullName(archived);
    NSString *identifier = [archived[@"id"] isKindOfClass:[NSString class]] ? archived[@"id"] : nil;
    if (identifier.length == 0 && [fullName hasPrefix:@"t1_"]) identifier = [fullName substringFromIndex:3];

    NSString *body = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
    if (identifier.length == 0 || body.length == 0 || ApolloDeletedCommentsBodyLooksDeleted(body)) return nil;

    NSString *author = [archived[@"author"] isKindOfClass:[NSString class]] ? archived[@"author"] : @"[deleted]";
    NSString *bodyHTML = ApolloDeletedCommentsRedditBodyHTML(body);
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    data[@"id"] = identifier;
    data[@"name"] = fullName ?: [@"t1_" stringByAppendingString:identifier];
    data[@"author"] = author.length > 0 ? author : @"[deleted]";
    data[@"body"] = body;
    if (bodyHTML.length > 0) data[@"body_html"] = bodyHTML;
    data[@"parent_id"] = [archived[@"parent_id"] isKindOfClass:[NSString class]] ? archived[@"parent_id"] : @"";
    data[@"link_id"] = [archived[@"link_id"] isKindOfClass:[NSString class]] ? archived[@"link_id"] : @"";
    data[@"subreddit"] = [archived[@"subreddit"] isKindOfClass:[NSString class]] ? archived[@"subreddit"] : @"";
    data[@"subreddit_id"] = [archived[@"subreddit_id"] isKindOfClass:[NSString class]] ? archived[@"subreddit_id"] : @"";
    data[@"permalink"] = [archived[@"permalink"] isKindOfClass:[NSString class]] ? archived[@"permalink"] : @"";
    data[@"score"] = [archived[@"score"] respondsToSelector:@selector(integerValue)] ? archived[@"score"] : @0;
    data[@"ups"] = data[@"score"];
    data[@"downs"] = @0;
    data[@"created_utc"] = [archived[@"created_utc"] respondsToSelector:@selector(doubleValue)] ? archived[@"created_utc"] : @0;
    data[@"created"] = data[@"created_utc"];
    data[@"replies"] = @"";
    data[@"saved"] = @NO;
    data[@"stickied"] = @NO;
    data[@"is_submitter"] = @NO;
    data[@"score_hidden"] = @NO;
    data[@"controversiality"] = @0;
    data[@"archived"] = @NO;
    data[@"locked"] = @NO;
    data[@"distinguished"] = [NSNull null];
    data[@"edited"] = @NO;
    data[@"gilded"] = @0;
    ApolloDeletedCommentsApplyRecoveredMetadata(data, label);
    ApolloDeletedCommentsClearRemovalMetadata(data);
    return [@{@"kind": @"t1", @"data": data} mutableCopy];
}

typedef struct {
    NSUInteger t1Count;
    NSUInteger deletedLookingCount;
    NSUInteger archivedMatchCount;
    NSUInteger recoverableCount;
    NSUInteger insertedFromMoreCount;
} ApolloDeletedCommentsPatchStats;

static NSUInteger ApolloDeletedCommentsPatchRedditJSONNode(id node, NSDictionary<NSString *, NSDictionary *> *arcticComments, NSMutableSet<NSString *> *visibleNames, ApolloDeletedCommentsPatchStats *stats) {
    if (!node || !arcticComments) return 0;
    NSUInteger patched = 0;

    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)node;
        NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
        NSMutableDictionary *data = [dict[@"data"] isKindOfClass:[NSMutableDictionary class]] ? dict[@"data"] : nil;
        if ([kind isEqualToString:@"t1"] && data) {
            if (stats) stats->t1Count++;
            NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
            NSDictionary *archived = fullName.length > 0 ? arcticComments[fullName] : nil;
            if (archived && stats) stats->archivedMatchCount++;
            NSString *archivedBody = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
            NSString *currentBody = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
            NSString *currentBodyHTML = [data[@"body_html"] isKindOfClass:[NSString class]] ? data[@"body_html"] : nil;
            BOOL currentLooksDeleted = ApolloDeletedCommentsBodyLooksDeleted(currentBody);
            if (!currentLooksDeleted && currentBodyHTML.length > 0) {
                NSString *htmlText = ApolloDeletedCommentsUnescapedHTMLText(currentBodyHTML);
                currentLooksDeleted = [htmlText rangeOfString:@"[removed]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                      [htmlText rangeOfString:@"[deleted]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                      [htmlText rangeOfString:@"Removed by moderator" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                      [htmlText rangeOfString:@"User deleted comment" options:NSCaseInsensitiveSearch].location != NSNotFound;
            }
            if (currentLooksDeleted && stats) stats->deletedLookingCount++;
            if (currentLooksDeleted && archivedBody.length > 0 && !ApolloDeletedCommentsBodyLooksDeleted(archivedBody)) {
                if (stats) stats->recoverableCount++;
                NSString *author = [archived[@"author"] isKindOfClass:[NSString class]] ? archived[@"author"] : nil;
                data[@"body"] = archivedBody;
                NSString *bodyHTML = ApolloDeletedCommentsRedditBodyHTML(archivedBody);
                if (bodyHTML.length > 0) data[@"body_html"] = bodyHTML;
                if (author.length > 0) data[@"author"] = author;
                if ([archived[@"created_utc"] respondsToSelector:@selector(doubleValue)]) data[@"created_utc"] = archived[@"created_utc"];
                if ([archived[@"score"] respondsToSelector:@selector(integerValue)]) data[@"score"] = archived[@"score"];
                NSString *label = ApolloDeletedCommentsBadgeLabelForCurrentBody(currentBody, currentBodyHTML);
                ApolloDeletedCommentsApplyRecoveredMetadata(data, label);
                ApolloDeletedCommentsClearRemovalMetadata(data);
                ApolloLog(@"[DeletedComments] Recovered visible deleted comment %@", fullName ?: @"unknown");
                patched++;
            }
        }

        for (id value in [dict allValues]) {
            patched += ApolloDeletedCommentsPatchRedditJSONNode(value, arcticComments, visibleNames, stats);
        }
    } else if ([node isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *array = (NSMutableArray *)node;
        for (NSUInteger i = 0; i < array.count; i++) {
            id value = array[i];
            if ([value isKindOfClass:[NSMutableDictionary class]]) {
                NSMutableDictionary *dict = (NSMutableDictionary *)value;
                NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
                NSMutableDictionary *data = [dict[@"data"] isKindOfClass:[NSMutableDictionary class]] ? dict[@"data"] : nil;
                NSMutableArray *children = [data[@"children"] isKindOfClass:[NSMutableArray class]] ? data[@"children"] : nil;
                if ([kind isEqualToString:@"more"] && children.count > 0) {
                    NSUInteger originalMoreCount = [data[@"count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [data[@"count"] unsignedIntegerValue] : children.count;
                    BOOL completeDeletedCluster = originalMoreCount == children.count;
                    if (completeDeletedCluster) {
                        for (id childID in children) {
                            NSString *identifier = nil;
                            if ([childID isKindOfClass:[NSString class]]) identifier = childID;
                            else if ([childID respondsToSelector:@selector(stringValue)]) identifier = [childID stringValue];
                            NSString *fullName = [identifier hasPrefix:@"t1_"] ? identifier : (identifier.length > 0 ? [@"t1_" stringByAppendingString:identifier] : nil);
                            NSDictionary *archived = fullName.length > 0 ? arcticComments[fullName] : nil;
                            if (fullName.length > 0 &&
                                ![visibleNames containsObject:fullName] &&
                                ApolloDeletedCommentsArchivedLooksDeletedOrUnavailable(archived)) {
                                continue;
                            }
                            completeDeletedCluster = NO;
                            break;
                        }
                    }
                    if (!completeDeletedCluster) {
                        patched += ApolloDeletedCommentsPatchRedditJSONNode(value, arcticComments, visibleNames, stats);
                        continue;
                    }

                    NSMutableArray *expanded = [NSMutableArray array];
                    NSMutableArray *remainingChildren = [NSMutableArray array];
                    for (id childID in children) {
                        NSString *identifier = nil;
                        if ([childID isKindOfClass:[NSString class]]) identifier = childID;
                        else if ([childID respondsToSelector:@selector(stringValue)]) identifier = [childID stringValue];
                        NSString *fullName = [identifier hasPrefix:@"t1_"] ? identifier : (identifier.length > 0 ? [@"t1_" stringByAppendingString:identifier] : nil);
                        NSDictionary *archived = fullName.length > 0 ? arcticComments[fullName] : nil;
                        if (fullName.length > 0 &&
                            ![visibleNames containsObject:fullName] &&
                            ApolloDeletedCommentsArchivedWasDeleted(archived)) {
                            NSMutableDictionary *thing = ApolloDeletedCommentsThingFromArchived(archived, ApolloDeletedCommentsBadgeLabelForArchived(archived));
                            if (thing) {
                                [expanded addObject:thing];
                                [visibleNames addObject:fullName];
                                if (stats) stats->insertedFromMoreCount++;
                                continue;
                            }
                        }
                        [remainingChildren addObject:childID];
                    }
                    if (expanded.count > 0) {
                        if (remainingChildren.count > 0) {
                            [children setArray:remainingChildren];
                            NSUInteger adjustedCount = originalMoreCount > expanded.count ? originalMoreCount - expanded.count : remainingChildren.count;
                            if (adjustedCount < remainingChildren.count) adjustedCount = remainingChildren.count;
                            data[@"count"] = @(adjustedCount);
                            NSString *firstRemainingID = [remainingChildren.firstObject isKindOfClass:[NSString class]] ? remainingChildren.firstObject : nil;
                            if (firstRemainingID.length > 0) {
                                data[@"id"] = firstRemainingID;
                                data[@"name"] = [firstRemainingID hasPrefix:@"t1_"] ? firstRemainingID : [@"t1_" stringByAppendingString:firstRemainingID];
                            }
                            [array insertObjects:expanded atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(i, expanded.count)]];
                            patched += expanded.count;
                            i += expanded.count;
                        } else {
                            [array replaceObjectsInRange:NSMakeRange(i, 1)
                                               withObjectsFromArray:expanded];
                            patched += expanded.count;
                            i += expanded.count - 1;
                        }
                        continue;
                    }
                }
            }
            patched += ApolloDeletedCommentsPatchRedditJSONNode(value, arcticComments, visibleNames, stats);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) patched += ApolloDeletedCommentsPatchRedditJSONNode(value, arcticComments, visibleNames, stats);
    }
    return patched;
}

void ApolloDeletedCommentsPatchResponseAsync(NSData *data, NSURLRequest *request, void (^completion)(NSData *patchedData)) {
    NSString *linkFullName = sShowDeletedComments ? ApolloDeletedCommentsLinkFullNameForRequest(request) : nil;
    if (linkFullName.length == 0 || data.length == 0) {
        completion(data);
        return;
    }

    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (!root) {
        completion(data);
        return;
    }

    ApolloDeletedCommentsFetchArcticComments(linkFullName, ^(NSDictionary<NSString *, NSDictionary *> *comments) {
        if (comments.count == 0) {
            completion(data);
            return;
        }

        NSMutableSet<NSString *> *visibleNames = [NSMutableSet set];
        ApolloDeletedCommentsCollectVisibleCommentNames(root, visibleNames);
        ApolloDeletedCommentsPatchStats stats = {0, 0, 0, 0, 0};
        NSUInteger patched = ApolloDeletedCommentsPatchRedditJSONNode(root, comments, visibleNames, &stats);
        if (patched == 0) {
            ApolloLog(@"[DeletedComments] Response patch found no deleted comments to replace for %@ url=%@ (t1=%lu deletedLooking=%lu archivedMatches=%lu recoverable=%lu insertedMore=%lu archived=%lu)",
                      linkFullName,
                      request.URL.absoluteString ?: @"",
                      (unsigned long)stats.t1Count,
                      (unsigned long)stats.deletedLookingCount,
                      (unsigned long)stats.archivedMatchCount,
                      (unsigned long)stats.recoverableCount,
                      (unsigned long)stats.insertedFromMoreCount,
                      (unsigned long)comments.count);
            completion(data);
            return;
        }

        NSData *patchedData = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
        if (patchedData.length == 0) {
            completion(data);
            return;
        }
        ApolloLog(@"[DeletedComments] Patched Reddit comments response for %@ (%lu comments, visible=%lu, insertedMore=%lu)",
                  linkFullName,
                  (unsigned long)patched,
                  (unsigned long)stats.recoverableCount,
                  (unsigned long)stats.insertedFromMoreCount);
        completion(patchedData);
    });
}

void ApolloDeletedCommentsInstallResponseTransformerForDelegate(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!cls) return;
    NSString *classKey = NSStringFromClass(cls);

    @synchronized ([NSURLSession class]) {
        if (!sApolloDeletedCommentsDelegateTransformerInstalledClasses) sApolloDeletedCommentsDelegateTransformerInstalledClasses = [NSMutableSet set];
        if ([sApolloDeletedCommentsDelegateTransformerInstalledClasses containsObject:classKey]) return;
        [sApolloDeletedCommentsDelegateTransformerInstalledClasses addObject:classKey];
    }

    SEL didReceiveDataSelector = @selector(URLSession:dataTask:didReceiveData:);
    Method didReceiveDataMethod = class_getInstanceMethod(cls, didReceiveDataSelector);
    IMP originalDidReceiveDataIMP = didReceiveDataMethod ? method_getImplementation(didReceiveDataMethod) : NULL;
    const char *didReceiveDataTypes = didReceiveDataMethod ? method_getTypeEncoding(didReceiveDataMethod) : "v@:@@@";
    IMP didReceiveDataIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data) {
        if (sShowDeletedComments && ApolloDeletedCommentsIsCommentsListingTask(dataTask) && data.length > 0) {
            NSMutableData *buffered = objc_getAssociatedObject(dataTask, kApolloDeletedCommentsResponseDataKey);
            if (!buffered) {
                buffered = [NSMutableData data];
                objc_setAssociatedObject(dataTask, kApolloDeletedCommentsResponseDataKey, buffered, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [buffered appendData:data];
            return;
        }
        if (originalDidReceiveDataIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, dataTask, data);
        }
    });
    class_replaceMethod(cls, didReceiveDataSelector, didReceiveDataIMP, didReceiveDataTypes);

    SEL didCompleteSelector = @selector(URLSession:task:didCompleteWithError:);
    Method didCompleteMethod = class_getInstanceMethod(cls, didCompleteSelector);
    IMP originalDidCompleteIMP = didCompleteMethod ? method_getImplementation(didCompleteMethod) : NULL;
    const char *didCompleteTypes = didCompleteMethod ? method_getTypeEncoding(didCompleteMethod) : "v@:@@@";

    void (^deliverOriginal)(NSURLSession *, NSURLSessionTask *, NSData *, NSError *, id) = ^(NSURLSession *session, NSURLSessionTask *task, NSData *data, NSError *error, id selfObject) {
        void (^run)(void) = ^{
            if (data.length > 0 && originalDidReceiveDataIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, (NSURLSessionDataTask *)task, data);
            }
            if (originalDidCompleteIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
            }
        };
        NSOperationQueue *delegateQueue = session.delegateQueue;
        if (delegateQueue) {
            [delegateQueue addOperationWithBlock:run];
        } else {
            run();
        }
    };

    IMP didCompleteIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
        if (sShowDeletedComments && ApolloDeletedCommentsIsCommentsListingTask(task)) {
            NSMutableData *buffered = objc_getAssociatedObject(task, kApolloDeletedCommentsResponseDataKey);
            objc_setAssociatedObject(task, kApolloDeletedCommentsResponseDataKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSURLRequest *request = task.originalRequest ?: task.currentRequest;
            if (buffered.length > 0 && !error) {
                ApolloDeletedCommentsPatchResponseAsync(buffered, request, ^(NSData *patchedData) {
                    deliverOriginal(session, task, patchedData.length > 0 ? patchedData : buffered, error, selfObject);
                });
                return;
            }
        }

        if (originalDidCompleteIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
        }
    });
    class_replaceMethod(cls, didCompleteSelector, didCompleteIMP, didCompleteTypes);

    ApolloLog(@"[DeletedComments] Installed comments response transformer on delegate class %@", classKey);
}
