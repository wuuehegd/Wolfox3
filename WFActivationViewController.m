// WFActivationViewController.m - WolFox v.1.0.0 "Royal Final"
#import "WFActivationViewController.h"
#import "WFLicenseClient.h"
#import "WolFoxProTheme.h"

@interface WFActivationViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) NSLayoutConstraint *cardCenterY;
@property (nonatomic, strong) UITextField *codeField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *uuidLabel;
@property (nonatomic, strong) UIButton *activateButton;
@property (nonatomic, strong) UIButton *updateButton;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UIView *loadingOverlay;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UILabel *waitLabel;
@property (nonatomic, strong) UIImageView *lockIcon;
@property (nonatomic, strong) NSTimer *activationTimer;
@property (nonatomic, assign) NSInteger countdown;
@end

@implementation WFActivationViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[WolFoxProTheme royalBackground] colorWithAlphaComponent:0.98];
    
    // Tap to dismiss keyboard
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    [self.view addGestureRecognizer:tap];
    
    // Notifications for keyboard
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];

    self.card = [[UIView alloc] initWithFrame:CGRectZero];
    self.card.translatesAutoresizingMaskIntoConstraints = NO;
    self.card.backgroundColor = [WolFoxProTheme royalCard];
    self.card.layer.cornerRadius = 26.0;
    self.card.layer.borderWidth = 1.0;
    self.card.layer.borderColor = [[WolFoxProTheme royalBlue] colorWithAlphaComponent:0.55].CGColor;
    self.card.clipsToBounds = YES;
    [self.view addSubview:self.card];
    
    UIView *card = self.card;

    self.headerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.backgroundColor = [WolFoxProTheme royalField];
    [card addSubview:self.headerView];

    UIButton *exitBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    exitBtn.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *exitConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
        [exitBtn setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:exitConfig] forState:UIControlStateNormal];
    }
    [exitBtn setTitleColor:[UIColor colorWithRed:0.96 green:0.30 blue:0.30 alpha:1.0] forState:UIControlStateNormal];
    exitBtn.tintColor = [UIColor colorWithRed:0.96 green:0.30 blue:0.30 alpha:1.0];
    exitBtn.hidden = YES;
    [self.headerView addSubview:exitBtn];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Wolfox";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.headerView addSubview:titleLabel];

    UIImageView *crownIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"crown.fill"]];
    crownIcon.translatesAutoresizingMaskIntoConstraints = NO;
    crownIcon.tintColor = [WolFoxProTheme royalBlue];
    crownIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.headerView addSubview:crownIcon];

    [NSLayoutConstraint activateConstraints:@[
        [exitBtn.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:20],
        [exitBtn.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [titleLabel.centerXAnchor constraintEqualToAnchor:self.headerView.centerXAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [crownIcon.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-20],
        [crownIcon.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [crownIcon.widthAnchor constraintEqualToConstant:24],
        [crownIcon.heightAnchor constraintEqualToConstant:24]
    ]];

    self.lockIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.shield.fill"]];
    self.lockIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.lockIcon.tintColor = [WolFoxProTheme royalBlue];
    self.lockIcon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:self.lockIcon];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Wolfox";
    subtitle.textColor = [WolFoxProTheme textPrimary];
    subtitle.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBlack];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [card addSubview:subtitle];

    UILabel *desc = [UILabel new];
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    desc.text = @"أدخل كود التفعيل للمتابعة بأمان";
    desc.textColor = [UIColor colorWithWhite:0.73 alpha:1.0];
    desc.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    desc.textAlignment = NSTextAlignmentCenter;
    [card addSubview:desc];

    self.codeField = [UITextField new];
    self.codeField.translatesAutoresizingMaskIntoConstraints = NO;
    self.codeField.backgroundColor = [WolFoxProTheme royalField];
    self.codeField.textColor = [UIColor whiteColor];
    self.codeField.tintColor = [WolFoxProTheme royalBlue];
    self.codeField.layer.cornerRadius = 16.0;
    self.codeField.layer.borderWidth = 1.5;
    self.codeField.layer.borderColor = [[WolFoxProTheme royalBlue] colorWithAlphaComponent:0.62].CGColor;
    self.codeField.placeholder = @"GPS-XXXX-XXXX-XXXX";
    self.codeField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:self.codeField.placeholder attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.40 alpha:1.0]}];
    self.codeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.codeField.textAlignment = NSTextAlignmentCenter;
    self.codeField.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightBlack];
    self.codeField.delegate = self;
    self.codeField.text = [WFLicenseClient storedCode] ?: @"";
    [card addSubview:self.codeField];

    self.activateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.activateButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.activateButton.backgroundColor = [WolFoxProTheme royalBlue];
    self.activateButton.layer.cornerRadius = 16.0;
    [self.activateButton setTitle:@"تفعيل الآن" forState:UIControlStateNormal];
    [self.activateButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.activateButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBlack];
    
    // Add Shadow to Button
    self.activateButton.layer.shadowColor = [WolFoxProTheme royalBlue].CGColor;
    self.activateButton.layer.shadowOffset = CGSizeMake(0, 4);
    self.activateButton.layer.shadowOpacity = 0.8;
    self.activateButton.layer.shadowRadius = 10;
    [self.activateButton addTarget:self action:@selector(activatePressed) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:self.activateButton];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textColor = [UIColor colorWithRed:1.0 green:0.50 blue:0.50 alpha:1.0];
    self.statusLabel.backgroundColor = [UIColor colorWithRed:0.35 green:0.08 blue:0.10 alpha:0.40];
    self.statusLabel.layer.cornerRadius = 10.0;
    self.statusLabel.clipsToBounds = YES;
    self.statusLabel.hidden = YES;
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    [card addSubview:self.statusLabel];

    self.updateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.updateButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.updateButton.backgroundColor = [[WolFoxProTheme royalBlue] colorWithAlphaComponent:0.15];
    self.updateButton.layer.cornerRadius = 12;
    self.updateButton.layer.borderWidth = 1;
    self.updateButton.layer.borderColor = [[WolFoxProTheme royalBlue] colorWithAlphaComponent:0.7].CGColor;
    [self.updateButton setTitle:@"تنزيل التحديث المطلوب" forState:UIControlStateNormal];
    [self.updateButton setTitleColor:[WolFoxProTheme textPrimary] forState:UIControlStateNormal];
    self.updateButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [self.updateButton addTarget:self action:@selector(openUpdateURL) forControlEvents:UIControlEventTouchUpInside];
    self.updateButton.hidden = !self.updateURL.length;
    [card addSubview:self.updateButton];

    self.uuidLabel = [UILabel new];
    self.uuidLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.uuidLabel.textColor = [UIColor colorWithWhite:0.48 alpha:1.0];
    self.uuidLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
    self.uuidLabel.textAlignment = NSTextAlignmentCenter;
    self.uuidLabel.numberOfLines = 0;
    self.uuidLabel.text = [NSString stringWithFormat:@"معرّف الجهاز • %@", [WFLicenseClient deviceIdentifier]];
    [card addSubview:self.uuidLabel];

    self.loadingOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.loadingOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingOverlay.backgroundColor = [WolFoxProTheme royalCard];
    self.loadingOverlay.hidden = YES;
    self.loadingOverlay.alpha = 0;
    [card addSubview:self.loadingOverlay];

    self.waitLabel = [UILabel new];
    self.waitLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.waitLabel.text = @"جارٍ التحقق من الكود";
    self.waitLabel.textColor = [UIColor whiteColor];
    self.waitLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBlack];
    self.waitLabel.textAlignment = NSTextAlignmentCenter;
    [self.loadingOverlay addSubview:self.waitLabel];

    self.timerLabel = [UILabel new];
    self.timerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.timerLabel.textColor = [UIColor colorWithRed:0.08 green:0.45 blue:0.98 alpha:1.0];
    self.timerLabel.font = [UIFont systemFontOfSize:64 weight:UIFontWeightBlack];
    self.timerLabel.textAlignment = NSTextAlignmentCenter;
    [self.loadingOverlay addSubview:self.timerLabel];

    self.cardCenterY = [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        self.cardCenterY,
        [card.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.90],
        [card.widthAnchor constraintLessThanOrEqualToConstant:400],

        [self.headerView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [self.headerView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:64],

        [titleLabel.centerXAnchor constraintEqualToAnchor:self.headerView.centerXAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],

        [self.lockIcon.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:26],
        [self.lockIcon.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [self.lockIcon.widthAnchor constraintEqualToConstant:60],
        [self.lockIcon.heightAnchor constraintEqualToConstant:60],

        [subtitle.topAnchor constraintEqualToAnchor:self.lockIcon.bottomAnchor constant:15],
        [subtitle.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        
        [desc.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:10],
        [desc.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [self.codeField.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:22],
        [self.codeField.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [self.codeField.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [self.codeField.heightAnchor constraintEqualToConstant:56],

        [self.activateButton.topAnchor constraintEqualToAnchor:self.codeField.bottomAnchor constant:18],
        [self.activateButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [self.activateButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [self.activateButton.heightAnchor constraintEqualToConstant:56],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.activateButton.bottomAnchor constant:14],
        [self.statusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:38],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        
        [self.updateButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
        [self.updateButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [self.updateButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [self.updateButton.heightAnchor constraintEqualToConstant:self.updateURL.length ? 44 : 0],

        [self.uuidLabel.topAnchor constraintEqualToAnchor:self.updateButton.bottomAnchor constant:12],
        [self.uuidLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [self.uuidLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [self.uuidLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-30],

        [self.loadingOverlay.topAnchor constraintEqualToAnchor:card.topAnchor],
        [self.loadingOverlay.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.loadingOverlay.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [self.loadingOverlay.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],

        [self.waitLabel.centerXAnchor constraintEqualToAnchor:self.loadingOverlay.centerXAnchor],
        [self.waitLabel.centerYAnchor constraintEqualToAnchor:self.loadingOverlay.centerYAnchor constant:-50],

        [self.timerLabel.centerXAnchor constraintEqualToAnchor:self.loadingOverlay.centerXAnchor],
        [self.timerLabel.topAnchor constraintEqualToAnchor:self.waitLabel.bottomAnchor constant:15]
    ]];
    if (self.noticeMessage.length) [self showActivationError:self.noticeMessage];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_activationTimer invalidate];
}

- (void)closePressed {
    [self.view endEditing:YES];
    [self.activationTimer invalidate];
    self.activationTimer = nil;
    self.statusLabel.hidden = YES;
    self.statusLabel.text = @"";
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary* userInfo = [notification userInfo];
    CGRect keyboardFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = keyboardFrame.size.height;
    
    [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{
        self.cardCenterY.constant = -(keyboardHeight / 2.0) + 40;
        [self.view layoutIfNeeded];
    }];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{
        self.cardCenterY.constant = 0;
        [self.view layoutIfNeeded];
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self activatePressed];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    textField.layer.borderColor = [WolFoxProTheme royalBlue].CGColor;
    textField.layer.borderWidth = 2.0;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    textField.layer.borderColor = [[WolFoxProTheme royalBlue] colorWithAlphaComponent:0.62].CGColor;
    textField.layer.borderWidth = 1.5;
}

- (void)activatePressed {
    if (!self.activateButton.enabled) return;
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSLog(@"[WolFox][ACT] activation_submitted length=%lu", (unsigned long)code.length);
    if (code.length == 0) {
        [self showActivationError:@"أدخل كود التفعيل أولاً ثم حاول مرة أخرى."];
        return;
    }

    [self.activationTimer invalidate];
    self.activationTimer = nil;
    self.activateButton.enabled = NO;
    self.loadingOverlay.hidden = NO;
    [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{ self.loadingOverlay.alpha = 1.0; }];

    self.timerLabel.text = @"•••";
    [self finalizeActivation];
}

- (void)tickTimer {
    self.countdown--;
    if (self.countdown <= 0) {
        [self.activationTimer invalidate];
        self.activationTimer = nil;
        self.timerLabel.text = @"0";
        [self finalizeActivation];
        return;
    }
    self.timerLabel.text = [NSString stringWithFormat:@"%ld", (long)self.countdown];
}

- (void)finalizeActivation {
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSLog(@"[WolFox][ACT] server_activation_begin length=%lu", (unsigned long)code.length);
    __weak typeof(self) weakSelf = self;
    [WFLicenseClient activateCode:code completion:^(WFLicenseResult *result) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        
        if (result.success) {
            NSLog(@"[WolFox][ACT] server_activation_ok status=%ld", (long)result.status);
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"WF_ACT_SHOWN"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            
            self.waitLabel.text = @"تم التفعيل بنجاح";
            self.timerLabel.hidden = YES;
            [self.lockIcon.layer removeAllAnimations];
            self.lockIcon.image = [UIImage systemImageNamed:@"checkmark.seal.fill"];
            self.lockIcon.tintColor = [UIColor systemGreenColor];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self dismissViewControllerAnimated:YES completion:^{
                    NSLog(@"[WolFox][ACT] activation_view_dismissed");
                    if (self.completion) self.completion(YES);
                }];
            });
        } else {
            NSLog(@"[WolFox][ACT] server_activation_failed status=%ld", (long)result.status);
            [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{ self.loadingOverlay.alpha = 0; } completion:^(BOOL f){
                self.loadingOverlay.hidden = YES;
                [self showActivationError:[self friendlyActivationMessage:result]];
                [self.lockIcon.layer removeAllAnimations];
                self.activateButton.enabled = YES;
                self.timerLabel.hidden = NO;
            }];
        }
    }];
}

- (NSString *)friendlyActivationMessage:(WFLicenseResult *)result {
    switch (result.status) {
        case WFLicenseStatusNetworkError:
            return @"تعذر الاتصال بخادم التفعيل. تحقق من الشبكة ثم أعد المحاولة.";
        case WFLicenseStatusExpired:
            return @"انتهت صلاحية هذا الكود. راجع حالة الاشتراك.";
        case WFLicenseStatusBlocked:
            return @"تم إيقاف هذا الكود. تواصل مع الدعم للمراجعة.";
        case WFLicenseStatusInvalid:
            return @"الكود غير صحيح أو غير مخصص لهذا الجهاز.";
        case WFLicenseStatusInvalidToken:
            return @"انتهت جلسة التفعيل. أعد تفعيل الكود نفسه.";
        case WFLicenseStatusProjectDisabled:
            return @"المشروع متوقف حالياً من لوحة التحكم.";
        case WFLicenseStatusUpdateRequired:
            return @"يجب تثبيت الإصدار المطلوب قبل المتابعة.";
        case WFLicenseStatusRateLimited:
            return @"طلبات كثيرة خلال وقت قصير. انتظر قليلاً ثم أعد المحاولة.";
        default:
            return @"لم يكتمل التفعيل حالياً. حاول مرة أخرى لاحقاً.";
    }
}

- (void)showActivationError:(NSString *)message {
    self.statusLabel.text = [NSString stringWithFormat:@"⚠︎ %@", message ?: @"تعذر إكمال التفعيل"];
    self.statusLabel.hidden = NO;
    self.statusLabel.alpha = 0;
    [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{ self.statusLabel.alpha = 1.0; }];
}

- (void)openUpdateURL {
    NSURL *url = [NSURL URLWithString:self.updateURL ?: @""];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
