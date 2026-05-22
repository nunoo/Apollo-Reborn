#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *const ApolloDeletedCommentsObservedThreadNotification;

NSString *ApolloDeletedCommentsLinkFullNameFromRedditURL(NSURL *url);
BOOL ApolloDeletedCommentsIsCommentsListingTask(NSURLSessionTask *task);
BOOL ApolloDeletedCommentsShouldTransformRequest(NSURLRequest *request);
void ApolloDeletedCommentsObserveRequest(NSURLRequest *request, NSString *source);
void ApolloDeletedCommentsPatchResponseAsync(NSData *data, NSURLRequest *request, void (^completion)(NSData *patchedData));
void ApolloDeletedCommentsInstallResponseTransformerForDelegate(id delegate);

#ifdef __cplusplus
}
#endif
