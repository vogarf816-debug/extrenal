# VESPER

المستودع يحتوي على تطبيق iOS وواجهة VesperDash وخدمة Flask وملفات البناء والنشر.

## البنية

- `ThreeOneOSFive`: تطبيق SwiftUI وموارد التطبيق ومساعداته.
- `ThreeOneOSFive.xcodeproj`: مشروع Xcode.
- `vesperdash`: خادم Flask ولوحة الإدارة وسكريبتات النشر.
- `build_unsigned.sh`: بناء IPA غير موقّع على macOS.

## أمان التفعيل

يرسل التطبيق مفتاح الترخيص ومعرّف الجهاز إلى `POST /api/client/session` فقط. يتحقق خادم VesperDash من الترخيص مع M3SB باستخدام الأسرار الموجودة على VPS في `/etc/vesperdash.env`، ثم يعيد جلسة قصيرة العمر للتطبيق. مفاتيح M3SB لا تُضمّن في IPA ولا تُمرر إلى GitHub Actions أثناء البناء. مسار التوافق القديم `/api/client/session/bridge` معطّل.

قوائم patches وكلمات مرور `.3105` والتنزيلات تتطلب جلسة Bearer صالحة. تُخزن الحزم البعيدة محلياً في مخزن AES-GCM، لكن أي بيانات يجب أن تصل إلى جهاز العميل يمكن استخراجها من جهاز مكسور الحماية أو بعد عكس التطبيق؛ لا يوجد تمويه يضمن إخفاءً تشفيرياً عن مالك الجهاز.

يُموّه التطبيق نص عنوان VesperDash لتقليل ظهوره في البحث النصي فقط. لا يمكن إخفاء عنوان خدمة يحتاج التطبيق للاتصال بها عن فحص الشبكة أو الهندسة العكسية؛ الحماية الفعلية هي التحقق من الترخيص والجلسات والصلاحيات على الخادم. يجب تدوير أي M3SB credentials سبق تضمينها في إصدار قديم.

راجع [`vesperdash/README.md`](vesperdash/README.md) لإعداد أسرار الخادم والنشر.

## لوحة الإدارة

تسجيل الدخول إلى Control Center يتم باستخدام اسم المستخدم وكلمة المرور. تمت إزالة خيار إدخال legacy admin token من واجهة الويب. خيار `--new-admin` يولّد username/password جديدين، يعطّل legacy token، ويبطل جلسات إدارة VESPER القديمة؛ حساب Jefry منفصل ولا يتغير.

## البناء

يتطلب بناء IPA جهاز macOS مع Xcode. لا يحتاج بناء التطبيق إلى أي M3SB token أو HMAC secret:

```bash
./build_unsigned.sh
```

ينتج `build/VESPER-Build-35-unsigned.ipa` باستخدام scheme `3105`. يتأكد workflow من عدم وجود مفاتيح M3SB أو عناوين upstream الخام في الحزمة. الـIPA غير موقّع ويحتاج إلى توقيع بالطريقة المعتادة قبل تثبيته.

يعمل GitHub Actions عند الدفع إلى `main` أو عبر التشغيل اليدوي، ولا يحتاج Secrets لمفاتيح M3SB. بعد نجاحه ينشر ملف IPA كأصل إصدار GitHub.

## نشر VesperDash وإنشاء بيانات دخول جديدة

شغّل هذا الأمر مرة واحدة من Terminal تفاعلي على VPS بصلاحية root:

```bash
curl -fsSL https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/deploy_from_vps.sh | sudo bash -s -- --new-admin
```

بعد التأكد من تدوير M3SB credentials الموجودة على VPS، أدخل `ROTATED` ثم `DEPLOY` عند الطلب؛ لا يُطلب منك إدخال أي token أو كلمة مرور في الدردشة. بعد نجاح النشر سيُنشأ username/password جديدان، ويُعرضان مرة واحدة في Terminal ديال VPS — احتفظ بهما ثم استعملهما في حقلي Username وPassword في لوحة VesperDash. سيُعطّل السكريبت legacy admin token، ويبطل جلسات إدارة VESPER القديمة، ويحافظ على بيانات Jefry منفصلة. يحتفظ بنسخة احتياطية من `/etc/vesperdash.env` ولا يطبع أسرار M3SB.

إذا لم تدوّر M3SB credentials التي ظهرت في IPA قديم، لا تؤكد `ROTATED`: دوّرها أولاً عند M3SB وحدّثها في environment الآمن على VPS. لا تستخدم وضع الإبقاء على أسرار قديمة مكشوفة.

يحتفظ تحديث VPS ببيانات `/opt/vesperdash/data`، ويشغّل الاختبارات وفحوص health وواجهات الوصول المحمية قبل اعتبار النشر ناجحاً.

## API routes

- `POST /api/client/session`: تحقق server-side وإصدار جلسة قصيرة.
- `POST /api/client/session/logout`: إلغاء جلسة العميل.
- `GET /api/patches` و`GET /api/patches/:id/download`: يتطلبان جلسة Bearer.
- `/api/auth/login` و`/api/admin/*`: جلسة لوحة الإدارة وعملياتها.

اختبارات الخادم:

```bash
python3 -m unittest discover -s vesperdash -v
```
