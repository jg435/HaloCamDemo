//
//  DJIAlbumTransfer.h
//
//  Copyright (c) 2015 DJI. All rights reserved.
//


#import <DJIWidgetMacros.h>
#import "DJIAlbumTransfer.h"
#import <Photos/Photos.h>

#ifndef SAFE_BLOCK
#define SAFE_BLOCK(block, ...) if(block){block(__VA_ARGS__);};
#endif

@implementation DJIAlbumTransfer

+(void) writeVideo:(NSString*)file toAlbum:(NSString*)album completionBlock:(void(^)(NSURL *assetURL, NSError *error))block{

    NSFileManager* fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:file]) {
        NSError *customError = [[NSError alloc] initWithDomain:@"drone.dji.com" code:DJIAlbumTransferErrorCode_FileNotFound userInfo:nil];
        SAFE_BLOCK(block, nil, customError);
        return;
    }

    if(!UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(file)){
        NSError *customError = [[NSError alloc] initWithDomain:@"drone.dji.com" code:DJIAlbumTransferErrorCode_FileCannotPlay userInfo:nil];
        SAFE_BLOCK(block, nil, customError);
        return;
    }

    NSURL* fileURL = [NSURL fileURLWithPath:file];

    __block NSString *assetId = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetChangeRequest *request = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
        assetId = request.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
        if (!success || !assetId) {
            SAFE_BLOCK(block, nil, error);
            return;
        }

        // Add to album
        PHAssetCollection *collection = [DJIAlbumTransfer findOrCreateAlbum:album];
        if (!collection) {
            SAFE_BLOCK(block, nil, [NSError errorWithDomain:@"drone.dji.com" code:DJIAlbumTransferErrorCode_AlbumCanNotCreate userInfo:nil]);
            return;
        }

        PHFetchResult *assets = [PHAsset fetchAssetsWithLocalIdentifiers:@[assetId] options:nil];
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCollectionChangeRequest *albumChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:collection];
            [albumChangeRequest addAssets:assets];
        } completionHandler:^(BOOL success, NSError *error) {
            SAFE_BLOCK(block, fileURL, error);
        }];
    }];
}

+(void) writeVidoToAssetLibrary:(NSString*)file completionBlock:(void(^)(NSURL *assetURL, NSError *error))block{

    NSFileManager* fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:file]) {
        NSError *customError = [[NSError alloc] initWithDomain:@"drone.dji.com" code:DJIAlbumTransferErrorCode_FileNotFound userInfo:nil];
        SAFE_BLOCK(block, nil, customError);
        return;
    }

    if(!UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(file)){
        NSError *customError = [[NSError alloc] initWithDomain:@"drone.dji.com" code:DJIAlbumTransferErrorCode_FileCannotPlay userInfo:nil];
        SAFE_BLOCK(block, nil, customError);
        return;
    }

    NSURL* fileURL = [NSURL fileURLWithPath:file];
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *error) {
        if (success) {
            SAFE_BLOCK(block, fileURL, nil);
        } else {
            SAFE_BLOCK(block, nil, error);
        }
    }];
}

+ (PHAssetCollection *)findOrCreateAlbum:(NSString *)albumName {
    // Search for existing album
    PHFetchOptions *options = [[PHFetchOptions alloc] init];
    options.predicate = [NSPredicate predicateWithFormat:@"title = %@", albumName];
    PHFetchResult *collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum subtype:PHAssetCollectionSubtypeAny options:options];

    if (collections.firstObject) {
        return collections.firstObject;
    }

    // Create album synchronously
    __block NSString *collectionId = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetCollectionChangeRequest *request = [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:albumName];
        collectionId = request.placeholderForCreatedAssetCollection.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    if (collectionId) {
        return [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[collectionId] options:nil].firstObject;
    }
    return nil;
}

+(void) createAlbumIfNotExist:(NSString *)album{
    [DJIAlbumTransfer findOrCreateAlbum:album];
}

@end
