# VESPER

هذا هو المشروع الكامل المرسل في أرشيف MediaFire، ويحتوي على مشروع Xcode الأصلي والواجهات والخدمات والأصول.

## البنية

- `ThreeOneOSFive/views`: واجهات التطبيق ونظام التصميم.
- `ThreeOneOSFive/helpers`: خدمات الملفات والمشاريع والتفعيل والمزامنة.
- `ThreeOneOSFive/Assets.xcassets`: الأيقونات والصور والخلفيات.
- `ThreeOneOSFive/Patches`: حزم patch المحلية.
- `ThreeOneOSFive/exploit` و`ThreeOneOSFive/kexploit`: ملفات الدعم الأصلية للمشروع.
- `ThreeOneOSFive.xcodeproj`: مشروع Xcode.
- `build_unsigned.sh`: بناء IPA غير موقّع على macOS.

## أمان التفعيل

التطبيق يرسل تحقق M3SB مباشرةً من iOS، ثم يرسل رد M3SB الموقّع إلى VesperDash ليصدر الخادم جلسة قصيرة العمر لتنزيل الكتالوج والحزم. الـPackage Token وHMAC Secret يُحقنان وقت البناء من GitHub Actions secrets ويُخزنان بصيغة XOR/Base64 مموهة داخل IPA.

**التمويه ليس تشفيرًا آمنًا:** يمكن استخراج القيم من IPA. اختير هذا المسار بعد أن كان طلب VPS إلى M3SB يُرفض بـ403، مع قبول المستخدم لمخاطرة استخراج الأسرار. لا تضع القيم في المصدر أو المحادثات، ودوّرها إذا أردت إلغاء صلاحية نسخ IPA القديمة.

راجع [`vesperdash/README.md`](vesperdash/README.md) لمسار إصدار جلسة VesperDash ونشر الخادم مع أو بدون تدوير القيم.

## البناء

يتطلب بناء IPA جهاز macOS مع Xcode. يتطلب `build_unsigned.sh` المتغيرين `M3SB_PACKAGE_TOKEN` و`M3SB_HMAC_SECRET` في بيئة البناء؛ لا يطبع السكربت القيم. شغّل:

```bash
./build_unsigned.sh
```

أو استخدم GitHub Actions عبر `.github/workflows/build.yml` بعد ضبط الاسمين أعلاه كـGitHub Actions secrets. ينتج البناء ملفًا غير موقّع باسم `VESPER-Build-10-unsigned.ipa` ويتحقق من غياب النص الخام للقيم داخل التطبيق.

يضيف البناء 150,000,000 بايت من النقاط إلى نهاية الملف التنفيذي، ثم يضغط IPA بأقصى مستوى ZIP (`-9`). هذا الحشو غير مستخدم؛ يزيد مساحة التطبيق بعد فكّه بنحو 150MB، بينما الحجم المضغوط النهائي يعتمد على بقية الملفات ولا يمكن ضمان أنه 2MB قبل تشغيل البناء. لتعطيل الحشو استخدم `VESPER_EXECUTABLE_PADDING_MB=0`.
