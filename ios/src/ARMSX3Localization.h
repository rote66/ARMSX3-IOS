#pragma once

#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const ARMSX3LanguageDidChangeNotification;

NSString *ARMSX3L(NSString *key, NSString *englishFallback);
NSString *ARMSX3SelectedLanguageCode(void);
NSString *ARMSX3ResolvedLanguageCode(void);
NSArray<NSDictionary<NSString *, NSString *> *> *ARMSX3SupportedLanguages(void);
void ARMSX3SetLanguageCode(NSString *code);
BOOL ARMSX3LanguageIsSimplifiedChinese(void);
BOOL ARMSX3LanguageIsTraditionalChinese(void);
BOOL ARMSX3LanguageIsRTL(void);

@interface ARMSX3LanguageViewController : UITableViewController
@end
