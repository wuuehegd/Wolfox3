// WolFoxMaster.mm - WolFox v.1.6.1 "Royal Sidebar Pro Edition"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <Photos/Photos.h>
#import <math.h>

#import "WolFoxProStore.h"
#import "WolFoxProTheme.h"
#import "WolFoxProHookManager.h"
#import "WolFoxProCellModel.h"
#import "WFLicenseClient.h"
#import "WFActivationViewController.h"

@class WolFoxMainViewController;
static NSString * const WFUIHiddenOnLaunchKey = @"WF_UI_HIDDEN_UNTIL_VOLUME_REQUEST";

static BOOL WFMasterProcessIsEligible(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
    NSString *process = NSProcessInfo.processInfo.processName.lowercaseString;
    return bundleID.length && ![bundleID hasPrefix:@"com.apple."] && ![process containsString:@"springboard"] && ![process containsString:@"backboard"];
}

@interface WolFoxController : NSObject
@property (nonatomic, strong) WolFoxMainViewController *mainVC;
@property (nonatomic, strong) UIButton *floatingIcon;
@property (nonatomic, strong) UIButton *cameraIcon;
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, weak) UIWindow *previousKeyWindow;
@property (nonatomic, strong) AVAudioSession *volumeSession;
@property (nonatomic, assign) NSInteger volumePulseCount;
@property (nonatomic, assign) NSTimeInterval lastVolumePulseTime;
@property (nonatomic, assign) NSTimeInterval lastVolumeToggleTime;
@property (nonatomic, assign) NSTimeInterval lastSystemVolumeNotificationTime;
@property (nonatomic, assign) NSTimeInterval lastFallbackVolumePulseTime;
+ (instancetype)shared;
- (void)showUI;
- (void)dismissUI;
- (void)toggleUI;
- (void)toggleCameraIcon:(BOOL)show;
- (void)handleVolumeGesturePulse;
- (void)prepareHiddenVolumeListening;
- (void)recordVolumeButtonPress;
- (void)showActivationScreen;
- (void)showActivationScreenWithResult:(WFLicenseResult *)result;
@end

@interface WolFoxOverlayWindow : UIWindow
@end

@interface WolFoxMainViewController : UIViewController <MKMapViewDelegate, UITextFieldDelegate, UISearchBarDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, CBCentralManagerDelegate, CLLocationManagerDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) MKPointAnnotation *realLocPin;
- (void)refreshSpoofHeaderStatus;
- (void)closeExpandedMapIfNeeded;
@end

@implementation WolFoxOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) return nil;
    
    UIViewController *root = self.rootViewController;
    if (root) {
        if (root.presentedViewController) return [super hitTest:point withEvent:event];
        if ([root isKindOfClass:objc_getClass("WolFoxMainViewController")]) {
            WolFoxMainViewController *vc = (WolFoxMainViewController *)root;
            if (vc.view && !vc.view.hidden && vc.view.alpha > 0.5) return [super hitTest:point withEvent:event];
        }
    }
    
    Class ctrlCls = objc_getClass("WolFoxController");
    if (ctrlCls) {
        WolFoxController *ctrl = [ctrlCls shared];
        if (ctrl && ctrl.cameraIcon && !ctrl.cameraIcon.hidden && ctrl.cameraIcon.alpha > 0.1) {
            CGPoint p = [self convertPoint:point toView:ctrl.cameraIcon];
            if ([ctrl.cameraIcon pointInside:p withEvent:event]) return ctrl.cameraIcon;
        }
    }
    return nil;
}

// Volume buttons handled via UIApplication hook in WolFoxIntegrated.mm
@end

@implementation WolFoxMainViewController {
    UIVisualEffectView *_blurView;
    UIView *_tabsBar;
    UIView *_dashboard;
    UIView *_header;
    UILabel *_titleLabel;
    UILabel *_spoofStatusLabel;
    MKPointAnnotation *_currentPin;
    UIView *_mapCard;
    UIView *_expandedMapContainer;
    UIButton *_expandedMapCloseButton;
    MKLocalSearch *_activeMapSearch;
    BOOL _mapExpanded;
    UITextField *_latInput;
    UITextField *_lonInput;
    UIScrollView *_scrollDashboard;
    NSMutableArray *_tabBtns;
    NSInteger _activePage; // 0: GPS, 1: ID, 2: Camera, 3: Settings
    CLLocationManager *_realLocManager;
    CBCentralManager *_btManager;
    NSMutableArray *_discoveredDevices; // array of NSDictionary
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    _tabBtns = [NSMutableArray new];
    _realLocManager = [CLLocationManager new];
    _realLocManager.delegate = self;
    _realLocManager.desiredAccuracy = kCLLocationAccuracyBest;
    [_realLocManager requestWhenInUseAuthorization];
    [_realLocManager startUpdatingLocation];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(routeFinished) name:@"WF_ROUTE_FINISHED" object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"WF_ROUTE_FINISHED" object:nil];
    [_activeMapSearch cancel];
    [_realLocManager stopUpdatingLocation];
    _realLocManager.delegate = nil;
    _btManager.delegate = nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_mapExpanded) [self layoutExpandedMap];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // Setup UI here so bounds are guaranteed non-zero
    if (_tabBtns.count == 0) {
        [self setupUI];
        [self switchPage:0];
    }
}

- (void)setupUI {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat safeTop = MAX(self.view.safeAreaInsets.top, 28.0);
    CGFloat headerHeight = safeTop + 58.0;
    
    _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:[WolFoxProTheme blurStyle]]];
    _blurView.frame = self.view.bounds;
    [self.view addSubview:_blurView];
    
    // 1. Header — respects the status area and keeps every SF Symbol aligned.
    _header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, headerHeight)];
    _header.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.16];
    [self.view addSubview:_header];
    
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, safeTop + 7, 135, 26)];
    _titleLabel.text = @"Wolfox";
    _titleLabel.textAlignment = NSTextAlignmentLeft;
    _titleLabel.font = [WolFoxProTheme fontOfSize:20 weight:UIFontWeightBlack];
    _titleLabel.textColor = [WolFoxProTheme textPrimary];
    [_header addSubview:_titleLabel];

    _spoofStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, safeTop + 34, 190, 16)];
    _spoofStatusLabel.textAlignment = NSTextAlignmentLeft;
    _spoofStatusLabel.font = [WolFoxProTheme fontOfSize:11 weight:UIFontWeightBold];
    _spoofStatusLabel.isAccessibilityElement = YES;
    [_header addSubview:_spoofStatusLabel];
    [self refreshSpoofHeaderStatus];
    
    UIButton *closeBtn = [self headerCircleBtn:@"xmark" color:[WolFoxProTheme danger] x:w - 58];
    [closeBtn addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    closeBtn.accessibilityLabel = @"إخفاء Wolfox مع إبقاء أزرار الصوت فعالة";
    [_header addSubview:closeBtn];
    
    UIButton *crownBtn = [self headerCircleBtn:@"crown.fill" color:[WolFoxProTheme accent] x:w - 110];
    [crownBtn addTarget:self action:@selector(showSubscriptionInfo) forControlEvents:UIControlEventTouchUpInside];
    crownBtn.accessibilityLabel = @"معلومات الاشتراك";
    [_header addSubview:crownBtn];

    // 2. Top Tabs Bar
    _tabsBar = [[UIView alloc] initWithFrame:CGRectMake(0, headerHeight, w, 58)];
    _tabsBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.1];
    [self.view addSubview:_tabsBar];
    
    UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 55, w / 5.0, 3)];
    indicator.backgroundColor = [WolFoxProTheme accent];
    objc_setAssociatedObject(self, "_tab_indicator", indicator, OBJC_ASSOCIATION_ASSIGN);
    [_tabsBar addSubview:indicator];
    
    NSArray *icons = @[@"location.fill", @"person.text.rectangle.fill", @"antenna.radiowaves.left.and.right", @"camera.fill", @"gearshape.fill"];
    NSArray *tabLabels = @[@"الموقع GPS", @"معرف الجهاز", @"البلوتوث", @"الكاميرا", @"الإعدادات"];
    UIImageSymbolConfiguration *tabConfig = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
    CGFloat tw = w / icons.count;
    for (NSUInteger i = 0; i < icons.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(i * tw, 0, tw, 58);
        if (@available(iOS 13.0, *)) {
            [b setImage:[UIImage systemImageNamed:icons[i] withConfiguration:tabConfig] forState:UIControlStateNormal];
        }
        b.tintColor = [UIColor whiteColor];
        b.adjustsImageWhenHighlighted = NO;
        b.tag = (NSInteger)i;
        b.accessibilityLabel = tabLabels[i];
        b.accessibilityHint = @"يفتح هذا القسم";
        [b addTarget:self action:@selector(tabBtnPressed:) forControlEvents:UIControlEventTouchUpInside];
        [_tabsBar addSubview:b];
        [_tabBtns addObject:b];
    }
    
    // 3. Dashboard (Main Content)
    _dashboard = [[UIView alloc] initWithFrame:CGRectMake(0, headerHeight + 58, w, h - headerHeight - 58)];
    [self.view addSubview:_dashboard];
    
    _scrollDashboard = [[UIScrollView alloc] initWithFrame:_dashboard.bounds];
    _scrollDashboard.alwaysBounceVertical = YES;
    [_dashboard addSubview:_scrollDashboard];
}

- (UIButton *)headerCircleBtn:(NSString *)icon color:(UIColor *)color x:(CGFloat)x {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    CGFloat safeTop = MAX(self.view.safeAreaInsets.top, 28.0);
    b.frame = CGRectMake(x, safeTop + 3, 44, 44);
    b.backgroundColor = [color colorWithAlphaComponent:0.12];
    b.layer.cornerRadius = 13;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
        [b setImage:[UIImage systemImageNamed:icon withConfiguration:config] forState:UIControlStateNormal];
    }
    b.tintColor = color;
    b.adjustsImageWhenHighlighted = NO;
    return b;
}

- (void)refreshSpoofHeaderStatus {
    WolFoxProStore *store = [WolFoxProStore shared];
    BOOL active = store.spoofActive || store.bluetoothActive || store.mediaUploadActive || [store validatedActiveIdentifier] != nil;
    _spoofStatusLabel.text = active ? @"● نشط • التزييف مفعّل" : @"○ متوقف • الوضع الحقيقي";
    _spoofStatusLabel.textColor = active ? [WolFoxProTheme success] : [WolFoxProTheme textSecondary];
    _spoofStatusLabel.accessibilityLabel = active ? @"حالة التزييف: نشط" : @"حالة التزييف: متوقف";
}

- (void)tabBtnPressed:(UIButton *)b { [self switchPage:b.tag]; }

- (void)switchPage:(NSInteger)page {
    if (_mapExpanded) [self closeExpandedMapIfNeeded];
    CGFloat w = self.view.bounds.size.width;
    UIView *indicator = objc_getAssociatedObject(self, "_tab_indicator");

    if (!indicator) {
        for (UIView *v in _tabsBar.subviews) { if (v.frame.size.height == 3) { indicator = v; break; } }
    }

    CGFloat tw = w / 5.0;
    if (indicator) indicator.frame = CGRectMake(page * tw, 55, tw, 3);
    for (UIButton *b in _tabBtns) b.tintColor = (b.tag == page) ? [WolFoxProTheme accent] : [UIColor whiteColor];

    for (UIView *v in _scrollDashboard.subviews) [v removeFromSuperview];

    // Stop BT scan if leaving BT tab (check before updating _activePage)
    if (_activePage == 2 && page != 2 && _btManager) {
        [_btManager stopScan];
    }

    _activePage = page;
    [self refreshSpoofHeaderStatus];

    if (page == 0) [self setupGPSPage];
    else if (page == 1) [self setupIDPage];
    else if (page == 2) [self setupBluetoothPage];
    else if (page == 3) [self setupCameraPage];
    else if (page == 4) [self setupSettingsPage];
}

#pragma mark - Bluetooth Page

- (void)setupBluetoothPage {
    CGFloat w = _scrollDashboard.bounds.size.width;
    CGFloat y = 10;

    // ── Toggle Card ──
    UIView *toggleCard = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 65)];
    toggleCard.backgroundColor = [WolFoxProTheme surfacePrimary]; toggleCard.layer.cornerRadius = 15;
    [_scrollDashboard addSubview:toggleCard];

    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(15, 0, toggleCard.bounds.size.width - 80, 65)];
    tl.text = @"تفعيل تزييف البلوتوث"; tl.textColor = [WolFoxProTheme textPrimary];
    tl.font = [WolFoxProTheme fontOfSize:15 weight:UIFontWeightBold]; tl.textAlignment = NSTextAlignmentRight;
    [toggleCard addSubview:tl];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(15, 17, 50, 30)];
    sw.on = [WolFoxProStore shared].bluetoothActive; sw.onTintColor = [WolFoxProTheme accent];
    sw.accessibilityLabel = @"تزييف البلوتوث";
    [sw addTarget:self action:@selector(btToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [toggleCard addSubview:sw];
    y += 80;

    // ── Action Buttons Row ──
    CGFloat bw = (w - 45) / 2.0;

    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    scanBtn.frame = CGRectMake(15, y, bw, 50);
    scanBtn.backgroundColor = [WolFoxProTheme accent]; scanBtn.layer.cornerRadius = 14;
    if (@available(iOS 13.0, *)) [scanBtn setImage:[UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"] forState:UIControlStateNormal];
    [scanBtn setTitle:@"  بحث" forState:UIControlStateNormal];
    [scanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    scanBtn.tintColor = [UIColor whiteColor];
    scanBtn.titleLabel.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBlack];
    [scanBtn addTarget:self action:@selector(startBTScan) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(self, "bt_scan_btn", scanBtn, OBJC_ASSOCIATION_ASSIGN);
    [_scrollDashboard addSubview:scanBtn];

    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.frame = CGRectMake(bw + 30, y, bw, 50);
    addBtn.backgroundColor = [WolFoxProTheme surfacePrimary]; addBtn.layer.cornerRadius = 14;
    if (@available(iOS 13.0, *)) [addBtn setImage:[UIImage systemImageNamed:@"plus.circle.fill"] forState:UIControlStateNormal];
    [addBtn setTitle:@"  إضافة يدوي" forState:UIControlStateNormal];
    [addBtn setTitleColor:[WolFoxProTheme textPrimary] forState:UIControlStateNormal];
    addBtn.tintColor = [WolFoxProTheme accent];
    addBtn.titleLabel.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold];
    [addBtn addTarget:self action:@selector(addBleDeviceManually) forControlEvents:UIControlEventTouchUpInside];
    [_scrollDashboard addSubview:addBtn];
    y += 65;

    // ── Discovered Devices (scan results) ──
    NSArray *discovered = _discoveredDevices ?: @[];
    if (discovered.count > 0) {
        UILabel *discTitle = [[UILabel alloc] initWithFrame:CGRectMake(15, y, w - 30, 28)];
        discTitle.text = @"أجهزة مكتشفة"; discTitle.textColor = [WolFoxProTheme textSecondary];
        discTitle.font = [WolFoxProTheme fontOfSize:13 weight:UIFontWeightBold];
        [_scrollDashboard addSubview:discTitle];
        y += 33;

        for (NSDictionary *dev in discovered) {
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 58)];
            row.backgroundColor = [WolFoxProTheme surfacePrimary]; row.layer.cornerRadius = 13;
            [_scrollDashboard addSubview:row];

            UILabel *nl = [[UILabel alloc] initWithFrame:CGRectMake(55, 8, row.bounds.size.width - 105, 22)];
            nl.text = dev[@"name"] ?: @"جهاز غير معروف";
            nl.textColor = [WolFoxProTheme textPrimary]; nl.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold];
            nl.textAlignment = NSTextAlignmentRight; [row addSubview:nl];

            UILabel *ul = [[UILabel alloc] initWithFrame:CGRectMake(55, 30, row.bounds.size.width - 105, 18)];
            NSString *uuidStr = dev[@"uuid"] ?: @"";
            ul.text = uuidStr.length > 8 ? [uuidStr substringToIndex:8] : uuidStr;
            ul.textColor = [WolFoxProTheme textSecondary]; ul.font = [WolFoxProTheme fontOfSize:11 weight:UIFontWeightMedium];
            ul.textAlignment = NSTextAlignmentRight; [row addSubview:ul];

            UILabel *rssiL = [[UILabel alloc] initWithFrame:CGRectMake(10, 15, 40, 28)];
            rssiL.text = [NSString stringWithFormat:@"%@ dBm", dev[@"rssi"] ?: @"0"];
            rssiL.textColor = [WolFoxProTheme accent]; rssiL.font = [WolFoxProTheme fontOfSize:10 weight:UIFontWeightBold];
            rssiL.numberOfLines = 2; rssiL.textAlignment = NSTextAlignmentCenter; [row addSubview:rssiL];

            UIButton *saveB = [UIButton buttonWithType:UIButtonTypeSystem];
            saveB.frame = CGRectMake(row.bounds.size.width - 50, 7, 44, 44);
            if (@available(iOS 13.0, *)) [saveB setImage:[UIImage systemImageNamed:@"square.and.arrow.down"] forState:UIControlStateNormal];
            saveB.tintColor = [WolFoxProTheme success];
            objc_setAssociatedObject(saveB, "bt_dev_dict", dev, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [saveB addTarget:self action:@selector(saveDiscoveredDevice:) forControlEvents:UIControlEventTouchUpInside];
            saveB.accessibilityLabel = @"حفظ جهاز البلوتوث المكتشف";
            [row addSubview:saveB];
            y += 66;
        }
        y += 5;
    }

    // ── Saved Profiles ──
    NSArray *profiles = [WolFoxProStore shared].savedBleProfiles;
    UILabel *savedTitle = [[UILabel alloc] initWithFrame:CGRectMake(15, y, w - 30, 28)];
    savedTitle.text = [NSString stringWithFormat:@"الأجهزة المحفوظة (%lu)", (unsigned long)profiles.count];
    savedTitle.textColor = [WolFoxProTheme textSecondary]; savedTitle.font = [WolFoxProTheme fontOfSize:13 weight:UIFontWeightBold];
    [_scrollDashboard addSubview:savedTitle];
    y += 33;

    if (profiles.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(15, y, w - 30, 44)];
        empty.text = @"لا توجد أجهزة محفوظة بعد";
        empty.textColor = [WolFoxProTheme textSecondary]; empty.font = [UIFont systemFontOfSize:13];
        empty.textAlignment = NSTextAlignmentCenter; [_scrollDashboard addSubview:empty];
        y += 50;
    } else {
        for (WolFoxBleProfile *p in profiles) {
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 62)];
            BOOL isActive = [p.profileID isEqualToString:[WolFoxProStore shared].activeBleProfileID];
            row.backgroundColor = isActive ? [[WolFoxProTheme accent] colorWithAlphaComponent:0.15] : [WolFoxProTheme surfacePrimary];
            row.layer.cornerRadius = 14;
            if (isActive) { row.layer.borderColor = [WolFoxProTheme accent].CGColor; row.layer.borderWidth = 1.5; }
            [_scrollDashboard addSubview:row];

            UILabel *nl = [[UILabel alloc] initWithFrame:CGRectMake(50, 8, row.bounds.size.width - 100, 22)];
            nl.text = p.name ?: @"جهاز"; nl.textColor = [WolFoxProTheme textPrimary];
            nl.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold]; nl.textAlignment = NSTextAlignmentRight;
            [row addSubview:nl];

            UILabel *idl = [[UILabel alloc] initWithFrame:CGRectMake(50, 30, row.bounds.size.width - 100, 18)];
            NSString *disp = p.localName.length ? p.localName : (p.uuid.length > 8 ? [p.uuid substringToIndex:8] : p.uuid);
            idl.text = disp; idl.textColor = [WolFoxProTheme textSecondary];
            idl.font = [WolFoxProTheme fontOfSize:11 weight:UIFontWeightMedium]; idl.textAlignment = NSTextAlignmentRight;
            [row addSubview:idl];

            if (isActive) {
                UILabel *actL = [[UILabel alloc] initWithFrame:CGRectMake(10, 20, 35, 22)];
                actL.text = @"✓"; actL.textColor = [WolFoxProTheme accent];
                actL.font = [WolFoxProTheme fontOfSize:18 weight:UIFontWeightBlack]; actL.textAlignment = NSTextAlignmentCenter;
                [row addSubview:actL];
            }

            // Select button (full row tap)
            UIButton *selB = [UIButton buttonWithType:UIButtonTypeCustom];
            selB.frame = CGRectMake(0, 0, row.bounds.size.width - 45, row.bounds.size.height);
            objc_setAssociatedObject(selB, "bt_profile", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [selB addTarget:self action:@selector(activateBleProfile:) forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:selB];

            // Delete button
            UIButton *delB = [UIButton buttonWithType:UIButtonTypeSystem];
            delB.frame = CGRectMake(row.bounds.size.width - 50, 9, 44, 44);
            if (@available(iOS 13.0, *)) [delB setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
            delB.tintColor = [WolFoxProTheme danger];
            objc_setAssociatedObject(delB, "bt_profile", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [delB addTarget:self action:@selector(deleteBleProfile:) forControlEvents:UIControlEventTouchUpInside];
            delB.accessibilityLabel = @"حذف جهاز البلوتوث المحفوظ";
            [row addSubview:delB];

            y += 70;
        }
    }

    _scrollDashboard.contentSize = CGSizeMake(w, y + 30);
}

- (void)btToggleChanged:(UISwitch *)sw {
    if (sw.on) {
        [WolFoxProStore shared].bluetoothActive = YES;
        [[WolFoxProStore shared] saveSettings];
        [self refreshSpoofHeaderStatus];
        [self showToast:@"✅ تم تفعيل تزييف البلوتوث"];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"إيقاف تزييف البلوتوث؟" message:@"ستعود معلومات البلوتوث الحقيقية بعد التأكيد." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"متابعة التزييف" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { [sw setOn:YES animated:YES]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إيقاف الآن" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [WolFoxProStore shared].bluetoothActive = NO;
        [[WolFoxProStore shared] saveSettings];
        [self refreshSpoofHeaderStatus];
        [self showToast:@"⚠️ تم إيقاف تزييف البلوتوث"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startBTScan {
    if (_discoveredDevices == nil) _discoveredDevices = [NSMutableArray new];
    [_discoveredDevices removeAllObjects];

    UIButton *scanBtn = objc_getAssociatedObject(self, "bt_scan_btn");
    [scanBtn setTitle:@"  جاري البحث..." forState:UIControlStateNormal];
    scanBtn.enabled = NO;

    if (!_btManager) {
        _btManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
    } else {
        [self _doStartBTScan];
    }
    [self showToast:@"🔍 جاري البحث عن أجهزة Bluetooth..."];
}

- (void)_doStartBTScan {
    if (_btManager.state != CBManagerStatePoweredOn) {
        [self showToast:@"❌ البلوتوث غير مفعّل على الجهاز"];
        UIButton *scanBtn = objc_getAssociatedObject(self, "bt_scan_btn");
        [scanBtn setTitle:@"  بحث" forState:UIControlStateNormal]; scanBtn.enabled = YES;
        return;
    }
    [_btManager scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [_btManager stopScan];
        UIButton *scanBtn = objc_getAssociatedObject(self, "bt_scan_btn");
        [scanBtn setTitle:@"  بحث" forState:UIControlStateNormal]; scanBtn.enabled = YES;
        [self switchPage:2]; // Refresh BT page
        [self showToast:[NSString stringWithFormat:@"✅ تم العثور على %lu جهاز", (unsigned long)_discoveredDevices.count]];
    });
}

// CBCentralManagerDelegate
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBManagerStatePoweredOn) [self _doStartBTScan];
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)adData RSSI:(NSNumber *)RSSI {
    NSString *name = peripheral.name ?: adData[CBAdvertisementDataLocalNameKey] ?: @"جهاز غير معروف";
    NSString *uuidStr = peripheral.identifier.UUIDString;
    // Avoid duplicates
    for (NSDictionary *d in _discoveredDevices) {
        if ([d[@"uuid"] isEqualToString:uuidStr]) return;
    }
    [_discoveredDevices addObject:@{@"name": name, @"uuid": uuidStr, @"localName": adData[CBAdvertisementDataLocalNameKey] ?: @"", @"rssi": RSSI ?: @0}];
}

- (void)saveDiscoveredDevice:(UIButton *)btn {
    NSDictionary *dev = objc_getAssociatedObject(btn, "bt_dev_dict");
    if (!dev) return;
    WolFoxBleProfile *p = [WolFoxBleProfile new];
    p.profileID = [[NSUUID UUID] UUIDString];
    p.name      = dev[@"name"] ?: @"جهاز";
    p.uuid      = dev[@"uuid"] ?: @"";
    p.localName = dev[@"localName"] ?: @"";
    p.rssi      = [dev[@"rssi"] integerValue];
    [[WolFoxProStore shared] saveBleProfile:p];
    [self showToast:[NSString stringWithFormat:@"✅ تم حفظ: %@", p.name]];
    [self switchPage:2];
}

- (void)addBleDeviceManually {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"إضافة جهاز يدوي" message:@"أدخل اسم الجهاز والـ UUID" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.placeholder = @"اسم الجهاز (مثال: iPhone 13)";
        tf.textAlignment = NSTextAlignmentRight;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.placeholder = @"UUID (اختياري)";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *name = ac.textFields[0].text;
        NSString *uuid = ac.textFields[1].text;
        if (name.length == 0) { [self showToast:@"❌ الاسم مطلوب"]; return; }
        WolFoxBleProfile *p = [WolFoxBleProfile new];
        p.profileID = [[NSUUID UUID] UUIDString];
        p.name      = name;
        p.uuid      = uuid.length > 0 ? uuid : [[NSUUID UUID] UUIDString];
        p.localName = name;
        p.rssi      = -60;
        [[WolFoxProStore shared] saveBleProfile:p];
        [self showToast:[NSString stringWithFormat:@"✅ تم إضافة: %@", name]];
        [self switchPage:2];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)activateBleProfile:(UIButton *)btn {
    WolFoxBleProfile *p = objc_getAssociatedObject(btn, "bt_profile");
    if (!p) return;
    [WolFoxProStore shared].activeBleProfileID = p.profileID;
    [[WolFoxProStore shared] saveSettings];
    [self showToast:[NSString stringWithFormat:@"✅ تم تفعيل: %@", p.name]];
    [self switchPage:2];
}

- (void)deleteBleProfile:(UIButton *)btn {
    WolFoxBleProfile *p = objc_getAssociatedObject(btn, "bt_profile");
    if (!p) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"حذف جهاز البلوتوث؟" message:@"سيتم حذف الملف المحفوظ ولن يمكن التراجع عن العملية." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"حذف" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[WolFoxProStore shared] deleteBleProfileID:p.profileID];
        [self showToast:@"✅ تم حذف جهاز البلوتوث"];
        [self switchPage:2];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - GPS Page (Royal Keyboard Style)

- (void)setupGPSPage {
    CGFloat w = _scrollDashboard.bounds.size.width;
    
    // Map Card
    UIView *mapCard = [[UIView alloc] initWithFrame:CGRectMake(15, 10, w - 30, 280)];
    _mapCard = mapCard;
    mapCard.backgroundColor = [WolFoxProTheme surfacePrimary];
    mapCard.layer.cornerRadius = 20; mapCard.clipsToBounds = YES;
    [_scrollDashboard addSubview:mapCard];
    
    self.mapView = [[MKMapView alloc] initWithFrame:mapCard.bounds];
    self.mapView.delegate = self;
    self.mapView.mapType = (MKMapType)[WolFoxProStore shared].mapStyle;
    [mapCard addSubview:self.mapView];
    
    // يظهر الموقع الحقيقي أولاً، ولا تظهر دبوس الإحداثيات الوهمية قبل تفعيل التزييف.
    CLLocation *real = [WolFoxProHookManager shared].lastRealLocation;
    if (real && ![WolFoxProStore shared].spoofActive) {
        self.realLocPin = [MKPointAnnotation new];
        self.realLocPin.coordinate = real.coordinate;
        self.realLocPin.title = @"REAL_LOC";
        [self.mapView addAnnotation:self.realLocPin];
    }
    
    // Search Bar
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(10, 10, mapCard.bounds.size.width - 20, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"إحداثيات أو عنوان / اسم مكان";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.barTintColor = [UIColor clearColor];
    self.searchBar.keyboardAppearance = UIKeyboardAppearanceDark;
    self.searchBar.returnKeyType = UIReturnKeySearch;
    self.searchBar.accessibilityLabel = @"البحث بالإحداثيات أو العنوان";
    if (@available(iOS 13.0, *)) {
        UITextField *searchField = self.searchBar.searchTextField;
        searchField.backgroundColor = [[WolFoxProTheme surfaceSecondary] colorWithAlphaComponent:0.92];
        searchField.textColor = [WolFoxProTheme textPrimary];
        searchField.tintColor = [WolFoxProTheme accent];
        searchField.layer.cornerRadius = 12;
        searchField.clipsToBounds = YES;
    }
    [mapCard addSubview:self.searchBar];
    
    // Style Toggle Button
    UIButton *styleBtn = [self mapCircleBtn:@"map.fill" x:10 y:mapCard.bounds.size.height - 54];
    styleBtn.accessibilityLabel = @"تغيير نمط الخريطة";
    [styleBtn addTarget:self action:@selector(toggleMapStyle) forControlEvents:UIControlEventTouchUpInside];
    [mapCard addSubview:styleBtn];
    
    // Real Location Button
    UIButton *realLocBtn = [self mapCircleBtn:@"person.fill" x:62 y:mapCard.bounds.size.height - 54];
    realLocBtn.accessibilityLabel = @"عرض الموقع الحقيقي";
    [realLocBtn addTarget:self action:@selector(showRealLocation) forControlEvents:UIControlEventTouchUpInside];
    [mapCard addSubview:realLocBtn];

    // Expand Map Button
    UIButton *expandBtn = [self mapCircleBtn:@"arrow.up.left.and.arrow.down.right" x:114 y:mapCard.bounds.size.height - 54];
    expandBtn.accessibilityLabel = @"توسيع الخريطة إلى ملء الشاشة";
    [expandBtn addTarget:self action:@selector(expandMap) forControlEvents:UIControlEventTouchUpInside];
    [mapCard addSubview:expandBtn];

    // Open the selected point in Apple Maps or Google Maps without embedding
    // a provider API key in the tweak.
    UIButton *externalMapsBtn = [self mapCircleBtn:@"arrow.triangle.turn.up.right.diamond.fill" x:mapCard.bounds.size.width - 106 y:mapCard.bounds.size.height - 54];
    externalMapsBtn.accessibilityLabel = @"فتح الموقع في خرائط Apple أو Google";
    [externalMapsBtn addTarget:self action:@selector(openSelectedLocationInMaps:) forControlEvents:UIControlEventTouchUpInside];
    [mapCard addSubview:externalMapsBtn];
    
    // Locate Me Button (Fake Pin)
    UIButton *locateBtn = [self mapCircleBtn:@"location.fill" x:mapCard.bounds.size.width - 54 y:mapCard.bounds.size.height - 54];
    locateBtn.accessibilityLabel = @"التمركز على الموقع الوهمي";
    [locateBtn addTarget:self action:@selector(centerMapOnPin) forControlEvents:UIControlEventTouchUpInside];
    [mapCard addSubview:locateBtn];
    
    // Remove any existing long press recognizers to prevent accumulation on tab switch
    for (UIGestureRecognizer *gr in [self.mapView.gestureRecognizers copy]) {
        if ([gr isKindOfClass:[UILongPressGestureRecognizer class]]) {
            [self.mapView removeGestureRecognizer:gr];
        }
    }
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.mapView addGestureRecognizer:lp];
    if ([WolFoxProStore shared].spoofActive) [self updateMapPin:[WolFoxProStore shared].currentFakeCoords];
    else [self showRealLocation];
    
    // Keyboard Input Area
    UIView *kbCard = [[UIView alloc] initWithFrame:CGRectMake(15, 305, w - 30, 210)];
    kbCard.backgroundColor = [WolFoxProTheme surfacePrimary]; kbCard.layer.cornerRadius = 20;
    [_scrollDashboard addSubview:kbCard];
    
    CGFloat iw = (kbCard.bounds.size.width - 60) / 2.0;
    _latInput = [self royalInput:@"24.713600" frame:CGRectMake(15, 15, iw, 45)];
    [kbCard addSubview:_latInput];
    _lonInput = [self royalInput:@"46.675300" frame:CGRectMake(iw + 25, 15, iw - 45, 45)];
    [kbCard addSubview:_lonInput];
    
    // Paste Button
    UIButton *pasteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    pasteBtn.frame = CGRectMake(kbCard.bounds.size.width - 54, 15, 44, 45);
    pasteBtn.backgroundColor = [[WolFoxProTheme accent] colorWithAlphaComponent:0.1];
    pasteBtn.layer.cornerRadius = 10;
    if (@available(iOS 13.0, *)) [pasteBtn setImage:[UIImage systemImageNamed:@"doc.on.clipboard.fill"] forState:UIControlStateNormal];
    pasteBtn.tintColor = [WolFoxProTheme accent];
    [pasteBtn addTarget:self action:@selector(pasteCoordinates) forControlEvents:UIControlEventTouchUpInside];
    pasteBtn.accessibilityLabel = @"لصق الإحداثيات من الحافظة";
    [kbCard addSubview:pasteBtn];
    
    // Activate / Apply Button
    UIButton *applyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    applyBtn.frame = CGRectMake(15, 75, kbCard.bounds.size.width - 30, 44);
    applyBtn.backgroundColor = [WolFoxProTheme accent]; applyBtn.layer.cornerRadius = 12;
    [applyBtn setTitle:@"تفعيل الإحداثيات الآن ⚡" forState:UIControlStateNormal]; [applyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    applyBtn.titleLabel.font = [WolFoxProTheme fontOfSize:15 weight:UIFontWeightBlack];
    [applyBtn addTarget:self action:@selector(applyManualCoords) forControlEvents:UIControlEventTouchUpInside];
    applyBtn.accessibilityLabel = @"تطبيق الإحداثيات وتشغيل الموقع الوهمي";
    [kbCard addSubview:applyBtn];

    // GPS input and activation live in one card to reduce visual fragmentation.
    [kbCard addSubview:[self royalSwitchInside:kbCard t:@"تفعيل الموقع الوهمي" i:@"location.fill" isOn:[WolFoxProStore shared].spoofActive y:130 action:^(UISwitch *s){
        if (s.on) {
            [WolFoxProStore shared].spoofActive = YES;
            [[WolFoxProStore shared] saveSettings];
            [[WolFoxProHookManager shared] deliverFakeUpdate];
            [self refreshSpoofHeaderStatus];
            [self showToast:@"✅ تم تشغيل تزييف الموقع وسيستمر حتى إيقافه"];
        } else {
            [self confirmDisableSpoofForSwitch:s];
        }
    }]];

    CGFloat cy = 530;

    UIView *routeCard = [[UIView alloc] initWithFrame:CGRectMake(15, cy, w - 30, 166)];
    routeCard.backgroundColor = [WolFoxProTheme surfacePrimary];
    routeCard.layer.cornerRadius = 18;
    [_scrollDashboard addSubview:routeCard];

    UILabel *speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, routeCard.bounds.size.width - 36, 24)];
    speedLabel.text = [NSString stringWithFormat:@"السرعة: %.0f كم/س", [WolFoxProStore shared].simSpeed];
    speedLabel.textColor = [WolFoxProTheme textPrimary];
    speedLabel.textAlignment = NSTextAlignmentRight;
    speedLabel.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold];
    [routeCard addSubview:speedLabel];
    objc_setAssociatedObject(self, "_speed_label", speedLabel, OBJC_ASSOCIATION_ASSIGN);

    UISlider *speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(18, 38, routeCard.bounds.size.width - 36, 30)];
    speedSlider.minimumValue = 1;
    speedSlider.maximumValue = 120;
    speedSlider.value = MAX(1, [WolFoxProStore shared].simSpeed);
    speedSlider.minimumTrackTintColor = [WolFoxProTheme accent];
    [speedSlider addTarget:self action:@selector(speedChanged:) forControlEvents:UIControlEventValueChanged];
    [routeCard addSubview:speedSlider];

    UILabel *jitterLabel = [[UILabel alloc] initWithFrame:CGRectMake(80, 70, routeCard.bounds.size.width - 98, 32)];
    jitterLabel.text = @"حركة طبيعية بسيطة";
    jitterLabel.textColor = [WolFoxProTheme textSecondary];
    jitterLabel.textAlignment = NSTextAlignmentRight;
    jitterLabel.font = [WolFoxProTheme fontOfSize:13 weight:UIFontWeightSemibold];
    [routeCard addSubview:jitterLabel];
    UISwitch *jitterSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(18, 70, 50, 30)];
    jitterSwitch.on = [WolFoxProStore shared].jitterActive;
    jitterSwitch.onTintColor = [WolFoxProTheme accent];
    [jitterSwitch addTarget:self action:@selector(jitterChanged:) forControlEvents:UIControlEventValueChanged];
    [routeCard addSubview:jitterSwitch];

    UIButton *routeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    routeButton.frame = CGRectMake(18, 108, routeCard.bounds.size.width - 36, 44);
    routeButton.backgroundColor = [WolFoxProStore shared].routeActive ? [WolFoxProTheme danger] : [WolFoxProTheme accent];
    routeButton.layer.cornerRadius = 12;
    [routeButton setTitle:[WolFoxProStore shared].routeActive ? @"إيقاف المحاكاة 🛑" : @"بدء محاكاة المسار 🚶‍♂️" forState:UIControlStateNormal];
    [routeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    routeButton.titleLabel.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBlack];
    [routeButton addTarget:self action:@selector(toggleRouteSimulation) forControlEvents:UIControlEventTouchUpInside];
    routeButton.accessibilityLabel = [WolFoxProStore shared].routeActive ? @"إيقاف محاكاة المسار" : @"بدء محاكاة المسار";
    [routeCard addSubview:routeButton];
    objc_setAssociatedObject(self, "_route_btn", routeButton, OBJC_ASSOCIATION_ASSIGN);
    cy += 181;

    NSArray *savedLocations = [WolFoxProStore shared].locations;
    BOOL favoritesEmpty = savedLocations.count == 0;
    CGFloat favoritesHeight = favoritesEmpty ? 184.0 : 126.0;
    UIView *favoritesCard = [[UIView alloc] initWithFrame:CGRectMake(15, cy, w - 30, favoritesHeight)];
    favoritesCard.backgroundColor = [WolFoxProTheme surfacePrimary];
    favoritesCard.layer.cornerRadius = 18;
    [_scrollDashboard addSubview:favoritesCard];

    UILabel *favoritesTitle = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, favoritesCard.bounds.size.width - 36, 24)];
    favoritesTitle.text = @"المفضلة";
    favoritesTitle.textAlignment = NSTextAlignmentRight;
    favoritesTitle.textColor = [WolFoxProTheme textPrimary];
    favoritesTitle.font = [WolFoxProTheme fontOfSize:16 weight:UIFontWeightBold];
    [favoritesCard addSubview:favoritesTitle];

    UILabel *favoritesCount = [[UILabel alloc] initWithFrame:CGRectMake(18, 16, 150, 22)];
    favoritesCount.text = favoritesEmpty ? @"لا توجد مواقع" : [NSString stringWithFormat:@"%lu مواقع محفوظة", (unsigned long)savedLocations.count];
    favoritesCount.textAlignment = NSTextAlignmentLeft;
    favoritesCount.textColor = [WolFoxProTheme accent];
    favoritesCount.font = [WolFoxProTheme fontOfSize:12 weight:UIFontWeightBold];
    [favoritesCard addSubview:favoritesCount];

    CGFloat actionW = (favoritesCard.bounds.size.width - 48) / 2.0;
    CGFloat favoritesActionsY = favoritesEmpty ? 116.0 : 54.0;
    if (favoritesEmpty) {
        UIImageView *emptyIcon = [[UIImageView alloc] initWithFrame:CGRectMake((favoritesCard.bounds.size.width - 34) / 2.0, 48, 34, 34)];
        if (@available(iOS 13.0, *)) emptyIcon.image = [UIImage systemImageNamed:@"star.slash"];
        emptyIcon.tintColor = [WolFoxProTheme textSecondary];
        emptyIcon.contentMode = UIViewContentModeScaleAspectFit;
        emptyIcon.isAccessibilityElement = NO;
        [favoritesCard addSubview:emptyIcon];
        UILabel *emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 84, favoritesCard.bounds.size.width - 40, 22)];
        emptyLabel.text = @"احفظ موقعك الأول للوصول إليه سريعاً";
        emptyLabel.textColor = [WolFoxProTheme textSecondary];
        emptyLabel.font = [WolFoxProTheme fontOfSize:12 weight:UIFontWeightSemibold];
        emptyLabel.textAlignment = NSTextAlignmentCenter;
        [favoritesCard addSubview:emptyLabel];
    }
    UIButton *saveFav = [UIButton buttonWithType:UIButtonTypeSystem];
    saveFav.frame = favoritesEmpty ? CGRectMake(16, favoritesActionsY, favoritesCard.bounds.size.width - 32, 52) : CGRectMake(16, favoritesActionsY, actionW, 52);
    saveFav.backgroundColor = [WolFoxProTheme accentSoft];
    saveFav.layer.cornerRadius = 13;
    [saveFav setTitle:@"حفظ الموقع" forState:UIControlStateNormal];
    [saveFav setTitleColor:[WolFoxProTheme accent] forState:UIControlStateNormal];
    saveFav.titleLabel.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold];
    if (@available(iOS 13.0, *)) [saveFav setImage:[UIImage systemImageNamed:@"star.fill"] forState:UIControlStateNormal];
    saveFav.tintColor = [WolFoxProTheme accent];
    [saveFav addTarget:self action:@selector(saveCurrentLocation) forControlEvents:UIControlEventTouchUpInside];
    saveFav.accessibilityLabel = @"حفظ الموقع الحالي في المفضلة";
    [favoritesCard addSubview:saveFav];

    if (!favoritesEmpty) {
        UIButton *showFav = [UIButton buttonWithType:UIButtonTypeSystem];
        showFav.frame = CGRectMake(32 + actionW, favoritesActionsY, actionW, 52);
        showFav.backgroundColor = [WolFoxProTheme accentSoft];
        showFav.layer.cornerRadius = 13;
        [showFav setTitle:@"عرض المفضلة" forState:UIControlStateNormal];
        [showFav setTitleColor:[WolFoxProTheme accent] forState:UIControlStateNormal];
        showFav.titleLabel.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold];
        if (@available(iOS 13.0, *)) [showFav setImage:[UIImage systemImageNamed:@"list.bullet"] forState:UIControlStateNormal];
        showFav.tintColor = [WolFoxProTheme accent];
        [showFav addTarget:self action:@selector(showSavedLocations) forControlEvents:UIControlEventTouchUpInside];
        showFav.accessibilityLabel = @"عرض المواقع المحفوظة";
        [favoritesCard addSubview:showFav];
    }

    _scrollDashboard.contentSize = CGSizeMake(w, cy + favoritesHeight + 30);
}

- (void)jitterChanged:(UISwitch *)sender {
    [WolFoxProStore shared].jitterActive = sender.on;
    [[WolFoxProStore shared] saveSettings];
}

- (UIButton *)mapCircleBtn:(NSString *)icon x:(CGFloat)x y:(CGFloat)y {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(x, y, 44, 44);
    b.backgroundColor = [[WolFoxProTheme surfacePrimary] colorWithAlphaComponent:0.8];
    b.layer.cornerRadius = 22;
    if (@available(iOS 13.0, *)) [b setImage:[UIImage systemImageNamed:icon] forState:UIControlStateNormal];
    b.tintColor = [WolFoxProTheme accent]; return b;
}

- (void)expandMap {
    if (_mapExpanded || !self.mapView || !_mapCard) return;
    [self.searchBar resignFirstResponder];
    _mapExpanded = YES;

    UIView *container = [[UIView alloc] initWithFrame:self.view.bounds];
    container.backgroundColor = [WolFoxProTheme surfacePrimary];
    container.accessibilityViewIsModal = YES;
    _expandedMapContainer = container;

    [self.mapView removeFromSuperview];
    self.mapView.frame = container.bounds;
    self.mapView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:self.mapView];

    [self.searchBar removeFromSuperview];
    self.searchBar.tag = 6201;
    [container addSubview:self.searchBar];

    UIButton *closeButton = [self mapCircleBtn:@"xmark" x:0 y:0];
    closeButton.tag = 6202;
    closeButton.backgroundColor = [[WolFoxProTheme danger] colorWithAlphaComponent:0.94];
    closeButton.tintColor = [UIColor whiteColor];
    closeButton.accessibilityLabel = @"إغلاق الخريطة الموسعة";
    [closeButton addTarget:self action:@selector(closeExpandedMap) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:closeButton];
    _expandedMapCloseButton = closeButton;

    UIButton *styleButton = [self mapCircleBtn:@"map.fill" x:0 y:0];
    styleButton.tag = 6203;
    styleButton.accessibilityLabel = @"تغيير نمط الخريطة";
    [styleButton addTarget:self action:@selector(toggleMapStyle) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:styleButton];

    UIButton *realButton = [self mapCircleBtn:@"person.fill" x:0 y:0];
    realButton.tag = 6204;
    realButton.accessibilityLabel = @"عرض الموقع الحقيقي";
    [realButton addTarget:self action:@selector(showRealLocation) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:realButton];

    UIButton *pinButton = [self mapCircleBtn:@"location.fill" x:0 y:0];
    pinButton.tag = 6205;
    pinButton.accessibilityLabel = @"التمركز على الموقع المحدد";
    [pinButton addTarget:self action:@selector(centerMapOnPin) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:pinButton];

    UIButton *externalMapsButton = [self mapCircleBtn:@"arrow.triangle.turn.up.right.diamond.fill" x:0 y:0];
    externalMapsButton.tag = 6206;
    externalMapsButton.accessibilityLabel = @"فتح الموقع في خرائط Apple أو Google";
    [externalMapsButton addTarget:self action:@selector(openSelectedLocationInMaps:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:externalMapsButton];

    [self.view addSubview:container];
    [self layoutExpandedMap];
    container.alpha = 0;
    container.transform = CGAffineTransformMakeScale(0.985, 0.985);
    [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{
        container.alpha = 1;
        container.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL finished) {
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.searchBar);
    }];
}

- (void)layoutExpandedMap {
    if (!_mapExpanded || !_expandedMapContainer) return;
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat safeTop = MAX(self.view.safeAreaInsets.top, 12.0);
    CGFloat safeBottom = MAX(self.view.safeAreaInsets.bottom, 12.0);
    _expandedMapContainer.frame = self.view.bounds;
    self.mapView.frame = _expandedMapContainer.bounds;
    self.searchBar.frame = CGRectMake(10, safeTop + 4, MAX(120, width - 78), 48);
    _expandedMapCloseButton.frame = CGRectMake(width - 56, safeTop + 6, 44, 44);
    CGFloat controlsY = height - safeBottom - 50;
    [_expandedMapContainer viewWithTag:6203].frame = CGRectMake(12, controlsY, 44, 44);
    [_expandedMapContainer viewWithTag:6204].frame = CGRectMake(64, controlsY, 44, 44);
    [_expandedMapContainer viewWithTag:6206].frame = CGRectMake(width - 108, controlsY, 44, 44);
    [_expandedMapContainer viewWithTag:6205].frame = CGRectMake(width - 56, controlsY, 44, 44);
}

- (void)closeExpandedMap {
    [self closeExpandedMapIfNeeded];
}

- (void)closeExpandedMapIfNeeded {
    if (!_mapExpanded) return;
    [self.searchBar resignFirstResponder];
    _mapExpanded = NO;

    [self.mapView removeFromSuperview];
    [self.searchBar removeFromSuperview];
    if (_mapCard) {
        self.mapView.autoresizingMask = UIViewAutoresizingNone;
        self.mapView.frame = _mapCard.bounds;
        [_mapCard insertSubview:self.mapView atIndex:0];
        self.searchBar.tag = 0;
        self.searchBar.frame = CGRectMake(10, 10, _mapCard.bounds.size.width - 20, 44);
        [_mapCard addSubview:self.searchBar];
    }
    [_expandedMapContainer removeFromSuperview];
    _expandedMapContainer = nil;
    _expandedMapCloseButton = nil;
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _mapCard);
}

- (void)toggleMapStyle {
    NSInteger s = ([WolFoxProStore shared].mapStyle + 1) % 3;
    [WolFoxProStore shared].mapStyle = s;
    [[WolFoxProStore shared] saveSettings];
    self.mapView.mapType = (MKMapType)s;
    [self showToast:s == 0 ? @"نمط عادي" : (s == 1 ? @"نمط قمر صناعي" : @"نمط هجين")];
}

- (void)speedChanged:(UISlider *)s {
    [WolFoxProStore shared].simSpeed = s.value;
    [[WolFoxProStore shared] saveSettings];
    UILabel *l = objc_getAssociatedObject(self, "_speed_label");
    if (l) l.text = [NSString stringWithFormat:@"السرعة: %.0f كم/س", s.value];
}

- (void)toggleRouteSimulation {
    if (![WFLicenseClient isRuntimeLicenseValid]) {
        [self showToast:@"يلزم تحقق اشتراك صالح قبل تشغيل المسار"];
        return;
    }
    if ([WolFoxProStore shared].routeActive) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"إيقاف محاكاة المسار؟" message:@"سيتوقف التحرك الآلي عند الموقع الحالي بعد التأكيد." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"متابعة المسار" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"إيقاف الآن" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [[WolFoxProHookManager shared] stopRoute];
            UIButton *b = objc_getAssociatedObject(self, "_route_btn");
            [b setTitle:@"بدء محاكاة المسار 🚶‍♂️" forState:UIControlStateNormal];
            b.backgroundColor = [WolFoxProTheme accent];
            b.accessibilityLabel = @"بدء محاكاة المسار";
            [self showToast:@"⚠️ توقفت محاكاة المسار"];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [WolFoxProStore shared].spoofActive = YES;
        [[WolFoxProStore shared] saveSettings];
        // Build a simple straight-line route: current fake → target (5 intermediate steps)
        CLLocationCoordinate2D from = [WolFoxProStore shared].currentFakeCoords;
        CLLocationCoordinate2D to   = [WolFoxProStore shared].targetRouteCoords;
        // If no target set, use Riyadh as demo target
        if (to.latitude == 0 && to.longitude == 0) {
            to = CLLocationCoordinate2DMake(24.7000, 46.7000);
            [WolFoxProStore shared].targetRouteCoords = to;
        }
        NSMutableArray *waypoints = [NSMutableArray new];
        for (int i = 0; i <= 10; i++) {
            double lat = from.latitude  + (to.latitude  - from.latitude)  * (i / 10.0);
            double lon = from.longitude + (to.longitude - from.longitude) * (i / 10.0);
            [waypoints addObject:[[CLLocation alloc] initWithLatitude:lat longitude:lon]];
        }
        [[WolFoxProHookManager shared] startRouteWithWaypoints:waypoints speedKmh:[WolFoxProStore shared].simSpeed];
        UIButton *b = objc_getAssociatedObject(self, "_route_btn");
        [b setTitle:@"إيقاف المحاكاة 🛑" forState:UIControlStateNormal];
        b.backgroundColor = [WolFoxProTheme danger];
        b.accessibilityLabel = @"إيقاف محاكاة المسار";
        [self refreshSpoofHeaderStatus];
        [self showToast:@"🚶‍♂️ بدأت المحاكاة"];
    }
}

- (void)routeFinished {
    UIButton *b = objc_getAssociatedObject(self, "_route_btn");
    [b setTitle:@"بدء محاكاة المسار 🚶‍♂️" forState:UIControlStateNormal];
    b.backgroundColor = [WolFoxProTheme accent];
    b.accessibilityLabel = @"بدء محاكاة المسار";
    [self showToast:@"✅ اكتملت المحاكاة"];
}

- (NSString *)normalizedMapSearchText:(NSString *)text {
    NSString *result = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray<NSString *> *from = @[@"٠",@"١",@"٢",@"٣",@"٤",@"٥",@"٦",@"٧",@"٨",@"٩",@"۰",@"۱",@"۲",@"۳",@"۴",@"۵",@"۶",@"۷",@"۸",@"۹",@"٫",@"،",@"−"];
    NSArray<NSString *> *to   = @[@"0",@"1",@"2",@"3",@"4",@"5",@"6",@"7",@"8",@"9",@"0",@"1",@"2",@"3",@"4",@"5",@"6",@"7",@"8",@"9",@".",@",",@"-"];
    for (NSUInteger index = 0; index < from.count; index++) {
        result = [result stringByReplacingOccurrencesOfString:from[index] withString:to[index]];
    }
    return result;
}

- (BOOL)parseCoordinateSearchText:(NSString *)text coordinate:(CLLocationCoordinate2D *)coordinate {
    NSString *normalized = [self normalizedMapSearchText:text];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@",; \t\r\n"];
    NSArray<NSString *> *rawParts = [normalized componentsSeparatedByCharactersInSet:separators];
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *part in rawParts) {
        NSString *clean = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (clean.length) [parts addObject:clean];
    }
    if (parts.count != 2) return NO;

    double values[2] = {0, 0};
    for (NSUInteger index = 0; index < 2; index++) {
        NSScanner *scanner = [NSScanner scannerWithString:parts[index]];
        scanner.locale = @{NSLocaleDecimalSeparator: @"."};
        if (![scanner scanDouble:&values[index]] || !scanner.isAtEnd || !isfinite(values[index])) return NO;
    }
    CLLocationCoordinate2D parsed = CLLocationCoordinate2DMake(values[0], values[1]);
    if (!CLLocationCoordinate2DIsValid(parsed)) return NO;
    if (coordinate) *coordinate = parsed;
    return YES;
}

- (void)selectMapSearchCoordinate:(CLLocationCoordinate2D)coordinate title:(NSString *)title toast:(NSString *)toast {
    if (!CLLocationCoordinate2DIsValid(coordinate)) {
        [self showToast:@"الإحداثيات خارج النطاق المسموح ❌"];
        return;
    }
    [WolFoxProStore shared].currentFakeCoords = coordinate;
    [[WolFoxProStore shared] saveSettings];
    [self updateMapPin:coordinate];
    _currentPin.title = title.length ? title : @"الموقع المحدد";
    if (_latInput) _latInput.text = [NSString stringWithFormat:@"%.6f", coordinate.latitude];
    if (_lonInput) _lonInput.text = [NSString stringWithFormat:@"%.6f", coordinate.longitude];
    [[WolFoxProHookManager shared] deliverFakeUpdate];
    [self showToast:toast];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *query = [[self normalizedMapSearchText:searchBar.text ?: @""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) {
        [self showToast:@"أدخل إحداثيات أو عنواناً للبحث"];
        return;
    }

    CLLocationCoordinate2D coordinate;
    if ([self parseCoordinateSearchText:query coordinate:&coordinate]) {
        searchBar.text = [NSString stringWithFormat:@"%.6f, %.6f", coordinate.latitude, coordinate.longitude];
        [self selectMapSearchCoordinate:coordinate title:@"إحداثيات محددة" toast:@"تم تحديد الإحداثيات على الخريطة ✅"];
        return;
    }

    [_activeMapSearch cancel];
    MKLocalSearchRequest *request = [MKLocalSearchRequest new];
    request.naturalLanguageQuery = query;
    if (self.mapView) request.region = self.mapView.region;
    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
    _activeMapSearch = search;
    __weak typeof(self) weakSelf = self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self->_activeMapSearch != search) return;
            self->_activeMapSearch = nil;
            MKMapItem *item = response.mapItems.firstObject;
            CLLocation *location = item.placemark.location;
            if (!location || error) {
                [self showToast:@"لم يتم العثور على العنوان أو المكان ❌"];
                return;
            }
            NSString *title = item.name.length ? item.name : query;
            searchBar.text = title;
            [self selectMapSearchCoordinate:location.coordinate title:title toast:@"تم العثور على المكان وتحديده ✅"];
        });
    }];
}

- (UITextField *)royalInput:(NSString *)p frame:(CGRect)f {
    UITextField *tf = [[UITextField alloc] initWithFrame:f];
    tf.backgroundColor = [WolFoxProTheme surfaceSecondary];
    tf.layer.cornerRadius = 10;
    tf.textColor = [WolFoxProTheme textPrimary];
    tf.textAlignment = NSTextAlignmentCenter;
    tf.font = [WolFoxProTheme fontOfSize:13 weight:UIFontWeightBold];
    tf.placeholder = p;
    tf.layer.borderWidth = 1.0;
    tf.layer.borderColor = [[WolFoxProTheme accent] colorWithAlphaComponent:0.32].CGColor;
    tf.tintColor = [WolFoxProTheme accent];
    tf.delegate = self;
    return tf;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    textField.layer.borderWidth = 1.5;
    textField.layer.borderColor = [WolFoxProTheme accent].CGColor;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    textField.layer.borderWidth = 1.0;
    textField.layer.borderColor = [[WolFoxProTheme accent] colorWithAlphaComponent:0.32].CGColor;
}

- (UIView *)royalSwitch:(NSString *)t icon:(NSString *)i isOn:(BOOL)on y:(CGFloat)y action:(void(^)(UISwitch *))block {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(15, y, _scrollDashboard.bounds.size.width - 30, 65)];
    v.backgroundColor = [WolFoxProTheme surfacePrimary]; v.layer.cornerRadius = 15;
    
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(v.bounds.size.width - 45, 17, 30, 30)];
    if (@available(iOS 13.0, *)) iv.image = [UIImage systemImageNamed:i];
    iv.tintColor = [WolFoxProTheme accent]; iv.contentMode = UIViewContentModeScaleAspectFit;
    [v addSubview:iv];
    
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(80, 0, v.bounds.size.width - 135, 65)];
    l.text = t; l.textColor = [WolFoxProTheme textPrimary]; l.font = [WolFoxProTheme fontOfSize:15 weight:UIFontWeightBold]; l.textAlignment = NSTextAlignmentRight;
    [v addSubview:l];
    
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(15, 17, 50, 30)];
    sw.on = on; sw.onTintColor = [WolFoxProTheme accent];
    sw.accessibilityLabel = t;
    [sw addTarget:objc_getAssociatedObject(self, "_sw_proxy") ?: self action:@selector(handleSwitch:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(sw, "_sw_block", block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [v addSubview:sw];
    return v;
}

- (void)handleSwitch:(UISwitch *)s {
    void(^block)(UISwitch *) = objc_getAssociatedObject(s, "_sw_block");
    if (block) block(s);
}

- (UIButton *)royalBtn:(NSString *)t icon:(NSString *)i color:(UIColor *)c y:(CGFloat)y {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(15, y, _scrollDashboard.bounds.size.width - 30, 55);
    BOOL dangerous = CGColorEqualToColor(c.CGColor, [WolFoxProTheme danger].CGColor);
    b.backgroundColor = dangerous ? [WolFoxProTheme danger] : [WolFoxProTheme surfacePrimary]; b.layer.cornerRadius = 15;
    [b setTitle:t forState:UIControlStateNormal]; [b setTitleColor:dangerous ? UIColor.whiteColor : [WolFoxProTheme textPrimary] forState:UIControlStateNormal];
    b.titleLabel.font = [WolFoxProTheme fontOfSize:15 weight:UIFontWeightBold];
    if (@available(iOS 13.0, *)) [b setImage:[UIImage systemImageNamed:i] forState:UIControlStateNormal];
    b.tintColor = dangerous ? UIColor.whiteColor : c; b.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 15);
    return b;
}

#pragma mark - ID & Camera Pages (Stubs for linking)

- (void)setupIDPage {
    CGFloat w = _scrollDashboard.bounds.size.width;
    UIView *idCard = [[UIView alloc] initWithFrame:CGRectMake(15, 10, w - 30, 380)];
    idCard.backgroundColor = [WolFoxProTheme surfacePrimary]; idCard.layer.cornerRadius = 20;
    [_scrollDashboard addSubview:idCard];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 15, idCard.bounds.size.width, 30)];
    title.text = @"الهوية الموحدة • IDFA • IDFV • Web"; title.textColor = [WolFoxProTheme textPrimary]; title.textAlignment = NSTextAlignmentCenter; title.font = [WolFoxProTheme fontOfSize:16 weight:UIFontWeightBold];
    [idCard addSubview:title];
    
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(15, 60, idCard.bounds.size.width - 30, 50)];
    tf.backgroundColor = [WolFoxProTheme surfaceSecondary]; tf.layer.cornerRadius = 12; tf.textColor = [WolFoxProTheme textPrimary]; tf.textAlignment = NSTextAlignmentCenter;
    tf.layer.borderWidth = 1.0; tf.layer.borderColor = [[WolFoxProTheme accent] colorWithAlphaComponent:0.32].CGColor; tf.tintColor = [WolFoxProTheme accent]; tf.delegate = self;
    tf.text = [WolFoxProStore shared].activeIdentifierUUID ?: [WFLicenseClient deviceIdentifier];
    tf.font = [WolFoxProTheme fontOfSize:11 weight:UIFontWeightBold];
    objc_setAssociatedObject(self, "_id_tf_page", tf, OBJC_ASSOCIATION_ASSIGN);
    [idCard addSubview:tf];
    
    UIButton *sav = [self royalBtnInside:idCard t:@"حفظ وتفعيل" i:@"checkmark" c:[WolFoxProTheme success] y:120];
    [sav addTarget:self action:@selector(saveIDProPage) forControlEvents:UIControlEventTouchUpInside];
    
    UIButton *imp = [self royalBtnInside:idCard t:@"استيراد" i:@"arrow.down" c:[WolFoxProTheme accent] y:185];
    [imp addTarget:self action:@selector(importIDProPage) forControlEvents:UIControlEventTouchUpInside];
    
    UIButton *exp = [self royalBtnInside:idCard t:@"تصدير" i:@"arrow.up" c:[WolFoxProTheme accent] y:250];
    [exp addTarget:self action:@selector(exportIDProPage) forControlEvents:UIControlEventTouchUpInside];
    
    UIButton *res = [self royalBtnInside:idCard t:@"إعادة تعيين للأصلي" i:@"arrow.clockwise" c:[WolFoxProTheme danger] y:315];
    [res addTarget:self action:@selector(resetIDProPage) forControlEvents:UIControlEventTouchUpInside];
    
    _scrollDashboard.contentSize = CGSizeMake(w, 450);
}

- (UIButton *)royalBtnInside:(UIView *)p t:(NSString *)t i:(NSString *)i c:(UIColor *)c y:(CGFloat)y {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(15, y, p.bounds.size.width - 30, 50);
    BOOL dangerous = CGColorEqualToColor(c.CGColor, [WolFoxProTheme danger].CGColor);
    b.backgroundColor = dangerous ? [WolFoxProTheme danger] : [c colorWithAlphaComponent:0.12]; b.layer.cornerRadius = 12;
    [b setTitle:t forState:UIControlStateNormal]; [b setTitleColor:dangerous ? UIColor.whiteColor : c forState:UIControlStateNormal];
    b.titleLabel.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold];
    if (@available(iOS 13.0, *)) [b setImage:[UIImage systemImageNamed:i] forState:UIControlStateNormal];
    b.tintColor = dangerous ? UIColor.whiteColor : c; b.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 10);
    [p addSubview:b]; return b;
}

- (void)saveIDProPage {
    UITextField *tf = objc_getAssociatedObject(self, "_id_tf_page");
    if ([[WolFoxProStore shared] activateIdentifierString:tf.text ?: @""]) {
        tf.text = [WolFoxProStore shared].activeIdentifierUUID;
        [self refreshSpoofHeaderStatus];
        [self showToast:@"تم توحيد وتفعيل IDFA وIDFV ومعرف Web ✅"];
    } else {
        [self showToast:@"صيغة UUID غير صحيحة ❌"];
    }
}

- (void)importIDProPage {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    if (pb.string.length > 0) {
        UITextField *tf = objc_getAssociatedObject(self, "_id_tf_page");
        tf.text = pb.string; [self showToast:@"تم الاستيراد من الحافظة 📋"];
    }
}

- (void)exportIDProPage {
    UITextField *tf = objc_getAssociatedObject(self, "_id_tf_page");
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = tf.text; [self showToast:@"تم النسخ للحافظة 📤"];
}

- (void)resetIDProPage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"إعادة المعرّف الأصلي؟" message:@"سيتم إيقاف المعرّف المخصص والعودة إلى معرّف الجهاز الأصلي." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إعادة الآن" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSString *orig = [WFLicenseClient deviceIdentifier];
        UITextField *tf = objc_getAssociatedObject(self, "_id_tf_page");
        tf.text = orig; [[WolFoxProStore shared] deactivateIdentifier]; [self refreshSpoofHeaderStatus];
        [self showToast:@"✅ تمت العودة للمعرف الأصلي"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setupCameraPage {
    CGFloat w = _scrollDashboard.bounds.size.width;
    
    // Control Card
    UIView *camCard = [[UIView alloc] initWithFrame:CGRectMake(15, 10, w - 30, 150)];
    camCard.backgroundColor = [WolFoxProTheme surfacePrimary]; camCard.layer.cornerRadius = 20;
    [_scrollDashboard addSubview:camCard];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 15, camCard.bounds.size.width, 30)];
    title.text = @"تزييف الكاميرا"; title.textColor = [WolFoxProTheme textPrimary]; title.textAlignment = NSTextAlignmentCenter; title.font = [WolFoxProTheme fontOfSize:18 weight:UIFontWeightBold];
    [camCard addSubview:title];
    
    BOOL isCamOn = [WolFoxProStore shared].mediaUploadActive;
    [camCard addSubview:[self royalSwitchInside:camCard t:@"الرفع من الاستوديو" i:@"photo.on.rectangle.angled" isOn:isCamOn y:60 action:^(UISwitch *s){
        if (s.on) {
            [WolFoxProStore shared].mediaUploadActive = YES;
            [[WolFoxProStore shared] saveSettings];
            [self refreshSpoofHeaderStatus];
            [[WolFoxController shared] toggleCameraIcon:YES];
            [self showToast:@"اضغط زر الرفع العائم لاختيار صورة من الأستديو"];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"إيقاف تزييف الكاميرا؟" message:@"ستعود الكاميرا والوسائط الحقيقية بعد التأكيد." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"متابعة التزييف" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { [s setOn:YES animated:YES]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"إيقاف الآن" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [self performClearSpoofedImage]; }]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }]];
    
    // Preview Card (Conditional)
    if ([WolFoxProStore shared].spoofedImagePath) {
        UIView *prevCard = [[UIView alloc] initWithFrame:CGRectMake(15, 170, w - 30, 234)];
        prevCard.backgroundColor = [WolFoxProTheme surfacePrimary]; prevCard.layer.cornerRadius = 20;
        [_scrollDashboard addSubview:prevCard];
        
        UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, prevCard.bounds.size.width, 25)];
        pt.text = @"معاينة الوسائط"; pt.textColor = [WolFoxProTheme textSecondary]; pt.textAlignment = NSTextAlignmentCenter; pt.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold];
        [prevCard addSubview:pt];
        
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(20, 40, prevCard.bounds.size.width - 40, 130)];
        iv.backgroundColor = [WolFoxProTheme surfaceSecondary]; iv.layer.cornerRadius = 15; iv.contentMode = UIViewContentModeScaleAspectFill; iv.clipsToBounds = YES;
        iv.image = [UIImage imageWithContentsOfFile:[WolFoxProStore shared].spoofedImagePath];
        [prevCard addSubview:iv];
        
        UIButton *clr = [UIButton buttonWithType:UIButtonTypeSystem];
        clr.frame = CGRectMake(20, 178, prevCard.bounds.size.width - 40, 44);
        clr.backgroundColor = [WolFoxProTheme danger]; clr.layer.cornerRadius = 12;
        [clr setTitle:@"حذف الصورة والعودة للواقع" forState:UIControlStateNormal]; [clr setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        clr.titleLabel.font = [WolFoxProTheme fontOfSize:13 weight:UIFontWeightBold];
        [clr addTarget:self action:@selector(clearSpoofedImage) forControlEvents:UIControlEventTouchUpInside];
        [prevCard addSubview:clr];
        
        clr.accessibilityLabel = @"حذف الصورة وإيقاف تزييف الكاميرا";
        _scrollDashboard.contentSize = CGSizeMake(w, 420);
    } else {
        _scrollDashboard.contentSize = CGSizeMake(w, 200);
    }
}

- (void)clearSpoofedImage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"حذف الصورة وإيقاف التزييف؟" message:@"سيتم حذف الصورة المختارة والعودة إلى الكاميرا الحقيقية." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"حذف وإيقاف" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [self performClearSpoofedImage]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performClearSpoofedImage {
    NSString *oldPath = [WolFoxProStore shared].spoofedImagePath;
    if (oldPath.length) [[NSFileManager defaultManager] removeItemAtPath:oldPath error:nil];
    [WolFoxProStore shared].spoofedImagePath = nil;
    [WolFoxProStore shared].mediaUploadActive = NO;
    [[WolFoxProStore shared] saveSettings];
    [self refreshSpoofHeaderStatus];
    [[WolFoxController shared] toggleCameraIcon:NO];
    [self switchPage:3];
    [self showToast:@"⚠️ تم إيقاف تزييف الكاميرا والعودة للواقع"];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    if (img) {
        NSString *path = [[WolFoxProStore shared] mediaStoragePath];
        BOOL stored = [UIImageJPEGRepresentation(img, 0.86) writeToFile:path atomically:YES];
        if (stored) {
            [WolFoxProStore shared].spoofedImagePath = path;
            [WolFoxProStore shared].mediaUploadActive = YES;
            [[WolFoxProStore shared] saveSettings];
            [self refreshSpoofHeaderStatus];
            [[WolFoxController shared] toggleCameraIcon:YES];
            [self switchPage:3];
            [self showToast:@"تم اختيار الصورة بنجاح ✅"];
        } else {
            [self showToast:@"تعذر حفظ الصورة المختارة"];
        }
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (UIView *)royalSwitchInside:(UIView *)p t:(NSString *)t i:(NSString *)i isOn:(BOOL)on y:(CGFloat)y action:(void(^)(UISwitch *))block {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(15, y, p.bounds.size.width - 30, 65)];
    v.backgroundColor = [WolFoxProTheme surfaceSecondary]; v.layer.cornerRadius = 15;
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(v.bounds.size.width - 45, 17, 30, 30)];
    if (@available(iOS 13.0, *)) iv.image = [UIImage systemImageNamed:i];
    iv.tintColor = [WolFoxProTheme accent]; iv.contentMode = UIViewContentModeScaleAspectFit; [v addSubview:iv];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(80, 0, v.bounds.size.width - 135, 65)];
    l.text = t; l.textColor = [WolFoxProTheme textPrimary]; l.font = [WolFoxProTheme fontOfSize:15 weight:UIFontWeightBold]; l.textAlignment = NSTextAlignmentRight; [v addSubview:l];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(15, 17, 50, 30)];
    sw.on = on; sw.onTintColor = [WolFoxProTheme accent];
    sw.accessibilityLabel = t;
    [sw addTarget:self action:@selector(handleSwitch:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(sw, "_sw_block", block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [v addSubview:sw]; return v;
}

- (void)setupSettingsPage {
    CGFloat w = _scrollDashboard.bounds.size.width;
    UIView *setCard = [[UIView alloc] initWithFrame:CGRectMake(15, 10, w - 30, 220)];
    setCard.backgroundColor = [WolFoxProTheme surfacePrimary]; setCard.layer.cornerRadius = 20;
    [_scrollDashboard addSubview:setCard];
    
    [setCard addSubview:[self royalSwitchInside:setCard t:@"إظهار الواجهة بزر الصوت" i:@"speaker.wave.2.fill" isOn:[WolFoxProStore shared].volumeGestureEnabled y:15 action:^(UISwitch *s){
        [WolFoxProStore shared].volumeGestureEnabled = s.on;
        [[WolFoxProStore shared] saveSettings];
        [self showToast:s.on ? @"استخدم 3 ضغطات سريعة على زر الصوت لإظهار الواجهة" : @"تم إيقاف إظهار الواجهة بزر الصوت"];
    }]];
    
    UIButton *tg = [self royalBtnInside:setCard t:@"قناة التلجرام" i:@"paperplane.fill" c:[WolFoxProTheme accent] y:90];
    [tg addTarget:self action:@selector(openTelegram) forControlEvents:UIControlEventTouchUpInside];
    
    UIButton *resetLic = [self royalBtnInside:setCard t:@"تسجيل الخروج" i:@"rectangle.portrait.and.arrow.right" c:[WolFoxProTheme danger] y:155];
    [resetLic addTarget:self action:@selector(logoutPressed) forControlEvents:UIControlEventTouchUpInside];
    
    _scrollDashboard.contentSize = CGSizeMake(w, 250);
}

- (void)showSubscriptionInfo {
    // Show cached first, then refresh from server
    WFLicenseResult *cached = [WFLicenseClient lastLicenseResult] ?: [WFLicenseClient storedLicenseInfo];
    [self _presentSubscriptionPopup:cached];
    
    [WFLicenseClient verifySavedLicenseWithCompletion:^(WFLicenseResult *live) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Dismiss old popup and show fresh data
            [self hidePopup];
            if (live.success) [self _presentSubscriptionPopup:live];
        });
    }];
}

- (void)_presentSubscriptionPopup:(WFLicenseResult *)info {
    if (!info) info = [WFLicenseResult new]; // safe default
    NSString *deviceShort = [WFLicenseClient deviceIdentifier];
    if (deviceShort.length > 8) deviceShort = [deviceShort substringToIndex:8];
    NSString *code = [WFLicenseClient storedCode] ?: @"—";
    NSString *status = info.success ? @"✅ نشط" : @"❌ غير نشط";
    [self showPopupWithTitle:@"معلومات الاشتراك" icon:@"crown.fill" content:^{
        CGFloat contentWidth = MIN(300.0, self.view.bounds.size.width - 80.0);
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, contentWidth, 364)];
        [self addInfoRow:v t:@"الحالة" v:status y:0];
        [self addInfoRow:v t:@"نوع الباقة" v:info.planName ?: @"تجريبي" y:72];
        [self addInfoRow:v t:@"تاريخ الانتهاء" v:info.expiresAt ?: @"غير متوفر" y:144];
        [self addInfoRow:v t:@"كود التفعيل" v:code y:216];
        [self addInfoRow:v t:@"معرّف الجهاز" v:deviceShort y:288];
        return v;
    } btnTitle:@"موافق" btnColor:[WolFoxProTheme accent]];
}

- (void)addInfoRow:(UIView *)p t:(NSString *)t v:(NSString *)v y:(CGFloat)y {
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(15, y, p.bounds.size.width - 30, 20)];
    tl.text = t; tl.textColor = [WolFoxProTheme textSecondary]; tl.font = [WolFoxProTheme fontOfSize:13 weight:UIFontWeightMedium]; tl.textAlignment = NSTextAlignmentRight;
    [p addSubview:tl];
    UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(15, y + 25, p.bounds.size.width - 30, 40)];
    vl.backgroundColor = [WolFoxProTheme surfaceSecondary]; vl.layer.cornerRadius = 11; vl.text = v; vl.textColor = [WolFoxProTheme textPrimary]; vl.font = [WolFoxProTheme fontOfSize:13 weight:UIFontWeightBold]; vl.textAlignment = NSTextAlignmentCenter; vl.lineBreakMode = NSLineBreakByTruncatingMiddle; vl.adjustsFontSizeToFitWidth = YES; vl.minimumScaleFactor = 0.72;
    [p addSubview:vl];
}

// activateCodePressed removed - activation handled by WFActivationViewController

- (void)logoutPressed {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"تسجيل الخروج" message:@"هل أنت متأكد من رغبتك في حذف الترخيص من هذا الجهاز؟" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"نعم، حذف" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
        [WFLicenseClient clearStoredLicense];
        [self showToast:@"تم حذف الترخيص 🔄"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}


- (void)openTelegram { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://t.me/WolFoxGPS"] options:@{} completionHandler:nil]; }


#pragma mark - Actions & Map

- (void)applyManualCoords {
    NSString *input = [NSString stringWithFormat:@"%@,%@", _latInput.text ?: @"", _lonInput.text ?: @""];
    CLLocationCoordinate2D c;
    if (![self parseCoordinateSearchText:input coordinate:&c]) {
        [self showToast:@"الإحداثيات غير صحيحة؛ خط العرض من -90 إلى 90 والطول من -180 إلى 180 ❌"];
        return;
    }
    [WolFoxProStore shared].spoofActive = YES;
    [WolFoxProStore shared].currentFakeCoords = c;
    [[WolFoxProStore shared] saveSettings];
    [self updateMapPin:c];
    [[WolFoxProHookManager shared] deliverFakeUpdate];
    [self refreshSpoofHeaderStatus];
    [self showToast:@"✅ تم تطبيق الموقع وتشغيل التزييف"];
}

- (void)toggleTheme {
    [WolFoxProStore shared].themeIndex = ([WolFoxProStore shared].themeIndex == 0) ? 1 : 0;
    [[WolFoxProStore shared] saveSettings];
    self->_blurView.effect = [UIBlurEffect effectWithStyle:[WolFoxProTheme blurStyle]];
    self->_titleLabel.textColor = [WolFoxProTheme textPrimary];
    UIButton *tb = objc_getAssociatedObject(self, "_theme_btn");
    if (@available(iOS 13.0, *)) {
        NSString *icon = ([WolFoxProStore shared].themeIndex == 0) ? @"sun.max.fill" : @"moon.fill";
        [tb setImage:[UIImage systemImageNamed:icon] forState:UIControlStateNormal];
    }
    [self switchPage:self->_activePage];
}

- (void)dismiss { [[WolFoxController shared] dismissUI]; }

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:self.mapView];
    CLLocationCoordinate2D c = [self.mapView convertPoint:p toCoordinateFromView:self.mapView];
    [WolFoxProStore shared].currentFakeCoords = c;
    [[WolFoxProStore shared] saveSettings];
    [self updateMapPin:c];
    [[WolFoxProHookManager shared] deliverFakeUpdate];
    if (_latInput) _latInput.text = [NSString stringWithFormat:@"%.6f", c.latitude];
    if (_lonInput) _lonInput.text = [NSString stringWithFormat:@"%.6f", c.longitude];
}

- (void)updateMapPin:(CLLocationCoordinate2D)c {
    if (_currentPin) [self.mapView removeAnnotation:_currentPin];
    _currentPin = [MKPointAnnotation new]; _currentPin.coordinate = c; _currentPin.title = @"الموقع المحدد";
    [self.mapView addAnnotation:_currentPin];
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(c, 1400.0, 1400.0);
    [self.mapView setRegion:region animated:YES];
}

- (void)centerMapOnPin {
    if (_currentPin) {
        [self.mapView setCenterCoordinate:_currentPin.coordinate animated:YES];
        [self showToast:@"تم التمركز على الموقع المزيّف 📍"];
    }
}

- (BOOL)externalMapsCoordinate:(CLLocationCoordinate2D *)coordinate title:(NSString **)title {
    if (_currentPin && CLLocationCoordinate2DIsValid(_currentPin.coordinate)) {
        if (coordinate) *coordinate = _currentPin.coordinate;
        if (title) *title = _currentPin.title.length ? _currentPin.title : @"موقع WolFox";
        return YES;
    }

    CLLocation *real = [WolFoxProHookManager shared].lastRealLocation;
    if (real && CLLocationCoordinate2DIsValid(real.coordinate)) {
        if (coordinate) *coordinate = real.coordinate;
        if (title) *title = @"الموقع الحالي";
        return YES;
    }
    return NO;
}

- (void)openSelectedLocationInMaps:(UIButton *)sender {
    CLLocationCoordinate2D coordinate;
    NSString *title = nil;
    if (![self externalMapsCoordinate:&coordinate title:&title]) {
        [self showToast:@"حدد موقعاً أو انتظر وصول الموقع الحقيقي أولاً ❌"];
        return;
    }

    UIAlertController *chooser = [UIAlertController alertControllerWithTitle:@"فتح الموقع"
                                                                      message:@"اختر تطبيق الخرائط لبدء اتجاهات القيادة"
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [chooser addAction:[UIAlertAction actionWithTitle:@"خرائط Apple"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
        [weakSelf openAppleMapsAtCoordinate:coordinate title:title];
    }]];
    [chooser addAction:[UIAlertAction actionWithTitle:@"خرائط Google"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
        [weakSelf openGoogleMapsAtCoordinate:coordinate];
    }]];
    [chooser addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = chooser.popoverPresentationController;
    if (popover) {
        popover.sourceView = sender;
        popover.sourceRect = sender.bounds;
    }
    [self presentViewController:chooser animated:YES completion:nil];
}

- (void)openAppleMapsAtCoordinate:(CLLocationCoordinate2D)coordinate title:(NSString *)title {
    MKPlacemark *placemark = [[MKPlacemark alloc] initWithCoordinate:coordinate];
    MKMapItem *destination = [[MKMapItem alloc] initWithPlacemark:placemark];
    destination.name = title.length ? title : @"موقع WolFox";
    NSDictionary *options = @{
        MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving,
        MKLaunchOptionsShowsTrafficKey: @YES
    };
    if (![destination openInMapsWithLaunchOptions:options]) {
        [self showToast:@"تعذر فتح خرائط Apple ❌"];
    }
}

- (void)openGoogleMapsAtCoordinate:(CLLocationCoordinate2D)coordinate {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.google.com/maps/dir/"];
    NSString *destination = [NSString stringWithFormat:@"%.8f,%.8f", coordinate.latitude, coordinate.longitude];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"api" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"destination" value:destination],
        [NSURLQueryItem queryItemWithName:@"travelmode" value:@"driving"],
        [NSURLQueryItem queryItemWithName:@"dir_action" value:@"navigate"]
    ];
    NSURL *url = components.URL;
    if (!url) {
        [self showToast:@"تعذر تجهيز رابط خرائط Google ❌"];
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) dispatch_async(dispatch_get_main_queue(), ^{
            [self showToast:@"تعذر فتح خرائط Google ❌"];
        });
    }];
}

- (void)showRealLocation {
    CLLocation *real = [WolFoxProHookManager shared].lastRealLocation;
    if (real) {
        if (!self.realLocPin) {
            self.realLocPin = [MKPointAnnotation new];
            self.realLocPin.title = @"REAL_LOC";
            [self.mapView addAnnotation:self.realLocPin];
        }
        self.realLocPin.coordinate = real.coordinate;
        [self.mapView setCenterCoordinate:real.coordinate animated:YES];
        [self showToast:@"تم عرض موقعك الحقيقي 🔵"];
    } else {
        [self showToast:@"بانتظار تحديث الموقع الحقيقي... ⏳"];
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    if (!location) return;
    // While spoofing, the delegate proxy has already saved the real CLLocation
    // before forwarding the synthetic one. Do not overwrite that real value.
    if (![WolFoxProStore shared].spoofActive) {
        [WolFoxProHookManager shared].lastRealLocation = location;
        if (self.mapView) [self showRealLocation];
    }
}

- (void)confirmDisableSpoofForSwitch:(UISwitch *)sw {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"إيقاف تزييف الموقع؟" message:@"سيعود التطبيق لاستخدام موقع الجهاز الحقيقي. لن يتوقف التزييف إلا بعد التأكيد." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"متابعة التزييف" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        [sw setOn:YES animated:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إيقاف الآن" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[WolFoxProHookManager shared] stopRoute];
        [WolFoxProStore shared].spoofActive = NO;
        [[WolFoxProStore shared] saveSettings];
        [self refreshSpoofHeaderStatus];
        [self showRealLocation];
        [self showToast:@"تم إيقاف تزييف الموقع وعرض الموقع الحقيقي"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyActivationCode {
    NSString *code = [WFLicenseClient storedCode];
    if (code) {
        [UIPasteboard generalPasteboard].string = code;
        [self showToast:@"تم نسخ الكود للحافظة 📋"];
    } else {
        [self showToast:@"لا يوجد كود للنسخ ❌"];
    }
}

- (void)pasteCoordinates {
    NSString *str = [UIPasteboard generalPasteboard].string;
    if (!str.length) { [self showToast:@"الحافظة فارغة ❌"]; return; }
    
    // Support formats: "lat, lon" or "lat lon"
    NSArray *parts = [str componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]];
    NSMutableArray *cleanParts = [NSMutableArray new];
    for (NSString *p in parts) {
        NSString *c = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (c.length > 0) [cleanParts addObject:c];
    }
    
    if (cleanParts.count >= 2) {
        if (_latInput) _latInput.text = cleanParts[0];
        if (_lonInput) _lonInput.text = cleanParts[1];
        [self showToast:@"تم اللصق بنجاح ✅"];
    } else {
        [self showToast:@"تنسيق الإحداثيات غير صحيح ❌"];
    }
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKPointAnnotation class]]) {
        MKPointAnnotation *pa = (MKPointAnnotation *)annotation;
        if ([pa.title isEqualToString:@"REAL_LOC"]) {
            MKAnnotationView *av = [mapView dequeueReusableAnnotationViewWithIdentifier:@"real_dot"];
            if (!av) av = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"real_dot"];
            av.image = [self createBlueDotImage];
            return av;
        }
        MKPinAnnotationView *pin = (MKPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:@"fake_pin"];
        if (!pin) pin = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"fake_pin"];
        pin.pinTintColor = [UIColor systemRedColor]; pin.canShowCallout = YES;
        return pin;
    }
    return nil;
}

- (UIImage *)createBlueDotImage {
    CGFloat s = 20;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setFill]; CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, s, s));
    [[UIColor systemBlueColor] setFill]; CGContextFillEllipseInRect(ctx, CGRectMake(2, 2, s-4, s-4));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)saveCurrentLocation {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"حفظ الموقع" message:@"أدخل اسماً لهذا الموقع" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"اسم الموقع"; tf.textAlignment = NSTextAlignmentRight; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *name = ac.textFields.firstObject.text ?: @"موقع جديد";
        WolFoxProLocation *l = [WolFoxProLocation new];
        CLLocationCoordinate2D selected = self.mapView ? self.mapView.centerCoordinate : [WolFoxProStore shared].currentFakeCoords;
        l.name = name; l.coordinate = selected; l.altitude = 300.0;
        [[WolFoxProStore shared] saveLocation:l];
        NSUInteger count = [WolFoxProStore shared].locations.count;
        [self showToast:[NSString stringWithFormat:@"تم الحفظ في المفضلة • %lu مواقع", (unsigned long)count]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_activePage == 0) [self switchPage:0];
        });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showSavedLocations {
    NSArray *locs = [WolFoxProStore shared].locations;
    if (locs.count == 0) { [self showToast:@"لا توجد مواقع محفوظة 📋"]; return; }
    [self showPopupWithTitle:@"المواقع المحفوظة" icon:@"list.bullet" content:^{
        CGFloat ph = MIN((CGFloat)(locs.count * 60 + 20), 400.0);
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, 300, ph)];
        sv.alwaysBounceVertical = YES;
        CGFloat cy = 10;
        for (NSUInteger i = 0; i < locs.count; i++) {
            WolFoxProLocation *l = locs[i];
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10, cy, 280, 50)];
            row.backgroundColor = [WolFoxProTheme surfaceSecondary]; row.layer.cornerRadius = 12;
            [sv addSubview:row];
            UILabel *nl = [[UILabel alloc] initWithFrame:CGRectMake(50, 5, 220, 20)];
            nl.text = l.name; nl.textColor = [WolFoxProTheme textPrimary]; nl.textAlignment = NSTextAlignmentRight; nl.font = [WolFoxProTheme fontOfSize:14 weight:UIFontWeightBold];
            [row addSubview:nl];
            UILabel *cl = [[UILabel alloc] initWithFrame:CGRectMake(50, 25, 220, 20)];
            cl.text = [NSString stringWithFormat:@"%.6f, %.6f", l.coordinate.latitude, l.coordinate.longitude];
            cl.textColor = [WolFoxProTheme textSecondary]; cl.textAlignment = NSTextAlignmentRight; cl.font = [WolFoxProTheme fontOfSize:10 weight:UIFontWeightMedium];
            [row addSubview:cl];
            UIButton *selB = [UIButton buttonWithType:UIButtonTypeCustom]; selB.frame = row.bounds; selB.tag = (NSInteger)i;
            [selB addTarget:self action:@selector(favSelected:) forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:selB];
            UIButton *delB = [UIButton buttonWithType:UIButtonTypeSystem]; delB.frame = CGRectMake(6, 3, 44, 44);
            if (@available(iOS 13.0, *)) [delB setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
            delB.tintColor = [WolFoxProTheme danger];
            objc_setAssociatedObject(delB, "loc_id", @(l.ID), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [delB addTarget:self action:@selector(deleteFav:) forControlEvents:UIControlEventTouchUpInside];
            delB.accessibilityLabel = [NSString stringWithFormat:@"حذف الموقع %@", l.name ?: @""];
            [row addSubview:delB];
            cy += 60;
        }
        sv.contentSize = CGSizeMake(300, cy);
        return sv;
    } btnTitle:@"إغلاق" btnColor:[WolFoxProTheme accent]];
}

- (void)favSelected:(UIButton *)b {
    NSArray *locs = [WolFoxProStore shared].locations;
    if (b.tag < 0 || (NSUInteger)b.tag >= locs.count) return;
    WolFoxProLocation *l = locs[b.tag];
    [WolFoxProStore shared].currentFakeCoords = l.coordinate;
    [[WolFoxProStore shared] saveSettings];
    [self updateMapPin:l.coordinate];
    [[WolFoxProHookManager shared] deliverFakeUpdate];
    [self hidePopup];
    [self showToast:@"تم اختيار الموقع 📍"];
}

- (void)deleteFav:(UIButton *)b {
    NSNumber *locID = objc_getAssociatedObject(b, "loc_id");
    if (!locID) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"حذف الموقع المحفوظ؟" message:@"سيُحذف هذا الموقع من المفضلة نهائياً." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"حذف" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[WolFoxProStore shared] deleteLocationID:[locID longLongValue]];
        [self hidePopup];
        [self showToast:@"✅ تم حذف الموقع من المفضلة"];
        if (self->_activePage == 0) [self switchPage:0];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showPopupWithTitle:(NSString *)title icon:(NSString *)iconName content:(UIView *(^)(void))contentBlock btnTitle:(NSString *)bt btnColor:(UIColor *)bc {
    [self hidePopup];
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78]; overlay.tag = 999;
    [self.view addSubview:overlay];
    CGFloat pw = MIN(340.0, self.view.bounds.size.width - 32.0);
    UIView *content = contentBlock();
    CGFloat safeTop = self.view.safeAreaInsets.top;
    CGFloat safeBottom = self.view.safeAreaInsets.bottom;
    CGFloat maxHeight = self.view.bounds.size.height - safeTop - safeBottom - 32.0;
    CGFloat desiredHeight = 135.0 + content.frame.size.height + 90.0;
    CGFloat cardHeight = MIN(maxHeight, desiredHeight);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width-pw)/2, safeTop + (maxHeight-cardHeight)/2.0 + 16.0, pw, cardHeight)];
    card.backgroundColor = [WolFoxProTheme royalCard]; card.layer.cornerRadius = 24; card.clipsToBounds = YES;
    card.layer.borderWidth = 1.0; card.layer.borderColor = [[WolFoxProTheme accent] colorWithAlphaComponent:0.28].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor; card.layer.shadowOpacity = 0.35; card.layer.shadowRadius = 20; card.layer.shadowOffset = CGSizeMake(0, 10);
    [overlay addSubview:card];
    UIImageView *topIcon = [[UIImageView alloc] initWithFrame:CGRectMake((pw-60)/2, 25, 60, 60)];
    if (@available(iOS 13.0, *)) topIcon.image = [UIImage systemImageNamed:iconName];
    topIcon.tintColor = [WolFoxProTheme accent]; topIcon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:topIcon];
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(0, 95, pw, 30)];
    tl.text = title; tl.textColor = [WolFoxProTheme textPrimary]; tl.font = [WolFoxProTheme fontOfSize:20 weight:UIFontWeightBold]; tl.textAlignment = NSTextAlignmentCenter;
    [card addSubview:tl];
    UIScrollView *contentScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 130, pw - 24, cardHeight - 204)];
    contentScroll.alwaysBounceVertical = content.frame.size.height > contentScroll.bounds.size.height;
    content.frame = CGRectMake(0, 0, contentScroll.bounds.size.width, content.frame.size.height);
    contentScroll.contentSize = CGSizeMake(contentScroll.bounds.size.width, content.frame.size.height);
    [contentScroll addSubview:content];
    [card addSubview:contentScroll];
    UIButton *ok = [UIButton buttonWithType:UIButtonTypeSystem];
    ok.frame = CGRectMake(20, cardHeight - 64, pw - 40, 48);
    ok.backgroundColor = bc; ok.layer.cornerRadius = 15;
    [ok setTitle:bt forState:UIControlStateNormal]; [ok setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    ok.titleLabel.font = [WolFoxProTheme fontOfSize:17 weight:UIFontWeightBold];
    [ok addTarget:self action:@selector(hidePopup) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:ok];
}

- (void)hidePopup { [[self.view viewWithTag:999] removeFromSuperview]; }

- (void)showToast:(NSString *)text {
    [[self.view viewWithTag:998] removeFromSuperview];
    CGFloat width = self.view.bounds.size.width - 32;
    CGFloat top = MAX(CGRectGetMaxY(_tabsBar.frame) + 12.0, self.view.safeAreaInsets.top + 104.0);
    UIView *tv = [[UIView alloc] initWithFrame:CGRectMake(16, top, width, 56)];
    tv.tag = 998;
    UIColor *stateColor = [WolFoxProTheme accent];
    NSString *stateIcon = @"info.circle.fill";
    if ([text containsString:@"✅"] || [text containsString:@"تشغيل"] || [text containsString:@"تم التفعيل"] || [text containsString:@"تم الحفظ"]) { stateColor = [WolFoxProTheme success]; stateIcon = @"checkmark.circle.fill"; }
    else if ([text containsString:@"⚠"] || [text containsString:@"❌"] || [text containsString:@"إيقاف"] || [text containsString:@"توقفت"] || [text containsString:@"حذف"] || [text containsString:@"تعذر"] || [text containsString:@"خطأ"]) { stateColor = [WolFoxProTheme danger]; stateIcon = @"exclamationmark.triangle.fill"; }
    else if ([text containsString:@"حقيقي"]) { stateColor = [WolFoxProTheme accent]; stateIcon = @"location.circle.fill"; }
    tv.backgroundColor = [[WolFoxProTheme surfacePrimary] colorWithAlphaComponent:0.96]; tv.layer.cornerRadius = 18; tv.layer.borderWidth = 1; tv.layer.borderColor = [stateColor colorWithAlphaComponent:0.82].CGColor; tv.alpha = 0;
    tv.layer.shadowColor = [UIColor blackColor].CGColor; tv.layer.shadowOpacity = 0.30; tv.layer.shadowRadius = 10; tv.layer.shadowOffset = CGSizeMake(0, 5);
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(18, 14, 28, 28)];
    if (@available(iOS 13.0, *)) icon.image = [UIImage systemImageNamed:stateIcon];
    icon.tintColor = stateColor; icon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(58, 0, width - 76, 56)]; l.text = text; l.textColor = [WolFoxProTheme textPrimary]; l.font = [WolFoxProTheme fontOfSize:16 weight:UIFontWeightBold]; l.textAlignment = NSTextAlignmentRight; l.lineBreakMode = NSLineBreakByTruncatingTail;
    [tv addSubview:icon];
    [tv addSubview:l]; [self.view addSubview:tv];
    tv.isAccessibilityElement = YES;
    tv.accessibilityLabel = text;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
    tv.transform = CGAffineTransformMakeTranslation(0, -10);
    [UIView animateWithDuration:[WolFoxProTheme transitionDuration] delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ tv.alpha = 1.0; tv.transform = CGAffineTransformIdentity; } completion:^(BOOL f) {
        [UIView animateWithDuration:[WolFoxProTheme transitionDuration] delay:2.50 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn animations:^{ tv.alpha = 0; tv.transform = CGAffineTransformMakeTranslation(0, -8); } completion:^(BOOL f2) { [tv removeFromSuperview]; }];
    }];
}

@end

@implementation WolFoxController
+ (instancetype)shared { static WolFoxController *s=nil; static dispatch_once_t o; dispatch_once(&o,^{s=[WolFoxController new];}); return s; }
- (instancetype)init { 
    if(self=[super init]){
        NSLog(@"[WolFox][UI] controller_init");
        [self setupUI];
        [self setupVolumeObserver];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(licenseStateChanged:) name:@"WF_LICENSE_STATE_CHANGED" object:nil];
    } 
    return self; 
}

- (void)dealloc {
    @try { [self.volumeSession removeObserver:self forKeyPath:@"outputVolume"]; } @catch (__unused NSException *exception) {}
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)licenseStateChanged:(NSNotification *)notification {
    WFLicenseResult *result = [notification.object isKindOfClass:WFLicenseResult.class] ? notification.object : nil;
    if (result.success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.mainVC refreshSpoofHeaderStatus];
            if ([WolFoxProStore shared].spoofActive) {
                [[WolFoxProHookManager shared] deliverFakeUpdate];
                NSLog(@"[WolFox][GPS] license_ready_fake_update_delivered");
            }
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[WolFoxProHookManager shared] stopRoute];
        [WolFoxProStore shared].spoofActive = NO;
        [[WolFoxProStore shared] saveSettings];
        [self.mainVC refreshSpoofHeaderStatus];
        [self toggleCameraIcon:NO];
        self.mainVC.view.hidden = YES;
        self.mainVC.view.alpha = 0;
        if ([[NSUserDefaults standardUserDefaults] boolForKey:WFUIHiddenOnLaunchKey]) {
            self.overlayWindow.hidden = YES;
            [self restoreHostKeyWindow];
            [self prepareHiddenVolumeListening];
            NSLog(@"[WolFox][LICENSE] invalid_while_hidden_waiting_for_volume_request");
            return;
        }
        [self showActivationScreenWithResult:result];
    });
}

- (void)setupVolumeObserver {
    self.volumeSession = [AVAudioSession sharedInstance];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(systemVolumeDidChange:) name:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil];
    [center addObserver:self selector:@selector(applicationBecameActiveForVolume:) name:UIApplicationDidBecomeActiveNotification object:nil];
    @try {
        [self.volumeSession addObserver:self forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew context:NULL];
        NSLog(@"[WolFox][UI] volume_kvo_ready");
    } @catch (NSException *exception) {
        NSLog(@"[WolFox][UI] volume_kvo_unavailable=%@", exception.name);
    }
    [self prepareHiddenVolumeListening];
}

- (void)prepareHiddenVolumeListening {
    if (![WolFoxProStore shared].volumeGestureEnabled || !self.volumeSession) return;
    NSError *error = nil;
    BOOL active = [self.volumeSession setActive:YES error:&error];
    if (active) NSLog(@"[WolFox][UI] hidden_volume_listener_active");
    else NSLog(@"[WolFox][UI] hidden_volume_listener_activation_failed=%@", error.localizedDescription ?: @"unknown");
}

- (void)applicationBecameActiveForVolume:(NSNotification *)notification {
    (void)notification;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:WFUIHiddenOnLaunchKey] || self.mainVC.view.hidden) {
        [self prepareHiddenVolumeListening];
    }
}

- (void)systemVolumeDidChange:(NSNotification *)notification {
    if (![WolFoxProStore shared].volumeGestureEnabled) return;
    NSString *reason = [notification.userInfo[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"] description];
    if (reason.length && [reason rangeOfString:@"explicit" options:NSCaseInsensitiveSearch].location == NSNotFound) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (now - self.lastSystemVolumeNotificationTime < 0.08) return;
        self.lastSystemVolumeNotificationTime = now;
        [self recordVolumeButtonPress];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"outputVolume"] && object == self.volumeSession) {
        [self handleVolumeGesturePulse];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)handleVolumeGesturePulse {
    if (![WolFoxProStore shared].volumeGestureEnabled) return;
    NSTimeInterval candidateTime = NSDate.timeIntervalSinceReferenceDate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![WolFoxProStore shared].volumeGestureEnabled) return;
        if (self.lastSystemVolumeNotificationTime >= candidateTime - 0.03) return;
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (now - self.lastFallbackVolumePulseTime < 0.18) return;
        self.lastFallbackVolumePulseTime = now;
        [self recordVolumeButtonPress];
    });
}

- (void)recordVolumeButtonPress {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self recordVolumeButtonPress]; });
        return;
    }
    if (![WolFoxProStore shared].volumeGestureEnabled) return;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - self.lastVolumePulseTime > 1.50) self.volumePulseCount = 0;
    self.lastVolumePulseTime = now;
    self.volumePulseCount++;
    NSLog(@"[WolFox][UI] volume_request_progress=%ld/3", (long)MIN(self.volumePulseCount, 3));
    if (self.volumePulseCount >= 3 && now - self.lastVolumeToggleTime > 0.85) {
        self.volumePulseCount = 0;
        self.lastVolumeToggleTime = now;
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        NSLog(@"[WolFox][UI] volume_toggle_confirmed");
        [self toggleUI];
    }
}

- (UIWindow *)hostKeyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window != self.overlayWindow && window.isKeyWindow) return window;
            }
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window != self.overlayWindow && window.isKeyWindow) return window;
    }
    return nil;
}

- (void)makeOverlayKey {
    UIWindow *host = [self hostKeyWindow];
    if (host) self.previousKeyWindow = host;
    self.overlayWindow.hidden = NO;
    [self.overlayWindow makeKeyAndVisible];
}

- (void)restoreHostKeyWindow {
    UIWindow *host = self.previousKeyWindow ?: [self hostKeyWindow];
    if (host) [host makeKeyWindow];
}

- (void)setupUI {
    NSLog(@"[WolFox][UI] setup_overlay_begin");
    UIWindowScene *activeScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) { activeScene = (UIWindowScene *)scene; break; }
        }
        if (!activeScene) { for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) { if ([scene isKindOfClass:[UIWindowScene class]]) { activeScene = (UIWindowScene *)scene; break; } } }
    }
    
    if (activeScene) {
        self.overlayWindow = [[WolFoxOverlayWindow alloc] initWithWindowScene:activeScene];
    } else {
        self.overlayWindow = [[WolFoxOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 2;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.hidden = YES;
    
    self.mainVC = [WolFoxMainViewController new];
    self.overlayWindow.rootViewController = self.mainVC;
    
    // Hide Floating Icon as requested, but keep it in memory for toggleUI logic
    self.floatingIcon = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingIcon.hidden = YES; 
    
    self.mainVC.view.hidden = YES;
    NSLog(@"[WolFox][UI] overlay_ready main_hidden=1");
    
    // Triple Finger Tap Fallback
    UITapGestureRecognizer *tripleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleUI)];
    tripleTap.numberOfTouchesRequired = 3;
    [self.overlayWindow addGestureRecognizer:tripleTap];

    // لا نستخدم مؤقتاً متكرراً لإبقاء النافذة مرئية؛ مسارات العرض المخصصة
    // هي الوحيدة التي تغيّر حالة النافذة، لتفادي مورد واجهة دائم بلا إلغاء.
}

- (void)toggleUI {
    NSLog(@"[WolFox][UI] toggle_requested verified=%d main_hidden=%d", [WFLicenseClient isRuntimeLicenseValid], self.mainVC.view.hidden);
    if (![WFLicenseClient isRuntimeLicenseValid]) {
        [self showActivationScreenWithResult:[WFLicenseClient lastLicenseResult]];
        return;
    }
    
    if (self.mainVC.view.hidden) [self showUI];
    else [self dismissUI];
}

- (void)showActivationScreen {
    [self showActivationScreenWithResult:[WFLicenseClient lastLicenseResult]];
}

- (void)showActivationScreenWithResult:(WFLicenseResult *)result {
    if (self.mainVC.presentedViewController) return; // already showing
    NSLog(@"[WolFox][ACT] presenting_activation");

    WFActivationViewController *avc = [WFActivationViewController new];
    avc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    avc.noticeMessage = result.message;
    avc.updateURL = result.updateURL;
    avc.completion = ^(BOOL success) {
        NSLog(@"[WolFox][ACT] completion success=%d", success);
        if (success) {
            [self showUI];
        }
    };

    // Make window visible and present
    [self makeOverlayKey];

    // mainVC must be in window hierarchy
    self.mainVC.view.hidden = NO;
    self.mainVC.view.alpha = 0; // invisible but present

    [self.mainVC presentViewController:avc animated:YES completion:^{
        // Keep mainVC invisible after activation VC appears
        self.mainVC.view.alpha = 0;
    }];
}
- (void)showUI { 
    NSLog(@"[WolFox][UI] show_main_requested");
    if (![WFLicenseClient isRuntimeLicenseValid]) {
        NSLog(@"[WolFox][UI] blocked_without_activation");
        [self showActivationScreen];
        return;
    }
    [self makeOverlayKey];
    [self.mainVC refreshSpoofHeaderStatus];
    self.mainVC.view.hidden = NO; 
    self.mainVC.view.alpha = 0; 
    if ([WolFoxProStore shared].mediaUploadActive) [self toggleCameraIcon:YES];
    [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{
        self.mainVC.view.alpha = 1.0;
    } completion:^(__unused BOOL finished) {
        NSLog(@"[WolFox][UI] main_visible");
    }]; 
}
- (void)dismissUI { 
    NSLog(@"[WolFox][UI] dismiss_main_requested");
    [self.mainVC closeExpandedMapIfNeeded];
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    [WolFoxProStore shared].volumeGestureEnabled = YES;
    [[WolFoxProStore shared] saveSettings];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:WFUIHiddenOnLaunchKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self prepareHiddenVolumeListening];
    [self.cameraIcon.layer removeAllAnimations];
    self.cameraIcon.alpha = 0;
    self.cameraIcon.hidden = YES;
    [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{
        self.mainVC.view.alpha = 0;
    } completion:^(BOOL f){
        self.mainVC.view.hidden = YES;
        self.overlayWindow.hidden = YES;
        [self restoreHostKeyWindow];
        NSLog(@"[WolFox][UI] dismiss_confirmed_volume_hook_stays_active");
    }]; 
}

- (void)toggleCameraIcon:(BOOL)show {
    if (show && ![WFLicenseClient isRuntimeLicenseValid]) show = NO;
    if (show) {
        self.overlayWindow.hidden = NO;
        if (!self.cameraIcon) {
            self.cameraIcon = [UIButton buttonWithType:UIButtonTypeCustom];
            self.cameraIcon.frame = CGRectMake(18, 330, 52, 52);
            self.cameraIcon.backgroundColor = [WolFoxProTheme accent];
            self.cameraIcon.layer.cornerRadius = 26;
            if (@available(iOS 13.0, *)) {
                [self.cameraIcon setImage:[UIImage systemImageNamed:@"arrow.up.circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
            }
            self.cameraIcon.tintColor = [UIColor whiteColor];
            [self.cameraIcon addTarget:self action:@selector(cameraIconPressed) forControlEvents:UIControlEventTouchUpInside];
            [self.overlayWindow addSubview:self.cameraIcon];
            
            // Shadow
            self.cameraIcon.layer.shadowColor = [UIColor blackColor].CGColor;
            self.cameraIcon.layer.shadowOffset = CGSizeMake(0, 4);
            self.cameraIcon.layer.shadowOpacity = 0.5;
            self.cameraIcon.layer.shadowRadius = 8;
        }
        self.cameraIcon.hidden = NO;
        self.cameraIcon.alpha = 0;
        [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{ self.cameraIcon.alpha = 1.0; }];
    } else {
        [UIView animateWithDuration:[WolFoxProTheme transitionDuration] animations:^{ self.cameraIcon.alpha = 0; } completion:^(BOOL f){
            self.cameraIcon.hidden = YES;
            if (self.mainVC.view.hidden && !self.mainVC.presentedViewController) self.overlayWindow.hidden = YES;
        }];
    }
}

- (void)cameraIconPressed {
    if (![WFLicenseClient isRuntimeLicenseValid]) {
        [self showActivationScreenWithResult:[WFLicenseClient lastLicenseResult]];
        return;
    }
    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self.mainVC;
    // Show mainVC first if hidden, then present picker
    if (self.mainVC.view.hidden) {
        [self showUI];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([WolFoxProTheme transitionDuration] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.mainVC presentViewController:picker animated:YES completion:nil];
        });
    } else {
        [self.mainVC presentViewController:picker animated:YES completion:nil];
    }
}
@end

static void __attribute__((constructor)) initialize() {
    if (!WFMasterProcessIsEligible()) return;
    NSLog(@"[WolFox][BOOT] ui_constructor_loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WolFoxController *controller = [WolFoxController shared];
        NSLog(@"[WolFox][BOOT] startup_stored=%d verify_before_ui=1", [WFLicenseClient hasStoredLicense]);
        [WFLicenseClient validateStrictlyWithCompletion:^(WFLicenseResult *result) {
            BOOL stayHidden = [[NSUserDefaults standardUserDefaults] boolForKey:WFUIHiddenOnLaunchKey];
            if (!stayHidden) {
                if (result.success) {
                    if ([WolFoxProStore shared].mediaUploadActive) [controller toggleCameraIcon:YES];
                    [controller showUI];
                } else {
                    [controller showActivationScreenWithResult:result];
                }
            } else {
                NSLog(@"[WolFox][BOOT] startup_ui_stays_hidden_until_volume_request");
            }
            [WFLicenseClient startHeartbeat];
        }];
    });
}
