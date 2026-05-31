# DNS Scout

## شروع در Ubuntu
### روش اول
کد زیر را اجرا کنید تا نصب خودکار، آغاز شود:

```bash
curl -fsSL https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/install_online.sh | bash
```
یا به کمک پروکسی http:
```bash
export http_proxy="http://<your proxy ip>:<your proxy port>"
export https_proxy="http://<your proxy ip>:<your proxy port>"
export no_proxy="localhost,127.0.0.1,::1,mirror-linux.runflare.com,mirror.arvancloud.ir,linux-mirror.liara.ir,repo.abrha.net,ubuntu.hostiran.ir,archive.ubuntu.petiak.ir,archive.ubuntu.petiak.ir,ubuntu-mirror.kimiahost.com,ir.ubuntu.sindad.cloud,mirror.faraso.org,mirror.aminidc.com,mirrors.pardisco.co,mirror.0-1.cloud,linuxmirrors.ir,repo.iut.ac.ir,ubuntu.shatel.ir,ubuntu.byteiran.com,mirror.rasanegar.com,mirror-pypi.runflare.com,package-mirror.liara.ir,mirror.abrha.net,pypi.runflare.com,package-mirror.liara.ir,mirror.abrha.net,pypi.mirrors.chabokan.com,pypi.tuna.tsinghua.edu.cn,mirrors.aliyun.com,pypi.mirrors.ustc.edu.cn"

curl -fsSL https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/install_online.sh | bash
```
روند نصب:
1. ابتدا source codeهای پروژه دریافت و ذخیره می‌شود.
2. سپس، از شما (`username`) و رمز عبور (`password`) پنل را دریافت می‌شود.
3. یک `port` آزاد و تصادفی برای پنل پیشنهاد میشود (که میتوانید آن را تأیید کنید و یا پورت دلخواه خود را وارد کنید)
4. سرویس `dns-scout.service` را نصب و اجرا می‌شود.
5. آدرس پنل را نمایش میشود و پنل، راه‌اندازی می‌شود.

### روش دوم
- ابتدا فایل zip این پروژه را دریافت کنید.
- سپس، آن را در مسیر دلخواه خود extract کنید
- در مسیر پروژه، فرمان زیر را وارد کنید:
```bash
sudo bash install.sh
```

روند نصب:
1. از شما (`username`) و رمز عبور (`password`) پنل را دریافت می‌شود.
2. یک `port` آزاد و تصادفی برای پنل پیشنهاد میشود (که میتوانید آن را تأیید کنید و یا پورت دلخواه خود را وارد کنید)
4. سرویس `dns-scout.service` را نصب و اجرا می‌شود.
5. آدرس پنل نمایش میشود و پنل، راه‌اندازی میشود.
## CLI تغییر نام کاربری/رمز پنل

بعد از نصب، برای تغییر `username/password` بدون نصب مجدد:

```bash
sudo /opt/dns-scout/.venv/bin/python /opt/dns-scout/manage_panel_auth.py --config /opt/dns-scout/panel_config.json
```

نکته:
- اگر پارامتر ندهید، اسکریپت به‌صورت تعاملی username/password جدید را می‌گیرد.
- بعد از تغییر، سرویس را ری‌استارت کنید:

```bash
sudo systemctl restart dns-scout.service
```


## پنل 

###  اسکن IPها
در این قسمت، میتوانید تمامی IPهایی که در قسمت منابع، قرار داده شده را اسکن کنید.
### تست DNSهای یافت‌شده 
در این قسمت، میتوانید تمامی DNSهایی که در قسمت `اسکن IPها` یافت شده‌اند را دریافت و یا آنها را بر اساس عملکردشان، اسکن کنید  

### منابع
در این قسمت، میتوانید فایل csv دلخواه خود را اضافه و یا آن را حذف و غیر فعال کنید.
همچنین، در قسمت `تنظیم استخراج`، میتوانید چگونگی پیدا کردن رکوردها و ستون فایل‌های csv را (که بخشی از فایل `csv_extractor_config.json` هست) تغییر دهید.

## Uninstall

برای حذف سرویس نصب‌شده و بازنشانی وضعیت نصب سیستم (بدون حذف فایل‌های پروژه‌ای که در ابتدا clone شده):

```bash
sudo bash ./uninstall.sh
```

## تنظیمات CSV Extraction

فایل: `csv_extractor_config.json`

نمونه:

```json
{
  "target_directory": "./source",
  "output_file": "filtered_CIDR_database.csv",
  "csv_read_options": {
    "encoding": "utf-8",
    "delimiter": ",",
    "header": false
  },
  "default_rule": {
    "filter": {
      "logic": "AND",
      "conditions": [
        { "column": "2", "operator": "equals", "value": "Iran (Islamic Republic of)" }
      ]
    },
    "columns_to_extract": ["0"]
  },
  "file_rules": [],
  "output_deduplicate": {
    "enabled": true,
    "columns": [0],
    "keep": "first"
  },
  "output_format": {
    "encoding": "utf-8",
    "delimiter": ",",
    "index": false
  }
}
```

کلیدها:

- `target_directory`: مسیر جستجوی CSVها
- `output_file`: فایل خروجی مرحله استخراج CIDR
- `csv_read_options`: تنظیمات پایه خواندن CSV
- `default_rule`: قانون پیش‌فرض برای فایل‌هایی که rule خاص ندارند
- `file_rules`: قوانین خاص بر اساس `filename_pattern`
- `output_deduplicate`: حذف رکوردهای تکراری
- `output_format`: تنظیمات نوشتن CSV خروجی

خروجی پیش‌فرض این مرحله در این پروژه:

- `filtered_CIDR_database.csv`

## تنظیمات DNS Scanner

فایل: `scanner_config.json`

نمونه:

```json
{
  "csv_file": "filtered_CIDR_database.csv",
  "output_file": "live_dns.txt",
  "cidr_column": "subnet",
  "timeout": 1.5,
  "max_workers": 200,
  "max_in_flight": 800,
  "query_domain": "google.com",
  "query_type": "A",
  "resume_enabled": true,
  "resume_meta_file": ".scanner_resume_meta.json",
  "resume_db_file": ".scanner_progress.sqlite3"
}
```

کلیدها:

- `csv_file`: فایل ورودی CIDR
- `output_file`: فایل خروجی IPهای DNS تاییدشده
- `cidr_column`: نام ستون CIDR
- `timeout`: timeout هر درخواست UDP
- `max_workers`: تعداد worker thread
- `max_in_flight`: تعداد jobهای همزمان در صف
- `query_domain`: دامنه مبنای تست DNS
- `query_type`: نوع رکورد (`A` یا `AAAA`)
- `resume_enabled`: فعال بودن حالت ادامه اسکن
- `resume_meta_file`: فایل fingerprint/metadata اسکن قبلی
- `resume_db_file`: دیتابیس SQLite پیشرفت اسکن

نکته:

- `main.py` بعد از مرحله CSV، فایل ورودی scanner را خودکار روی خروجی جدید تنظیم می‌کند.
- اسکنر به‌صورت stream-based اجرا می‌شود و IPها را یکجا در RAM نگه نمی‌دارد.
- هر IP تاییدشده (`CONFIRMED`) همان لحظه در فایل خروجی نوشته می‌شود.

## خروجی نهایی

فایل خروجی اسکن:

- `live_dns.txt`

هر خط شامل یک IP فعال DNS است.

## سلب مسئولیت (Disclaimer)

- این ابزار فقط برای استفاده قانونی، اخلاقی، و دارای مجوز طراحی شده است.
- هرگونه استفاده غیرمجاز، مخرب، یا ناقض قوانین محلی/بین‌المللی، کاملاً بر عهده کاربر است.
- توسعه‌دهنده این پروژه هیچ مسئولیتی در قبال سوءاستفاده، خسارت مستقیم یا غیرمستقیم، قطع سرویس، نقض امنیت، یا پیامدهای حقوقی ناشی از استفاده از این ابزار ندارد.
- با استفاده از این برنامه، شما تأیید می‌کنید که مسئولیت کامل نحوه استفاده و نتایج آن را می‌پذیرید.

## منبع داده‌های پیش‌فرض CIDR

- [lite.ip2location.com](https://lite.ip2location.com/)
