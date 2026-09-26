#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL ARMSX3ExtractSafeZip(NSURL *archiveURL, NSURL *staging, NSUInteger * _Nullable writtenOut,
    NSURL * _Nullable * _Nullable loneOut, NSString * _Nullable * _Nullable errorOut);

NS_ASSUME_NONNULL_END
