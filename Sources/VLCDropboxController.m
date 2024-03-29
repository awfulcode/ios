/*****************************************************************************
 * VLCDropboxController.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2013 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *          Jean-Baptiste Kempf <jb # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCDropboxController.h"
#import "NSString+SupportedMedia.h"
#import "VLCAppDelegate.h"

@interface VLCDropboxController ()
{
    DBRestClient *_restClient;
    NSArray *_currentFileList;

    NSMutableArray *_listOfDropboxFilesToDownload;
    BOOL _downloadInProgress;

    NSInteger _outstandingNetworkRequests;

    CGFloat _averageSpeed;
    CGFloat _fileSize;
    NSTimeInterval _startDL;
    NSTimeInterval _lastStatsUpdate;
}

@end

@implementation VLCDropboxController

#pragma mark - session handling

- (void)startSession
{
}

- (void)logout
{
    [[DBSession sharedSession] unlinkAll];
}

- (BOOL)sessionIsLinked
{
    return  [[DBSession sharedSession] isLinked];
}

- (DBRestClient *)restClient {
    if (!_restClient) {
        _restClient = [[DBRestClient alloc] initWithSession:[DBSession sharedSession]];
        _restClient.delegate = self;
    }
    return _restClient;
}

#pragma mark - file management
- (void)requestDirectoryListingAtPath:(NSString *)path
{
    if (self.sessionIsLinked)
        [[self restClient] loadMetadata:path];
}

- (void)downloadFileToDocumentFolder:(DBMetadata *)file
{
    if (!file.isDirectory) {
        if (!_listOfDropboxFilesToDownload)
            _listOfDropboxFilesToDownload = [[NSMutableArray alloc] init];
        [_listOfDropboxFilesToDownload addObject:file];

        if ([self.delegate respondsToSelector:@selector(numberOfFilesWaitingToBeDownloadedChanged)])
            [self.delegate numberOfFilesWaitingToBeDownloadedChanged];

        [self _triggerNextDownload];
    }
}

- (void)streamFile:(DBMetadata *)file
{
    if (!file.isDirectory)
        [[self restClient] loadStreamableURLForFile:file.path];
}

- (void)_triggerNextDownload
{
    if (_listOfDropboxFilesToDownload.count > 0 && !_downloadInProgress) {
        [self _reallyDownloadFileToDocumentFolder:_listOfDropboxFilesToDownload[0]];
        [_listOfDropboxFilesToDownload removeObjectAtIndex:0];

        if ([self.delegate respondsToSelector:@selector(numberOfFilesWaitingToBeDownloadedChanged)])
            [self.delegate numberOfFilesWaitingToBeDownloadedChanged];
    }
}

- (void)_reallyDownloadFileToDocumentFolder:(DBMetadata *)file
{
    NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *filePath = [searchPaths[0] stringByAppendingFormat:@"/%@", file.filename];
    _startDL = [NSDate timeIntervalSinceReferenceDate];
    _fileSize = file.totalBytes;
    [[self restClient] loadFile:file.path intoPath:filePath];

    if ([self.delegate respondsToSelector:@selector(operationWithProgressInformationStarted)])
        [self.delegate operationWithProgressInformationStarted];

    _downloadInProgress = YES;
}

#pragma mark - restClient delegate
- (BOOL)_supportedFileExtension:(NSString *)filename
{
    if ([filename isSupportedMediaFormat] || [filename isSupportedAudioMediaFormat] || [filename isSupportedSubtitleFormat])
        return YES;

    return NO;
}

- (void)restClient:(DBRestClient *)client loadedMetadata:(DBMetadata *)metadata {
    NSMutableArray *listOfGoodFilesAndFolders = [[NSMutableArray alloc] init];

    if (metadata.isDirectory) {
        NSArray *contents = metadata.contents;
        NSUInteger metaDataCount = metadata.contents.count;
        for (NSUInteger x = 0; x < metaDataCount; x++) {
            DBMetadata *file = contents[x];
            if ([file isDirectory] || [self _supportedFileExtension:file.filename])
                [listOfGoodFilesAndFolders addObject:file];
        }
    }

    _currentFileList = [NSArray arrayWithArray:listOfGoodFilesAndFolders];

    APLog(@"found filtered metadata for %lu files", (unsigned long)_currentFileList.count);
    if ([self.delegate respondsToSelector:@selector(mediaListUpdated)])
        [self.delegate mediaListUpdated];
}

- (void)restClient:(DBRestClient *)client loadMetadataFailedWithError:(NSError *)error
{
    APLog(@"DBMetadata download failed with error %li", (long)error.code);
    [self _handleError:error];
}

- (void)restClient:(DBRestClient*)client loadedFile:(NSString*)localPath
{
    /* update library now that we got a file */
    VLCAppDelegate *appDelegate = [UIApplication sharedApplication].delegate;
    [appDelegate performSelectorOnMainThread:@selector(updateMediaList) withObject:nil waitUntilDone:NO];

    if ([self.delegate respondsToSelector:@selector(operationWithProgressInformationStopped)])
        [self.delegate operationWithProgressInformationStopped];
    _downloadInProgress = NO;

    [self _triggerNextDownload];
}

- (void)restClient:(DBRestClient*)client loadFileFailedWithError:(NSError*)error
{
    APLog(@"DBFile download failed with error %li", (long)error.code);
    [self _handleError:error];
    if ([self.delegate respondsToSelector:@selector(operationWithProgressInformationStopped)])
        [self.delegate operationWithProgressInformationStopped];
    _downloadInProgress = NO;
    [self _triggerNextDownload];
}

- (void)restClient:(DBRestClient*)client loadProgress:(CGFloat)progress forFile:(NSString*)destPath
{
    if ((_lastStatsUpdate > 0 && ([NSDate timeIntervalSinceReferenceDate] - _lastStatsUpdate > .5)) || _lastStatsUpdate <= 0) {
        [self calculateRemainingTime:progress*_fileSize expectedDownloadSize:_fileSize];
        _lastStatsUpdate = [NSDate timeIntervalSinceReferenceDate];
    }

    if ([self.delegate respondsToSelector:@selector(currentProgressInformation:)])
        [self.delegate currentProgressInformation:progress];
}

- (void)restClient:(DBRestClient*)restClient loadedStreamableURL:(NSURL*)url forFile:(NSString*)path
{
    VLCAppDelegate *appDelegate = (VLCAppDelegate *)[UIApplication sharedApplication].delegate;
    [appDelegate openMovieFromURL:url];
}

- (void)restClient:(DBRestClient*)restClient loadStreamableURLFailedWithError:(NSError*)error
{
    APLog(@"loadStreamableURL failed with error %li", (long)error.code);
    [self _handleError:error];
}

#pragma mark - DBSession delegate

- (void)sessionDidReceiveAuthorizationFailure:(DBSession *)session userId:(NSString *)userId
{
    APLog(@"DBSession received authorization failure with user ID %@", userId);
}

#pragma mark - DBNetworkRequest delegate
- (void)networkRequestStarted
{
    _outstandingNetworkRequests++;
    if (_outstandingNetworkRequests == 1) {
        [(VLCAppDelegate*)[UIApplication sharedApplication].delegate networkActivityStarted];
        [(VLCAppDelegate*)[UIApplication sharedApplication].delegate disableIdleTimer];
    }
}

- (void)networkRequestStopped
{
    _outstandingNetworkRequests--;
    if (_outstandingNetworkRequests == 0) {
        [(VLCAppDelegate*)[UIApplication sharedApplication].delegate networkActivityStopped];
        [(VLCAppDelegate*)[UIApplication sharedApplication].delegate activateIdleTimer];
    }
}

#pragma mark - VLC internal communication and delegate

- (void)calculateRemainingTime:(CGFloat)receivedDataSize expectedDownloadSize:(CGFloat)expectedDownloadSize
{
    CGFloat lastSpeed = receivedDataSize / ([NSDate timeIntervalSinceReferenceDate] - _startDL);
    CGFloat smoothingFactor = 0.005;
    _averageSpeed = isnan(_averageSpeed) ? lastSpeed : smoothingFactor * lastSpeed + (1 - smoothingFactor) * _averageSpeed;

    CGFloat RemainingInSeconds = (expectedDownloadSize - receivedDataSize)/_averageSpeed;

    NSDate *date = [NSDate dateWithTimeIntervalSince1970:RemainingInSeconds];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss"];
    [formatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];

    NSString  *remaingTime = [formatter stringFromDate:date];
    if ([self.delegate respondsToSelector:@selector(updateRemainingTime:)])
        [self.delegate updateRemainingTime:remaingTime];
}

- (NSArray *)currentListFiles
{
    return _currentFileList;
}

- (NSInteger)numberOfFilesWaitingToBeDownloaded
{
    if (_listOfDropboxFilesToDownload)
        return _listOfDropboxFilesToDownload.count;

    return 0;
}

#pragma mark - user feedback
- (void)_handleError:(NSError *)error
{
    UIAlertView * alert = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:NSLocalizedString(@"ERROR_NUMBER", @""), error.code] message:error.localizedDescription delegate:self cancelButtonTitle:NSLocalizedString(@"BUTTON_CANCEL", @"") otherButtonTitles:nil];
    [alert show];
}

@end
