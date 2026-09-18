#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# WolFox v1.6.1 compatibility build
# Runtime target: iOS 15.8 through iOS 26.5
# Build SDK: iPhoneOS 16.5. يظل Deployment Target عند iOS 15.8.
VERSION="1.6.1"
MIN_IOS="${MIN_IOS:-15.8}"
MAX_TARGET_IOS="26.5"
REQUIRED_SDK_VERSION="${REQUIRED_SDK_VERSION:-16.5}"
export THEOS="${THEOS:-$HOME/theos}"
export PATH="$THEOS/bin:$PATH"
# يعتمد هذا المسار المستقر على Clang النظام الحديث وSDK 16.5 النظيفة.
# لا يستخدم Toolchain Theos القديمة ولا يخلط ملفات من SDK أخرى.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

SDK_PATH="${SDKROOT:-${SDK_PATH:-$THEOS/sdks/iPhoneOS${REQUIRED_SDK_VERSION}.sdk}}"
THEOS_INC="$THEOS/include"
BUILD_DIR="$PROJECT_DIR/.wolfox-build"
OUTPUT_DYLIB="$PROJECT_DIR/WolFox.dylib"
WOLFOX_ARCHS="${WOLFOX_ARCHS:-arm64}"
WOLFOX_LINKER="${WOLFOX_LINKER:-lld}"

if [ "$WOLFOX_ARCHS" != "arm64" ]; then
    echo "❌ هذا مسار البناء المستقر يتطلب arm64 فقط؛ لا تُضم arm64e من دون Toolchain تدعمها فعلياً."
    exit 1
fi

case "$WOLFOX_LINKER" in
    ld|lld) ;;
    *)
        echo "❌ رابط غير مدعوم: $WOLFOX_LINKER (المسموح: ld أو lld)."
        exit 1
        ;;
esac

if [ ! -d "$SDK_PATH" ]; then
    echo "❌ لم يتم العثور على iPhoneOS SDK داخل: $THEOS/sdks"
    echo "   استخدم iPhoneOS${REQUIRED_SDK_VERSION}.sdk أو أحدث لبناء يستهدف iOS 15.8."
    exit 1
fi

SDK_BASENAME="$(basename "$SDK_PATH")"
if [[ "$SDK_BASENAME" =~ ^iPhoneOS([0-9]+([.][0-9]+)*)[.]sdk$ ]]; then
    SDK_VERSION="${BASH_REMATCH[1]}"
else
    echo "❌ تعذر تحديد إصدار SDK من الاسم: $SDK_BASENAME"
    echo "   استخدم اسماً مثل iPhoneOS${REQUIRED_SDK_VERSION}.sdk."
    exit 1
fi

version_at_least() {
    local actual="$1"
    local required="$2"
    [ "$(printf '%s\n' "$required" "$actual" | sort -V | head -n 1)" = "$required" ]
}

if ! version_at_least "$SDK_VERSION" "$REQUIRED_SDK_VERSION"; then
    if [ "${ALLOW_OLDER_SDK:-0}" = "1" ]; then
        echo "⚠️  بناء أولي فقط: SDK $SDK_VERSION أقدم من المطلوب $REQUIRED_SDK_VERSION."
    else
        echo "❌ SDK الحالي $SDK_VERSION أقدم من المطلوب $REQUIRED_SDK_VERSION."
        echo "   أضف iPhoneOS${REQUIRED_SDK_VERSION}.sdk أو استخدم ALLOW_OLDER_SDK=1 لبناء أولي غير معتمد."
        exit 1
    fi
fi

SDK_REQUIRED_FILES=(
    "$SDK_PATH/System/Library/Frameworks/UIKit.framework/Headers/UIKit.h"
    "$SDK_PATH/System/Library/Frameworks/WebKit.framework/Headers/WebKit.h"
    "$SDK_PATH/usr/lib/libSystem.tbd"
    "$SDK_PATH/usr/lib/libc++.tbd"
    "$SDK_PATH/usr/lib/libobjc.tbd"
)
for required_file in "${SDK_REQUIRED_FILES[@]}"; do
    if [ ! -f "$required_file" ]; then
        echo "❌ SDK غير مكتملة أو تحتوي رابطاً مكسوراً: $required_file"
        echo "   أعد تثبيت iPhoneOS${REQUIRED_SDK_VERSION}.sdk كاملة مع الحفاظ على الروابط الرمزية."
        exit 1
    fi
done
BROKEN_SDK_LINK="$(find "$SDK_PATH" -xtype l -print -quit 2>/dev/null || true)"
if [ -n "$BROKEN_SDK_LINK" ]; then
    echo "❌ يوجد رابط رمزي مكسور داخل SDK: $BROKEN_SDK_LINK"
    exit 1
fi

CC="${CC:-/usr/bin/clang}"
CXX="${CXX:-/usr/bin/clang++}"
DPKG_DEB="${DPKG_DEB:-$(command -v dpkg-deb || true)}"
LDID="${LDID:-}"

if [ -z "$LDID" ] || [ ! -x "$LDID" ]; then
    for candidate in \
        "$THEOS/toolchain/linux/iphone/bin/ldid" \
        "$THEOS/bin/ldid" \
        /usr/local/bin/ldid \
        "$(command -v ldid 2>/dev/null || true)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            LDID="$candidate"
            break
        fi
    done
fi

if { [ ! -x "$CC" ] && ! command -v "$CC" >/dev/null 2>&1; } || \
   { [ ! -x "$CXX" ] && ! command -v "$CXX" >/dev/null 2>&1; }; then
    echo "❌ clang/clang++ غير متوفرين في Theos toolchain."
    exit 1
fi
if [ -z "$DPKG_DEB" ]; then
    echo "❌ dpkg-deb غير متوفر."
    exit 1
fi
if [ "${WOLFOX_REQUIRE_SIGNING:-1}" != "0" ] && [ -z "$LDID" ]; then
    echo "❌ ldid غير متوفر؛ التوقيع مطلوب للنسخة النهائية."
    echo "   ثبّت ldid أو استخدم WOLFOX_REQUIRE_SIGNING=0 لبناء أولي غير موقّع فقط."
    exit 1
fi

DPKG_BUILD_FLAGS=(-Zgzip)
if "$DPKG_DEB" --help 2>&1 | grep -q -- '--root-owner-group'; then
    DPKG_BUILD_FLAGS+=(--root-owner-group)
elif [ "$(id -u)" != "0" ] && [ -z "${FAKEROOTKEY:-}" ]; then
    echo "❌ dpkg-deb لا يدعم --root-owner-group والبناء ليس داخل fakeroot."
    echo "   شغّل: fakeroot ./build_v1_deb.sh"
    exit 1
fi

# يمنع البناء الحقن العام. عيّن التطبيقات المستهدفة بإحدى الطريقتين:
#   WOLFOX_TARGET_BUNDLE_IDS="com.example.app,com.example.second" ./build_v1_deb.sh
# أو أنشئ WolFoxTargetBundles.txt بجانب هذا السكربت، سطراً واحداً لكل Bundle ID.
TARGET_BUNDLES_FILE="${TARGET_BUNDLES_FILE:-$PROJECT_DIR/WolFoxTargetBundles.txt}"
TARGET_BUNDLE_IDS="${WOLFOX_TARGET_BUNDLE_IDS:-}"
TARGET_BUNDLES=()

add_target_bundle() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [ -z "$value" ] && return 0
    [[ "$value" == \#* ]] && return 0
    if ! [[ "$value" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+$ ]]; then
        echo "❌ Bundle ID غير صالح: $value"
        exit 1
    fi
    if [[ "${value,,}" == com.apple.* ]]; then
        echo "❌ لا يسمح البناء باستهداف حزم Apple: $value"
        exit 1
    fi
    local existing
    for existing in "${TARGET_BUNDLES[@]:-}"; do
        [ "$existing" = "$value" ] && return 0
    done
    TARGET_BUNDLES+=("$value")
}

if [ -n "$TARGET_BUNDLE_IDS" ]; then
    IFS=',' read -r -a REQUESTED_BUNDLES <<< "$TARGET_BUNDLE_IDS"
    for bundle in "${REQUESTED_BUNDLES[@]}"; do add_target_bundle "$bundle"; done
elif [ -f "$TARGET_BUNDLES_FILE" ]; then
    while IFS= read -r bundle || [ -n "$bundle" ]; do add_target_bundle "$bundle"; done < "$TARGET_BUNDLES_FILE"
else
    echo "❌ لم تُحدّد Bundle IDs مستهدفة. تم إيقاف البناء لمنع الحقن العام."
    echo "   استخدم WOLFOX_TARGET_BUNDLE_IDS أو أنشئ: $TARGET_BUNDLES_FILE"
    exit 1
fi

if [ "${#TARGET_BUNDLES[@]}" -eq 0 ]; then
    echo "❌ لا توجد Bundle IDs صالحة للبناء. تم إيقاف البناء لمنع الحقن العام."
    exit 1
fi

FILES=(
    "WolFoxProCellModel.m"
    "WolFoxProTheme.m"
    "WolFoxProStore.m"
    "WFLicenseClient.m"
    "WFActivationViewController.m"
    "WolFoxProHookManager.m"
    "WolFoxIntegrated.mm"
    "WolFoxMaster.mm"
)

for file in "${FILES[@]}"; do
    if [ ! -f "$PROJECT_DIR/$file" ]; then
        echo "❌ ملف مفقود: $file"
        exit 1
    fi
done

COMMON_FLAGS=(
    -isysroot "$SDK_PATH"
    -I"$THEOS_INC"
    -I"$PROJECT_DIR"
    -miphoneos-version-min="$MIN_IOS"
    -fobjc-arc
    -fblocks
    -O2
    -Wall
    -Wextra
    -Werror=return-type
    -Wno-deprecated-declarations
    -Wno-unused-parameter
)

BASE_LINK_FLAGS=(
    -fuse-ld="$WOLFOX_LINKER"
    -isysroot "$SDK_PATH"
    -miphoneos-version-min="$MIN_IOS"
    -dynamiclib
    -install_name "@rpath/WolFox.dylib"
    -Wl,-ObjC
    -Wl,-undefined,dynamic_lookup
    -framework UIKit
    -framework Foundation
    -framework CoreLocation
    -framework CoreBluetooth
    -framework MapKit
    -framework Security
    -framework Photos
    -framework AVFoundation
    -framework AdSupport
    -framework WebKit
    -lsqlite3
)
LINK_FLAGS=("${BASE_LINK_FLAGS[@]}")

# تقوية آمنة للإصدار النهائي دون تغيير أسماء كلاسات Objective-C أو selectors
# التي تعتمد عليها الهوكات وقت التشغيل. يمكن تعطيلها فقط للتشخيص عبر:
# WOLFOX_HARDENING=0 ./build_v1_deb.sh
if [ "${WOLFOX_HARDENING:-1}" != "0" ]; then
    COMMON_FLAGS+=(
        -fvisibility=hidden
        -fno-common
    )
    LINK_FLAGS+=(
        -Wl,-dead_strip
        -Wl,-x
    )
fi

build_arch() {
    local arch="$1"
    local target="${arch}-apple-ios${MIN_IOS}"
    local arch_dir="$BUILD_DIR/$arch"
    local objects=()
    mkdir -p "$arch_dir"

    echo "⚙  بناء شريحة $arch — target $target"
    for file in "${FILES[@]}"; do
        local object="$arch_dir/${file%.*}.o"
        "$CC" -target "$target" "${COMMON_FLAGS[@]}" -c "$PROJECT_DIR/$file" -o "$object" || return 1
        objects+=("$object")
    done

    if ! "$CXX" -target "$target" "${LINK_FLAGS[@]}" -o "$arch_dir/WolFox.dylib" "${objects[@]}"; then
        if [ "${WOLFOX_HARDENING:-1}" != "0" ]; then
            echo "⚠️  linker الحالي لم يقبل dead_strip/-x؛ إعادة الربط تلقائياً بالخيارات الأساسية."
            "$CXX" -target "$target" "${BASE_LINK_FLAGS[@]}" -o "$arch_dir/WolFox.dylib" "${objects[@]}" || return 1
        else
            return 1
        fi
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " WolFox v$VERSION — iOS $MIN_IOS إلى iOS $MAX_TARGET_IOS"
echo " SDK: $(basename "$SDK_PATH")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

build_arch arm64
cp "$BUILD_DIR/arm64/WolFox.dylib" "$OUTPUT_DYLIB"
echo "✅ Dylib: arm64"

if [ "${WOLFOX_REQUIRE_SIGNING:-1}" != "0" ]; then
    "$LDID" -S "$OUTPUT_DYLIB"
    echo "✅ تم توقيع WolFox.dylib توقيعاً ad-hoc باستخدام ldid"
else
    echo "⚠️  خرج WolFox.dylib بلا توقيع؛ هذه نسخة أولية غير معتمدة للتثبيت."
fi

make_package() {
    local scheme="$1"
    local prefix="$2"
    local architecture="$3"
    local output="$4"
    local package_dir="$BUILD_DIR/package_$scheme"
    local tweak_dir="$package_dir$prefix/Library/MobileSubstrate/DynamicLibraries"

    mkdir -p "$tweak_dir" "$package_dir/DEBIAN"
    install -m 0755 "$OUTPUT_DYLIB" "$tweak_dir/WolFox.dylib"

    {
        echo "{"
        echo "    Filter = {"
        echo "        Bundles = ("
        for bundle in "${TARGET_BUNDLES[@]}"; do
            printf '            "%s",\n' "$bundle"
        done
        echo "        );"
        echo "    };"
        echo "}"
    } > "$tweak_dir/WolFox.plist"

    cat > "$package_dir/DEBIAN/control" <<CTRL
Package: com.wolfox.gpspro
Name: WolFox
Version: $VERSION
Architecture: $architecture
Description: WolFox iOS 15.8-26.5 arm64 — GPS/ID/Camera/Bluetooth tools with License Hub.
Author: WolFox
Maintainer: WolFox
Section: Tweaks
Depends: firmware (>= 15.8), mobilesubstrate
CTRL

    cat > "$package_dir/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
# يعاد التحميل فقط إن وُجد sbreload؛ بخلاف ذلك يكفي إغلاق التطبيقات المستهدفة
# وفتحها من جديد ليحمّل MobileSubstrate التعديل ضمن نطاق Bundle IDs المحدد.
if [ -x /var/jb/usr/bin/sbreload ]; then
    /var/jb/usr/bin/sbreload || true
elif [ -x /usr/bin/sbreload ]; then
    /usr/bin/sbreload || true
fi
exit 0
POSTINST
    chmod 0755 "$package_dir/DEBIAN/postinst"

    "$DPKG_DEB" "${DPKG_BUILD_FLAGS[@]}" -b "$package_dir" "$output"
}

validate_package() {
    local package="$1"
    local expected_architecture="$2"
    local expected_payload="$3"
    local actual_architecture
    local actual_dependencies

    actual_architecture="$("$DPKG_DEB" -f "$package" Architecture 2>/dev/null || true)"
    actual_dependencies="$("$DPKG_DEB" -f "$package" Depends 2>/dev/null || true)"

    if [ "$actual_architecture" != "$expected_architecture" ]; then
        echo "❌ معمارية الحزمة غير صحيحة: $package"
        echo "   المتوقع: $expected_architecture — الفعلي: ${actual_architecture:-missing}"
        exit 1
    fi
    if [[ "$actual_dependencies" != *"firmware (>= 15.8)"* ]] || [[ "$actual_dependencies" != *"mobilesubstrate"* ]]; then
        echo "❌ حقل Depends مفقود أو غير مكتمل داخل: $package"
        echo "   الفعلي: ${actual_dependencies:-missing}"
        exit 1
    fi
    if ! "$DPKG_DEB" -c "$package" | grep -F -- "$expected_payload/WolFox.dylib" >/dev/null; then
        echo "❌ مسار WolFox.dylib غير صحيح داخل: $package"
        exit 1
    fi
    if ! "$DPKG_DEB" -c "$package" | awk '$2 != "root/root" { bad=1 } END { exit bad }'; then
        echo "❌ ملكية بعض ملفات الحزمة ليست root:root داخل: $package"
        exit 1
    fi

    echo "✅ تحقق DEB: $(basename "$package") — arch=$actual_architecture — depends=$actual_dependencies"
}

ROOTFUL_DEB="$PROJECT_DIR/WolFox_v${VERSION}_iOS15.8-26.5_Rootful.deb"
ROOTLESS_DEB="$PROJECT_DIR/WolFox_v${VERSION}_iOS15.8-26.5_Rootless.deb"

make_package rootful "" "iphoneos-arm" "$ROOTFUL_DEB"
make_package rootless "/var/jb" "iphoneos-arm64" "$ROOTLESS_DEB"

validate_package "$ROOTFUL_DEB" "iphoneos-arm" "./Library/MobileSubstrate/DynamicLibraries"
validate_package "$ROOTLESS_DEB" "iphoneos-arm64" "./var/jb/Library/MobileSubstrate/DynamicLibraries"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ اكتمل البناء المتوافق"
echo " Rootful : $ROOTFUL_DEB"
echo " Rootless: $ROOTLESS_DEB"
echo " Minimum : iOS $MIN_IOS"
echo " Target  : iOS $MIN_IOS–$MAX_TARGET_IOS source compatibility"
echo " SDK     : iPhoneOS $SDK_VERSION (required >= $REQUIRED_SDK_VERSION)"
echo " Arch    : arm64 only"
echo " Signed  : $([ "${WOLFOX_REQUIRE_SIGNING:-1}" != "0" ] && echo yes || echo no)"
echo " Filter  : ${TARGET_BUNDLES[*]}"
echo " Protect : binary hardening ${WOLFOX_HARDENING:-1} (visibility/dead-strip/local symbols)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
