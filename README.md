# DNS Scout

[![Python 3.9+](https://img.shields.io/badge/Python-3.12%2B-blue?logo=python&logoColor=white)](https://www.python.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

## فهرست
- [شروع](#شروع)
	- [Ubuntu](#ubuntu)
		- [روش آنلاین](#روش-آنلاین)
		- [روش آفلاین](#روش-آفلاین)
	- [Windows](#windows)
		- [روش آنلاین](#روش-آنلاین-1)
		- [روش آفلاین](#روش-آفلاین-1)
	- [Android](#android)
		- [روش آنلاین](#روش-آنلاین-2)
		- [روش آفلاین](#روش-آفلاین-2)
- [CLI تغییر نام کاربری/رمز پنل](#cli-تغییر-نام-کاربریرمز-پنل)
- [بازگردانی لینک پنل](#بازگردانی-لینک-پنل)
- [پنل](#پنل)
	- [اسکن IPها](#اسکن-ipها)
	- [تست DNSهای یافت‌شده](#تست-dnsهای-یافتشده)
	- [منابع](#منابع)
- [Uninstall](#uninstall)
	- [فرمان حذف در Ubuntu](#فرمان-حذف-در-ubuntu)
	- [فرمان حذف در Windows](#فرمان-حذف-در-windows)
	- [فرمان حذف در Android](#فرمان-حذف-در-android)
- [تنظیمات CSV Extraction](#تنظیمات-csv-extraction)
- [تنظیمات DNS Scanner](#تنظیمات-dns-scanner)
- [خروجی نهایی](#خروجی-نهایی)
- [سلب مسئولیت (Disclaimer)](#سلب-مسئولیت-disclaimer)
- [منبع داده‌های پیش‌فرض CIDR](#منبع-دادههای-پیشفرض-cidr)

## شروع
### Ubuntu
#### روش آنلاین
کد زیر را اجرا کنید تا نصب خودکار، آغاز شود:

```bash
curl -fsSL https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/install_online_ubuntu.sh | bash
```
یا به کمک پروکسی http:
```bash
curl -x http://PROXY_IP:PORT -fsSL https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/install_online_ubuntu.sh | bash
```
یا به کمک پروکسی Socks:
```bash
curl --socks5 PROXY_IP:PORT -fsSL https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/install_online_ubuntu.sh | bash
```
روند نصب:
1. ابتدا source codeهای پروژه دریافت و ذخیره می‌شود.
2. سپس، از شما (`username`) و رمز عبور (`password`) پنل را دریافت می‌شود.
3. یک `port` آزاد و تصادفی برای پنل پیشنهاد میشود (که میتوانید آن را تأیید کنید و یا پورت دلخواه خود را وارد کنید)
4. سرویس `dns-scout.service` را نصب و اجرا می‌شود.
5. آدرس پنل را نمایش میشود و پنل، راه‌اندازی می‌شود.

#### روش آفلاین
- ابتدا فایل zip این پروژه را دریافت کنید و یا از mirrorهای داخلی، clone کنید.
- سپس، آن را در مسیر دلخواه خود extract کنید
- در مسیر پروژه، فرمان زیر را وارد کنید:
```bash
sudo bash install_ubuntu.sh
```

روند نصب:
1. از شما (`username`) و رمز عبور (`password`) پنل را دریافت می‌شود.
2. یک `port` آزاد و تصادفی برای پنل پیشنهاد میشود (که میتوانید آن را تأیید کنید و یا پورت دلخواه خود را وارد کنید)
4. سرویس `dns-scout.service` را نصب و اجرا می‌شود.
5. آدرس پنل نمایش میشود و پنل، راه‌اندازی میشود.

### Windows

#### روش آنلاین
کد زیر را اجرا کنید تا نصب خودکار آغاز شود:

```powershell
curl -o install_online_windows.ps1 https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/install_online_windows.ps1
powershell -ExecutionPolicy Bypass -File .\install_online_windows.ps1
```

اگر لازم باشد از پراکسی استفاده کنید:

```powershell
curl -x http://PROXY_IP:PORT -o install_online_windows.ps1 https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/install_online_windows.ps1
powershell -ExecutionPolicy Bypass -File .\install_online_windows.ps1
```

```powershell
curl --socks5 PROXY_IP:PORT -o install_online_windows.ps1 https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/install_online_windows.ps1
powershell -ExecutionPolicy Bypass -File .\install_online_windows.ps1
```

روند نصب:
1. سورس پروژه ابتدا دانلود و در مسیر نصب ویندوز کپی می‌شود.
2. اگر Python نصب نباشد، نصب یا از نسخه موجود استفاده می‌شود.
3. محیط مجازی و وابستگی‌ها ساخته و نصب می‌شوند.
4. فایل `panel_config.json` ساخته می‌شود و اطلاعات ورود پنل از شما گرفته می‌شود.
5. اجرای خودکار با یک Scheduled Task در Startup تنظیم می‌شود و Ruleهای فایروال هم اضافه می‌شوند.
6. در پایان، آدرس پنل و مسیرهای مدیریتی نمایش داده می‌شود.

#### روش آفلاین
- اگر مخزن را از قبل clone کرده‌اید یا فایل ZIP را استخراج کرده‌اید، وارد ریشه پروژه شوید و این دستور را اجرا کنید:

```powershell
powershell -ExecutionPolicy Bypass -File .\install_windows.ps1
```

روند نصب:
1. فایل‌های پروژه در `%ProgramData%\dns-scout` کپی می‌شوند.
2. اگر لازم باشد Python نصب یا استفاده می‌شود.
3. محیط مجازی و وابستگی‌ها نصب می‌شوند.
4. `panel_config.json` ساخته می‌شود و اطلاعات ورود پنل از شما گرفته می‌شود.
5. Scheduled Task اجرا و برای startup ثبت می‌شود.
6. Ruleهای فایروال ایجاد می‌شوند و در پایان، آدرس پنل نمایش داده می‌شود.

### Android
پیش‌نیاز این بخش، نصب Termux روی دستگاه اندروید است.

#### روش آنلاین
کد زیر را اجرا کنید تا نصب خودکار آغاز شود:

```bash
curl -fsSL https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/online_install_termux_android.sh | bash
```

اگر لازم باشد از پراکسی استفاده کنید:

```bash
curl -x http://PROXY_IP:PORT -fsSL https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/online_install_termux_android.sh | bash
```

```bash
curl --socks5 PROXY_IP:PORT -fsSL https://raw.githubusercontent.com/SAMPA-ASA/dns-scout/main/online_install_termux_android.sh | bash
```

روند نصب:
1. سورس پروژه از مخزن اصلی clone می‌شود.
2. فایل‌ها در مسیر `~/.dns-scout` کپی می‌شوند.
3. Python، virtualenv و وابستگی‌های لازم در Termux آماده می‌شوند.
4. فایل `panel_config.json` ساخته می‌شود و اطلاعات ورود پنل از شما گرفته می‌شود.
5. پنل با اسکریپت‌های `dns-scout-start`، `dns-scout-stop` و `dns-scout-status` مدیریت می‌شود.
6. در پایان، آدرس پنل و دستورهای کنترلی نمایش داده می‌شوند.

#### روش آفلاین
- اگر مخزن را از قبل clone کرده‌اید یا فایل ZIP را استخراج کرده‌اید، وارد ریشه پروژه شوید و این دستور را اجرا کنید:

```bash
bash install_termux_android.sh
```

روند نصب:
1. فایل‌های پروژه در `~/.dns-scout` کپی می‌شوند.
2. Python و وابستگی‌های موردنیاز در Termux نصب می‌شوند.
3. محیط مجازی ساخته و پکیج‌های لازم نصب می‌شوند.
4. `panel_config.json` ساخته می‌شود و اطلاعات ورود پنل از شما گرفته می‌شود.
5. پنل راه‌اندازی می‌شود و URL نهایی به شما نمایش داده می‌شود.

## CLI تغییر نام کاربری/رمز پنل

بعد از نصب، برای تغییر `username/password` بدون نصب مجدد:

Ubuntu:

```bash
sudo /opt/dns-scout/.venv/bin/python /opt/dns-scout/manage_panel_auth.py --config /opt/dns-scout/panel_config.json
sudo systemctl restart dns-scout.service
```

Windows (run as administrator);

```powershell
$installDir = Join-Path $env:ProgramData "dns-scout"
$venvPython = Join-Path $installDir ".venv\Scripts\python.exe"
& $venvPython "$installDir\manage_panel_auth.py" --config "$installDir\panel_config.json"
Stop-ScheduledTask -TaskName "dns-scout"
Start-ScheduledTask -TaskName "dns-scout"
```

## بازگردانی لینک پنل

فرمان زیر برای نمایش دوباره URLهای ورود پنل مدیریت است (مثل `http://localhost:<port>/login`) تا بعد از نصب هم لینک ورود را از طریق CLI داشته باشید.

Ubuntu:

```bash
sudo /opt/dns-scout/.venv/bin/python /opt/dns-scout/manage_panel_auth.py --config /opt/dns-scout/panel_config.json --show-urls
```

Windows:

```powershell
$installDir = Join-Path $env:ProgramData "dns-scout"
& "$installDir\.venv\Scripts\python.exe" "$installDir\manage_panel_auth.py" --config "$installDir\panel_config.json" --show-urls
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

برای حذف سرویس نصب‌شده و بازنشانی وضعیت نصب سیستم (بدون حذف فایل‌های پروژه‌ای که در ابتدا clone شده).

### فرمان حذف در Ubuntu
```bash
sudo bash ./uninstall_ubuntu.sh
```
### فرمان حذف در Windows
```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall_windows.ps1
```

### فرمان حذف در Android
```bash
bash uninstall_termux_android.sh
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

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
