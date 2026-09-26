#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const ARMSX3LibraryMetadataDidChangeNotification;

NSString * _Nullable ARMSX3CustomGameName(NSString *serial);
void ARMSX3SetCustomGameName(NSString *serial, NSString * _Nullable name);

NSURL * _Nullable ARMSX3CustomCoverURL(NSString *serial);
BOOL ARMSX3SetCustomCover(NSString *serial, NSURL *sourceURL);
void ARMSX3ClearCustomCover(NSString *serial);

void ARMSX3PlayTimeStart(NSString *serial);
void ARMSX3PlayTimeStop(void);
NSTimeInterval ARMSX3PlayedSeconds(NSString *serial);
NSDate * _Nullable ARMSX3LastPlayedDate(NSString *serial);
NSString *ARMSX3FormatPlayedTime(NSTimeInterval seconds);
NSString *ARMSX3FormatLastPlayed(NSDate * _Nullable date);

NS_ASSUME_NONNULL_END
