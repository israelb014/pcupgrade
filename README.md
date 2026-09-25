# QuickDeploy — הקמת מחשב חדש

כלי יחיד להקמת מחשב Windows חדש: התקנת תוכנות דרך winget, ניקוי אפליקציות מובנות, הגדרות מערכת, רשת, כוננים ממופים, מדפסות, שינוי שם מחשב והצטרפות לדומיין — עם ממשק גרפי בעברית (RTL, ערכת צבעים כהה), מצב סימולציה, מצב שקט, יומן ודוח HTML.

| קובץ | תפקיד |
|---|---|
| `QuickDeploy.ps1` | הכלי כולו בקובץ אחד (PowerShell 5.1 + WPF, נשמר כ-UTF-8 עם BOM) |
| `QuickDeploy.cmd` | קובץ הפעלה (לחיצה כפולה) |
| `README.md` | המסמך הזה |

## דרישות

- Windows 10 22H2 או Windows 11 22H2 ומעלה.
- Windows PowerShell 5.1 (מובנה). אין צורך ב-PowerShell 7 ואין מודולים חיצוניים.
- הרשאות מנהל. הכלי מבקש הגבהה (UAC) בעצמו, וגם מפעיל את עצמו מחדש במצב STA או מתוך Windows PowerShell אם הופעל מ-PowerShell 7.
- winget. אם הוא חסר, הכלי מוריד ומתקין את App Installer ואת התלויות שלו בזמן ההרצה.

## הפעלה

### ממשק גרפי
לחיצה כפולה על `QuickDeploy.cmd`, ואז:
1. **פרופיל**: בוחרים תבנית (משרד / ביתי / גיימינג או פרופיל שלכם) ובודקים את פרטי המחשב.
2. **תוכנות**, **ניקוי**, **הגדרות מערכת**, **רשת ומדפסות**: מסמנים מה לבצע ושומרים לפרופיל.
3. **סיכום והרצה**: מסמנים "מצב סימולציה" אם רוצים רק לראות מה יקרה, ולוחצים **הרץ**.

פרטי הזדהות לדומיין, סיסמת המנהל המקומי וסיסמאות Wi-Fi נאספים בחלון מאובטח **לפני** שההרצה מתחילה. מרגע שלוחצים "הרץ" ההרצה ממשיכה בלי צורך בהתערבות.

### שורת פקודה / מצב שקט
```powershell
QuickDeploy.cmd -Profile "משרד" -ComputerName "PC-01" -Silent
QuickDeploy.cmd -Profile "משרד" -Silent -Simulate
QuickDeploy.cmd -Profile "גיימינג"            # פותח את הממשק עם הפרופיל טעון
```

| פרמטר | משמעות |
|---|---|
| `-Profile` | שם הפרופיל (שם התצוגה או שם הקובץ) |
| `-ComputerName` | שם מחשב חדש (לא נשמר בפרופיל) |
| `-Silent` | הרצה בלי ממשק |
| `-Simulate` | סימולציה: שום שינוי לא מתבצע, וכל פעולה נרשמת כ-`[SIM] would …` |
| `-NoReboot` | לא להפעיל מחדש בסיום |

קודי יציאה במצב שקט: `0` הכל תקין · `1` חלק מהפעולות נכשלו · `2` שגיאה קריטית (למשל פרופיל לא נמצא).
במצב שקט הכלי מדלג על פעולות שדורשות סוד (הצטרפות לדומיין, מנהל מקומי, Wi-Fi) ורושם על כך אזהרה ביומן. אם נדרשת הפעלה מחדש ולא הועבר `-NoReboot`, המחשב יופעל מחדש אחרי 60 שניות. אפשר לבטל עם `shutdown /a`.

## תיקיות

```
%ProgramData%\QuickDeploy\
  Profiles\*.json
  Logs\QuickDeploy_<PC>_<yyyyMMdd_HHmmss>.log         (+ _transcript.log)
  Reports\Report_<PC>_<yyyyMMdd_HHmmss>.html
```

## שלבי ההרצה (סדר קבוע)

1. **בדיקות מקדימות**: הרשאות, גרסת מערכת, אינטרנט, מקום פנוי (אזהרה מתחת ל-10GB), סוללה.
2. **נקודת שחזור**: אם היצירה נכשלת, נרשמת אזהרה וההרצה ממשיכה.
3. **ניקוי תוכנות**
4. **הגדרות מערכת**
5. **התקנת תוכנות**: כולל התקדמות לכל תוכנה.
6. **רשת, כוננים ומדפסות**
7. **שם מחשב ודומיין**: תמיד השלב האחרון, ואחריו סריקת Windows Update.
8. **דוח סיכום**

שלב שנכשל לא עוצר את שאר השלבים. ביטול נכנס לתוקף רק בין פעולות, אף פעם לא באמצע התקנה.

## מבנה פרופיל (JSON)

```json
{
  "schemaVersion": 1,
  "name": "משרד",
  "description": "...",
  "apps": ["Google.Chrome", "7zip.7zip"],
  "customApps": [{ "id": "X.Y", "name": "...", "source": "winget" }],
  "debloat": { "packages": ["Microsoft.BingNews"], "consumerFeatures": true, "ads": true, "bingSearch": true, "copilot": false, "oneDrive": false },
  "system": { "timezone": true, "hebrewKeyboard": true, "powerPlan": "balanced", "disableHibernation": false, "disableFastStartup": true,
              "showExtensions": true, "showHidden": false, "explorerThisPC": true, "taskbarLeft": false, "classicContextMenu": false,
              "enableRdp": false, "createLocalAdmin": false, "windowsUpdateScan": true },
  "network": {
    "joinType": "none", "workgroup": "", "domain": "", "ou": "",
    "drives":   [{ "letter": "S", "path": "\\\\server\\share", "label": "" }],
    "wifi":     [{ "ssid": "", "security": "WPA2" }],
    "printers": [{ "type": "ip", "name": "", "ip": "", "driver": "", "default": false, "testPage": false },
                 { "type": "unc", "path": "\\\\server\\printer", "default": false }]
  }
}
```

- `powerPlan` מקבל `balanced` או `high`. `joinType` מקבל `none`, `workgroup` או `domain`. `security` מקבל `WPA2` או `WPA3`.
- מפתחות לא מוכרים נזנחים ומפתחות חסרים מקבלים ברירת מחדל. קובץ פגום מציג הודעת שגיאה ולא מקריס את הכלי.
- שם מחשב, סיסמאות ופרטי הזדהות לעולם לא נשמרים בפרופיל.

## קטלוג תוכנות מובנה

| קטגוריה | תוכנות (מזהה winget) |
|---|---|
| דפדפנים | Chrome `Google.Chrome` · Firefox `Mozilla.Firefox` · Brave `Brave.Brave` |
| כלים | 7-Zip `7zip.7zip` · Notepad++ `Notepad++.Notepad++` · Everything `voidtools.Everything` · PowerToys `Microsoft.PowerToys` |
| משרד ומסמכים | Microsoft 365 `Microsoft.Office` · Acrobat Reader `Adobe.Acrobat.Reader.64-bit` |
| תקשורת | Zoom `Zoom.Zoom` · Teams `Microsoft.Teams` · WhatsApp `9NKSQGP7F2NH` (msstore) · Telegram `Telegram.TelegramDesktop` |
| תמיכה מרחוק | AnyDesk `AnyDesk.AnyDesk` · TeamViewer `TeamViewer.TeamViewer` |
| מדיה | VLC `VideoLAN.VLC` · Spotify `Spotify.Spotify` |
| ספריות הרצה | VC++ 2015-2022 x64 `Microsoft.VCRedist.2015+.x64` · .NET Desktop Runtime 8 `Microsoft.DotNet.DesktopRuntime.8` · Java `Oracle.JavaRuntimeEnvironment` |
| גיימינג | Steam `Valve.Steam` · Discord `Discord.Discord` · Epic Games `EpicGames.EpicGamesLauncher` |
| פיתוח | VS Code `Microsoft.VisualStudioCode` · Git `Git.Git` |

אפשר להוסיף כל מזהה winget ידנית, דרך חיפוש (`winget search`) בעמוד התוכנות.

## אפליקציות שניתן להסיר

`Microsoft.BingNews`, `Microsoft.BingWeather`, `Microsoft.GetHelp`, `Microsoft.Getstarted`, `Microsoft.MicrosoftSolitaireCollection`, `Microsoft.People`, `Microsoft.WindowsFeedbackHub`, `Microsoft.ZuneMusic`, `Microsoft.ZuneVideo`, `Microsoft.MicrosoftOfficeHub`, `Microsoft.SkypeApp`, `Clipchamp.Clipchamp`, `Microsoft.Todos`, `MicrosoftTeams` (Teams לצרכן), `Microsoft.549981C3F5F10` (Cortana), `*CandyCrush*`, `*Disney*`, `*TikTok*`, `*Facebook*`, `*Instagram*`, `Microsoft.XboxApp`, `Microsoft.GamingApp`, `Microsoft.XboxGamingOverlay`, `Microsoft.XboxGameOverlay`, `Microsoft.XboxSpeechToTextOverlay`, `Microsoft.Xbox.TCUI`.

האפליקציות מוסרות לכל המשתמשים (`Remove-AppxPackage -AllUsers`) ומוסרות גם מההקצאה (`Remove-AppxProvisionedPackage -Online`), כך שמשתמשים חדשים לא יקבלו אותן. בפרופיל "גיימינג" אפליקציות ה-Xbox נשמרות.

**מוגנות, ולעולם לא יוסרו גם אם תבנית תופסת אותן:** `Microsoft.WindowsStore`, `Microsoft.DesktopAppInstaller`, `Microsoft.WindowsCalculator`, `Microsoft.Windows.Photos`, `Microsoft.WindowsNotepad`, `Microsoft.WindowsTerminal`, `Microsoft.SecHealthUI`, `Microsoft.Paint`, `Microsoft.ScreenSketch`, `Microsoft.StorePurchaseApp`, `Microsoft.VCLibs*`, `Microsoft.UI.Xaml*`, `Microsoft.NET*`, `MSTeams`.

## החלטות שהתקבלו

1. **מתג כבוי = לא לגעת.** הגדרה כבויה (למשל "הצג קבצים מוסתרים") לא מחזירה את ההגדרה לברירת המחדל של Windows. היא פשוט לא משנה אותה.
2. **`MSTeams` נוסף לרשימת המוגנות.** כך Teams לעבודה לא יוסר גם אם בעתיד תתווסף תבנית רחבה.
3. **פרטי הדומיין נאספים בחלון מאובטח של הכלי (PasswordBox) ולא דרך `Get-Credential`.** החלון של `Get-Credential` שייך לחלון המסוף המוסתר, ועלול להיפתח מאחורי הממשק או לא להופיע בכלל. התוצאה זהה: אובייקט `PSCredential` שנשמר בזיכרון בלבד.
4. **במצב סימולציה לא נאספים סודות.** שלבי הדומיין, המנהל המקומי וה-Wi-Fi מסומנים כ"סימולציה".
5. **הדוח מופק תמיד, גם אחרי ביטול.** כך יש תיעוד של מה שבוצע. השלבים שלא רצו מסומנים "בוטל".
6. **סריקת Windows Update מופעלת בסוף שלב 7** (אחרי שינוי השם והצטרפות לדומיין), כדי שתהיה הפעולה האחרונה.
7. **שם מחשב עם קבוצת עבודה:** קודם משנים קבוצת עבודה ואחר כך את השם. עם דומיין השם משתנה יחד עם ההצטרפות (`Add-Computer -NewName`). אם המחשב כבר חבר בדומיין, הכלי לא מוציא אותו לקבוצת עבודה, כי לשם כך נדרשים פרטי מנהל דומיין.
8. **משתמש מנהל שכבר קיים:** הכלי לא משנה את הסיסמה שלו. הוא רק מוודא חברות בקבוצת המנהלים, שמזוהה לפי SID ולכן לא תלויה בשפת המערכת.
9. **חוקי חומת האש של RDP** מופעלים לפי מזהה הקבוצה `@FirewallAPI.dll,-28752` ולא לפי השם "Remote Desktop", כי השם מתורגם במערכות בעברית.
10. **Wi-Fi:** ה-XML עם הסיסמה נכתב לקובץ זמני ונמחק מיד אחרי `netsh` (בבלוק `finally`).
11. **מדפסת משותפת (UNC):** המשימה המתוזמנת מופעלת מיד, כי המשתמש כבר מחובר, וגם בכניסה הבאה. היא מוחקת את עצמה, ויש לה גם תאריך תפוגה של 7 ימים עם מחיקה אוטומטית, למקרה שלמשתמש רגיל אין הרשאה למחוק אותה.
12. **מדפסת ברירת מחדל** מוגדרת למשתמש שמריץ את הכלי, ובנוסף נכתב `LegacyDefaultPrinterMode=1` כדי ש-Windows לא יחליף אותה אוטומטית.
13. **שדות נוספים בפרופיל:** לכל מדפסת נוספו `testPage` (הדפסת דף ניסיון) ו-`path` (למדפסת משותפת). זו הרחבה של הסכמה, ופרופילים ישנים נטענים בלי שינוי.
14. **תפריט לחצן ימני קלאסי** מוחל רק על משתמשים קיימים. במשתמש Default המפתח שייך ל-UsrClass.dat ולא ל-NTUSER.DAT. שינויי שורת המשימות והתפריט דורשים כניסה מחדש, ולכן הם מסמנים "נדרשת הפעלה מחדש".
15. **הגדרות HKCU** נכתבות למשתמש הנוכחי, למשתמש המחובר בפועל אם הוא שונה מהמנהל המוגבה (לפי הבעלים של `explorer.exe`), ול-Default. כך גם הגדרות מסוג "הצעות ופרסומות" חלות על משתמשים חדשים.
16. **OneDrive** מוסר, ובנוסף נחסם דרך מדיניות (`DisableFileSyncNGSC=1`) ונמחק מ-Run של משתמש Default, כדי שלא יותקן מחדש.
17. **התקנות "כבר מותקן":** גם הקודים `0x8A15002B` ו-`0x8A150061` של winget נחשבים "כבר מותקן", והקודים 3010/1641 נחשבים הצלחה שדורשת הפעלה מחדש.
18. **בדיקת זמינות בקטלוג:** מזהה מסומן "לא זמין" רק כש-winget מחזיר "לא נמצא" במפורש. שגיאות אחרות, כמו היעדר אינטרנט, מוצגות כ"לא נבדק" והמזהה נשאר זמין לבחירה.
19. **חלון המסוף** מוסתר במצב גרפי רק אם הוא שייך לתהליך הכלי בלבד, כדי לא להסתיר חלון מסוף של המשתמש.
20. **סגירת הכלי בזמן הרצה חסומה.** קודם מבטלים וממתינים לסיום הפעולה הנוכחית.
21. **פרופילים מובנים:** לפרופיל "ביתי" לא הוגדר ניקוי ספציפי, ולכן הוא מקבל ניקוי מלא כברירת מחדל.
22. **עדכון נקודת השחזור:** הערך `SystemRestorePointCreationFrequency` משוחזר לערך הקודם אחרי יצירת הנקודה, ונמחק אם לא היה קיים קודם.
