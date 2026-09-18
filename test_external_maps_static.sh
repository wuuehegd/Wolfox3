#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0

expect_pattern() {
    local label="$1"
    local pattern="$2"
    if rg -q -- "$pattern" WolFoxMaster.mm; then
        echo "✅ $label"
        PASS=$((PASS + 1))
    else
        echo "❌ $label"
        FAIL=$((FAIL + 1))
    fi
}

expect_pattern "زر اختيار تطبيق الخرائط في البطاقة" 'openSelectedLocationInMaps:'
expect_pattern "زر الخرائط متاح في وضع ملء الشاشة" 'externalMapsButton.tag = 6206'
expect_pattern "فتح خرائط Apple عبر MKMapItem" 'openInMapsWithLaunchOptions:'
expect_pattern "اتجاهات القيادة في خرائط Apple" 'MKLaunchOptionsDirectionsModeDriving'
expect_pattern "رابط Google Maps الرسمي" 'https://www.google.com/maps/dir/'
expect_pattern "إصدار Maps URLs الإلزامي" 'queryItemWithName:@"api" value:@"1"'
expect_pattern "تمرير الوجهة إلى Google Maps" 'queryItemWithName:@"destination"'
expect_pattern "بدء الملاحة عند توفرها" 'queryItemWithName:@"dir_action" value:@"navigate"'
expect_pattern "ترميز الرابط عبر NSURLComponents" 'NSURLComponents \*components'
expect_pattern "رسالة واضحة عند غياب الموقع" 'حدد موقعاً أو انتظر وصول الموقع الحقيقي أولاً'

echo "النتيجة: $PASS ناجح، $FAIL فاشل"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
