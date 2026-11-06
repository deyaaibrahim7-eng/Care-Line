# Care Line — خطوات التشغيل (مجاني 100%)

المحتويات:
- `index.html` — موقع المريض (Care Line)
- `nurse/index.html` — لوحة الممرضة (Care Line - Dashboard)
- `config.js` — إعدادات الربط (تعدّله مرة واحدة)
- `supabase/schema.sql` — قاعدة البيانات والصلاحيات

## 1) قاعدة البيانات (Supabase – الخطة المجانية)
1. أنشئ حسابًا على supabase.com ثم مشروعًا جديدًا (Free).
2. من القائمة: **SQL Editor** ← New query ← الصق محتوى `supabase/schema.sql` ← Run.
3. من **Authentication ← Providers ← Email**: أوقف خيار **Confirm email** (لأن المريض يسجّل برقم الموبايل لا ببريد حقيقي).
4. من **Project Settings ← API** انسخ: `Project URL` و `anon public key`.

## 2) الإعدادات
افتح `config.js` وضع القيمتين في `supabaseUrl` و `supabaseKey`. يمكنك أيضًا وضع رقم واتساب الممرضة في `nurseWhatsapp`.
> مفتاح anon آمن للنشر العلني، لأن الحماية تتم داخل قاعدة البيانات (RLS).
> إن رفض Supabase النطاق `careline.app` في البريد الافتراضي، غيّر `phoneEmailDomain` إلى نطاق آخر مثل `example.com` **قبل** تسجيل أول مريض.

## 3) النشر على Vercel
ارفع هذا المجلد كاملًا إلى مستودع GitHub، ثم من vercel.com اختر Add New ← Project ← استورد المستودع ← Deploy (دون أي إعدادات إضافية).
- موقع المريض: `https://اسم-مشروعك.vercel.app/`
- لوحة الممرضة: `https://اسم-مشروعك.vercel.app/nurse/`

## 4) إنشاء حساب الممرضة
1. افتح **Authentication ← Users ← Add user** وأنشئ مستخدمًا ببريد وكلمة مرور (فعّل Auto Confirm).
2. من SQL Editor نفّذ (بعد تعديل البريد والاسم):
```sql
update public.profiles set role='nurse', full_name='اسم الممرضة'
where id=(select id from auth.users where email='nurse@example.com');
```
3. ادخل إلى لوحة الممرضة بهذا البريد.

## ملاحظات
- المريض لا يستطيع ترقية نفسه إلى ممرضة: الدور يُحدَّد من قاعدة البيانات فقط.
- المشاريع المجانية في Supabase تتوقف بعد نحو أسبوع دون أي استخدام؛ يكفي فتح الموقع أو الضغط على Restore في لوحة Supabase.
- لا تفتح موقع المريض ولوحة الممرضة بحسابين في المتصفح نفسه في وقت واحد، فالجلسة تُحفظ لكل نطاق؛ استخدم متصفحين أو نافذة خاصة.
- بدون ملء `config.js` يعمل الموقع بنسخة تجريبية محلية على الجهاز فقط (للعرض).
