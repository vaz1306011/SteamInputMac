#import <stdint.h>

/// 設定 Steam Controller 的左右馬達速度（0–65535，0 為停止），會持續重送直到下次設定。
/// source 只用於紀錄，例如 "HID"、"InControl"。
void steamRumbleSet(uint16_t left, uint16_t right, const char *source);
