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

لا يحتوي تطبيق iOS على M3SB package token أو HMAC secret. يرسل التطبيق المفتاح ومعرّف الجهاز إلى خادم VesperDash عبر HTTPS؛ الخادم وحده يتصل بـM3SB ويوقّع الطلب، ثم يصدر جلسة قصيرة العمر عند نجاح التحقق. تتطلب قائمة الحزم والتنزيلات جلسة Bearer صالحة.

لا تُضف أسراراً إلى `Info.plist` أو Xcode build settings أو GitHub Actions أو التطبيق. إخفاء نص عنوان API داخل التطبيق لا يمنع اكتشافه من حركة الشبكة؛ الحماية الفعلية تعتمد على TLS والتحقق على الخادم. راجع [`vesperdash/README.md`](vesperdash/README.md) لمتغيرات VPS المطلوبة وخطوات التحديث. بما أن ملفات IPA السابقة احتوت بيانات اعتماد M3SB، ينبغي تدويرها وإبطالها قبل نشر تحديث الخادم.

## البناء

يتطلب بناء IPA جهاز macOS مع Xcode. شغّل:

```bash
./build_unsigned.sh
```

أو استخدم GitHub Actions من خلال `.github/workflows/build.yml`. Workflow البناء لا يحتاج أسرار M3SB، وينتج IPA غير موقّع باسم `VESPER-Build-9-unsigned.ipa` بعد نجاح الاختبارات. افتراضياً يضيف سكربت البناء 150,000,000 بايت من النقاط إلى نهاية الملف التنفيذي، ثم يضغط IPA بخيار ZIP الأقصى (`-9`). هذا حشو غير مستخدم: يزيد المساحة بعد فك التطبيق/تثبيته بنحو 150MB، بينما الحجم المضغوط النهائي يعتمد على ملفات التطبيق ولا يمكن ضمان أنه 2MB قبل تشغيل بناء macOS. لتعطيل الحشو استخدم `VESPER_EXECUTABLE_PADDING_MB=0`.
