# DNS Scout

این پروژه یک pipeline سه‌مرحله‌ای برای پیدا کردن DNSهای فعال از روی دیتای ZIP/CSV است:

1. استخراج فایل‌های ZIP
2. استخراج و فیلتر CIDRها از CSV
3. اسکن IPها و ذخیره IPهای DNS فعال

## شروع

### گام 1: بررسی و نصب پایتون
اگر پایتون را نصب ندارید، میتوانید از لینک‌های زیر، دانلود و نصب کنید:
- [سایت اصلی پایتون](https://www.python.org/downloads/)
- سایت‌های داخلی:
  - [soft98.ir](https://soft98.ir/software/programming/16260-python.html)
  - [yasdl.com](https://www.yasdl.com/102171/%D8%AF%D8%A7%D9%86%D9%84%D9%88%D8%AF-python.html)
  - [p30download.ir](https://p30download.ir/fa/entry/36554/python)
  - [asandownload.ir](https://asandownload.ir/software/entry/7370/)

### گام 2: نصب پکیج `pandas`
در برنامه‌ی cmd ویندوز یا terminal لینوکس، فرمان زیر را بنویسید:
```bash
pip install pandas
```
اگر به دلیل مشکلات ناشی از محدودیت اینترنت در ایران، نتوانستید از طریق کد فوق، این وابستگی را نصب کنید، به صورت زیر از Mirror استفاده کنید:
```bash
pip install -i https://mirror-pypi.runflare.com/simple pandas
```

### گام 3: اجرای برنامه
برای اجرای کامل برنامه، در مسیری که کدهای این پروژه را قرار دادید، در برنامه‌ی cmd ویندوز یا terminal لینوکس، فرمان زیر را بنویسید:
```bash
python main.py
```

> تمامی DNSهایی که در طول اسکن یافت می‌شوند، در مسیری که کدهای این پروژه را قرار دادید، در فایل `live_dns.txt` ذخیره می‌شوند.

## ساختار فایل‌ها

- `main.py`: اجرای یکپارچه کل pipeline
- `zip_extractor.py`: استخراج همه ZIPهای داخل `source`
- `csv_extractor.py`: استخراج/فیلتر CSV بر اساس فایل کانفیگ
- `scanner.py`: اسکن DNS روی IPهای تولیدشده
- `csv_extractor_config.json`: تنظیمات مرحله CSV extraction
- `scanner_config.json`: تنظیمات مرحله DNS scan

## پیش‌نیازها

- Python 3.10+
- پکیج `pandas`

نصب وابستگی:

```bash
pip install pandas
```
اگر به دلیل مشکلات ناشی از محدودیت اینترنت در ایران، نتوانستید از طریق کد فوق، این وابستگی را نصب کنید، به صورت زیر از Mirror استفاده کنید:
```bash
pip install -i https://mirror-pypi.runflare.com/simple pandas
```

## نحوه اجرای اصلی

اجرای کامل pipeline:

```bash
python main.py
```

با مسیرهای سفارشی:

```bash
python main.py --source-dir source --csv-config csv_extractor_config.json --scanner-config scanner_config.json --output-file live_dns.txt
```

## حالت تست

برای تست end-to-end بدون وابستگی به دیتای واقعی:

```bash
python main.py --test
```

در حالت تست:

- داده موقت ساخته می‌شود.
- ZIP تستی تولید و extract می‌شود.
- CSV فیلتر می‌شود.
- اسکن DNS به‌صورت mock اجرا می‌شود.
- خروجی بررسی می‌شود و نتیجه پاس/فیل مشخص می‌شود.

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

رفتار resume:

- اگر fingerprint فایل منبع تغییر نکرده باشد، برنامه به انگلیسی می‌پرسد:
  - `Continue from last scan? (y/N)`
- اگر `y/yes` بزنید، از نقطه قبلی ادامه می‌دهد.
- در غیر این صورت از اول شروع می‌کند.


نکته:

- `main.py` بعد از مرحله CSV، فایل ورودی scanner را خودکار روی خروجی جدید تنظیم می‌کند.
- اسکنر به‌صورت stream-based اجرا می‌شود و IPها را یکجا در RAM نگه نمی‌دارد.
- هر IP تاییدشده (`CONFIRMED`) همان لحظه در فایل خروجی نوشته می‌شود.

## لاگ‌های اسکن

در زمان scan، برای هر IP لاگ چاپ می‌شود:

- وضعیت شروع اسکن (`[START]`)
- اولین IP اسکن‌شده (`[FIRST-SCAN]`)
- وضعیت هر IP (`[SCAN] ... RESULT: CONFIRMED/REJECTED/ERROR`)
- شمارنده تجمعی `CONFIRMED` و `REJECTED`

## خروجی نهایی

فایل خروجی اسکن:

- `live_dns.txt`

هر خط شامل یک IP فعال DNS است.

## نکات کارایی

- اگر رنج CIDR خیلی بزرگ باشد، تعداد IPها بسیار زیاد می‌شود و زمان scan بالا می‌رود.
- برای شروع، `max_workers` و `timeout` را محافظه‌کارانه تنظیم کنید.
- برای نتایج دقیق‌تر، چند بار اسکن را تکرار کنید.

## سلب مسئولیت (Disclaimer)

- این ابزار فقط برای استفاده قانونی، اخلاقی، و دارای مجوز طراحی شده است.
- هرگونه استفاده غیرمجاز، مخرب، یا ناقض قوانین محلی/بین‌المللی، کاملاً بر عهده کاربر است.
- توسعه‌دهنده این پروژه هیچ مسئولیتی در قبال سوءاستفاده، خسارت مستقیم یا غیرمستقیم، قطع سرویس، نقض امنیت، یا پیامدهای حقوقی ناشی از استفاده از این ابزار ندارد.
- با استفاده از این برنامه، شما تأیید می‌کنید که مسئولیت کامل نحوه استفاده و نتایج آن را می‌پذیرید.

## منبع داده‌های پیش‌فرض CIDR

- [lite.ip2location.com](https://lite.ip2location.com/)
