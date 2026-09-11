# HYperRegedit / 3105

هذا هو المشروع الكامل المرسل في أرشيف MediaFire، وليس نموذجًا جديدًا. يحتوي على مشروع Xcode الأصلي، الشاشات، الخدمات، الأصول، ملفات الـpatch، ووحدات العمل الداخلية.

## البنية

- `ThreeOneOSFive/views`: واجهات التطبيق ونظام التصميم.
- `ThreeOneOSFive/helpers`: الخدمات الداخلية مثل إدارة الملفات، المشاريع، التنظيف، التخزين، الأرشفة، وإدارة التفعيل.
- `ThreeOneOSFive/Assets.xcassets`: الأيقونات والصور والخلفيات.
- `ThreeOneOSFive/Patches`: حزم patch المضمنة في التطبيق.
- `ThreeOneOSFive/exploit` و`ThreeOneOSFive/kexploit`: ملفات الدعم الأصلية للمشروع كما وردت في المصدر.
- `ThreeOneOSFive.xcodeproj`: مشروع Xcode الكامل.
- `build_unsigned.sh`: بناء IPA غير موقّع على macOS.

## التفعيل

يستعمل التطبيق الآن تحقق M3SB API موقّعًا عبر `/api/sdk/verify` داخل `helpers/LicenseManager.swift`، مع ربط الجهاز بـKeychain والتحقق من توقيع استجابة الخادم قبل فتح التطبيق.

لا تضع `token` أو `hmac_secret` داخل المصدر أو `Info.plist` بشكل مباشر. مررهما كإعدادات build:

```bash
xcodebuild ... M3SB_PACKAGE_TOKEN="$M3SB_PACKAGE_TOKEN" M3SB_HMAC_SECRET="$M3SB_HMAC_SECRET"
```

في Xcode يمكن وضع القيم في User-Defined Settings محلية غير مرفوعة للمستودع. إذا بقيت القيم placeholders، سيبقى التطبيق مغلقًا ويعرض أن API غير مهيأة.

## البناء

يتطلب البناء جهاز macOS مع Xcode. يمكن تشغيل:

```bash
./build_unsigned.sh
```

ثم استخدام GitHub Actions من خلال Workflow البناء الموجود في `.github/workflows/build.yml`.
