#pragma once

#import <UIKit/UIKit.h>

@class ARMSX3TouchControlsView;

NS_ASSUME_NONNULL_BEGIN

BOOL ARMSX3SecondScreenEnabled(void);
void ARMSX3SetSecondScreenEnabled(BOOL enabled);
BOOL ARMSX3SecondScreenMoveOSD(void);
void ARMSX3SetSecondScreenMoveOSD(BOOL enabled);

void ARMSX3SecondScreenAttachControls(ARMSX3TouchControlsView *controls);
void ARMSX3SecondScreenSetForeground(BOOL foreground);
void ARMSX3SecondScreenRefresh(void);

NS_ASSUME_NONNULL_END
