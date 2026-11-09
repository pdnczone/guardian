# Guardian 🛡️

**Traffic & Connection Flood Circuit Breaker for Linux Proxy & Tunnel Nodes**  
Designed for servers running X-UI, Xray, FRPS/FRPC, Backhaul, and Hashem Panel.

---

### چرا گاردین؟ (Why Guardian?)

خیلی وقتا به خاطر لو رفتن یک کانفیگ، سابسکریپشن عمومی، بات‌های اسکنر یا حملات Flood، سرور در عرض چند ساعت صدها گیگابایت یا چند ترابایت ترافیک می‌سوزاند و پهنای باند را به سقف می‌رساند.

گاردین مثل یک فیوز هوشمند (Circuit Breaker) عمل می‌کند:
1. **محدودسازی اتصالات همزمان هر IP (`connlimit`)**: هیچ آی‌پی اجازه ندارد بیشتر از ۳۵ کانکشن همزمان روی پورت‌های پروکسی/تانل باز کند.
2. **محافظت از پورت‌های داخلی تانل**: پورت‌های داخلی تانل (مثل 1020 تا 1050) را روی اینترفیس عمومی اینترنت می‌بندد تا فقط از طریق لوکال‌هاست/تانل قابل دسترس باشند.
3. **قطع خودکار در صورت اشباع پهنای باند**: اگر سرور بیش از ۳ دقیقه مداوم با پهنای باند بالای ۱۸۰ مگابیت اشباع شود، تانل/سرویس را ریستارت می‌کند تا لوپ یا دانلودهای اسپم قطع شوند.
4. **جلوگیری از سیل کانکشن (Connection Flood Guard)**: اگر تعداد کانکشن‌های فعال به بیش از ۴۵۰۰ برسد، سریعاً جلوی کرش کردن سرور را می‌گیرد.

---

## نصب سریع با یک دستور (One-Line Install)

```bash
curl -fsSL https://raw.githubusercontent.com/pdnczone/guardian/main/guardian.sh | bash
```

یا با کلون ریپازیتوری:
```bash
git clone https://github.com/pdnczone/guardian.git
cd guardian
chmod +x guardian.sh
./guardian.sh install
```

---

## دستورات مدیریتی (CLI Commands)

پس از نصب، دستور `guardian` در هر کجای ترمینال در دسترس است:

```bash
# مشاهده وضعیت زنده، سرعت اینترفیس، تعداد کانکشن و رول‌های فایروال
guardian status

# اعمال مجدد رول‌های فایروال
guardian firewall

# اجرای دستی بررسی وضعیت
guardian run

# حذف کامل گاردین
guardian uninstall
```

---

## تنظیمات (Configuration)

فایل تنظیمات در مسیر `/etc/guardian/guardian.conf` ذخیره می‌شود:

```bash
# اینترفیس شبکه (پیش‌فرض: auto)
IFACE="auto"

# حداکثر تعداد کانکشن همزمان قبل از تریگر فیوز
MAX_CONNS=4500

# سقف مگابیت بر ثانیه مجاز
MAX_MBPS=180

# تعداد دفعات بررسی مداوم سرعت قبل از قطع موقت (هر بار ۱ دقیقه)
MAX_STREAK=3

# پورت‌های محافظت‌شده فایروال
PROTECTED_PORTS="1020,1030,1040,1050,7443,9443"

# حداکثر کانکشن همزمان به ازای هر IP کاربر
CONN_LIMIT_PER_IP=35

# سرویس‌هایی که هنگام بحران ریستارت می‌شوند
RESTART_SERVICES="frps frpc"
```

---

## لایسنس (License)

توسعه‌داده‌شده برای کامیونیتی **PDNC ZONE** (@pdnczone). تحت لایسنس MIT.
