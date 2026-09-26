#import "ARMSX3LibraryMetadata.h"
#import <UIKit/UIKit.h>

#include <cmath>

NSNotificationName const ARMSX3LibraryMetadataDidChangeNotification = @"ARMSX3LibraryMetadataDidChangeNotification";

static NSString *const kNamePrefix = @"ARMSX3.Library.CustomName.";
static NSString *const kPlayedPrefix = @"ARMSX3.Library.PlayedSeconds.";
static NSString *const kLastPrefix = @"ARMSX3.Library.LastPlayed.";
static NSString *gActivePlaySerial;
static NSDate *gActivePlayStart;

static NSString *SafeSerial(NSString *serial)
{
    NSString *value = serial.uppercaseString ?: @"";
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    return [[value componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
}

static NSURL *CoverRoot(void)
{
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *root = [[[base URLByAppendingPathComponent:@"ARMSX3" isDirectory:YES]
        URLByAppendingPathComponent:@"covers" isDirectory:YES]
        URLByAppendingPathComponent:@"custom" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

NSString *ARMSX3CustomGameName(NSString *serial)
{
    if (!serial.length) return nil;
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:[kNamePrefix stringByAppendingString:serial.uppercaseString]];
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return value.length ? value : nil;
}

void ARMSX3SetCustomGameName(NSString *serial, NSString *name)
{
    if (!serial.length) return;
    NSString *key = [kNamePrefix stringByAppendingString:serial.uppercaseString];
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) [NSUserDefaults.standardUserDefaults setObject:trimmed forKey:key];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3LibraryMetadataDidChangeNotification object:serial];
}

NSURL *ARMSX3CustomCoverURL(NSString *serial)
{
    if (!serial.length) return nil;
    NSString *stem = SafeSerial(serial);
    for (NSString *ext in @[@"png", @"jpg", @"jpeg", @"webp"])
    {
        NSURL *url = [CoverRoot() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", stem, ext]];
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) return url;
    }
    return nil;
}

void ARMSX3ClearCustomCover(NSString *serial)
{
    if (!serial.length) return;
    NSString *stem = SafeSerial(serial);
    for (NSString *ext in @[@"png", @"jpg", @"jpeg", @"webp"])
        [NSFileManager.defaultManager removeItemAtURL:[CoverRoot() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", stem, ext]] error:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3LibraryMetadataDidChangeNotification object:serial];
}

BOOL ARMSX3SetCustomCover(NSString *serial, NSURL *sourceURL)
{
    if (!serial.length || !sourceURL) return NO;
    NSData *data = [NSData dataWithContentsOfURL:sourceURL options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || data.length > 24 * 1024 * 1024) return NO;
    UIImage *image = [UIImage imageWithData:data];
    if (!image) return NO;
    NSData *png = UIImagePNGRepresentation(image);
    if (!png.length) return NO;
    ARMSX3ClearCustomCover(serial);
    NSURL *dest = [CoverRoot() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", SafeSerial(serial)]];
    BOOL ok = [png writeToURL:dest options:NSDataWritingAtomic error:nil];
    if (ok) [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3LibraryMetadataDidChangeNotification object:serial];
    return ok;
}

static NSString *PlayedKey(NSString *serial) { return [kPlayedPrefix stringByAppendingString:serial.uppercaseString ?: @""]; }
static NSString *LastKey(NSString *serial) { return [kLastPrefix stringByAppendingString:serial.uppercaseString ?: @""]; }

void ARMSX3PlayTimeStart(NSString *serial)
{
    ARMSX3PlayTimeStop();
    if (!serial.length) return;
    gActivePlaySerial = serial.uppercaseString;
    gActivePlayStart = NSDate.date;
    [NSUserDefaults.standardUserDefaults setDouble:gActivePlayStart.timeIntervalSince1970 forKey:LastKey(gActivePlaySerial)];
}

void ARMSX3PlayTimeStop(void)
{
    if (!gActivePlaySerial.length || !gActivePlayStart) { gActivePlaySerial = nil; gActivePlayStart = nil; return; }
    NSTimeInterval delta = MAX(0, -gActivePlayStart.timeIntervalSinceNow);
    if (delta > 0 && delta < 7 * 24 * 60 * 60)
    {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSTimeInterval total = [defaults doubleForKey:PlayedKey(gActivePlaySerial)] + delta;
        [defaults setDouble:total forKey:PlayedKey(gActivePlaySerial)];
        [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:LastKey(gActivePlaySerial)];
        [NSNotificationCenter.defaultCenter postNotificationName:ARMSX3LibraryMetadataDidChangeNotification object:gActivePlaySerial];
    }
    gActivePlaySerial = nil;
    gActivePlayStart = nil;
}

NSTimeInterval ARMSX3PlayedSeconds(NSString *serial)
{
    if (!serial.length) return 0;
    NSTimeInterval total = [NSUserDefaults.standardUserDefaults doubleForKey:PlayedKey(serial)];
    if ([gActivePlaySerial isEqualToString:serial.uppercaseString] && gActivePlayStart) total += MAX(0, -gActivePlayStart.timeIntervalSinceNow);
    return total;
}

NSDate *ARMSX3LastPlayedDate(NSString *serial)
{
    if (!serial.length) return nil;
    NSTimeInterval stamp = [NSUserDefaults.standardUserDefaults doubleForKey:LastKey(serial)];
    return stamp > 0 ? [NSDate dateWithTimeIntervalSince1970:stamp] : nil;
}

NSString *ARMSX3FormatPlayedTime(NSTimeInterval seconds)
{
    NSInteger total = MAX(0, (NSInteger)llround(seconds));
    NSInteger hours = total / 3600, minutes = (total % 3600) / 60;
    if (hours > 0) return [NSString stringWithFormat:@"%ld h %ld min", (long)hours, (long)minutes];
    if (minutes > 0) return [NSString stringWithFormat:@"%ld min", (long)minutes];
    return total > 0 ? @"< 1 min" : @"—";
}

NSString *ARMSX3FormatLastPlayed(NSDate *date)
{
    if (!date) return @"—";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}
