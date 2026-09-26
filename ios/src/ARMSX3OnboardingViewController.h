#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UIViewController *ARMSX3MakeOnboardingViewController(dispatch_block_t firmwareAction,
    dispatch_block_t gameAction, dispatch_block_t completion, BOOL reopening);

BOOL ARMSX3OnboardingCompleted(void);

NS_ASSUME_NONNULL_END
