import Cocoa
import ApplicationServices
import ServiceManagement // Neu für modernen Autostart
import ScreenCaptureKit

// MARK: - Image Optimization (RAM Saver)

/// Zielgroesse der Icon-Bitmaps in Pixeln (84pt Zelle @2x abzueglich Padding).
let iconPixelSize = 144

extension NSImage {
    /// Rasterisiert das Icon EINMALIG in eine kleine CGImage-Bitmap.
    ///
    /// Wichtig fuer die Performance: Das Ergebnis wird direkt als `layer.contents`
    /// gesetzt. Dadurch entfaellt jedes erneute Zeichnen (die alte Variante mit
    /// `NSImage(size:flipped:)` + `cacheMode = .never` hat das Icon bei JEDEM
    /// Frame neu gerendert) und der Speicherbedarf sinkt drastisch.
    /// Reines CoreGraphics, damit der Aufruf gefahrlos im Hintergrund laufen kann.
    func downsampledCGImage(px: Int = iconPixelSize) -> CGImage? {
        var proposed = NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
        guard let src = cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        if src.width <= px && src.height <= px { return src }

        guard let ctx = CGContext(data: nil, width: px, height: px,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return src }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: px, height: px))
        return ctx.makeImage() ?? src
    }
}

/// Merkt sich bereits rasterisierte Icons, damit weder der Cache-Refresh (alle
/// 10 Minuten) noch das Oeffnen des Launchers dieselbe Arbeit erneut macht.
final class IconStore {
    static let shared = IconStore()
    private let lock = NSLock()
    private var cache = [String: CGImage]()

    func cached(_ key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    func store(_ key: String, _ image: CGImage?) {
        guard let image else { return }
        lock.lock(); cache[key] = image; lock.unlock()
    }

    /// Liefert das Icon aus dem Cache oder rasterisiert es einmalig nach.
    func icon(key: String, provider: () -> NSImage?) -> CGImage? {
        if let hit = cached(key) { return hit }
        let made = provider()?.downsampledCGImage()
        store(key, made)
        return made
    }
}

// MARK: - Fuzzy Search & Alias Logic

let appAliases: [String: [String]] = [
    "spotify": ["musik", "music", "audio", "podcast", "lied", "player", "stream"],
    "music": ["musik", "audio", "lied", "player", "apple"],
    "tv": ["film", "filme", "serie", "video", "kino", "stream"],
    "netflix": ["film", "filme", "serie", "video", "kino", "stream"],
    "prime": ["film", "filme", "serie", "video", "kino", "amazon"],
    "safari": ["browser", "internet", "web", "www", "surfen"],
    "chrome": ["browser", "internet", "web", "www", "google"],
    "firefox": ["browser", "internet", "web", "www"],
    "mail": ["email", "e-mail", "post", "brief"],
    "messages": ["email", "e-mail", "post", "nachrichten", "sms"],
    "rechner": ["taschenrechner", "mathe", "calculator", "calc", "plus"],
    "calculator": ["taschenrechner", "mathe", "rechner", "calc"],
    "kalender": ["datum", "termin", "calendar", "planung"],
    "fotos": ["bilder", "galerie", "kamera", "photos", "bild"],
    "karten": ["navigation", "gps", "route", "maps", "karte"],
    "wetter": ["wettervorhersage", "regen", "sonne", "weather"],
    "notizen": ["text", "notiz", "schreiben", "notes", "todo"],
    "pages": ["text", "schreiben", "dokument", "word", "office"],
    "word": ["text", "schreiben", "dokument", "office", "microsoft"],
    "excel": ["tabelle", "kalkulation", "office", "spreadsheet", "microsoft"],
    "powerpoint": ["präsentation", "folien", "office", "microsoft"],
    "keynote": ["präsentation", "folien", "apple"],
    "systemeinstellungen": ["settings", "optionen", "konfiguration", "wlan", "bluetooth", "mac"],
    "whatsapp": ["chat", "nachrichten", "messenger", "text", "schreiben"],
    "telegram": ["chat", "nachrichten", "messenger", "text"],
    "discord": ["chat", "nachrichten", "messenger", "gaming"],
    "slack": ["chat", "messenger", "team", "arbeit"],
    "zoom": ["videochat", "meeting", "konferenz", "team", "kamera"],
    "teams": ["videochat", "meeting", "konferenz", "office", "microsoft"],
    "terminal": ["cmd", "bash", "konsole", "command", "code", "programmieren"]
]

func isFuzzyMatch(query: String, target: String) -> Bool {
    let q = query.lowercased()
    let t = target.lowercased()
    
    if t.contains(q) || t.replacingOccurrences(of: " ", with: "").contains(q) { return true }
    
    for (appKey, aliases) in appAliases {
        if t.contains(appKey) {
            if aliases.contains(where: { $0.hasPrefix(q) || $0.contains(q) }) {
                return true
            }
        }
    }
    
    var qIndex = q.startIndex
    for tChar in t {
        if qIndex == q.endIndex { break }
        if tChar == q[qIndex] {
            qIndex = q.index(after: qIndex)
        }
    }
    if qIndex == q.endIndex { return true }
    
    if q.count < 3 { return false }
    
    func dist(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(0...b.count)
        for i in 1...a.count {
            var newD = [i]
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                newD.append(min(d[j] + 1, newD[j-1] + 1, d[j-1] + cost))
            }
            d = newD
        }
        return d.last!
    }
    
    let words = t.split(separator: " ").map(String.init) + [t, t.replacingOccurrences(of: " ", with: "")]
    let allowedTypos = q.count <= 4 ? 1 : 2
    
    for word in words {
        if dist(q, word) <= allowedTypos { return true }
        
        let minLen = max(1, q.count - 1)
        let maxLen = min(word.count, q.count + 1)
        if minLen <= maxLen {
            for len in minLen...maxLen {
                let prefix = String(word.prefix(len))
                if dist(q, prefix) <= allowedTypos { return true }
            }
        }
    }
    
    return false
}

// MARK: - Localization

/// Alle 34 Sprachvarianten, die macOS selbst im Language-&-Region-Picker als
/// Systemsprache anbietet (ermittelt ueber `Locale.Language.systemLanguages`,
/// nicht geraten). "system" folgt automatisch der aktuell eingestellten
/// Systemsprache; eine explizite Wahl in den Einstellungen ueberschreibt das
/// dauerhaft, bis "Systemsprache" wieder gewaehlt wird.
enum AppLanguage: String, CaseIterable {
    case system
    case ar, ca, cs, da, de, el, en, es, fi, fr, he, hi, hr, hu, id, it, ja, ko, ms, nb, nl, pl, pt, ro, ru, sk, sl, sv, th, tr, uk, vi, zhHans, zhHant

    private static let defaultsKey = "appLanguageOverride"

    /// Die tatsaechlich anzuzeigende Sprache - loest "system" bereits auf.
    /// Kennt macOS eine Systemsprache, die wir nicht uebersetzt haben, faellt das
    /// auf Englisch zurueck statt auf eine zufaellige andere Sprache zu raten.
    static var current: AppLanguage {
        if storedOverride != .system { return storedOverride }
        guard let identifier = Locale.preferredLanguages.first else { return .en }
        let language = Locale.Language(identifier: identifier)

        // Chinesisch braucht die Schrift zur Unterscheidung Vereinfacht/Traditionell -
        // der reine Sprachcode "zh" ist dafuer nicht eindeutig genug.
        if language.languageCode?.identifier == "zh" {
            return language.script?.identifier == "Hant" ? .zhHant : .zhHans
        }
        guard let code = language.languageCode?.identifier,
              let match = AppLanguage(rawValue: code) else { return .en }
        return match
    }

    /// Die in den Einstellungen gewaehlte Option, inklusive "system" selbst -
    /// fuer den Haken im Sprachmenue.
    static var storedOverride: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return .system }
        return AppLanguage(rawValue: raw) ?? .system
    }

    static func setOverride(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
    }

    /// Eigenname der Sprache - wie im System ueblich unuebersetzt (in einem
    /// englischsprachigen Menue heisst "Deutsch" trotzdem "Deutsch").
    var nativeName: String {
        switch self {
        case .system: return ""
        case .ar: return "العربية"
        case .ca: return "Català"
        case .cs: return "Čeština"
        case .da: return "Dansk"
        case .de: return "Deutsch"
        case .el: return "Ελληνικά"
        case .en: return "English"
        case .es: return "Español"
        case .fi: return "Suomi"
        case .fr: return "Français"
        case .he: return "עברית"
        case .hi: return "हिन्दी"
        case .hr: return "Hrvatski"
        case .hu: return "Magyar"
        case .id: return "Bahasa Indonesia"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .ms: return "Bahasa Melayu"
        case .nb: return "Norsk Bokmål"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .pt: return "Português"
        case .ro: return "Română"
        case .ru: return "Русский"
        case .sk: return "Slovenčina"
        case .sl: return "Slovenščina"
        case .sv: return "Svenska"
        case .th: return "ไทย"
        case .tr: return "Türkçe"
        case .uk: return "Українська"
        case .vi: return "Tiếng Việt"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        }
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

private let translations: [String: [AppLanguage: String]] = [
    "panel.title": [
        .ar: "ترتيب النافذة",
        .ca: "COL·LOCA LA FINESTRA",
        .cs: "UMÍSTIT OKNO",
        .da: "PLACER VINDUE",
        .de: "FENSTER PLATZIEREN",
        .el: "ΤΟΠΟΘΕΤΗΣΗ ΠΑΡΑΘΥΡΟΥ",
        .en: "PLACE WINDOW",
        .es: "COLOCAR VENTANA",
        .fi: "SIJOITA IKKUNA",
        .fr: "PLACER LA FENÊTRE",
        .he: "מיקום החלון",
        .hi: "विंडो व्यवस्थित करें",
        .hr: "POSTAVI PROZOR",
        .hu: "ABLAK ELHELYEZÉSE",
        .id: "TEMPATKAN JENDELA",
        .it: "POSIZIONA FINESTRA",
        .ja: "ウインドウを配置",
        .ko: "윈도우 배치",
        .ms: "LETAK TETINGKAP",
        .nb: "PLASSER VINDU",
        .nl: "VENSTER PLAATSEN",
        .pl: "UMIEŚĆ OKNO",
        .pt: "POSICIONAR JANELA",
        .ro: "POZIȚIONEAZĂ FEREASTRA",
        .ru: "РАЗМЕСТИТЬ ОКНО",
        .sk: "UMIESTNIŤ OKNO",
        .sl: "POSTAVI OKNO",
        .sv: "PLACERA FÖNSTER",
        .th: "จัดวางหน้าต่าง",
        .tr: "PENCEREYİ YERLEŞTİR",
        .uk: "РОЗМІСТИТИ ВІКНО",
        .vi: "SẮP XẾP CỬA SỔ",
        .zhHans: "排列窗口",
        .zhHant: "排列視窗",
    ],
    "search.placeholder": [
        .ar: "بحث",
        .ca: "Cerca",
        .cs: "Hledat",
        .da: "Søg",
        .de: "Suchen",
        .el: "Αναζήτηση",
        .en: "Search",
        .es: "Buscar",
        .fi: "Haku",
        .fr: "Rechercher",
        .he: "חיפוש",
        .hi: "खोजें",
        .hr: "Pretraži",
        .hu: "Keresés",
        .id: "Cari",
        .it: "Cerca",
        .ja: "検索",
        .ko: "검색",
        .ms: "Cari",
        .nb: "Søk",
        .nl: "Zoeken",
        .pl: "Szukaj",
        .pt: "Buscar",
        .ro: "Caută",
        .ru: "Поиск",
        .sk: "Hľadať",
        .sl: "Iskanje",
        .sv: "Sök",
        .th: "ค้นหา",
        .tr: "Ara",
        .uk: "Пошук",
        .vi: "Tìm kiếm",
        .zhHans: "搜索",
        .zhHant: "搜尋",
    ],
    "alert.accessibility.title": [
        .ar: "الإذن مطلوب",
        .ca: "Es requereix permís",
        .cs: "Vyžadováno oprávnění",
        .da: "Tilladelse påkrævet",
        .de: "Berechtigung benötigt",
        .el: "Απαιτείται άδεια",
        .en: "Permission Required",
        .es: "Se requiere permiso",
        .fi: "Käyttöoikeus vaaditaan",
        .fr: "Autorisation requise",
        .he: "נדרשת הרשאה",
        .hi: "अनुमति आवश्यक है",
        .hr: "Potrebna je dozvola",
        .hu: "Engedély szükséges",
        .id: "Izin Diperlukan",
        .it: "Autorizzazione richiesta",
        .ja: "許可が必要です",
        .ko: "권한이 필요합니다",
        .ms: "Kebenaran Diperlukan",
        .nb: "Tillatelse kreves",
        .nl: "Toestemming vereist",
        .pl: "Wymagane uprawnienie",
        .pt: "Permissão necessária",
        .ro: "Permisiune necesară",
        .ru: "Требуется разрешение",
        .sk: "Vyžaduje sa povolenie",
        .sl: "Potrebno je dovoljenje",
        .sv: "Behörighet krävs",
        .th: "ต้องการสิทธิ์การเข้าถึง",
        .tr: "İzin Gerekli",
        .uk: "Потрібен дозвіл",
        .vi: "Cần có quyền truy cập",
        .zhHans: "需要权限",
        .zhHant: "需要權限",
    ],
    "alert.accessibility.button": [
        .ar: "حسنًا",
        .ca: "Entesos",
        .cs: "Rozumím",
        .da: "Forstået",
        .de: "Verstanden",
        .el: "Κατάλαβα",
        .en: "Got It",
        .es: "Entendido",
        .fi: "Selvä",
        .fr: "Compris",
        .he: "הבנתי",
        .hi: "समझ गया",
        .hr: "Razumijem",
        .hu: "Rendben",
        .id: "Mengerti",
        .it: "Capito",
        .ja: "OK",
        .ko: "확인",
        .ms: "Faham",
        .nb: "Skjønner",
        .nl: "Begrepen",
        .pl: "Rozumiem",
        .pt: "Entendi",
        .ro: "Am înțeles",
        .ru: "Понятно",
        .sk: "Rozumiem",
        .sl: "Razumem",
        .sv: "Uppfattat",
        .th: "เข้าใจแล้ว",
        .tr: "Anladım",
        .uk: "Зрозуміло",
        .vi: "Đã hiểu",
        .zhHans: "知道了",
        .zhHant: "知道了",
    ],
    "menu.header": [
        .ar: "macOS Snap",
        .ca: "macOS Snap",
        .cs: "macOS Snap",
        .da: "macOS Snap",
        .de: "macOS Snap",
        .el: "macOS Snap",
        .en: "macOS Snap",
        .es: "macOS Snap",
        .fi: "macOS Snap",
        .fr: "macOS Snap",
        .he: "macOS Snap",
        .hi: "macOS Snap",
        .hr: "macOS Snap",
        .hu: "macOS Snap",
        .id: "macOS Snap",
        .it: "macOS Snap",
        .ja: "macOS Snap",
        .ko: "macOS Snap",
        .ms: "macOS Snap",
        .nb: "macOS Snap",
        .nl: "macOS Snap",
        .pl: "macOS Snap",
        .pt: "macOS Snap",
        .ro: "macOS Snap",
        .ru: "macOS Snap",
        .sk: "macOS Snap",
        .sl: "macOS Snap",
        .sv: "macOS Snap",
        .th: "macOS Snap",
        .tr: "macOS Snap",
        .uk: "macOS Snap",
        .vi: "macOS Snap",
        .zhHans: "macOS Snap",
        .zhHant: "macOS Snap",
    ],
    "menu.hint": [
        .ar: "اسحب نافذة إلى شريط القوائم ← رصّها",
        .ca: "Arrossega una finestra a la barra de menús → ajusta",
        .cs: "Přetáhněte okno na panel nabídek → přichytit",
        .da: "Træk et vindue til menulinjen → placer",
        .de: "Fenster zur Menüleiste ziehen → einrasten",
        .el: "Σύρετε ένα παράθυρο στη γραμμή μενού → προσάρτηση",
        .en: "Drag a window to the menu bar → snap",
        .es: "Arrastra una ventana a la barra de menús → ajustar",
        .fi: "Vedä ikkuna valikkoriville → sovita",
        .fr: "Faites glisser une fenêtre vers la barre des menus → ajuster",
        .he: "גרור חלון לשורת התפריטים ← הצמדה",
        .hi: "विंडो को मेनू बार पर खींचें → स्नैप करें",
        .hr: "Povucite prozor na traku izbornika → prihvati",
        .hu: "Húzzon egy ablakot a menüsorra → illesztés",
        .id: "Seret jendela ke bilah menu → tempatkan",
        .it: "Trascina una finestra sulla barra dei menu → posiziona",
        .ja: "ウインドウをメニューバーへドラッグ → 配置",
        .ko: "윈도우를 메뉴 막대로 드래그 → 배치",
        .ms: "Seret tetingkap ke bar menu → tetapkan",
        .nb: "Dra et vindu til menylinjen → fest",
        .nl: "Sleep een venster naar de menubalk → plaatsen",
        .pl: "Przeciągnij okno do paska menu → dopasuj",
        .pt: "Arraste uma janela até a barra de menus → posicionar",
        .ro: "Trage o fereastră spre bara de meniu → poziționează",
        .ru: "Перетащите окно на строку меню → разместить",
        .sk: "Presuňte okno na panel s ponukou → prichytiť",
        .sl: "Povlecite okno na menijsko vrstico → pripni",
        .sv: "Dra ett fönster till menyraden → placera",
        .th: "ลากหน้าต่างไปยังแถบเมนู → จัดวาง",
        .tr: "Bir pencereyi menü çubuğuna sürükleyin → yerleştir",
        .uk: "Перетягніть вікно на рядок меню → розмістити",
        .vi: "Kéo cửa sổ đến thanh menu → sắp xếp",
        .zhHans: "将窗口拖到菜单栏 → 贴靠",
        .zhHant: "將視窗拖到選單列 → 貼齊",
    ],
    "menu.autostart.on": [
        .ar: "✓ التشغيل التلقائي",
        .ca: "✓ Inicia automàticament",
        .cs: "✓ Spouštět automaticky",
        .da: "✓ Start automatisk",
        .de: "✓ Automatisch starten",
        .el: "✓ Αυτόματη εκκίνηση",
        .en: "✓ Start Automatically",
        .es: "✓ Iniciar automáticamente",
        .fi: "✓ Käynnistä automaattisesti",
        .fr: "✓ Démarrer automatiquement",
        .he: "✓ הפעלה אוטומטית",
        .hi: "✓ स्वचालित रूप से प्रारंभ करें",
        .hr: "✓ Pokreni automatski",
        .hu: "✓ Automatikus indítás",
        .id: "✓ Mulai Otomatis",
        .it: "✓ Avvia automaticamente",
        .ja: "✓ 自動的に起動",
        .ko: "✓ 자동으로 시작",
        .ms: "✓ Mula Secara Automatik",
        .nb: "✓ Start automatisk",
        .nl: "✓ Automatisch starten",
        .pl: "✓ Uruchamiaj automatycznie",
        .pt: "✓ Iniciar automaticamente",
        .ro: "✓ Pornire automată",
        .ru: "✓ Запускать автоматически",
        .sk: "✓ Spúšťať automaticky",
        .sl: "✓ Samodejni zagon",
        .sv: "✓ Starta automatiskt",
        .th: "✓ เริ่มโดยอัตโนมัติ",
        .tr: "✓ Otomatik Başlat",
        .uk: "✓ Запускати автоматично",
        .vi: "✓ Tự động khởi động",
        .zhHans: "✓ 自动启动",
        .zhHant: "✓ 自動啟動",
    ],
    "menu.autostart.off": [
        .ar: "  التشغيل عند الدخول",
        .ca: "  Inicia en iniciar la sessió",
        .cs: "  Spustit při přihlášení",
        .da: "  Start ved login",
        .de: "  Beim Login starten",
        .el: "  Εκκίνηση κατά τη σύνδεση",
        .en: "  Start at Login",
        .es: "  Iniciar al iniciar sesión",
        .fi: "  Käynnistä kirjautuessa",
        .fr: "  Démarrer à la connexion",
        .he: "  הפעלה בעת ההתחברות",
        .hi: "  लॉगिन पर प्रारंभ करें",
        .hr: "  Pokreni pri prijavi",
        .hu: "  Indítás bejelentkezéskor",
        .id: "  Mulai saat Login",
        .it: "  Avvia all'accesso",
        .ja: "  ログイン時に起動",
        .ko: "  로그인 시 시작",
        .ms: "  Mula semasa Log Masuk",
        .nb: "  Start ved innlogging",
        .nl: "  Starten bij inloggen",
        .pl: "  Uruchom przy zalogowaniu",
        .pt: "  Iniciar ao entrar",
        .ro: "  Pornire la conectare",
        .ru: "  Запускать при входе",
        .sk: "  Spustiť pri prihlásení",
        .sl: "  Zagon ob prijavi",
        .sv: "  Starta vid inloggning",
        .th: "  เริ่มเมื่อลงชื่อเข้าใช้",
        .tr: "  Girişte Başlat",
        .uk: "  Запускати під час входу",
        .vi: "  Khởi động khi đăng nhập",
        .zhHans: "  登录时启动",
        .zhHant: "  登入時啟動",
    ],
    "menu.accentColor": [
        .ar: "تغيير لون التمييز...",
        .ca: "Canvia el color d'accent...",
        .cs: "Změnit barvu zvýraznění...",
        .da: "Skift accentfarve...",
        .de: "Akzentfarbe ändern...",
        .el: "Αλλαγή χρώματος έμφασης...",
        .en: "Change Accent Color...",
        .es: "Cambiar color de énfasis...",
        .fi: "Vaihda korostusväri...",
        .fr: "Changer la couleur d'accentuation...",
        .he: "שינוי צבע הדגשה...",
        .hi: "एक्सेंट रंग बदलें...",
        .hr: "Promijeni boju isticanja...",
        .hu: "Kiemelőszín módosítása...",
        .id: "Ubah Warna Aksen...",
        .it: "Cambia colore d'accento...",
        .ja: "アクセントカラーを変更...",
        .ko: "강조 색상 변경...",
        .ms: "Tukar Warna Aksen...",
        .nb: "Endre aksentfarge...",
        .nl: "Accentkleur wijzigen...",
        .pl: "Zmień kolor akcentu...",
        .pt: "Alterar cor de destaque...",
        .ro: "Schimbă culoarea de accent...",
        .ru: "Изменить акцентный цвет...",
        .sk: "Zmeniť farbu zvýraznenia...",
        .sl: "Spremeni barvo poudarka...",
        .sv: "Ändra accentfärg...",
        .th: "เปลี่ยนสีเน้น...",
        .tr: "Vurgu Rengini Değiştir...",
        .uk: "Змінити акцентний колір...",
        .vi: "Đổi màu nhấn...",
        .zhHans: "更改强调色…",
        .zhHant: "變更強調色…",
    ],
    "menu.language": [
        .ar: "اللغة",
        .ca: "Idioma",
        .cs: "Jazyk",
        .da: "Sprog",
        .de: "Sprache",
        .el: "Γλώσσα",
        .en: "Language",
        .es: "Idioma",
        .fi: "Kieli",
        .fr: "Langue",
        .he: "שפה",
        .hi: "भाषा",
        .hr: "Jezik",
        .hu: "Nyelv",
        .id: "Bahasa",
        .it: "Lingua",
        .ja: "言語",
        .ko: "언어",
        .ms: "Bahasa",
        .nb: "Språk",
        .nl: "Taal",
        .pl: "Język",
        .pt: "Idioma",
        .ro: "Limbă",
        .ru: "Язык",
        .sk: "Jazyk",
        .sl: "Jezik",
        .sv: "Språk",
        .th: "ภาษา",
        .tr: "Dil",
        .uk: "Мова",
        .vi: "Ngôn ngữ",
        .zhHans: "语言",
        .zhHant: "語言",
    ],
    "menu.language.system": [
        .ar: "لغة النظام",
        .ca: "Idioma del sistema",
        .cs: "Jazyk systému",
        .da: "Systemsprog",
        .de: "Systemsprache",
        .el: "Γλώσσα συστήματος",
        .en: "System Language",
        .es: "Idioma del sistema",
        .fi: "Järjestelmän kieli",
        .fr: "Langue du système",
        .he: "שפת המערכת",
        .hi: "सिस्टम भाषा",
        .hr: "Jezik sustava",
        .hu: "Rendszer nyelve",
        .id: "Bahasa Sistem",
        .it: "Lingua di sistema",
        .ja: "システム言語",
        .ko: "시스템 언어",
        .ms: "Bahasa Sistem",
        .nb: "Systemspråk",
        .nl: "Systeemtaal",
        .pl: "Język systemu",
        .pt: "Idioma do sistema",
        .ro: "Limba sistemului",
        .ru: "Язык системы",
        .sk: "Jazyk systému",
        .sl: "Sistemski jezik",
        .sv: "Systemspråk",
        .th: "ภาษาระบบ",
        .tr: "Sistem Dili",
        .uk: "Мова системи",
        .vi: "Ngôn ngữ hệ thống",
        .zhHans: "系统语言",
        .zhHant: "系統語言",
    ],
    "menu.quit": [
        .ar: "إنهاء",
        .ca: "Surt",
        .cs: "Ukončit",
        .da: "Afslut",
        .de: "Beenden",
        .el: "Τερματισμός",
        .en: "Quit",
        .es: "Salir",
        .fi: "Lopeta",
        .fr: "Quitter",
        .he: "יציאה",
        .hi: "बाहर निकलें",
        .hr: "Izlaz",
        .hu: "Kilépés",
        .id: "Keluar",
        .it: "Esci",
        .ja: "終了",
        .ko: "종료",
        .ms: "Keluar",
        .nb: "Avslutt",
        .nl: "Stoppen",
        .pl: "Zamknij",
        .pt: "Sair",
        .ro: "Ieșire",
        .ru: "Выход",
        .sk: "Skončiť",
        .sl: "Izhod",
        .sv: "Avsluta",
        .th: "ออก",
        .tr: "Çık",
        .uk: "Вийти",
        .vi: "Thoát",
        .zhHans: "退出",
        .zhHant: "結束",
    ],
    "menu.appearance": [
        .ar: "المظهر",
        .ca: "Aparença",
        .cs: "Vzhled",
        .da: "Udseende",
        .de: "Erscheinungsbild",
        .el: "Εμφάνιση",
        .en: "Appearance",
        .es: "Apariencia",
        .fi: "Ulkoasu",
        .fr: "Apparence",
        .he: "מראה",
        .hi: "दिखावट",
        .hr: "Izgled",
        .hu: "Megjelenés",
        .id: "Tampilan",
        .it: "Aspetto",
        .ja: "外観",
        .ko: "모양",
        .ms: "Penampilan",
        .nb: "Utseende",
        .nl: "Weergave",
        .pl: "Wygląd",
        .pt: "Aparência",
        .ro: "Aspect",
        .ru: "Оформление",
        .sk: "Vzhľad",
        .sl: "Videz",
        .sv: "Utseende",
        .th: "ลักษณะที่ปรากฏ",
        .tr: "Görünüm",
        .uk: "Оформлення",
        .vi: "Giao diện",
        .zhHans: "外观",
        .zhHant: "外觀",
    ],
    "menu.appearance.light": [
        .ar: "فاتح",
        .ca: "Clar",
        .cs: "Světlý",
        .da: "Lyst",
        .de: "Hell",
        .el: "Ανοιχτό",
        .en: "Light",
        .es: "Claro",
        .fi: "Vaalea",
        .fr: "Clair",
        .he: "בהיר",
        .hi: "लाइट",
        .hr: "Svijetlo",
        .hu: "Világos",
        .id: "Terang",
        .it: "Chiaro",
        .ja: "ライト",
        .ko: "라이트",
        .ms: "Cerah",
        .nb: "Lyst",
        .nl: "Licht",
        .pl: "Jasny",
        .pt: "Claro",
        .ro: "Deschis",
        .ru: "Светлая",
        .sk: "Svetlý",
        .sl: "Svetlo",
        .sv: "Ljust",
        .th: "สว่าง",
        .tr: "Açık",
        .uk: "Світла",
        .vi: "Sáng",
        .zhHans: "浅色",
        .zhHant: "淺色",
    ],
    "menu.appearance.dark": [
        .ar: "داكن",
        .ca: "Fosc",
        .cs: "Tmavý",
        .da: "Mørkt",
        .de: "Dunkel",
        .el: "Σκούρο",
        .en: "Dark",
        .es: "Oscuro",
        .fi: "Tumma",
        .fr: "Sombre",
        .he: "כהה",
        .hi: "डार्क",
        .hr: "Tamno",
        .hu: "Sötét",
        .id: "Gelap",
        .it: "Scuro",
        .ja: "ダーク",
        .ko: "다크",
        .ms: "Gelap",
        .nb: "Mørkt",
        .nl: "Donker",
        .pl: "Ciemny",
        .pt: "Escuro",
        .ro: "Închis",
        .ru: "Тёмная",
        .sk: "Tmavý",
        .sl: "Temno",
        .sv: "Mörkt",
        .th: "มืด",
        .tr: "Koyu",
        .uk: "Темна",
        .vi: "Tối",
        .zhHans: "深色",
        .zhHant: "深色",
    ],
    "menu.hideIcon": [
        .ar: "إخفاء رمز شريط القوائم",
        .ca: "Amaga la icona de la barra de menús",
        .cs: "Skrýt ikonu v panelu nabídek",
        .da: "Skjul menulinjeikon",
        .de: "Menüleisten-Symbol ausblenden",
        .el: "Απόκρυψη εικονιδίου γραμμής μενού",
        .en: "Hide Menu Bar Icon",
        .es: "Ocultar icono de la barra de menús",
        .fi: "Piilota valikkorivin kuvake",
        .fr: "Masquer l'icône de la barre des menus",
        .he: "הסתר סמל בשורת התפריטים",
        .hi: "मेनू बार आइकन छिपाएं",
        .hr: "Sakrij ikonu trake izbornika",
        .hu: "Menüsor ikon elrejtése",
        .id: "Sembunyikan Ikon Bilah Menu",
        .it: "Nascondi icona nella barra dei menu",
        .ja: "メニューバーアイコンを隠す",
        .ko: "메뉴 막대 아이콘 숨기기",
        .ms: "Sembunyikan Ikon Bar Menu",
        .nb: "Skjul menylinjeikon",
        .nl: "Menubalkpictogram verbergen",
        .pl: "Ukryj ikonę paska menu",
        .pt: "Ocultar ícone da barra de menus",
        .ro: "Ascunde pictograma din bara de meniu",
        .ru: "Скрыть значок в строке меню",
        .sk: "Skryť ikonu na paneli s ponukou",
        .sl: "Skrij ikono v menijski vrstici",
        .sv: "Dölj ikon i menyraden",
        .th: "ซ่อนไอคอนแถบเมนู",
        .tr: "Menü Çubuğu Simgesini Gizle",
        .uk: "Сховати значок у рядку меню",
        .vi: "Ẩn biểu tượng thanh menu",
        .zhHans: "隐藏菜单栏图标",
        .zhHant: "隱藏選單列圖示",
    ],
    "menu.showIcon": [
        .ar: "إظهار رمز شريط القوائم",
        .ca: "Mostra la icona de la barra de menús",
        .cs: "Zobrazit ikonu v panelu nabídek",
        .da: "Vis menulinjeikon",
        .de: "Menüleisten-Symbol anzeigen",
        .el: "Εμφάνιση εικονιδίου γραμμής μενού",
        .en: "Show Menu Bar Icon",
        .es: "Mostrar icono de la barra de menús",
        .fi: "Näytä valikkorivin kuvake",
        .fr: "Afficher l'icône de la barre des menus",
        .he: "הצג סמל בשורת התפריטים",
        .hi: "मेनू बार आइकन दिखाएं",
        .hr: "Prikaži ikonu trake izbornika",
        .hu: "Menüsor ikon megjelenítése",
        .id: "Tampilkan Ikon Bilah Menu",
        .it: "Mostra icona nella barra dei menu",
        .ja: "メニューバーアイコンを表示",
        .ko: "메뉴 막대 아이콘 보기",
        .ms: "Tunjukkan Ikon Bar Menu",
        .nb: "Vis menylinjeikon",
        .nl: "Menubalkpictogram tonen",
        .pl: "Pokaż ikonę paska menu",
        .pt: "Mostrar ícone da barra de menus",
        .ro: "Afișează pictograma din bara de meniu",
        .ru: "Показать значок в строке меню",
        .sk: "Zobraziť ikonu na paneli s ponukou",
        .sl: "Pokaži ikono v menijski vrstici",
        .sv: "Visa ikon i menyraden",
        .th: "แสดงไอคอนแถบเมนู",
        .tr: "Menü Çubuğu Simgesini Göster",
        .uk: "Показати значок у рядку меню",
        .vi: "Hiện biểu tượng thanh menu",
        .zhHans: "显示菜单栏图标",
        .zhHant: "顯示選單列圖示",
    ],
    "picker.title": [
        .ar: "اختر النافذة",
        .ca: "Tria una finestra",
        .cs: "Vyberte okno",
        .da: "Vælg vindue",
        .de: "Fenster wählen",
        .el: "Επιλογή παραθύρου",
        .en: "Choose Window",
        .es: "Elegir ventana",
        .fi: "Valitse ikkuna",
        .fr: "Choisir une fenêtre",
        .he: "בחר חלון",
        .hi: "विंडो चुनें",
        .hr: "Odaberi prozor",
        .hu: "Ablak választása",
        .id: "Pilih Jendela",
        .it: "Scegli finestra",
        .ja: "ウインドウを選択",
        .ko: "윈도우 선택",
        .ms: "Pilih Tetingkap",
        .nb: "Velg vindu",
        .nl: "Kies venster",
        .pl: "Wybierz okno",
        .pt: "Escolher janela",
        .ro: "Alege fereastra",
        .ru: "Выберите окно",
        .sk: "Vyberte okno",
        .sl: "Izberi okno",
        .sv: "Välj fönster",
        .th: "เลือกหน้าต่าง",
        .tr: "Pencere Seç",
        .uk: "Виберіть вікно",
        .vi: "Chọn cửa sổ",
        .zhHans: "选择窗口",
        .zhHant: "選擇視窗",
    ],
    "settings.title": [
        .ar: "الإعدادات",
        .ca: "Configuració",
        .cs: "Nastavení",
        .da: "Indstillinger",
        .de: "Einstellungen",
        .el: "Ρυθμίσεις",
        .en: "Settings",
        .es: "Ajustes",
        .fi: "Asetukset",
        .fr: "Réglages",
        .he: "הגדרות",
        .hi: "सेटिंग्स",
        .hr: "Postavke",
        .hu: "Beállítások",
        .id: "Pengaturan",
        .it: "Impostazioni",
        .ja: "設定",
        .ko: "설정",
        .ms: "Tetapan",
        .nb: "Innstillinger",
        .nl: "Instellingen",
        .pl: "Ustawienia",
        .pt: "Ajustes",
        .ro: "Setări",
        .ru: "Настройки",
        .sk: "Nastavenia",
        .sl: "Nastavitve",
        .sv: "Inställningar",
        .th: "การตั้งค่า",
        .tr: "Ayarlar",
        .uk: "Параметри",
        .vi: "Cài đặt",
        .zhHans: "设置",
        .zhHant: "設定",
    ],
    "menu.settings": [
        .ar: "الإعدادات…",
        .ca: "Configuració…",
        .cs: "Nastavení…",
        .da: "Indstillinger…",
        .de: "Einstellungen…",
        .el: "Ρυθμίσεις…",
        .en: "Settings…",
        .es: "Ajustes…",
        .fi: "Asetukset…",
        .fr: "Réglages…",
        .he: "הגדרות…",
        .hi: "सेटिंग्स…",
        .hr: "Postavke…",
        .hu: "Beállítások…",
        .id: "Pengaturan…",
        .it: "Impostazioni…",
        .ja: "設定…",
        .ko: "설정…",
        .ms: "Tetapan…",
        .nb: "Innstillinger…",
        .nl: "Instellingen…",
        .pl: "Ustawienia…",
        .pt: "Ajustes…",
        .ro: "Setări…",
        .ru: "Настройки…",
        .sk: "Nastavenia…",
        .sl: "Nastavitve…",
        .sv: "Inställningar…",
        .th: "การตั้งค่า…",
        .tr: "Ayarlar…",
        .uk: "Параметри…",
        .vi: "Cài đặt…",
        .zhHans: "设置…",
        .zhHant: "設定…",
    ],
    "settings.general": [
        .ar: "عام",
        .ca: "General",
        .cs: "Obecné",
        .da: "Generelt",
        .de: "Allgemein",
        .el: "Γενικά",
        .en: "General",
        .es: "General",
        .fi: "Yleiset",
        .fr: "Général",
        .he: "כללי",
        .hi: "सामान्य",
        .hr: "Općenito",
        .hu: "Általános",
        .id: "Umum",
        .it: "Generali",
        .ja: "一般",
        .ko: "일반",
        .ms: "Umum",
        .nb: "Generelt",
        .nl: "Algemeen",
        .pl: "Ogólne",
        .pt: "Geral",
        .ro: "General",
        .ru: "Основные",
        .sk: "Všeobecné",
        .sl: "Splošno",
        .sv: "Allmänt",
        .th: "ทั่วไป",
        .tr: "Genel",
        .uk: "Загальні",
        .vi: "Chung",
        .zhHans: "通用",
        .zhHant: "一般",
    ],
    "settings.startAtLogin": [
        .ar: "التشغيل عند تسجيل الدخول",
        .ca: "Inicia en iniciar la sessió",
        .cs: "Spustit při přihlášení",
        .da: "Start ved login",
        .de: "Beim Login starten",
        .el: "Εκκίνηση κατά τη σύνδεση",
        .en: "Start at Login",
        .es: "Iniciar al iniciar sesión",
        .fi: "Käynnistä kirjautuessa",
        .fr: "Démarrer à la connexion",
        .he: "הפעלה בעת ההתחברות",
        .hi: "लॉगिन पर प्रारंभ करें",
        .hr: "Pokreni pri prijavi",
        .hu: "Indítás bejelentkezéskor",
        .id: "Mulai saat Login",
        .it: "Avvia all'accesso",
        .ja: "ログイン時に起動",
        .ko: "로그인 시 시작",
        .ms: "Mula semasa Log Masuk",
        .nb: "Start ved innlogging",
        .nl: "Starten bij inloggen",
        .pl: "Uruchom przy zalogowaniu",
        .pt: "Iniciar ao entrar",
        .ro: "Pornire la conectare",
        .ru: "Запускать при входе",
        .sk: "Spustiť pri prihlásení",
        .sl: "Zagon ob prijavi",
        .sv: "Starta vid inloggning",
        .th: "เริ่มเมื่อลงชื่อเข้าใช้",
        .tr: "Girişte Başlat",
        .uk: "Запускати під час входу",
        .vi: "Khởi động khi đăng nhập",
        .zhHans: "登录时启动",
        .zhHant: "登入時啟動",
    ],
    "settings.showMenuBarIcon": [
        .ar: "إظهار رمز شريط القوائم",
        .ca: "Mostra la icona de la barra de menús",
        .cs: "Zobrazit ikonu v panelu nabídek",
        .da: "Vis menulinjeikon",
        .de: "Menüleisten-Symbol anzeigen",
        .el: "Εμφάνιση εικονιδίου γραμμής μενού",
        .en: "Show Menu Bar Icon",
        .es: "Mostrar icono de la barra de menús",
        .fi: "Näytä valikkorivin kuvake",
        .fr: "Afficher l'icône de la barre des menus",
        .he: "הצג סמל בשורת התפריטים",
        .hi: "मेनू बार आइकन दिखाएं",
        .hr: "Prikaži ikonu trake izbornika",
        .hu: "Menüsor ikon megjelenítése",
        .id: "Tampilkan Ikon Bilah Menu",
        .it: "Mostra icona nella barra dei menu",
        .ja: "メニューバーアイコンを表示",
        .ko: "메뉴 막대 아이콘 보기",
        .ms: "Tunjukkan Ikon Bar Menu",
        .nb: "Vis menylinjeikon",
        .nl: "Toon menubalkpictogram",
        .pl: "Pokaż ikonę paska menu",
        .pt: "Mostrar ícone da barra de menus",
        .ro: "Afișează pictograma din bara de meniu",
        .ru: "Показывать значок в строке меню",
        .sk: "Zobraziť ikonu na paneli s ponukou",
        .sl: "Pokaži ikono v menijski vrstici",
        .sv: "Visa ikon i menyraden",
        .th: "แสดงไอคอนแถบเมนู",
        .tr: "Menü Çubuğu Simgesini Göster",
        .uk: "Показувати значок у рядку меню",
        .vi: "Hiện biểu tượng thanh menu",
        .zhHans: "显示菜单栏图标",
        .zhHant: "顯示選單列圖示",
    ],
    "settings.accentColor": [
        .ar: "لون التمييز",
        .ca: "Color d'accent",
        .cs: "Barva zvýraznění",
        .da: "Accentfarve",
        .de: "Akzentfarbe",
        .el: "Χρώμα έμφασης",
        .en: "Accent Color",
        .es: "Color de énfasis",
        .fi: "Korostusväri",
        .fr: "Couleur d'accentuation",
        .he: "צבע הדגשה",
        .hi: "एक्सेंट रंग",
        .hr: "Boja isticanja",
        .hu: "Kiemelőszín",
        .id: "Warna Aksen",
        .it: "Colore d'accento",
        .ja: "アクセントカラー",
        .ko: "강조 색상",
        .ms: "Warna Aksen",
        .nb: "Aksentfarge",
        .nl: "Accentkleur",
        .pl: "Kolor akcentu",
        .pt: "Cor de destaque",
        .ro: "Culoare de accent",
        .ru: "Акцентный цвет",
        .sk: "Farba zvýraznenia",
        .sl: "Barva poudarka",
        .sv: "Accentfärg",
        .th: "สีเน้น",
        .tr: "Vurgu Rengi",
        .uk: "Акцентний колір",
        .vi: "Màu nhấn",
        .zhHans: "强调色",
        .zhHant: "強調色",
    ],
    "menu.showLauncher": [
        .ar: "إظهار مشغّل التطبيقات",
        .ca: "Mostra el llançador d'apps",
        .cs: "Zobrazovat spouštěč aplikací",
        .da: "Vis appstarter",
        .de: "App-Launcher anzeigen",
        .el: "Εμφάνιση εκκινητή εφαρμογών",
        .en: "Show App Launcher",
        .es: "Mostrar lanzador de apps",
        .fi: "Näytä ohjelmien käynnistin",
        .fr: "Afficher le lanceur d'apps",
        .he: "הצג את משגר האפליקציות",
        .hi: "ऐप लॉन्चर दिखाएं",
        .hr: "Prikaži pokretač aplikacija",
        .hu: "Alkalmazásindító megjelenítése",
        .id: "Tampilkan Peluncur Aplikasi",
        .it: "Mostra il launcher di app",
        .ja: "Appランチャーを表示",
        .ko: "앱 실행기 표시",
        .ms: "Tunjukkan Pelancar Apl",
        .nb: "Vis appstarter",
        .nl: "Toon app-starter",
        .pl: "Pokaż launcher aplikacji",
        .pt: "Mostrar lançador de apps",
        .ro: "Afișează lansatorul de aplicații",
        .ru: "Показывать лаунчер приложений",
        .sk: "Zobraziť spúšťač aplikácií",
        .sl: "Pokaži zaganjalnik aplikacij",
        .sv: "Visa appstartare",
        .th: "แสดงตัวเปิดแอป",
        .tr: "Uygulama Başlatıcıyı Göster",
        .uk: "Показувати лаунчер програм",
        .vi: "Hiện trình khởi chạy ứng dụng",
        .zhHans: "显示应用启动器",
        .zhHant: "顯示應用程式啟動器",
    ],
    "menu.searchPaths": [
        .ar: "مسارات البحث",
        .ca: "Camins de cerca",
        .cs: "Cesty hledání",
        .da: "Søgestier",
        .de: "Suchpfade",
        .el: "Διαδρομές αναζήτησης",
        .en: "Search Paths",
        .es: "Rutas de búsqueda",
        .fi: "Hakupolut",
        .fr: "Chemins de recherche",
        .he: "נתיבי חיפוש",
        .hi: "खोज पथ",
        .hr: "Putanje pretraživanja",
        .hu: "Keresési útvonalak",
        .id: "Jalur Pencarian",
        .it: "Percorsi di ricerca",
        .ja: "検索パス",
        .ko: "검색 경로",
        .ms: "Laluan Carian",
        .nb: "Søkestier",
        .nl: "Zoekpaden",
        .pl: "Ścieżki wyszukiwania",
        .pt: "Caminhos de busca",
        .ro: "Căi de căutare",
        .ru: "Пути поиска",
        .sk: "Cesty vyhľadávania",
        .sl: "Poti iskanja",
        .sv: "Sökvägar",
        .th: "เส้นทางการค้นหา",
        .tr: "Arama Yolları",
        .uk: "Шляхи пошуку",
        .vi: "Đường dẫn tìm kiếm",
        .zhHans: "搜索路径",
        .zhHant: "搜尋路徑",
    ],
    "menu.addFolder": [
        .ar: "إضافة مجلد…",
        .ca: "Afegeix una carpeta…",
        .cs: "Přidat složku…",
        .da: "Tilføj mappe…",
        .de: "Ordner hinzufügen…",
        .el: "Προσθήκη φακέλου…",
        .en: "Add Folder…",
        .es: "Añadir carpeta…",
        .fi: "Lisää kansio…",
        .fr: "Ajouter un dossier…",
        .he: "הוסף תיקייה…",
        .hi: "फ़ोल्डर जोड़ें…",
        .hr: "Dodaj mapu…",
        .hu: "Mappa hozzáadása…",
        .id: "Tambah Folder…",
        .it: "Aggiungi cartella…",
        .ja: "フォルダを追加…",
        .ko: "폴더 추가…",
        .ms: "Tambah Folder…",
        .nb: "Legg til mappe…",
        .nl: "Map toevoegen…",
        .pl: "Dodaj folder…",
        .pt: "Adicionar pasta…",
        .ro: "Adaugă dosar…",
        .ru: "Добавить папку…",
        .sk: "Pridať priečinok…",
        .sl: "Dodaj mapo…",
        .sv: "Lägg till mapp…",
        .th: "เพิ่มโฟลเดอร์…",
        .tr: "Klasör Ekle…",
        .uk: "Додати папку…",
        .vi: "Thêm thư mục…",
        .zhHans: "添加文件夹…",
        .zhHant: "加入檔案夾…",
    ],
    "menu.remove": [
        .ar: "إزالة",
        .ca: "Elimina",
        .cs: "Odebrat",
        .da: "Fjern",
        .de: "Entfernen",
        .el: "Αφαίρεση",
        .en: "Remove",
        .es: "Eliminar",
        .fi: "Poista",
        .fr: "Supprimer",
        .he: "הסר",
        .hi: "हटाएं",
        .hr: "Ukloni",
        .hu: "Eltávolítás",
        .id: "Hapus",
        .it: "Rimuovi",
        .ja: "削除",
        .ko: "제거",
        .ms: "Buang",
        .nb: "Fjern",
        .nl: "Verwijder",
        .pl: "Usuń",
        .pt: "Remover",
        .ro: "Elimină",
        .ru: "Удалить",
        .sk: "Odstrániť",
        .sl: "Odstrani",
        .sv: "Ta bort",
        .th: "ลบ",
        .tr: "Kaldır",
        .uk: "Вилучити",
        .vi: "Xóa",
        .zhHans: "移除",
        .zhHant: "移除",
    ],
    "menu.appearance.system": [
        .ar: "تلقائي",
        .ca: "Automàtic",
        .cs: "Automaticky",
        .da: "Automatisk",
        .de: "Automatisch",
        .el: "Αυτόματα",
        .en: "Auto",
        .es: "Automático",
        .fi: "Automaattinen",
        .fr: "Automatique",
        .he: "אוטומטי",
        .hi: "स्वचालित",
        .hr: "Automatski",
        .hu: "Automatikus",
        .id: "Otomatis",
        .it: "Automatico",
        .ja: "自動",
        .ko: "자동",
        .ms: "Automatik",
        .nb: "Auto",
        .nl: "Automatisch",
        .pl: "Automatycznie",
        .pt: "Automático",
        .ro: "Automat",
        .ru: "Автоматически",
        .sk: "Automaticky",
        .sl: "Samodejno",
        .sv: "Automatiskt",
        .th: "อัตโนมัติ",
        .tr: "Otomatik",
        .uk: "Автоматично",
        .vi: "Tự động",
        .zhHans: "自动",
        .zhHant: "自動",
    ],
    "alert.accessibility.body": [
        .ar: "لتحريك النوافذ، يجب السماح بالوصول لهذا التطبيق من إعدادات النظام ضمن 'الخصوصية والأمان' > 'إمكانية الوصول'، ثم أعد تشغيل التطبيق.",
        .ca: "Per moure finestres, has de permetre l'accés a aquesta app a Configuració del Sistema, a 'Privadesa i seguretat' > 'Accessibilitat', i després reiniciar l'app.",
        .cs: "Aby bylo možné přesouvat okna, povolte přístup pro tuto aplikaci v Systémové nastavení v části 'Soukromí a zabezpečení' > 'Zpřístupnění' a poté aplikaci restartujte.",
        .da: "For at kunne flytte vinduer skal du give adgang til denne app i Systemindstillinger under 'Privatliv og sikkerhed' > 'Tilgængelighed' og derefter genstarte appen.",
        .de: "Damit Fenster verschoben werden können, musst du in den Systemeinstellungen unter 'Datenschutz & Sicherheit' > 'Bedienungshilfen' den Zugriff für diese App erlauben. Starte die App danach neu.",
        .el: "Για να μετακινούνται τα παράθυρα, πρέπει να επιτρέψετε την πρόσβαση σε αυτήν την εφαρμογή από τις Ρυθμίσεις Συστήματος, στην ενότητα 'Απόρρητο και ασφάλεια' > 'Προσβασιμότητα', και μετά να επανεκκινήσετε την εφαρμογή.",
        .en: "To move windows, allow access for this app in System Settings under 'Privacy & Security' > 'Accessibility', then restart the app.",
        .es: "Para mover ventanas, debes permitir el acceso a esta app en Ajustes del Sistema, en 'Privacidad y seguridad' > 'Accesibilidad', y luego reiniciar la app.",
        .fi: "Ikkunoiden siirtämistä varten anna tälle sovellukselle käyttöoikeus kohdassa Järjestelmäasetukset > 'Yksityisyys ja turvallisuus' > 'Helppokäyttötoiminnot' ja käynnistä sovellus sitten uudelleen.",
        .fr: "Pour déplacer les fenêtres, autorisez l'accès de cette app dans les Réglages Système, sous 'Confidentialité et sécurité' > 'Accessibilité', puis redémarrez l'app.",
        .he: "כדי להזיז חלונות, יש לאשר גישה לאפליקציה זו בהעדפות מערכת תחת 'פרטיות ואבטחה' > 'נגישות', ולאחר מכן להפעיל מחדש את האפליקציה.",
        .hi: "विंडो को स्थानांतरित करने के लिए, सिस्टम सेटिंग्स में 'गोपनीयता और सुरक्षा' > 'एक्सेसिबिलिटी' के अंतर्गत इस ऐप को एक्सेस की अनुमति दें, फिर ऐप को पुनः आरंभ करें।",
        .hr: "Da biste mogli pomicati prozore, dopustite pristup ovoj aplikaciji u Postavke sustava pod 'Privatnost i sigurnost' > 'Pristupačnost', a zatim ponovno pokrenite aplikaciju.",
        .hu: "Az ablakok mozgatásához engedélyezze az alkalmazás hozzáférését a Rendszerbeállítások 'Adatvédelem és biztonság' > 'Kisegítő lehetőségek' pontjában, majd indítsa újra az alkalmazást.",
        .id: "Untuk memindahkan jendela, izinkan akses untuk aplikasi ini di Pengaturan Sistem pada 'Privasi & Keamanan' > 'Aksesibilitas', lalu mulai ulang aplikasi.",
        .it: "Per spostare le finestre, consenti l'accesso a questa app in Impostazioni di Sistema, in 'Privacy e sicurezza' > 'Accessibilità', poi riavvia l'app.",
        .ja: "ウインドウを移動するには、システム設定の「プライバシーとセキュリティ」>「アクセシビリティ」でこのアプリのアクセスを許可し、アプリを再起動してください。",
        .ko: "창을 이동하려면 시스템 설정의 '개인정보 보호 및 보안' > '손쉬운 사용'에서 이 앱의 접근을 허용한 후 앱을 재시작하세요.",
        .ms: "Untuk menggerakkan tetingkap, benarkan akses untuk apl ini dalam Tetapan Sistem di bawah 'Privasi & Keselamatan' > 'Kebolehcapaian', kemudian mulakan semula apl.",
        .nb: "For å flytte vinduer må du gi denne appen tilgang i Systeminnstillinger under 'Personvern og sikkerhet' > 'Tilgjengelighet', og deretter starte appen på nytt.",
        .nl: "Om vensters te kunnen verplaatsen, moet je toegang voor deze app toestaan in Systeeminstellingen bij 'Privacy en beveiliging' > 'Toegankelijkheid' en de app daarna opnieuw starten.",
        .pl: "Aby przesuwać okna, zezwól tej aplikacji na dostęp w Ustawienia systemowe w sekcji 'Prywatność i bezpieczeństwo' > 'Dostępność', a następnie uruchom aplikację ponownie.",
        .pt: "Para mover janelas, permita o acesso a este app em Ajustes do Sistema, em 'Privacidade e segurança' > 'Acessibilidade' e reinicie o app.",
        .ro: "Pentru a muta ferestre, permite accesul acestei aplicații din Setări sistem, la 'Confidențialitate și securitate' > 'Accesibilitate', apoi repornește aplicația.",
        .ru: "Чтобы перемещать окна, разрешите доступ этому приложению в Системные настройки в разделе «Конфиденциальность и безопасность» > «Универсальный доступ», а затем перезапустите приложение.",
        .sk: "Ak chcete presúvať okná, povoľte tejto aplikácii prístup v Systémové nastavenia v časti 'Súkromie a bezpečnosť' > 'Zjednodušenie ovládania' a potom aplikáciu reštartujte.",
        .sl: "Za premikanje oken tej aplikaciji omogočite dostop v Sistemske nastavitve pod 'Zasebnost in varnost' > 'Dostopnost' in nato znova zaženite aplikacijo.",
        .sv: "För att flytta fönster måste du tillåta åtkomst för den här appen i Systeminställningar under 'Sekretess och säkerhet' > 'Tillgänglighet' och sedan starta om appen.",
        .th: "หากต้องการย้ายหน้าต่าง โปรดอนุญาตการเข้าถึงแอปนี้ในการตั้งค่าระบบภายใต้ 'ความเป็นส่วนตัวและความปลอดภัย' > 'การช่วยการเข้าถึง' จากนั้นเริ่มแอปใหม่",
        .tr: "Pencereleri taşımak için Sistem Ayarları içinde 'Gizlilik ve Güvenlik' > 'Erişilebilirlik' bölümünden bu uygulamaya erişim izni verin, ardından uygulamayı yeniden başlatın.",
        .uk: "Щоб переміщувати вікна, дозвольте доступ для цієї програми в Системні налаштування у розділі «Конфіденційність і безпека» > «Універсальний доступ», а потім перезапустіть програму.",
        .vi: "Để di chuyển cửa sổ, hãy cho phép ứng dụng này truy cập trong Cài đặt Hệ thống ở mục 'Quyền riêng tư & Bảo mật' > 'Trợ năng', sau đó khởi động lại ứng dụng.",
        .zhHans: "要移动窗口，请在“系统设置”的“隐私与安全性”>“辅助功能”中允许此应用的访问权限，然后重新启动应用。",
        .zhHant: "若要移動視窗，請在「系統設定」的「隱私權與安全性」>「輔助使用」中允許此應用程式的存取權限，然後重新啟動應用程式。",
    ],
]

/// Liefert den Text fuer `key` in der aktuell aktiven Sprache. Fehlt ein Eintrag
/// fuer die aktuelle Sprache (z.B. ein neuer Schluessel, der noch nicht fuer alle
/// 34 Sprachen gepflegt ist), faellt das auf Englisch zurueck statt den rohen
/// Schluessel anzuzeigen.
func L(_ key: String) -> String {
    guard let entry = translations[key] else { return key }
    return entry[AppLanguage.current] ?? entry[.en] ?? key
}

// MARK: - Color Settings

func accentColor() -> NSColor {
    guard let data = UserDefaults.standard.data(forKey: "customAccentColor"),
          let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
        return NSColor(red: 0.2, green: 0.55, blue: 1.0, alpha: 1.0)
    }
    return color
}

func setAccentColor(_ color: NSColor) {
    if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
        UserDefaults.standard.set(data, forKey: "customAccentColor")
    }
}

/// Faerbt echtes Liquid Glass (`NSGlassEffectView`) mit der vom Nutzer gewaehlten
/// Akzentfarbe ein. Bleibt bewusst zurueckhaltend: Das Glas soll den Akzent tragen,
/// nicht von ihm uebertoent werden - "ein Akzent, konsequent verwendet", nicht bunt.
func glassTint(_ alpha: CGFloat = 0.16) -> NSColor {
    accentColor().withAlphaComponent(alpha)
}

// MARK: - Einstellungen: Launcher & Suchpfade

enum LauncherSettings {
    private static let enabledKey = "launcherEnabled"
    private static let pathsKey = "extraSearchPaths"

    /// Standardmaessig an - der Launcher ist Teil des Kernablaufs.
    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .launcherSettingsDidChange, object: nil)
        }
    }

    /// Zusaetzliche Ordner, in denen nach Apps gesucht wird - ergaenzend zu
    /// /Applications, /System/Applications und dem Benutzer-Programmordner.
    static var extraPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: pathsKey) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: pathsKey)
            NotificationCenter.default.post(name: .launcherSettingsDidChange, object: nil)
        }
    }

    static func addPath(_ path: String) {
        var paths = extraPaths
        guard !paths.contains(path) else { return }
        paths.append(path)
        extraPaths = paths
    }

    static func removePath(_ path: String) {
        extraPaths = extraPaths.filter { $0 != path }
    }
}

enum GeneralSettings {
    private static let statusIconHiddenKey = "statusIconHidden"

    /// Sichtbarkeit des Menueleisten-Symbols. Liegt hier statt im AppDelegate,
    /// weil sowohl das Einstellungsfenster als auch der Entry Point (der vor dem
    /// Start des Delegates entscheidet) darauf zugreifen muessen.
    static var isStatusIconHidden: Bool {
        get { UserDefaults.standard.bool(forKey: statusIconHiddenKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: statusIconHiddenKey)
            NotificationCenter.default.post(name: .statusIconVisibilityDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let launcherSettingsDidChange = Notification.Name("launcherSettingsDidChange")
    static let statusIconVisibilityDidChange = Notification.Name("statusIconVisibilityDidChange")
    static let accentColorDidChange = Notification.Name("accentColorDidChange")
}

// MARK: - Design Modes

/// Vier vollstaendige, gegenseitig exklusive Erscheinungsbilder - keine automatische
/// Herleitung aus dem System-Appearance, sondern eine bewusste Wahl wie Akzentfarbe
/// oder Sprache. Light/Dark bilden macOS' eigene Systemmaterialien nach; Glass ist
/// das bereits umgesetzte Liquid-Glass-Material; Calm ist ein eigenstaendiger,
/// undurchsichtiger Look mit fester Palette statt globaler Akzentfarbe.
enum DesignMode: String, CaseIterable {
    case system, light, dark, glass, calm

    private static let defaultsKey = "designMode"

    static var current: DesignMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = DesignMode(rawValue: raw) else { return .glass }
        return mode
    }

    static func setCurrent(_ mode: DesignMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: .designModeDidChange, object: nil)
    }

    /// "system" loest bereits auf Light/Dark auf, je nachdem, was das echte
    /// System-Erscheinungsbild gerade ist.
    var resolved: DesignMode {
        guard self == .system else { return self }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? .dark : .light
    }

    /// Anzeigename im Menue - "Liquid Glass" und "Calm" sind Eigennamen und bleiben
    /// deshalb in jeder Sprache unuebersetzt, wie "AirDrop" oder "Stage Manager".
    var menuTitle: String {
        switch self {
        case .system: return L("menu.appearance.system")
        case .light: return L("menu.appearance.light")
        case .dark: return L("menu.appearance.dark")
        case .glass: return "Liquid Glass"
        case .calm: return "Calm"
        }
    }
}

extension Notification.Name {
    static let designModeDidChange = Notification.Name("designModeDidChange")
}

/// Prozessuebergreifend (DistributedNotificationCenter) statt nur app-lokal: eine
/// neu gestartete, sofort wieder beendete Instanz nutzt das, um die bereits
/// laufende Instanz zu bitten, ihr Menue zu zeigen - siehe Entry Point und
/// `AppDelegate.handleShowSettingsRequest`.
let showSettingsRequestNotification = Notification.Name("com.arunmeyer.WindowMangerDeClaude.showSettings")

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: alpha)
    }
}

/// Wie ein Panel sein Material aufbaut. Nur Liquid Glass ist tatsaechlich
/// durchscheinend - alle anderen Modi sind eine deckende Flaeche, nur die
/// Zielvorschau beim Ziehen bleibt (ausser in Calm) transluzent. Siehe
/// `DesignTokens.previewIsOpaque`.
enum PanelMaterial {
    case glass      // NSGlassEffectView - Liquid Glass, einziges durchscheinendes Material
    case opaque     // schlichte deckende NSView - Light, Dark, Calm
}

/// Der vollstaendige Satz an Gestaltungswerten fuer einen Modus. Ein Aufruf pro
/// Panel-Aufbau/Refresh - keine laufende Kostenstelle, daher bewusst als einfacher
/// Wertetyp statt eines beobachtbaren Objekts.
struct DesignTokens {
    let material: PanelMaterial
    let panelRadius: CGFloat
    let zoneRadius: CGFloat
    let text: NSColor
    let textMuted: NSColor
    let panelBorder: NSColor
    let zoneFill: NSColor
    let zoneEdge: NSColor
    let layoutBg: NSColor
    /// Deckende Panel-Flaeche - bei `material == .opaque` tatsaechlich gezeichnet.
    /// Glas bezieht seine Flaeche aus dem Systemmaterial selbst.
    let opaquePanelFill: NSColor
    /// Globale Akzentfarbe. In Calm bewusst fest statt aus dem Farbwaehler - siehe
    /// `accentPickerEnabled`.
    let accent: NSColor
    let accentPickerEnabled: Bool
    /// Jede Zonen-Gruppe traegt ihre eigene Palettenfarbe statt der globalen
    /// Akzentfarbe - nur in Calm. Gilt fuer Panel-Kacheln UND Zielvorschau gleichermassen.
    let usesGroupPalette: Bool
    /// Die Zielvorschau beim Ziehen ist normalerweise ein transluzenter Farbwasch.
    /// In Calm gibt es keinerlei Transparenz - dort wirkt sie wie eine feste,
    /// deckende Papierkarte an der Zielposition.
    let previewIsOpaque: Bool
    /// Erzwingt Aqua/DarkAqua auf der Material-View, unabhaengig vom System - so
    /// bleiben Light/Dark echte, unabhaengige Wahlmoeglichkeiten statt nur System
    /// nachzuahmen, und eingebettete native Controls (Suchfeld) passen farblich.
    /// nil nur bei Glass, das dem echten System-Erscheinungsbild folgen soll.
    let forcedAppearance: NSAppearance.Name?
    /// SF-Pro-Rounded statt der Systemschrift - Calms weichere, "Nunito"-nahe Anmutung
    /// ganz ohne eigene Schriftdatei im Bundle.
    let usesRoundedFont: Bool
    /// Ziel-Skalierung beim Hover - im Mockup fuer alle Modi einheitlich 1,12
    /// (vorher im Code 1,22; das Mockup-Wert gewinnt, siehe Design-Briefing).
    let hoverScale: CGFloat
    /// Eigene, etwas straffere Feder fuer den Icon-Hover.
    let hoverStiffness: Double
    let hoverDamping: Double
    /// Feder fuer die Zielvorschau (Zonenwechsel-Gleiten). Etwas weicher als der
    /// Icon-Hover, in Calm nochmal spuerbar ruhiger.
    let highlightStiffness: Double
    let highlightDamping: Double

    /// Loest "system" vorab auf Light/Dark auf, bevor der Tokensatz gebaut wird.
    static func current() -> DesignTokens { forMode(DesignMode.current.resolved) }

    static func forMode(_ mode: DesignMode) -> DesignTokens {
        switch mode {
        case .system:
            return forMode(mode.resolved)
        case .light:
            return DesignTokens(
                material: .opaque, panelRadius: 12, zoneRadius: 5,
                text: NSColor(hex: 0x14161B), textMuted: NSColor(hex: 0x5B6270),
                panelBorder: NSColor(hex: 0xDADCE0),
                zoneFill: NSColor(hex: 0xB4B4B4), zoneEdge: NSColor(hex: 0x9E9E9E),
                layoutBg: NSColor(white: 0, alpha: 0.05), opaquePanelFill: NSColor(hex: 0xF4F5F7),
                accent: accentColor(), accentPickerEnabled: true,
                usesGroupPalette: false, previewIsOpaque: false, forcedAppearance: .aqua,
                usesRoundedFont: false, hoverScale: 1.12, hoverStiffness: 260, hoverDamping: 26,
                highlightStiffness: 220, highlightDamping: 26)
        case .dark:
            return DesignTokens(
                material: .opaque, panelRadius: 12, zoneRadius: 5,
                text: NSColor(hex: 0xEDEFF3), textMuted: NSColor(hex: 0x9AA1AD),
                panelBorder: NSColor(hex: 0x2E3034),
                zoneFill: NSColor(hex: 0x45484D), zoneEdge: NSColor(hex: 0x56595F),
                layoutBg: NSColor(white: 1, alpha: 0.05), opaquePanelFill: NSColor(hex: 0x1C1E22),
                accent: accentColor(), accentPickerEnabled: true,
                usesGroupPalette: false, previewIsOpaque: false, forcedAppearance: .darkAqua,
                usesRoundedFont: false, hoverScale: 1.12, hoverStiffness: 260, hoverDamping: 26,
                highlightStiffness: 220, highlightDamping: 26)
        case .glass:
            return DesignTokens(
                material: .glass, panelRadius: 18, zoneRadius: 7,
                text: NSColor.labelColor, textMuted: NSColor.labelColor.withAlphaComponent(0.6),
                panelBorder: NSColor(white: 1, alpha: 0.28),
                zoneFill: NSColor(white: 1, alpha: 0.20), zoneEdge: NSColor(white: 1, alpha: 0.32),
                layoutBg: NSColor(white: 1, alpha: 0.08), opaquePanelFill: .clear,
                accent: accentColor(), accentPickerEnabled: true,
                usesGroupPalette: false, previewIsOpaque: false, forcedAppearance: nil,
                usesRoundedFont: false, hoverScale: 1.12, hoverStiffness: 260, hoverDamping: 26,
                highlightStiffness: 220, highlightDamping: 26)
        case .calm:
            return DesignTokens(
                material: .opaque, panelRadius: 22, zoneRadius: 9,
                text: NSColor(hex: 0x3B2F26), textMuted: NSColor(hex: 0x7A6B5D),
                panelBorder: NSColor(hex: 0xDED2BB),
                zoneFill: NSColor(hex: 0xE4EBD7), zoneEdge: NSColor(hex: 0xD6DFC3),
                layoutBg: NSColor(hex: 0x3B2F26, alpha: 0.05), opaquePanelFill: NSColor(hex: 0xF6EFDF),
                accent: NSColor(hex: 0x7A9A5C), accentPickerEnabled: false,
                usesGroupPalette: true, previewIsOpaque: true, forcedAppearance: .aqua,
                usesRoundedFont: true, hoverScale: 1.12, hoverStiffness: 200, hoverDamping: 24,
                highlightStiffness: 170, highlightDamping: 24)
        }
    }
}

/// Feste Palette in Calm: jede Zonen-Gruppe traegt ihre eigene Farbe statt der
/// globalen Akzentfarbe - macht die vier Andock-Kategorien auf einen Blick
/// unterscheidbar, ganz ohne Text.
extension SnapGroup {
    var calmColor: NSColor {
        switch id {
        case 0: return NSColor(hex: 0x93A8AE) // Vollbild
        case 1: return NSColor(hex: 0x7A9A5C) // Haelften
        case 2: return NSColor(hex: 0xB97A4E) // Zwei Drittel & Drittel
        default: return NSColor(hex: 0xEFC75E) // Viertel
        }
    }
}

/// Liefert die Zonenfarbe fuer den aktuellen Modus: in Calm die Palettenfarbe der
/// Gruppe, die `layout` enthaelt; sonst die globale Akzentfarbe. Der Abgleich laeuft
/// ueber den Zonentitel, da `SnapLayout` keine eigene Identitaet traegt und Titel
/// innerhalb einer Ziehgeste eindeutig sind.
func zoneColor(for layout: SnapLayout, tokens: DesignTokens) -> NSColor {
    guard tokens.usesGroupPalette else { return tokens.accent }
    for group in snapGroups where group.zones.contains(where: { $0.title == layout.title }) {
        return group.calmColor
    }
    return tokens.accent
}

extension NSFont {
    /// Rundes Systemdesign (SF Pro Rounded) statt einer gebuendelten Schriftdatei -
    /// selbes Prinzip wie bei den Systemfarben: kein eigenes Asset pflegen.
    static func appFont(ofSize size: CGFloat, weight: NSFont.Weight, rounded: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

// MARK: - LaunchAgent / Login Item (Optimiert für moderne Macs)

func launchAgentURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.snap.windowmanager.plist")
}

func isLoginItemEnabled() -> Bool {
    if #available(macOS 13.0, *) {
        return SMAppService.mainApp.status == .enabled
    } else {
        return FileManager.default.fileExists(atPath: launchAgentURL().path)
    }
}

func toggleLoginItem() {
    if #available(macOS 13.0, *) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Fehler beim Ändern des Autostarts (SMAppService): \(error)")
        }
    } else {
        if isLoginItemEnabled() {
            do {
                try FileManager.default.removeItem(at: launchAgentURL())
            } catch {
                print("Fehler beim Entfernen der plist: \(error)")
            }
        } else {
            let exec = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let plist: [String: Any] = [
                "Label": "com.snap.windowmanager",
                "ProgramArguments": [exec],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            let url = launchAgentURL()
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: url)
            } catch {
                print("Fehler beim Schreiben der plist: \(error)")
            }
        }
    }
}

// MARK: - Snap Layout Model

struct SnapLayout {
    let title: String
    let previewRect: CGRect
    let compute: (CGRect) -> CGRect
}

struct SnapGroup {
    let id: Int
    let zones: [SnapLayout]
}

let snapGroups: [SnapGroup] = [
    SnapGroup(id: 0, zones: [
        SnapLayout(title: "Vollbild", previewRect: CGRect(x: 0, y: 0, width: 1, height: 1)) { r in
            CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        }
    ]),
    SnapGroup(id: 1, zones: [
        SnapLayout(title: "← ½", previewRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)) { r in CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height) },
        SnapLayout(title: "→ ½", previewRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)) { r in CGRect(x: r.minX + r.width / 2, y: r.minY, width: r.width / 2, height: r.height) }
    ]),
    SnapGroup(id: 2, zones: [
        SnapLayout(title: "← ⅔", previewRect: CGRect(x: 0, y: 0, width: 0.667, height: 1)) { r in CGRect(x: r.minX, y: r.minY, width: r.width * 2 / 3, height: r.height) },
        SnapLayout(title: "→ ⅓", previewRect: CGRect(x: 0.667, y: 0, width: 0.333, height: 1)) { r in CGRect(x: r.minX + r.width * 2 / 3, y: r.minY, width: r.width / 3, height: r.height) }
    ]),
    SnapGroup(id: 3, zones: [
        SnapLayout(title: "← ½", previewRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)) { r in CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height) },
        SnapLayout(title: "↗ ¼", previewRect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)) { r in CGRect(x: r.minX + r.width / 2, y: r.minY + r.height / 2, width: r.width / 2, height: r.height / 2) },
        SnapLayout(title: "↘ ¼", previewRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)) { r in CGRect(x: r.minX + r.width / 2, y: r.minY, width: r.width / 2, height: r.height / 2) }
    ]),
    SnapGroup(id: 4, zones: [
        SnapLayout(title: "↖", previewRect: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)) { r in CGRect(x: r.minX, y: r.minY + r.height / 2, width: r.width / 2, height: r.height / 2) },
        SnapLayout(title: "↗", previewRect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)) { r in CGRect(x: r.minX + r.width / 2, y: r.minY + r.height / 2, width: r.width / 2, height: r.height / 2) },
        SnapLayout(title: "↙", previewRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)) { r in CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height / 2) },
        SnapLayout(title: "↘", previewRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)) { r in CGRect(x: r.minX + r.width / 2, y: r.minY, width: r.width / 2, height: r.height / 2) }
    ])
]

// MARK: - App Models & Cache

struct AppItem: Equatable {
    let id: String
    let name: String
    /// Fertig rasterisiertes Icon fuer `layer.contents` - wird nie neu gezeichnet.
    var icon: CGImage?
    let url: URL?
    var runningApp: NSRunningApplication?
    
    var isRunning: Bool { return runningApp != nil }
    static func == (lhs: AppItem, rhs: AppItem) -> Bool { lhs.id == rhs.id }
}

class AppCache {
    static let shared = AppCache()
    var installedApps: [AppItem] = []
    /// Wird gemeldet, sobald die Liste erstmals steht - der Launcher kann dann vorwaermen.
    var onReload: (() -> Void)?
    
    func startMonitoring() {
        load()
        
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            self.load()
        }
    }
    
    /// Liest die App-Liste neu ein - etwa nachdem ein Suchpfad ergaenzt oder
    /// entfernt wurde. Laeuft wie der regulaere Refresh im Hintergrund.
    func reload() { load() }

    private func load() {
        DispatchQueue.global(qos: .utility).async {
            var searchURLs = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications")
            ]
            if let userApps = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
                searchURLs.append(userApps)
            }
            // Vom Nutzer ergaenzte Ordner - etwa ein Apps-Ordner auf einem
            // externen Volume, den macOS von sich aus nicht beruecksichtigt.
            for path in LauncherSettings.extraPaths {
                searchURLs.append(URL(fileURLWithPath: path))
            }
            
            var tempApps = [AppItem]()
            var seen = Set<String>()
            let fm = FileManager.default
            
            for baseURL in searchURLs {
                if let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey, .localizedNameKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    
                    while let fileURL = enumerator.nextObject() as? URL {
                        if fileURL.pathExtension == "app" {
                            var appName = fileURL.deletingPathExtension().lastPathComponent
                            if let resources = try? fileURL.resourceValues(forKeys: [.localizedNameKey]), let locName = resources.localizedName {
                                appName = locName
                            }
                            
                            let id = Bundle(url: fileURL)?.bundleIdentifier ?? appName
                            if !seen.contains(id) {
                                seen.insert(id)
                                tempApps.append(AppItem(id: id, name: appName, icon: nil, url: fileURL, runningApp: nil))
                            }
                        }
                    }
                }
            }
            
            let sortedApps = tempApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            // Icons werden hier im Hintergrund rasterisiert. Frueher lief das auf dem
            // Main-Thread und hat die UI bei jedem Cache-Refresh sekundenlang blockiert.
            let finalApps = sortedApps.map { app -> AppItem in
                var updated = app
                if let url = app.url {
                    updated.icon = IconStore.shared.icon(key: url.path) {
                        NSWorkspace.shared.icon(forFile: url.path)
                    }
                }
                return updated
            }
            
            DispatchQueue.main.async {
                self.installedApps = finalApps
                self.onReload?()
            }
        }
    }
}

// MARK: - Window Handling Physics & Z-Order

func getMRUAppPIDs() -> [pid_t] {
    let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var orderedPIDs = [pid_t]()
    var seen = Set<pid_t>()
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
        if !seen.contains(pid) { seen.insert(pid); orderedPIDs.append(pid) }
    }
    return orderedPIDs
}

func findPIDUnderCursor(_ mousePos: NSPoint) -> pid_t {
    let screenH = NSScreen.screens.first!.frame.height
    let cgMouse = CGPoint(x: mousePos.x, y: screenH - mousePos.y)
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return 0 }
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let bd = info[kCGWindowBounds as String] as? [String: CGFloat],
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              pid != pid_t(ProcessInfo.processInfo.processIdentifier) else { continue }
        let rect = CGRect(x: bd["X"] ?? 0, y: bd["Y"] ?? 0, width: bd["Width"] ?? 0, height: bd["Height"] ?? 0)
        if rect.contains(cgMouse) { return pid }
    }
    return 0
}

func getWindowFrame(win: AXUIElement, screenH: CGFloat) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
    
    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    
    return CGRect(x: pos.x, y: screenH - pos.y - size.height, width: size.width, height: size.height)
}

/// Liest den Rahmen des gerade fokussierten Fensters eines Prozesses.
/// Synchroner AX-IPC in eine fremde App - ausschliesslich vom Hintergrund-Thread
/// aufrufen, nie vom Main-Thread.
func focusedWindowFrame(pid: pid_t, screenH: CGFloat, timeout: Float = 0.3) -> CGRect? {
    guard pid != 0 else { return nil }
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, timeout)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
          let winRef = ref else { return nil }
    return getWindowFrame(win: winRef as! AXUIElement, screenH: screenH)
}

func setWindowFrame(win: AXUIElement, target: CGRect, screenH: CGFloat) {
    var axPos = CGPoint(x: target.minX, y: screenH - target.minY - target.height)
    var axSize = CGSize(width: target.width, height: target.height)

    // Reihenfolge Position -> Groesse -> Position ist hier entscheidend:
    // Viele Apps beschneiden eine neue Groesse auf das, was vom aktuellen Ursprung aus
    // noch auf den Bildschirm passt. Wurde erst die Groesse gesetzt, blieb ein Fenster
    // aus der rechten Bildschirmhaelfte beim Maximieren zu klein - genau der Fehler
    // "geht zum Teil nicht Vollbild". Erst verschieben schafft den Platz; der zweite
    // Positionsaufruf faengt Apps ab, die beim Resizen selbst nachjustieren.
    if let pv = AXValueCreate(.cgPoint, &axPos) {
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
    }
    if let sv = AXValueCreate(.cgSize, &axSize) {
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
    }
    if let pv = AXValueCreate(.cgPoint, &axPos) {
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
    }
}

/// Laufende Snap-Animationen pro Prozess. Ein neuer Snap erhoeht die Generation,
/// dadurch beendet sich eine noch laufende aeltere Animation sofort selbst.
private let snapGenerationLock = NSLock()
private var snapGenerations = [pid_t: Int]()

private func nextSnapGeneration(for pid: pid_t) -> Int {
    snapGenerationLock.lock(); defer { snapGenerationLock.unlock() }
    let next = (snapGenerations[pid] ?? 0) + 1
    snapGenerations[pid] = next
    return next
}

private func snapGenerationIsCurrent(_ generation: Int, for pid: pid_t) -> Bool {
    snapGenerationLock.lock(); defer { snapGenerationLock.unlock() }
    return snapGenerations[pid] == generation
}

// MARK: - Wiederherstellung der Groesse vor dem Snap

struct RestoreEntry {
    /// Rahmen, den das Fenster vor dem ersten Snap hatte - das Ziel beim Wegziehen.
    var freeFrame: CGRect
    /// Rahmen, den wir zuletzt selbst gesetzt haben. Referenz fuer die Frage, ob der
    /// Nutzer zwischendurch selbst die Groesse veraendert hat.
    var snappedFrame: CGRect
}

/// Merkt sich pro Prozess, wie gross das Fenster vor dem Snappen war.
/// Nur vom Main-Thread benutzen.
final class WindowRestoreStore {
    static let shared = WindowRestoreStore()
    private var entries = [pid_t: RestoreEntry]()

    func entry(for pid: pid_t) -> RestoreEntry? { entries[pid] }
    func clear(_ pid: pid_t) { entries[pid] = nil }

    /// Bei einer Snap-Kette (links -> oben rechts -> ...) bleibt der urspruengliche
    /// freie Rahmen erhalten; nur der zuletzt gesetzte Snap-Rahmen wird nachgezogen.
    /// Dadurch fuehrt das Wegziehen immer zurueck zum letzten manuellen Zustand.
    func recordSnap(pid: pid_t, freeFrameCandidate: CGRect, snappedFrame: CGRect) {
        if var existing = entries[pid] {
            existing.snappedFrame = snappedFrame
            entries[pid] = existing
        } else {
            entries[pid] = RestoreEntry(freeFrame: freeFrameCandidate, snappedFrame: snappedFrame)
        }
    }
}

/// Animiert das fokussierte Fenster eines Prozesses federnd auf `target`.
/// - Parameter animateSize: Groesse mitfedern statt sie vorab in einem Schritt zu
///   setzen. Nur fuer "Vollbild" sinnvoll: dort ist die Zielgroesse so gross wie die
///   nutzbare Bildschirmflaeche, es gibt also gar keinen Platz, um bei voller Groesse
///   noch eine Position zu animieren. Ohne Mitfedern blieb nur der harte Sprung am
///   Ende der Bewegung - genau das wirkte "unfluessig".
/// - Parameter onFinished: erhaelt auf dem Main-Thread den Ausgangsrahmen und den
///   tatsaechlich erreichten Endrahmen.
/// Zaehlt laufende, von uns selbst ausgeloeste Fensteranimationen.
///
/// Bei Fingereingabe erkennen wir Ziehgesten ausschliesslich an AX-Meldungen ueber
/// Fensterbewegungen. Unsere eigene Snap-Animation bewegt aber ebenfalls Fenster -
/// ohne diese Sperre wuerde jeder Snap sofort als neue Nutzergeste gelten und sich
/// endlos selbst nachtriggern.
private let programmaticMoveLock = NSLock()
private var programmaticMoveCount = 0

func beginProgrammaticMove() {
    programmaticMoveLock.lock(); programmaticMoveCount += 1; programmaticMoveLock.unlock()
}

func endProgrammaticMove() {
    programmaticMoveLock.lock()
    programmaticMoveCount = max(0, programmaticMoveCount - 1)
    programmaticMoveLock.unlock()
}

var isProgrammaticMoveActive: Bool {
    programmaticMoveLock.lock(); defer { programmaticMoveLock.unlock() }
    return programmaticMoveCount > 0
}

/// - Parameter window: Ein bestimmtes Fenster statt des gerade fokussierten.
///   Wird vom Fenster-Auswahldialog genutzt, wenn eine App mehrere Fenster offen
///   hat und `kAXFocusedWindow` deshalb nicht eindeutig das gemeinte trifft.
func animateFocusedWindow(pid: pid_t,
                          to target: CGRect,
                          animateSize: Bool = false,
                          window: AXUIElement? = nil,
                          onFinished: ((CGRect, CGRect) -> Void)? = nil) {
    guard let screen = NSScreen.main, let firstScreen = NSScreen.screens.first else { return }
    let screenH = firstScreen.frame.height
    let generation = nextSnapGeneration(for: pid)
    // An die echte Bildwiederholrate koppeln: auf 60-Hz-Displays waeren 120 Schritte
    // pro Sekunde nur doppelt so viele AX-Aufrufe ohne sichtbaren Gewinn.
    let refreshHz = Double(max(60, min(120, screen.maximumFramesPerSecond)))

    // Der komplette AX-Teil laeuft im Hintergrund. Jeder einzelne AX-Aufruf ist ein
    // synchroner IPC in die Ziel-App und kann zweistellige Millisekunden dauern -
    // auf dem Main-Thread hat das bisher gleichzeitig die Panel-Animationen abgewuergt.
    DispatchQueue.global(qos: .userInteractive).async {
        beginProgrammaticMove()
        defer {
            // Kurze Nachlaufzeit: verspaetet eintreffende AX-Meldungen der eigenen
            // Animation duerfen nicht als Nutzergeste durchrutschen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { endProgrammaticMove() }
        }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.4)

        let win: AXUIElement
        if let explicit = window {
            win = explicit
        } else {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
                  let winRef = ref else { return }
            win = winRef as! AXUIElement
        }

        // Wird ein bestimmtes Fenster uebergeben (Fensterauswahl bei mehreren
        // offenen Fenstern derselben App), ist es nicht zwingend das, welches die
        // App selbst gerade als aktiv fuehrt. Ohne diese zwei Zeilen bewegt sich
        // das richtige Fenster zwar an die Zielposition, aber `activate()` holt
        // stattdessen ein anderes Fenster der App nach vorne - sichtbar wuerde dann
        // scheinbar "nichts passieren".
        if window != nil {
            AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, win)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }

        guard let startFrame = getWindowFrame(win: win, screenH: screenH) else {
            setWindowFrame(win: win, target: target, screenH: screenH)
            return
        }

        // Ohne Mitfedern wird die Groesse einmalig vorab gesetzt (teuerster AX-Aufruf),
        // animiert wird danach nur noch die Position. Dafuer braucht es ein
        // grosszuegiges Timeout, sonst bricht das Resize bei traegen Apps ab.
        if !animateSize {
            var axSize = CGSize(width: target.width, height: target.height)
            if let sv = AXValueCreate(.cgSize, &axSize) {
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
            }
        }

        // Ab jetzt kurzes Timeout: Ein haengender Frame darf die Animation nicht stauen.
        // Beim Mitfedern der Groesse etwas mehr Luft, weil ein Resize die Ziel-App zu
        // einem vollen Neu-Layout zwingt und damit traeger antwortet als ein Verschieben.
        AXUIElementSetMessagingTimeout(win, animateSize ? 0.09 : 0.05)

        // Spuerbar straffere Feder als zuvor (k=90/d=12 -> ~0.7s Nachlauf).
        // k=330, d=31 ergibt zeta ~0.85 und rund 0.25s bis zur Ruhe.
        let stiffness = 330.0
        let damping = 31.0
        let mass = 1.0
        let frameInterval = 1.0 / refreshHz
        let maxSubStep = 1.0 / 240.0
        var velX = 0.0, velY = 0.0, velW = 0.0, velH = 0.0
        var curX = Double(startFrame.minX), curY = Double(startFrame.minY)
        var curW = Double(startFrame.width), curH = Double(startFrame.height)
        let tX = Double(target.minX), tY = Double(target.minY)
        let tW = Double(target.width), tH = Double(target.height)
        var lastSent = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        var lastSentSize = CGSize(width: -1, height: -1)

        var previous = CACurrentMediaTime()
        let hardDeadline = previous + 1.2

        var superseded = false

        while true {
            let frameStart = CACurrentMediaTime()

            // Integration ueber die TATSAECHLICH vergangene Zeit statt ueber ein festes
            // dt. Vorher lief die Feder bei langsamem IPC in Zeitlupe und mit
            // schwankender Schrittweite - genau das sah wie Ruckeln aus.
            var elapsed = frameStart - previous
            previous = frameStart
            if elapsed <= 0 { elapsed = frameInterval }
            if elapsed > 0.05 { elapsed = 0.05 }

            var remaining = elapsed
            while remaining > 0 {
                let h = min(remaining, maxSubStep)
                velX += (-stiffness * (curX - tX) - damping * velX) / mass * h
                velY += (-stiffness * (curY - tY) - damping * velY) / mass * h
                curX += velX * h
                curY += velY * h
                if animateSize {
                    // Dieselben Federkonstanten wie fuer die Position, damit Wachsen
                    // und Wandern exakt im Gleichlauf ankommen.
                    velW += (-stiffness * (curW - tW) - damping * velW) / mass * h
                    velH += (-stiffness * (curH - tH) - damping * velH) / mass * h
                    curW += velW * h
                    curH += velH * h
                }
                remaining -= h
            }

            // AX rechnet von oben links, die Feder von unten links - die Umrechnung
            // braucht die Hoehe, die das Fenster in DIESEM Frame hat.
            let frameHeight = animateSize ? curH : Double(target.height)

            // Der WindowServer platziert Fenster ohnehin ganzzahlig - Runden spart
            // damit reine Leerlauf-IPCs ohne sichtbaren Unterschied.
            let posX = curX.rounded()
            let posY = (screenH - curY - frameHeight).rounded()

            // Position vor Groesse, aus demselben Grund wie in setWindowFrame:
            // erst Platz schaffen, dann wachsen.
            if posX != lastSent.x || posY != lastSent.y {
                var axPos = CGPoint(x: posX, y: posY)
                if let pv = AXValueCreate(.cgPoint, &axPos) {
                    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
                }
                lastSent = CGPoint(x: posX, y: posY)
            }

            if animateSize {
                let sizeW = curW.rounded()
                let sizeH = curH.rounded()
                if abs(sizeW - lastSentSize.width) >= 1 || abs(sizeH - lastSentSize.height) >= 1 {
                    var axSize = CGSize(width: sizeW, height: sizeH)
                    if let sv = AXValueCreate(.cgSize, &axSize) {
                        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
                    }
                    lastSentSize = CGSize(width: sizeW, height: sizeH)
                }
            }

            let settledPos = abs(curX - tX) < 0.6 && abs(curY - tY) < 0.6
                && abs(velX) < 6.0 && abs(velY) < 6.0
            let settledSize = !animateSize
                || (abs(curW - tW) < 0.6 && abs(curH - tH) < 0.6
                    && abs(velW) < 6.0 && abs(velH) < 6.0)
            if (settledPos && settledSize) || CACurrentMediaTime() > hardDeadline { break }
            if !snapGenerationIsCurrent(generation, for: pid) { superseded = true; break }

            // Auf den naechsten Frame-Slot warten. War der IPC langsamer als das
            // Budget, wird nicht geschlafen - die Bewegung bleibt zeitrichtig und
            // laeuft nur mit weniger Bildern statt zu stocken.
            let used = CACurrentMediaTime() - frameStart
            if used < frameInterval { Thread.sleep(forTimeInterval: frameInterval - used) }
        }

        guard !superseded, snapGenerationIsCurrent(generation, for: pid) else { return }
        AXUIElementSetMessagingTimeout(win, 0.4)
        setWindowFrame(win: win, target: target, screenH: screenH)

        if let onFinished {
            // Endrahmen zurueeklesen statt `target` anzunehmen: Apps mit Mindest- oder
            // Festgroesse landen nicht zwingend exakt dort, und ein falscher Referenz-
            // wert wuerde spaeter faelschlich als "Nutzer hat selbst resized" gelten.
            let actual = getWindowFrame(win: win, screenH: screenH) ?? target
            DispatchQueue.main.async { onFinished(startFrame, actual) }
        }
    }
}

func snapWindow(pid: pid_t, layout: SnapLayout, window: AXUIElement? = nil) {
    guard let screen = NSScreen.main else { return }
    let target = layout.compute(screen.visibleFrame)
    let isFullscreen = layout.title == "Vollbild"

    // Jeder Snap-Weg laeuft hier durch, deshalb wird die Vorher-Groesse zentral an
    // genau einer Stelle festgehalten - unabhaengig davon, ob der Snap aus dem Panel,
    // per Drop oder aus dem App-Launcher kam.
    animateFocusedWindow(pid: pid, to: target, animateSize: isFullscreen, window: window) { startFrame, actual in
        WindowRestoreStore.shared.recordSnap(pid: pid,
                                             freeFrameCandidate: startFrame,
                                             snappedFrame: actual)
    }
}

func launchAndSnap(appItem: AppItem, layout: SnapLayout) {
    guard let url = appItem.url else { return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
        guard let runningApp = app else { return }
        let pid = runningApp.processIdentifier
        let start = Date()
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        let pollQueue = DispatchQueue.global(qos: .userInitiated)

        func checkWindow() {
            if Date().timeIntervalSince(start) > 5.0 { return }
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success, ref != nil {
                // snapWindow liest NSScreen und muss daher auf dem Main-Thread starten.
                DispatchQueue.main.async {
                    snapWindow(pid: pid, layout: layout)
                    runningApp.activate(options: [])
                }
            } else {
                // Deutlich engeres Polling als die bisherigen 100ms: das Fenster wird
                // im Schnitt ~85ms frueher erwischt.
                pollQueue.asyncAfter(deadline: .now() + 0.015) { checkWindow() }
            }
        }
        pollQueue.async { checkWindow() }
    }
}

func leftoverRect(after layout: SnapLayout, screen: NSScreen) -> CGRect? {
    let vf = screen.visibleFrame
    let placed = layout.compute(vf)
    if vf.maxX - placed.maxX > vf.width * 0.2 {
        return CGRect(x: placed.maxX, y: vf.minY, width: vf.maxX - placed.maxX, height: vf.height)
    }
    if placed.minX - vf.minX > vf.width * 0.2 {
        return CGRect(x: vf.minX, y: vf.minY, width: placed.minX - vf.minX, height: vf.height)
    }
    return nil
}

// MARK: - Views (IconView & Flipped View)

class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

class SnapGroupIconView: NSView {
    let group: SnapGroup
    /// Massstab der Darstellung. Bei Fingerbedienung 1,5 - dann wachsen Einzuege
    /// und Rundungen mit, damit die Proportionen erhalten bleiben statt nur die
    /// Flaeche zu vergroessern.
    var scale: CGFloat = 1.0
    var hoveredZoneIndex: Int? = nil
    var onZoneSnap: ((SnapLayout) -> Void)?
    var onZoneHover: ((SnapLayout?) -> Void)?
    private var tracker: NSTrackingArea?
    private var isGroupHovered = false

    init(group: SnapGroup, frame: CGRect) {
        self.group = group
        super.init(frame: frame)
        wantsLayer = true
        rebuildTracker()
    }
    required init?(coder: NSCoder) { fatalError() }

    func zoneIndex(for localPoint: NSPoint) -> Int? {
        let area = bounds.insetBy(dx: 6 * scale, dy: 6 * scale)
        let rects = group.zones.map { zone -> CGRect in
            let pr = zone.previewRect
            return CGRect(x: area.minX + pr.minX * area.width,
                          y: area.minY + pr.minY * area.height,
                          width: pr.width * area.width,
                          height: pr.height * area.height)
        }

        for (i, r) in rects.enumerated() where r.contains(localPoint) { return i }

        // Kein direkter Treffer: die naechstgelegene Zone gewinnt. Vorher fiel jeder
        // Punkt zwischen oder neben den Zonen auf die ERSTE zurueck - bei den
        // Vierteln also stets auf "oben links", unabhaengig davon, wo man hinzeigt.
        // Das wirkte wie ein Fehler und war mit dem Finger, wo genaues Zielen kaum
        // moeglich ist, besonders stoerend. So gibt es keine toten Punkte mehr.
        guard bounds.contains(localPoint) else { return nil }
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, r) in rects.enumerated() {
            let dx = localPoint.x - r.midX
            let dy = localPoint.y - r.midY
            let d = dx * dx + dy * dy
            if d < bestDistance { bestDistance = d; bestIndex = i }
        }
        return bestIndex
    }

    override func draw(_ dirtyRect: NSRect) {
        let tokens = DesignTokens.current()
        // In Calm traegt jede Gruppe ihre eigene Palettenfarbe statt der globalen
        // Akzentfarbe - macht die vier Kategorien auf einen Blick unterscheidbar.
        let groupColor = tokens.usesGroupPalette ? group.calmColor : tokens.accent
        let cornerRadius: CGFloat = (tokens.usesGroupPalette ? 12 : 10) * scale

        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2 * scale, dy: 2 * scale),
                              xRadius: cornerRadius, yRadius: cornerRadius)
        let bgAlpha = tokens.layoutBg.alphaComponent * (isGroupHovered ? 1.6 : 1.0)
        tokens.layoutBg.withAlphaComponent(bgAlpha).setFill()
        bg.fill()

        let strokeColor = isGroupHovered ? groupColor.withAlphaComponent(0.7) : tokens.zoneEdge
        strokeColor.setStroke()
        bg.lineWidth = (isGroupHovered ? 1.5 : 0.75) * scale
        bg.stroke()

        let area = bounds.insetBy(dx: 7 * scale, dy: 7 * scale)
        for (i, zone) in group.zones.enumerated() {
            let pr = zone.previewRect
            let zr = CGRect(x: area.minX + pr.minX * area.width,
                            y: area.minY + pr.minY * area.height,
                            width: max(3, pr.width * area.width),
                            height: max(3, pr.height * area.height)).insetBy(dx: 1.5 * scale, dy: 1.5 * scale)

            let isHov = hoveredZoneIndex == i
            let zoneRadius = cornerRadius - 7 * scale
            let zPath = NSBezierPath(roundedRect: zr, xRadius: zoneRadius, yRadius: zoneRadius)

            if tokens.usesGroupPalette {
                // Calm: die Kachel traegt IMMER die Farbe ihrer Gruppe, nicht erst
                // beim Hover - Panel und Zielvorschau sprechen so von Anfang an
                // dieselbe Farbsprache.
                groupColor.withAlphaComponent(isHov ? 1.0 : (isGroupHovered ? 0.8 : 0.6)).setFill()
            } else if isHov {
                groupColor.setFill()
            } else {
                (isGroupHovered ? groupColor.withAlphaComponent(0.55) : tokens.zoneFill).setFill()
            }
            zPath.fill()

            if isHov {
                groupColor.setStroke()
                zPath.lineWidth = 1.5 * scale
                zPath.stroke()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let newIdx = zoneIndex(for: convert(event.locationInWindow, from: nil))
        if newIdx != hoveredZoneIndex {
            hoveredZoneIndex = newIdx
            needsDisplay = true
            onZoneHover?(newIdx != nil ? group.zones[newIdx!] : nil)
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        let localPt = convert(event.locationInWindow, from: nil)
        if let idx = zoneIndex(for: localPt) { onZoneSnap?(group.zones[idx]) }
        else if let first = group.zones.first { onZoneSnap?(first) }
    }
    
    override func mouseEntered(with event: NSEvent) {
        isGroupHovered = true
        needsDisplay = true
    }
    
    override func mouseExited(with event: NSEvent) {
        isGroupHovered = false
        hoveredZoneIndex = nil
        needsDisplay = true
        onZoneHover?(nil)
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTracker()
    }
    
    private func rebuildTracker() {
        if let t = tracker { removeTrackingArea(t) }
        tracker = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(tracker!)
    }
}

final class AppIconCell: NSView {
    /// Veraenderbar, damit die Zelle im Pool wiederverwendet werden kann.
    private(set) var item: AppItem
    var onClick: (() -> Void)?

    // Alles laeuft ueber CALayer statt ueber draw(_:). Dadurch braucht keine der
    // (potenziell mehreren hundert) Zellen einen eigenen Backing-Store, und das
    // Aufbauen des Grids kostet nur noch einen Bruchteil.
    private let contentLayer = CALayer()
    private let iconLayer = CALayer()
    private var selectionLayer: CALayer?
    private var badgeLayer: CATextLayer?

    /// Anzahl offener Fenster. Ab zwei erscheint ein Badge - nur dann gibt es
    /// ueberhaupt etwas zu entscheiden.
    var windowCount: Int = 1 {
        didSet {
            guard windowCount != oldValue else { return }
            updateBadge()
        }
    }
    private var nameLabel: NSTextField?
    private var hoverWorkItem: DispatchWorkItem?

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            animateScale(to: isHovered ? DesignTokens.current().hoverScale : 1.0)
            handleHoverDelay()
        }
    }

    var isKeyboardSelected = false {
        didSet {
            guard isKeyboardSelected != oldValue else { return }
            updateSelectionLayer()
            hoverWorkItem?.cancel() // Keyboard unterbricht Maus-Hover-Timer
            if isKeyboardSelected {
                updateLabelVisibility(show: true) // Bei Keyboard sofort anzeigen
            } else if !isHovered {
                updateLabelVisibility(show: false)
            }
        }
    }

    static let cornerRadius: CGFloat = 18

    init(item: AppItem, frame: NSRect) {
        self.item = item
        super.init(frame: frame)

        wantsLayer = true
        // Ohne Backing-Store: die View selbst zeichnet nichts mehr.
        layerContentsRedrawPolicy = .never

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        contentLayer.frame = bounds
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        contentLayer.contentsScale = scale

        iconLayer.frame = bounds.insetBy(dx: 9, dy: 9)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        iconLayer.minificationFilter = .trilinear
        iconLayer.magnificationFilter = .linear
        iconLayer.contents = item.icon
        iconLayer.opacity = item.isRunning ? 1.0 : 0.8
        contentLayer.addSublayer(iconLayer)

        layer?.addSublayer(contentLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Layer-Geometrie darf nicht implizit animieren, sonst "schwimmt" das Grid
        // beim Filtern sichtbar hinterher.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = bounds
        contentLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let pad: CGFloat = isKeyboardSelected ? 5 : 9
        iconLayer.frame = bounds.insetBy(dx: pad, dy: pad)
        selectionLayer?.frame = bounds.insetBy(dx: 4, dy: 4)
        CATransaction.commit()

        if let label = nameLabel {
            label.sizeToFit()
            let labelWidth = min(label.frame.width + 16, bounds.width + 40)
            label.frame = CGRect(x: (bounds.width - labelWidth) / 2, y: -14, width: labelWidth, height: 18)
        }
    }

    // Kurzes, ungefedertes Eindruecken beim Klick - die physische "Tastendruck"-
    // Rueckmeldung, die native macOS-Steuerelemente auch geben.
    override func mouseDown(with event: NSEvent) {
        animateScale(to: DesignTokens.current().hoverScale * 0.88, spring: false, duration: 0.07)
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
        animateScale(to: isHovered ? DesignTokens.current().hoverScale : 1.0)
    }

    private func updateSelectionLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isKeyboardSelected {
            let sel = selectionLayer ?? {
                let l = CALayer()
                l.cornerRadius = Self.cornerRadius + 2
                l.cornerCurve = .continuous // Apples "Squircle" statt Kreisbogen-Ecken
                l.borderWidth = 2.0
                l.contentsScale = contentLayer.contentsScale
                contentLayer.insertSublayer(l, below: iconLayer)
                selectionLayer = l
                return l
            }()
            let accent = DesignTokens.current().accent
            sel.frame = bounds.insetBy(dx: 4, dy: 4)
            sel.backgroundColor = accent.withAlphaComponent(0.25).cgColor
            sel.borderColor = accent.withAlphaComponent(0.7).cgColor
            sel.isHidden = false
        } else {
            selectionLayer?.isHidden = true
        }

        let pad: CGFloat = isKeyboardSelected ? 5 : 9
        iconLayer.frame = bounds.insetBy(dx: pad, dy: pad)

        CATransaction.commit()
    }

    /// `spring: true` (Standard) erzeugt das leicht ueberschwingende, "lebendige"
    /// Hover-Verhalten echter Liquid-Glass-Symbole. Fuer den Tastendruck selbst wird
    /// bewusst ohne Feder animiert (`spring: false`) - ein Andruecken darf nicht
    /// nachwippen, sonst wirkt der Klick weich statt praezise.
    private func animateScale(to scale: CGFloat, spring: Bool = true, duration: CFTimeInterval? = nil) {
        let from = contentLayer.presentation()?.transform ?? contentLayer.transform
        let to = CATransform3DMakeScale(scale, scale, 1.0)
        contentLayer.transform = to

        if spring {
            let tokens = DesignTokens.current()
            let anim = CASpringAnimation(keyPath: "transform")
            anim.fromValue = from
            anim.toValue = to
            anim.mass = 1.0
            anim.stiffness = tokens.hoverStiffness
            anim.damping = tokens.hoverDamping
            anim.duration = anim.settlingDuration
            contentLayer.add(anim, forKey: "scale")
        } else {
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = from
            anim.toValue = to
            anim.duration = duration ?? 0.11
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentLayer.add(anim, forKey: "scale")
        }
    }

    /// Das Namensschild wird erst bei Bedarf erzeugt. Vorher hatte jede Zelle ein
    /// eigenes NSTextField - bei ~300 Apps allein dafuer 300 Views im Grid.
    ///
    /// Kein Hintergrund - nur fetter, adaptiver Text. Sitzt auf dem Glas-Panel selbst
    /// (nicht direkt auf dem Desktop-Hintergrund), `labelColor` passt sich damit
    /// korrekt an Hell-/Dunkelmodus an, wie das Suchfeld daneben auch.
    private func ensureLabel() -> NSTextField {
        if let label = nameLabel { return label }
        let label = NSTextField(labelWithString: item.name)
        let tokens = DesignTokens.current()
        label.font = .appFont(ofSize: 11, weight: .bold, rounded: tokens.usesRoundedFont)
        // Nicht .labelColor: Calm ist unabhaengig vom echten System-Erscheinungsbild
        // und braucht deshalb eine feste, garantiert lesbare Textfarbe auf seiner
        // festen cremefarbenen Flaeche statt der System-Dunkel/Hell-Textfarbe.
        label.textColor = tokens.text
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.alphaValue = 0
        addSubview(label)
        nameLabel = label
        needsLayout = true
        layoutSubtreeIfNeeded()
        return label
    }

    // Timer-Logik für 0.75 Sekunden Verzögerung
    private func handleHoverDelay() {
        hoverWorkItem?.cancel() // Alten Timer abbrechen

        if isHovered {
            let item = DispatchWorkItem { [weak self] in
                self?.updateLabelVisibility(show: true)
            }
            hoverWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
        } else {
            if !isKeyboardSelected {
                updateLabelVisibility(show: false) // Direkt ausblenden, wenn Maus verlässt
            }
        }
    }

    private func updateLabelVisibility(show: Bool) {
        if !show && nameLabel == nil { return } // nichts zu verstecken
        let label = ensureLabel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            label.animator().alphaValue = show ? 1.0 : 0.0
        }
    }

    /// Setzt die Zelle beim Wiederverwenden im Pool zurueck.
    func resetForReuse() {
        windowCount = 1
        hoverWorkItem?.cancel()
        isHovered = false
        isKeyboardSelected = false
        nameLabel?.alphaValue = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.removeAnimation(forKey: "scale")
        contentLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Aktualisiert den Zustand einer wiederverwendeten Zelle (z.B. App wurde
    /// zwischenzeitlich gestartet), ohne die View neu aufzubauen.
    func update(item newItem: AppItem) {
        item = newItem
        if let icon = newItem.icon, iconLayer.contents == nil {
            iconLayer.contents = icon
        }
        iconLayer.opacity = newItem.isRunning ? 1.0 : 0.8
        nameLabel?.stringValue = newItem.name
    }

    private func updateBadge() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard windowCount > 1 else {
            badgeLayer?.isHidden = true
            return
        }

        let tokens = DesignTokens.current()
        let size: CGFloat = 18
        let badge = badgeLayer ?? {
            let l = CATextLayer()
            l.alignmentMode = .center
            l.cornerRadius = size / 2
            l.masksToBounds = true
            l.contentsScale = contentLayer.contentsScale
            contentLayer.addSublayer(l)
            badgeLayer = l
            return l
        }()

        // Oben rechts auf dem Symbol, wie beim Dock-Zaehler.
        badge.frame = CGRect(x: bounds.maxX - size - 6, y: bounds.maxY - size - 6,
                             width: size, height: size)
        badge.backgroundColor = tokens.accent.cgColor
        badge.foregroundColor = NSColor.white.cgColor
        badge.font = NSFont.appFont(ofSize: 11, weight: .bold, rounded: tokens.usesRoundedFont)
        badge.fontSize = 11
        badge.string = "\(windowCount)"
        badge.isHidden = false
    }

    /// Wird bei einem Akzentfarbwechsel aufgerufen, damit ein bereits sichtbarer
    /// Auswahlring sofort mitzieht statt erst beim naechsten Hover/Select.
    func refreshAccentColor() {
        updateBadge()
        guard isKeyboardSelected else { return }
        updateSelectionLayer()
    }

    /// Wird bei einem Wechsel des Erscheinungsbilds aufgerufen: Auswahlring-Farbe
    /// und Namensschild-Schriftbild (rund in Calm) muessen sofort mitziehen.
    func refreshDesign() {
        updateSelectionLayer()
        updateBadge()
        let tokens = DesignTokens.current()
        nameLabel?.font = .appFont(ofSize: 11, weight: .bold, rounded: tokens.usesRoundedFont)
        nameLabel?.textColor = tokens.text
    }
}

// MARK: - Panel Presentation Helpers

/// Skalierung um den Mittelpunkt, OHNE `anchorPoint` zu veraendern.
/// AppKit setzt `anchorPoint`/`position` einer View-Layer bei jedem Layout neu -
/// die Verschiebung muss deshalb Teil der Matrix sein.
func centeredScale(_ scale: CGFloat, in bounds: CGRect) -> CATransform3D {
    let s = CATransform3DMakeScale(scale, scale, 1.0)
    let t = CATransform3DMakeTranslation(bounds.midX * (1 - scale), bounds.midY * (1 - scale), 0)
    return CATransform3DConcat(s, t)
}

/// Blendet ein Panel ein: Fensterposition steht sofort fest, animiert werden nur
/// Alpha (WindowServer-seitig) und eine Layer-Skalierung (GPU-komponiert).
///
/// Vorher wurde `animator().setFrameOrigin` benutzt - das verschiebt das Fenster
/// per Timer bei jedem Frame, was zusammen mit dem NSVisualEffectView-Blur sichtbar
/// gehakt hat.
func presentPanel(_ window: NSWindow, at origin: NSPoint, makeKey: Bool, duration: Double = 0.18) {
    window.setFrameOrigin(origin)
    window.alphaValue = 0

    if let root = window.contentView {
        root.wantsLayer = true
        if let layer = root.layer {
            layer.masksToBounds = false
            let from = centeredScale(0.965, in: root.bounds)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()

            let pop = CASpringAnimation(keyPath: "transform")
            pop.fromValue = from
            pop.toValue = CATransform3DIdentity
            pop.damping = 22
            pop.stiffness = 380
            pop.mass = 1
            pop.duration = pop.settlingDuration
            layer.add(pop, forKey: "present")
        }
    }

    if makeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }

    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = duration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 1
    }
}

func dismissPanel(_ window: NSWindow, duration: Double = 0.12, completion: @escaping () -> Void) {
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = duration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
        window.animator().alphaValue = 0
    }, completionHandler: completion)
}

/// Baut das Panel-Material fuer den aktuellen Modus: echtes Liquid Glass oder eine
/// schlicht deckende Flaeche (Light, Dark, Calm - keiner davon ist durchscheinend,
/// nur die Zielvorschau beim Ziehen bleibt das, siehe `previewIsOpaque`). Beide
/// Varianten liefern eine `materialView` (wird in `root` eingehaengt) und eine
/// `contentContainer` (dort kommen die eigentlichen Inhalte rein) - bei Opaque ist
/// das dieselbe View, bei Glass sind es bewusst zwei getrennte (siehe
/// `NSGlassEffectView.contentView`).
func buildPanelMaterial(tokens: DesignTokens, bounds: CGRect,
                        radiusScale: CGFloat = 1.0) -> (materialView: NSView, contentContainer: NSView) {
    let panelRadius = tokens.panelRadius * radiusScale
    switch tokens.material {
    case .glass:
        let glass = NSGlassEffectView(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = panelRadius
        glass.style = .regular
        let inner = NSView(frame: bounds)
        inner.autoresizingMask = [.width, .height]
        glass.contentView = inner
        return (glass, inner)

    case .opaque:
        let plain = NSView(frame: bounds)
        plain.autoresizingMask = [.width, .height]
        // Erzwingt Aqua/DarkAqua, damit eingebettete native Controls (Suchfeld) zur
        // gewaehlten Palette passen, statt bei abweichendem System-Erscheinungsbild
        // farblich aus dem Rahmen zu fallen.
        if let name = tokens.forcedAppearance { plain.appearance = NSAppearance(named: name) }
        plain.wantsLayer = true
        plain.layer?.backgroundColor = tokens.opaquePanelFill.cgColor
        plain.layer?.cornerRadius = panelRadius
        plain.layer?.cornerCurve = .continuous
        plain.layer?.masksToBounds = true
        plain.layer?.borderWidth = 1
        plain.layer?.borderColor = tokens.panelBorder.cgColor
        return (plain, plain)
    }
}

// MARK: - Snap Panel (Top menu)

class SnapPanel: NSPanel {
    var onSnapSelected: ((SnapLayout) -> Void)?
    private var previewWin: NSWindow?
    private var highlightLayer: CALayer?
    private var titleLabel: NSTextField?
    private var groupIconViews: [SnapGroupIconView] = []
    private var targetOrigin: NSPoint = .zero
    private var lastPreviewKey: String?
    /// Darstellungsmassstab: 1,0 fuer Maus und Stift, 1,5 bei Fingerbedienung.
    /// Der Aufbau ist nicht teuer, wird aber nur bei tatsaechlicher Aenderung
    /// wiederholt - waehrend einer laufenden Geste soll nichts neu gebaut werden.
    private var uiScale: CGFloat = 1.0
    /// Das Layout, dessen Vorschau gerade sichtbar ist. Beim Loslassen gilt genau
    /// dieses als Ziel - "was du siehst, dorthin springt das Fenster".
    private(set) var previewedLayout: SnapLayout?
    
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { return frameRect }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: 2147483630)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hasShadow = true
        buildUI()
        buildPreview()
    }

    private func buildUI() {
        let tokens = DesignTokens.current()
        let s = uiScale
        let count = CGFloat(snapGroups.count)
        let padding: CGFloat = 18 * s
        let tileW: CGFloat = 76 * s
        let tileH: CGFloat = 56 * s
        let tileGap: CGFloat = 10 * s
        let pW: CGFloat = (padding * 2) + (count * tileW) + ((count - 1) * tileGap)

        // Vertikale Aufteilung von unten nach oben, statt einer summierten Konstante:
        // so ist ablesbar, woraus sich die Hoehe zusammensetzt. Der Abstand zwischen
        // Titel und Kacheln war mit 18 pt deutlich zu gross - das Panel wirkte
        // dadurch unnoetig hoch.
        let bottomPadding: CGFloat = 16 * s
        let titleGap: CGFloat = 6 * s
        let topInset: CGFloat = 10 * s

        // Titel vorab aufbauen, um seine tatsaechliche Hoehe zu kennen - die haengt
        // von Schriftgroesse und Sprache ab und soll nicht geraten werden.
        let title = NSTextField(labelWithString: L("panel.title"))
        title.font = .appFont(ofSize: 9 * s, weight: .semibold, rounded: tokens.usesRoundedFont)
        title.textColor = tokens.textMuted
        title.sizeToFit()
        let titleH = title.frame.height

        let pH: CGFloat = bottomPadding + tileH + titleGap + titleH + topInset

        // root bleibt eine reine, transparente Traeger-View: presentPanel() animiert
        // deren Layer-Transform beim Erscheinen. Das eigentliche Material haengt vom
        // gewaehlten Design-Modus ab (Glas oder deckende Flaeche).
        let root = NSView(frame: NSRect(x: 0, y: 0, width: pW, height: pH))
        root.wantsLayer = true

        let (material, inner) = buildPanelMaterial(tokens: tokens, bounds: root.bounds, radiusScale: s)
        root.addSubview(material)

        title.frame.origin = CGPoint(x: (pW - title.frame.width) / 2, y: pH - topInset - titleH)
        inner.addSubview(title)
        titleLabel = title

        groupIconViews.removeAll()
        for (gi, group) in snapGroups.enumerated() {
            let iv = SnapGroupIconView(group: group,
                                       frame: CGRect(x: padding + CGFloat(gi) * (tileW + tileGap),
                                                     y: bottomPadding, width: tileW, height: tileH))
            iv.scale = s
            iv.onZoneSnap = { [weak self] layout in self?.onSnapSelected?(layout) }
            iv.onZoneHover = { [weak self] layout in
                if let l = layout { self?.showPreview(for: l) } else { self?.hidePreview() }
            }
            inner.addSubview(iv)
            groupIconViews.append(iv)
        }

        contentView = root
        setContentSize(CGSize(width: pW, height: pH))
    }

    /// Die Zielvorschau ist ein bildschirmfuellendes, klickdurchlaessiges Overlay.
    /// Bewegt wird darin nur eine CALayer - dadurch gleitet die Markierung beim
    /// Wechsel zwischen zwei Zonen GPU-fluessig, statt dass ein Fenster pro Frame
    /// neu positioniert wird (das war sichtbar ruckelig und flackerte).
    private func buildPreview() {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: 2147483620)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let host = NSView()
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        win.contentView = host

        // Flaechige Akzent-Einfaerbung mit klarer Kante - der Windows-11-Look, der
        // sofort lesbar macht, wohin das Fenster springt.
        let hl = CALayer()
        hl.cornerRadius = 12
        hl.cornerCurve = .continuous
        hl.borderWidth = 2.0
        hl.opacity = 0
        host.layer?.addSublayer(hl)

        previewWin = win
        highlightLayer = hl
        applyPreviewColors()
    }

    /// In Calm traegt jede Zonen-Gruppe ihre eigene Palettenfarbe statt der globalen
    /// Akzentfarbe - `layout` bestimmt, welche Gruppenfarbe das ist. Ohne sichtbare
    /// Vorschau (z.B. beim initialen Aufbau) gilt die globale Akzentfarbe als Vorgabe.
    private func applyPreviewColors(for layout: SnapLayout? = nil) {
        let tokens = DesignTokens.current()
        let color = layout.map { zoneColor(for: $0, tokens: tokens) } ?? tokens.accent

        if tokens.previewIsOpaque {
            // Calm: keine Transparenz - die Vorschau wirkt wie eine feste, deckende
            // Papierkarte an der Zielposition, nicht wie ein durchscheinender Farbwasch.
            // Die Flaeche ist dabei stark mit dem Papierton verwaschen - wie mit
            // Buntstift aufgetragenes, duennes Pigment statt sattem Filzstift. Der
            // Rand bleibt kraeftiger, wie eine fester gezogene Bleistiftkontur um
            // eine locker schraffierte Flaeche.
            let washed = color.blended(withFraction: 0.6, of: tokens.opaquePanelFill) ?? color
            highlightLayer?.backgroundColor = washed.cgColor
            highlightLayer?.borderColor = (color.blended(withFraction: 0.15, of: .black) ?? color).cgColor
        } else {
            highlightLayer?.backgroundColor = color.withAlphaComponent(0.22).cgColor
            highlightLayer?.borderColor = color.withAlphaComponent(0.9).cgColor
        }
    }

    func showPreview(for layout: SnapLayout) {
        guard let pw = previewWin, let hl = highlightLayer, let screen = NSScreen.main else { return }
        // Waehrend des Ziehens feuert leftMouseDragged sehr haeufig. Ohne diese
        // Abkuerzung wuerde bei JEDEM Event neu animiert.
        let key = "\(layout.title)|\(layout.previewRect)"
        guard key != lastPreviewKey else { return }
        let isFirstShow = lastPreviewKey == nil
        lastPreviewKey = key
        previewedLayout = layout
        applyPreviewColors(for: layout)

        let vf = screen.visibleFrame
        if pw.frame != vf {
            pw.setFrame(vf, display: false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pw.contentView?.layer?.frame = CGRect(origin: .zero, size: vf.size)
            CATransaction.commit()
        }
        if !pw.isVisible { pw.orderFrontRegardless() }

        // Zielrechteck in Fensterkoordinaten (Ursprung unten links).
        let target = layout.compute(vf)
        let local = CGRect(x: target.minX - vf.minX, y: target.minY - vf.minY,
                           width: target.width, height: target.height)

        if isFirstShow {
            // Erstes Erscheinen: kein Gleiten aus einer alten Position, nur einblenden.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hl.frame = local
            CATransaction.commit()

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.13
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hl.opacity = 1
            hl.add(fade, forKey: "fade")
        } else {
            // Zonenwechsel: die Markierung gleitet gefedert hinueber.
            // `frame` ist bei CALayer abgeleitet und nicht animierbar - es muessen
            // `bounds` und `position` einzeln animiert werden.
            let pres = hl.presentation()
            let fromBounds = pres.map { CGRect(origin: .zero, size: $0.bounds.size) }
                ?? CGRect(origin: .zero, size: hl.bounds.size)
            let fromPos = pres?.position ?? hl.position

            let toBounds = CGRect(origin: .zero, size: local.size)
            let toPos = CGPoint(x: local.midX, y: local.midY)

            let motionTokens = DesignTokens.current()
            func spring(_ keyPath: String, _ from: Any, _ to: Any) -> CASpringAnimation {
                let a = CASpringAnimation(keyPath: keyPath)
                a.fromValue = from
                a.toValue = to
                a.mass = 1.0
                a.stiffness = motionTokens.highlightStiffness
                a.damping = motionTokens.highlightDamping
                a.duration = a.settlingDuration
                return a
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hl.bounds = toBounds
            hl.position = toPos
            hl.opacity = 1
            CATransaction.commit()

            hl.add(spring("bounds", fromBounds, toBounds), forKey: "moveBounds")
            hl.add(spring("position", fromPos, toPos), forKey: "movePosition")
        }
    }
    
    func hidePreview() {
        previewedLayout = nil
        guard lastPreviewKey != nil, let hl = highlightLayer else { return }
        lastPreviewKey = nil

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = hl.presentation()?.opacity ?? hl.opacity
        fade.toValue = 0
        fade.duration = 0.1
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        hl.opacity = 0
        hl.add(fade, forKey: "fade")

        // Fenster erst nach dem Ausblenden aus der Anzeige nehmen.
        let win = previewWin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            guard let self, self.lastPreviewKey == nil else { return }
            win?.orderOut(nil)
        }
    }

    func snapLayoutAt(screenPoint: NSPoint) -> SnapLayout? {
        // Die Zonen-Icons liegen innerhalb des NSGlassEffectView und sind damit KEINE
        // direkten Unteransichten der contentView mehr. Deshalb wird hier ueber die
        // gehaltene Referenzliste gegangen und per convert(_:from:) umgerechnet -
        // das funktioniert unabhaengig davon, wie tief die Views verschachtelt sind.
        let winPoint = NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)
        for gv in groupIconViews {
            let local = gv.convert(winPoint, from: nil)
            if gv.bounds.contains(local) {
                if let idx = gv.zoneIndex(for: local) { return gv.group.zones[idx] }
                return gv.group.zones.first
            }
        }
        return nil
    }

    func show(on screen: NSScreen, scale: CGFloat = 1.0) {
        // Auf schmalen Displays nicht breiter werden, als der Bildschirm hergibt -
        // sonst raegte das vergroesserte Panel seitlich hinaus.
        let count = CGFloat(snapGroups.count)
        let baseWidth = (18 * 2) + (count * 76) + ((count - 1) * 10)
        let maxScale = max(1.0, (screen.frame.width - 40) / baseWidth)
        let effective = min(scale, maxScale)

        if effective != uiScale {
            uiScale = effective
            buildUI()
        }
        guard let cv = contentView else { return }
        targetOrigin = CGPoint(x: screen.frame.midX - cv.frame.width / 2, y: screen.frame.maxY - 28 - cv.frame.height - 6)
        lastPreviewKey = nil
        previewedLayout = nil
        presentPanel(self, at: targetOrigin, makeKey: false, duration: 0.16)
    }

    func hide() {
        hidePreview()
        dismissPanel(self, duration: 0.12) { self.orderOut(nil) }
    }
    
    /// Wird aufgerufen, sobald der Nutzer ueber "Akzentfarbe aendern..." eine neue
    /// Farbe waehlt - das Glas faerbt sich live mit, die Customization bleibt also
    /// nicht auf Vorschau-Highlights und Auswahlringe beschraenkt.
    func refreshColors() {
        groupIconViews.forEach { $0.needsDisplay = true }
        applyPreviewColors(for: previewedLayout)
    }

    /// Wird aufgerufen, sobald der Nutzer im Menue ein anderes Erscheinungsbild
    /// waehlt. Anders als Akzentfarbe/Sprache reicht hier kein Token-Refresh, weil
    /// sich der View-TYP der Panel-Flaeche aendern kann (Glas ↔ Vibrancy ↔ deckend) -
    /// deshalb wird das Panel komplett neu aufgebaut.
    func refreshDesign() {
        buildUI()
        applyPreviewColors(for: previewedLayout)
    }

    func refreshLanguage() {
        guard let label = titleLabel, let containerWidth = label.superview?.bounds.width else { return }
        label.stringValue = L("panel.title")
        label.sizeToFit()
        label.frame.origin.x = (containerWidth - label.frame.width) / 2
    }
}

// MARK: - Fenster einer App ermitteln

/// Ein einzelnes Fenster einer App - Grundlage der Auswahl, wenn eine App mehrere
/// Fenster offen hat und `kAXFocusedWindow` deshalb nicht eindeutig das gemeinte trifft.
struct AppWindowInfo {
    let axElement: AXUIElement
    let title: String
    /// Bildschirmkoordinaten mit Ursprung unten links (AppKit-Konvention).
    let frame: CGRect
    var thumbnail: CGImage?

    /// Dieselbe Flaeche in CoreGraphics-Konvention (Ursprung oben links) - noetig,
    /// um AX-Fenster mit den Fenstern aus ScreenCaptureKit abzugleichen.
    func cgFrame(screenH: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: screenH - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// Listet die sichtbaren Fenster eines Prozesses auf. Synchroner AX-IPC -
/// ausschliesslich vom Hintergrund-Thread aufrufen.
func visibleWindows(of pid: pid_t, screenH: CGFloat) -> [AppWindowInfo] {
    guard pid != 0 else { return [] }
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.3)

    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
          let windows = ref as? [AXUIElement] else { return [] }

    return windows.compactMap { win in
        // Minimierte Fenster ueberspringen: sie liessen sich zwar andocken, haetten
        // aber kein sinnvolles Vorschaubild und wuerden die Auswahl aufblaehen.
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           (minimizedRef as? Bool) == true { return nil }

        guard let frame = getWindowFrame(win: win, screenH: screenH),
              frame.width > 80, frame.height > 80 else { return nil }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

        return AppWindowInfo(axElement: win, title: title, frame: frame, thumbnail: nil)
    }
}

// MARK: - Vorschaubilder (ScreenCaptureKit)

enum WindowThumbnails {
    /// Ist die Berechtigung "Bildschirmaufnahme" erteilt? Prueft, ohne einen Dialog
    /// auszuloesen - der Aufruf wuerde sonst bei jedem Oeffnen der Auswahl nerven.
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Fragt die Berechtigung aktiv an. macOS zeigt den Dialog nur einmal; danach
    /// fuehrt der Weg ueber die Systemeinstellungen.
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    /// Laedt Vorschaubilder fuer die uebergebenen Fenster und meldet sie einzeln,
    /// sobald sie da sind - so erscheint die Auswahl sofort und fuellt sich nach,
    /// statt auf das langsamste Bild zu warten.
    static func load(for windows: [AppWindowInfo], pid: pid_t, screenH: CGFloat,
                     onImage: @escaping (Int, CGImage) -> Void) {
        guard isPermitted else { return }

        SCShareableContent.getWithCompletionHandler { content, error in
            guard let content, error == nil else { return }
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid }

            for (index, info) in windows.enumerated() {
                let target = info.cgFrame(screenH: screenH)
                // Zuordnung ueber die Fensterflaeche: AX und ScreenCaptureKit teilen
                // keine gemeinsame Kennung, aber Position und Groesse stimmen ueberein.
                guard let match = candidates.first(where: { sc in
                    abs(sc.frame.minX - target.minX) < 4 && abs(sc.frame.minY - target.minY) < 4
                        && abs(sc.frame.width - target.width) < 4 && abs(sc.frame.height - target.height) < 4
                }) else { continue }

                let filter = SCContentFilter(desktopIndependentWindow: match)
                let config = SCStreamConfiguration()
                // Auf Vorschaugroesse herunterrechnen lassen statt volle Aufloesung
                // zu holen und selbst zu skalieren.
                let scale = min(320.0 / max(match.frame.width, 1), 200.0 / max(match.frame.height, 1))
                config.width = max(1, Int(match.frame.width * scale * 2))
                config.height = max(1, Int(match.frame.height * scale * 2))
                config.showsCursor = false

                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                    guard let image else { return }
                    DispatchQueue.main.async { onImage(index, image) }
                }
            }
        }
    }
}

// MARK: - Schliessen-Knopf

/// Schliessen-Knopf des App-Launchers.
///
/// Notwendig fuer Fingereingabe: Ein Tipp AUSSERHALB des Panels erreicht diese App
/// nie - der WindowServer stellt Fingereingaben ausschliesslich der App zu, deren
/// Fenster beruehrt wurde, und erzeugt dabei keine global sichtbaren Ereignisse.
/// Ein Ziel INNERHALB des eigenen Fensters bekommt dagegen ganz normale lokale
/// Mausereignisse - deshalb funktionieren auch die App-Symbole per Finger.
/// Bewusst grosszuegig dimensioniert, damit er mit dem Finger sicher zu treffen ist.
final class PanelCloseButton: NSView {
    var onClick: (() -> Void)?

    private var hovered = false
    private var pressed = false
    private var tracker: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rebuildTracker()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let tokens = DesignTokens.current()
        let circleRect = bounds.insetBy(dx: 2, dy: 2)
        let circle = NSBezierPath(ovalIn: circleRect)

        // Grundflaeche aus dem Tokensatz, damit der Knopf in allen vier
        // Erscheinungsbildern stimmig sitzt statt fest verdrahtet zu sein.
        let baseAlpha = tokens.layoutBg.alphaComponent
        if pressed {
            tokens.accent.withAlphaComponent(0.35).setFill()
        } else {
            tokens.layoutBg.withAlphaComponent(baseAlpha * (hovered ? 2.4 : 1.0)).setFill()
        }
        circle.fill()

        // In Calm bewusst ohne Rahmen: dort ist `zoneEdge` ein Gruenton, der als
        // Ring um den Knopf fremd wirkt. Die gefuellte Flaeche allein genuegt.
        if !tokens.usesGroupPalette {
            tokens.zoneEdge.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }

        let inset = circleRect.width * 0.33
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: circleRect.minX + inset, y: circleRect.minY + inset))
        cross.line(to: NSPoint(x: circleRect.maxX - inset, y: circleRect.maxY - inset))
        cross.move(to: NSPoint(x: circleRect.maxX - inset, y: circleRect.minY + inset))
        cross.line(to: NSPoint(x: circleRect.minX + inset, y: circleRect.maxY - inset))
        cross.lineWidth = 1.8
        cross.lineCapStyle = .round
        tokens.textMuted.setStroke()
        cross.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        // Nur ausloesen, wenn innerhalb losgelassen wurde - so laesst sich ein
        // versehentlicher Treffer durch Wegziehen noch abbrechen.
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTracker()
    }

    private func rebuildTracker() {
        if let t = tracker { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t)
        tracker = t
    }
}

// MARK: - Fenster-Auswahl

/// Eine Kachel der Fensterauswahl: Vorschaubild (sobald geladen) plus Titel.
/// Ohne Bild traegt die Kachel nur den Titel - so bleibt die Auswahl auch ohne
/// die Berechtigung "Bildschirmaufnahme" vollstaendig benutzbar.
final class WindowChoiceCell: NSView {
    var onClick: (() -> Void)?

    private let imageLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private var hovered = false
    private var tracker: NSTrackingArea?

    static let cellWidth: CGFloat = 176
    static let imageHeight: CGFloat = 110

    init(title: String, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        let tokens = DesignTokens.current()
        imageLayer.frame = NSRect(x: 0, y: bounds.height - Self.imageHeight,
                                  width: bounds.width, height: Self.imageHeight)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.cornerRadius = 8
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.borderWidth = 1
        imageLayer.borderColor = tokens.zoneEdge.cgColor
        imageLayer.backgroundColor = tokens.layoutBg.cgColor
        layer?.addSublayer(imageLayer)

        titleLabel.stringValue = title.isEmpty ? "—" : title
        titleLabel.font = .appFont(ofSize: 11, weight: .medium, rounded: tokens.usesRoundedFont)
        titleLabel.textColor = tokens.text
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.toolTip = title
        titleLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
        addSubview(titleLabel)

        rebuildTracker()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    /// Tastatur-Auswahl traegt denselben Rahmen wie Hover - beides bedeutet
    /// "dieses Fenster ist gerade das Ziel", nur ueber unterschiedliche Eingabewege.
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            applyHoverLook()
        }
    }

    private func applyHoverLook() {
        let tokens = DesignTokens.current()
        let highlighted = hovered || selected
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.borderColor = (highlighted ? tokens.accent : tokens.zoneEdge).cgColor
        imageLayer.borderWidth = highlighted ? 2 : 1
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; applyHoverLook() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyHoverLook() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTracker()
    }

    private func rebuildTracker() {
        if let t = tracker { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t)
        tracker = t
    }
}

/// Auswahl, welches Fenster einer App gemeint ist. Erscheint nur, wenn eine App
/// tatsaechlich mehrere Fenster offen hat - bei einem Fenster gibt es nichts zu
/// entscheiden und der Ablauf bleibt unveraendert.
final class WindowPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    private var cells: [WindowChoiceCell] = []
    private var windowInfos: [AppWindowInfo] = []
    private var perRow = 1
    private var selectedIndex: Int? {
        didSet {
            guard let old = oldValue, old < cells.count else {
                if let new = selectedIndex, new < cells.count { cells[new].selected = true }
                return
            }
            cells[old].selected = false
            if let new = selectedIndex, new < cells.count {
                cells[new].selected = true
                cells[new].scrollToVisible(cells[new].bounds.insetBy(dx: -20, dy: -20))
            }
        }
    }
    private var keyMonitor: Any?
    private var onPick: ((AppWindowInfo) -> Void)?
    private var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: 2147483629)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hasShadow = true
    }

    /// - Parameter screenFrame: voller sichtbarer Bildschirmbereich. Die Position
    ///   wird dagegen geklemmt statt gegen `rect` (die schmale Restflaeche) - sonst
    ///   konnte die Auswahl auf kleinen Displays (iPad) teilweise ausserhalb des
    ///   sichtbaren Bereichs landen, wenn `rect` nahe einem Bildschirmrand lag.
    func present(windows: [AppWindowInfo], pid: pid_t, near rect: CGRect, screenFrame: CGRect,
                 onPick: @escaping (AppWindowInfo) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel

        let tokens = DesignTokens.current()
        let padding: CGFloat = 18
        let gap: CGFloat = 12
        let cellW = WindowChoiceCell.cellWidth
        let cellH = WindowChoiceCell.imageHeight + 22

        // Bei vielen Fenstern umbrechen statt endlos breit zu werden.
        windowInfos = windows
        perRow = min(windows.count, 3)
        let rows = Int(ceil(Double(windows.count) / Double(max(perRow, 1))))
        let titleH: CGFloat = 24
        let pW = padding * 2 + CGFloat(perRow) * cellW + CGFloat(max(perRow - 1, 0)) * gap
        let pH = padding * 2 + titleH + CGFloat(rows) * cellH + CGFloat(max(rows - 1, 0)) * gap

        let root = NSView(frame: NSRect(x: 0, y: 0, width: pW, height: pH))
        root.wantsLayer = true
        let (material, inner) = buildPanelMaterial(tokens: tokens, bounds: root.bounds)
        root.addSubview(material)

        let heading = NSTextField(labelWithString: L("picker.title"))
        heading.font = .appFont(ofSize: 11, weight: .semibold, rounded: tokens.usesRoundedFont)
        heading.textColor = tokens.textMuted
        heading.sizeToFit()
        heading.frame.origin = CGPoint(x: (pW - heading.frame.width) / 2, y: pH - padding - heading.frame.height + 4)
        inner.addSubview(heading)

        cells.removeAll()
        for (i, info) in windows.enumerated() {
            let col = i % perRow
            let row = i / perRow
            let x = padding + CGFloat(col) * (cellW + gap)
            let y = pH - padding - titleH - CGFloat(row + 1) * cellH - CGFloat(row) * gap
            let cell = WindowChoiceCell(title: info.title,
                                        frame: NSRect(x: x, y: y, width: cellW, height: cellH))
            cell.onClick = { [weak self] in
                self?.dismiss()
                onPick(info)
            }
            inner.addSubview(cell)
            cells.append(cell)
        }

        contentView = root
        setContentSize(CGSize(width: pW, height: pH))

        let bounds = screenFrame.isEmpty ? rect : screenFrame
        var originX = rect.midX - pW / 2
        var originY = rect.midY - pH / 2
        originX = min(max(originX, bounds.minX + 20), bounds.maxX - pW - 20)
        originY = min(max(originY, bounds.minY + 20), bounds.maxY - pH - 20)
        let origin = NSPoint(x: originX, y: originY)
        presentPanel(self, at: origin, makeKey: true, duration: 0.16)

        installKeyMonitor()
        // Erste Kachel schon vorausgewaehlt - Enter funktioniert damit sofort,
        // ohne dass man erst einmal eine Pfeiltaste druecken muss.
        selectedIndex = cells.isEmpty ? nil : 0

        // Vorschaubilder nachladen - die Auswahl ist schon vorher benutzbar.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        WindowThumbnails.load(for: windows, pid: pid, screenH: screenH) { [weak self] index, image in
            guard let self, index < self.cells.count else { return }
            self.cells[index].setThumbnail(image)
        }
    }

    private func installKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { // Escape
                let cancel = self.onCancel
                self.dismiss()
                cancel?()
                return nil
            }

            if e.keyCode == 36 || e.keyCode == 76 { // Enter / Kleiner-Enter
                if let i = self.selectedIndex, i < self.windowInfos.count {
                    let info = self.windowInfos[i]
                    self.dismiss()
                    self.onPick?(info)
                }
                return nil
            }

            // Pfeiltasten UND WASD gleichwertig - dieselbe Gitter-Logik wie im
            // App-Launcher, nur mit `perRow` statt fest 4 Spalten.
            let leftKeys: Set<UInt16> = [123, 0]   // Links, A
            let rightKeys: Set<UInt16> = [124, 2]  // Rechts, D
            let downKeys: Set<UInt16> = [125, 1]   // Runter, S
            let upKeys: Set<UInt16> = [126, 13]    // Hoch, W

            guard !self.cells.isEmpty else { return e }
            guard leftKeys.contains(e.keyCode) || rightKeys.contains(e.keyCode)
                    || downKeys.contains(e.keyCode) || upKeys.contains(e.keyCode) else { return e }

            var i = self.selectedIndex ?? 0
            if leftKeys.contains(e.keyCode) { i -= 1 }
            else if rightKeys.contains(e.keyCode) { i += 1 }
            else if downKeys.contains(e.keyCode) { i += self.perRow }
            else if upKeys.contains(e.keyCode) { i -= self.perRow }

            self.selectedIndex = max(0, min(self.cells.count - 1, i))
            return nil
        }
    }

    func dismiss() {
        guard isVisible else { return }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        dismissPanel(self, duration: 0.12) { self.orderOut(nil) }
    }
}

// MARK: - Snap Assist Panel

class SnapAssistPanel: NSPanel, NSSearchFieldDelegate {
    override var canBecomeKey: Bool { return true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { return frameRect }

    private var clickMonitor: Any?
    private var keyMonitor: Any?
    
    private var allOpenApps = [AppItem]()
    private var allClosedApps = [AppItem]()
    private var curOpen = [AppItem]()
    private var curClosed = [AppItem]()
    private var cells = [AppIconCell]()

    /// Zellen werden ueber Oeffnungen hinweg wiederverwendet. Das Erzeugen von ~300
    /// Zellen war bisher bei jedem Oeffnen UND bei jedem Tastendruck faellig.
    private var cellPool = [String: AppIconCell]()
    private var docView: FlippedView?
    private var separatorLine: NSView?
    private var chromeSize: CGSize = .zero
    
    private var selIdx: Int? { didSet { updateSelectionVisuals() } }
    private var cRect = CGRect.zero
    private var screenFrame = CGRect.zero
    private var scrollView: NSScrollView?
    private var searchField: NSSearchField?
    private var closeButton: PanelCloseButton?
    private var windowPicker: WindowPickerPanel?
    private var flagsMonitor: Any?
    private var lastModifierFlags: NSEvent.ModifierFlags = []
    private var isDismissing = false
    /// Zeitpunkt des Einblendens - kurz danach wird ein Fokusverlust ignoriert,
    /// damit das Panel sich nicht waehrend des eigenen Aufbaus selbst schliesst.
    private var presentedAt: CFTimeInterval = 0

    @objc private func panelDidResignKey() {
        guard isVisible, !isDismissing else { return }
        guard CACurrentMediaTime() - presentedAt > 0.25 else { return }
        dismiss()
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: 2147483628)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hasShadow = true
        acceptsMouseMovedEvents = true
    }

    /// Baut die Zellen fuer die installierten Apps im Voraus auf (wird beim Erscheinen
    /// des Snap-Panels ausgeloest). Beim eigentlichen Oeffnen bleibt dann nur noch
    /// Positionieren uebrig - der Launcher ist sofort da.
    func prewarm() {
        let apps = AppCache.shared.installedApps
        guard !apps.isEmpty else { return }
        // Idempotent: bereits vorhandene Zellen werden nur aktualisiert.
        for app in apps { _ = cell(for: app) }
    }

    /// - Parameter screenFrame: der volle sichtbare Bildschirmbereich. Die Groesse
    ///   des Launchers richtet sich danach statt nach `rect` (der Restflaeche) -
    ///   auf kleinen Displays (iPad als Zweitbildschirm) war die Restflaeche neben
    ///   einem angedockten Fenster oft zu schmal, um den Launcher vollstaendig zu
    ///   zeigen. Er darf jetzt ueber das gerade verschobene Fenster ragen; er liegt
    ///   ohnehin auf einer sehr hohen Fensterebene und damit immer sichtbar davor.
    func present(in rect: CGRect, screenFrame: CGRect, excludingPID: pid_t) {
        cRect = rect
        self.screenFrame = screenFrame
        isDismissing = false
        
        let rawOpen = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != excludingPID && !$0.isTerminated
        }
        let orderedPIDs = getMRUAppPIDs()
        let pidOrder = Dictionary(uniqueKeysWithValues: orderedPIDs.enumerated().map { ($1, $0) })
        let sortedOpen = rawOpen.sorted { (pidOrder[$0.processIdentifier] ?? Int.max) < (pidOrder[$1.processIdentifier] ?? Int.max) }
        
        allOpenApps = sortedOpen.map { app in
            let id = app.bundleIdentifier ?? app.localizedName ?? ""
            // Icon aus dem Cache; nur unbekannte Apps werden einmalig rasterisiert.
            let icon = IconStore.shared.icon(key: app.bundleURL?.path ?? id) { app.icon }
            return AppItem(id: id, name: app.localizedName ?? "", icon: icon, url: app.bundleURL, runningApp: app)
        }
        
        let openIds = Set(allOpenApps.map { $0.id })
        allClosedApps = AppCache.shared.installedApps.filter { !openIds.contains($0.id) }
        
        curOpen = allOpenApps
        curClosed = allClosedApps
        selIdx = nil
        
        buildUI(in: rect)
        installMonitors()
    }

    private func buildUI(in rect: CGRect) {
        // Groesse richtet sich nach dem ganzen Bildschirm, nicht nach der (auf
        // kleinen Displays oft schmalen) Restflaeche neben dem angedockten Fenster.
        let bounds = screenFrame.isEmpty ? rect : screenFrame
        let totalGridW: CGFloat = (4.0 * 84.0) + (3.0 * 36.0) + 48.0
        let pW: CGFloat = min(bounds.width - 40.0, totalGridW)
        let idealH: CGFloat = 20.0 + 46.0 + 14.0 + 400.0 + 20.0
        let pH: CGFloat = min(bounds.height - 40.0, max(220.0, idealH))

        buildChromeIfNeeded(width: pW, height: pH)

        searchField?.stringValue = ""
        rebuildGrid(pW: pW)
        if let sv = scrollView {
            sv.contentView.scroll(to: NSPoint(x: 0, y: 0))
            sv.reflectScrolledClipView(sv.contentView)
        }

        // Bevorzugt zentriert ueber der Restflaeche (wirkt dort am natuerlichsten,
        // solange sie gross genug ist), danach in den vollen Bildschirmbereich
        // geklemmt statt in die kleine Restflaeche - so bleibt der Launcher immer
        // ganz sichtbar, auch wenn er dafuer das gerade verschobene Fenster
        // ueberdeckt.
        let clampBounds = screenFrame.isEmpty ? rect : screenFrame
        var targetX = rect.minX + (rect.width - pW) / 2
        var targetY = rect.minY + (rect.height - pH) / 2
        targetX = min(max(targetX, clampBounds.minX + 20), clampBounds.maxX - pW - 20)
        targetY = min(max(targetY, clampBounds.minY + 20), clampBounds.maxY - pH - 20)
        let target = CGPoint(x: targetX, y: targetY)
        presentPanel(self, at: target, makeKey: true, duration: 0.16)

        // Fokus SOFORT - vorher passierte das erst im completionHandler der 0,65s
        // langen Animation, man konnte also eine halbe Sekunde lang nicht tippen.
        makeFirstResponder(searchField)

        loadWindowCounts()
    }

    /// Ermittelt im Hintergrund, wie viele Fenster die laufenden Apps offen haben,
    /// und setzt die Badges nach. Bewusst nachtraeglich: das sind ein AX-Aufruf pro
    /// App, was das Oeffnen des Launchers sonst spuerbar verzoegern wuerde.
    private func loadWindowCounts() {
        let running = allOpenApps.compactMap { item -> (String, pid_t)? in
            guard let pid = item.runningApp?.processIdentifier else { return nil }
            return (item.id, pid)
        }
        guard !running.isEmpty else { return }
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var counts: [String: Int] = [:]
            for (id, pid) in running {
                counts[id] = visibleWindows(of: pid, screenH: screenH).count
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (id, count) in counts {
                    self.cellPool[id]?.windowCount = count
                }
            }
        }
    }

    /// Erzeugt Hintergrund, Suchfeld und ScrollView nur einmal pro Groesse.
    private func buildChromeIfNeeded(width pW: CGFloat, height pH: CGFloat) {
        if chromeSize == CGSize(width: pW, height: pH), contentView != nil { return }
        chromeSize = CGSize(width: pW, height: pH)
        let tokens = DesignTokens.current()

        let root = NSView(frame: NSRect(x: 0, y: 0, width: pW, height: pH))
        root.wantsLayer = true

        let (material, inner) = buildPanelMaterial(tokens: tokens, bounds: root.bounds)
        root.addSubview(material)

        // Platz fuer den Schliessen-Knopf rechts neben dem Suchfeld freihalten.
        let closeSize: CGFloat = 30
        let closeGap: CGFloat = 12
        let sf = NSSearchField(frame: NSRect(x: 24, y: pH - 20 - 46,
                                             width: pW - 48 - closeSize - closeGap, height: 46))
        sf.placeholderString = L("search.placeholder")
        sf.font = .appFont(ofSize: 16, weight: .regular, rounded: tokens.usesRoundedFont)
        sf.focusRingType = NSFocusRingType.none
        sf.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSControl.textDidChangeNotification, object: sf)
        inner.addSubview(sf)
        searchField = sf

        let close = PanelCloseButton(frame: NSRect(x: pW - 24 - closeSize,
                                                   y: pH - 20 - 46 + (46 - closeSize) / 2,
                                                   width: closeSize, height: closeSize))
        close.onClick = { [weak self] in self?.dismiss() }
        inner.addSubview(close)
        closeButton = close

        let sv = NSScrollView(frame: NSRect(x: 0, y: 20, width: pW, height: pH - 40 - 46 - 14))
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.scrollerStyle = NSScroller.Style.overlay

        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: sv.contentView)

        inner.addSubview(sv)
        scrollView = sv

        // Neues Chrome heisst neue ScrollView - das Dokument muss mitwandern.
        docView = nil
        separatorLine = nil

        contentView = root
        setContentSize(CGSize(width: pW, height: pH))
    }

    /// Liefert die Zelle fuer eine App aus dem Pool oder legt sie einmalig an.
    private func cell(for app: AppItem) -> AppIconCell {
        if let existing = cellPool[app.id] {
            existing.update(item: app)
            return existing
        }
        let created = AppIconCell(item: app, frame: NSRect(x: 0, y: 0, width: 84.0, height: 84.0))
        created.onClick = { [weak self, weak created] in
            guard let self, let created else { return }
            self.trigger(created.item)
        }
        cellPool[app.id] = created
        return created
    }

    private func rebuildGrid(pW: CGFloat) {
        guard let sv = scrollView else { return }
        
        let openRows = max(1, Int(ceil(Double(curOpen.count) / 4.0)))
        let closedRows = Int(ceil(Double(curClosed.count) / 4.0))
        
        var dH: CGFloat = 20.0
        dH += CGFloat(openRows) * 84.0 + CGFloat(max(0, openRows - 1)) * 36.0
        dH += 36.0
        dH += CGFloat(closedRows) * 84.0 + CGFloat(max(0, closedRows - 1)) * 36.0
        dH += 20.0

        // Dokument-View und Zellen werden wiederverwendet; frueher wurde bei JEDEM
        // Tastendruck das komplette Grid neu erzeugt - daher das zaehe Tippen.
        let doc: FlippedView
        if let existing = docView {
            doc = existing
        } else {
            doc = FlippedView(frame: .zero)
            doc.wantsLayer = true
            docView = doc
            sv.documentView = doc
        }
        doc.frame = NSRect(x: 0, y: 0, width: pW, height: max(dH, sv.frame.height))
        
        let gridStartX = (pW - ((4.0 * 84.0) + (3.0 * 36.0))) / 2.0
        var currentY: CGFloat = 20.0
        var newCells = [AppIconCell]()

        func addApps(_ apps: [AppItem]) {
            for (i, a) in apps.enumerated() {
                let cellX = gridStartX + CGFloat(i % 4) * 120.0
                let cellY = currentY + CGFloat(i / 4) * 120.0
                let c = cell(for: a)
                c.frame = NSRect(x: cellX, y: cellY, width: 84.0, height: 84.0)
                c.isHidden = false
                if c.superview !== doc { doc.addSubview(c) }
                newCells.append(c)
            }
        }

        addApps(curOpen)
        currentY += CGFloat(openRows) * 84.0 + CGFloat(max(0, openRows - 1)) * 36.0 + 18.0
        
        let line: NSView
        if let existing = separatorLine {
            line = existing
        } else {
            line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = DesignTokens.current().zoneEdge.cgColor
            separatorLine = line
            doc.addSubview(line)
        }
        line.frame = NSRect(x: 40, y: currentY, width: pW - 80, height: 1)
        
        currentY += 18.0
        addApps(curClosed)

        // Zellen, die durch den Filter gefallen sind, nur ausblenden statt zerstoeren.
        let stillVisible = Set(newCells.map { ObjectIdentifier($0) })
        for old in cells where !stillVisible.contains(ObjectIdentifier(old)) {
            old.isHidden = true
            old.resetForReuse()
        }

        cells = newCells
        updateSelectionVisuals()
    }

    private func updateSelectionVisuals() {
        for (i, c) in cells.enumerated() {
            c.isKeyboardSelected = (i == selIdx)
            if i == selIdx {
                c.scrollToVisible(c.bounds.insetBy(dx: -20, dy: -20))
            }
        }
    }

    override func mouseMoved(with e: NSEvent) {
        updateHover(mouseLoc: e.locationInWindow)
    }

    @objc private func scrolled() {
        updateHover(mouseLoc: self.mouseLocationOutsideOfEventStream)
    }

    private func updateHover(mouseLoc: NSPoint) {
        guard let doc = scrollView?.documentView else { return }
        let docPoint = doc.convert(mouseLoc, from: nil)
        for c in cells {
            let inside = !c.isHidden && c.frame.contains(docPoint)
            if c.isHovered != inside {
                c.isHovered = inside
            }
        }
    }

    private func trigger(_ a: AppItem) {
        guard !isDismissing else { return }

        let rect = cRect
        let layout = SnapLayout(title: "", previewRect: .zero) { _ in rect }

        guard a.isRunning, let rApp = a.runningApp else {
            isDismissing = true
            launchAndSnap(appItem: a, layout: layout)
            dismiss()
            return
        }

        let pid = rApp.processIdentifier

        // Hat die App mehrere Fenster offen, ist nicht eindeutig, welches gemeint
        // ist - dann erst fragen. Bei genau einem Fenster bleibt der Ablauf
        // unveraendert und kostet keinen zusaetzlichen Klick.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
            let windows = visibleWindows(of: pid, screenH: screenH)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDismissing else { return }

                guard windows.count > 1 else {
                    self.isDismissing = true
                    snapWindow(pid: pid, layout: layout, window: windows.first?.axElement)
                    rApp.activate(options: [])
                    self.dismiss()
                    return
                }

                self.showWindowPicker(windows: windows, pid: pid, app: rApp, layout: layout, rect: rect)
            }
        }
    }

    /// Ziel fuer Shift/Option/Tab: die per Tastatur ausgewaehlte Kachel, sonst die
    /// gerade mit der Maus schwebte Kachel - so funktioniert der Kurzbefehl in
    /// beiden Bedienweisen.
    private func currentTargetCell() -> AppIconCell? {
        if let i = selIdx, i < cells.count { return cells[i] }
        return cells.first { $0.isHovered }
    }

    /// Oeffnet die Fensterauswahl direkt, ohne erst zu snappen - nur sinnvoll (und
    /// nur dann etwas zu waehlen), wenn die Ziel-App tatsaechlich mehrere Fenster
    /// offen hat. `trigger()` erledigt genau das schon selbst: bei einem Fenster
    /// snappt es direkt, bei mehreren zeigt es die Auswahl - hier wird nur der
    /// erste Fall unterdrueckt, da diese Tasten explizit NUR die Auswahl meinen.
    private func openWindowPickerForCurrentTarget() {
        guard !isDismissing, let cell = currentTargetCell(), cell.windowCount > 1 else { return }
        trigger(cell.item)
    }

    private func showWindowPicker(windows: [AppWindowInfo], pid: pid_t,
                                  app: NSRunningApplication, layout: SnapLayout, rect: CGRect) {
        let picker = WindowPickerPanel()
        windowPicker = picker
        // Der Launcher tritt waehrend der Auswahl in den Hintergrund, bleibt aber
        // bestehen: bricht der Nutzer ab, ist er wieder da, wo er war.
        alphaValue = 0.25

        let screenFrame = NSScreen.screens.first { $0.frame.intersects(rect) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        picker.present(windows: windows, pid: pid, near: rect, screenFrame: screenFrame, onPick: { [weak self] chosen in
            guard let self else { return }
            self.alphaValue = 1
            self.isDismissing = true

            // Erst das gewaehlte Fenster als das aktive markieren und nach vorne
            // holen, DANN die App aktivieren - in dieser Reihenfolge, synchron
            // abgewartet. Sonst kann `app.activate()` schneller sein als die AX-
            // Umstellung im Hintergrund und ein anderes Fenster der App erscheint.
            let win = chosen.axElement
            DispatchQueue.global(qos: .userInteractive).async {
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, win)
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                DispatchQueue.main.async {
                    app.activate(options: [])
                    snapWindow(pid: pid, layout: layout, window: win)
                }
            }
            self.dismiss()
        }, onCancel: { [weak self] in
            self?.alphaValue = 1
            self?.windowPicker = nil
        })
    }

    @objc private func textChanged(_ n: Notification) {
        guard let sf = n.object as? NSSearchField, let pW = contentView?.frame.width else { return }
        let q = sf.stringValue.trimmingCharacters(in: .whitespaces)
        
        if q.isEmpty {
            curOpen = allOpenApps
            curClosed = allClosedApps
        } else {
            curOpen = allOpenApps.filter { isFuzzyMatch(query: q, target: $0.name) }
            curClosed = allClosedApps.filter { isFuzzyMatch(query: q, target: $0.name) }
        }
        selIdx = nil
        rebuildGrid(pW: pW)
    }

    func controlTextDidChange(_ o: Notification) {
        textChanged(o)
    }

    private func installMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }

        // Bei Fingereingabe erreichen uns keine globalen Mausereignisse - ein Tipp
        // ausserhalb des Panels bliebe deshalb unbemerkt. Der Verlust des Key-Status
        // ist das eingabe-unabhaengige Signal dafuer, dass woanders hingetippt oder
        // geklickt wurde: tippt man eine andere App an, wird diese aktiv.
        presentedAt = CACurrentMediaTime()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResignKey),
                                               name: NSWindow.didResignKeyNotification, object: self)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let s = self else { return e }
            if e.keyCode == 53 { s.dismiss(); return nil }
            
            if e.keyCode == 36 || e.keyCode == 76 {
                if let i = s.selIdx, i < s.cells.count {
                    s.trigger(s.cells[i].item)
                } else if let first = s.cells.first {
                    s.trigger(first.item)
                }
                return nil
            }

            // Tab: eigenstaendige Auslosetaste fuer "Fenster waehlen" bei Apps mit
            // mehreren offenen Fenstern - kein Fokuswechsel wie sonst ueblich.
            if e.keyCode == 48 {
                s.openWindowPickerForCurrentTarget()
                return nil
            }
            
            if [123, 124, 125, 126].contains(e.keyCode) {
                if s.selIdx == nil {
                    if [125, 126].contains(e.keyCode) { s.selIdx = 0; return nil }
                    return e
                }
                if s.cells.isEmpty { return e }
                var i = s.selIdx!
                if e.keyCode == 123 { i -= 1 }
                else if e.keyCode == 124 { i += 1 }
                else if e.keyCode == 125 { i += 4 }
                else if e.keyCode == 126 { i -= 4 }
                
                s.selIdx = max(0, min(s.cells.count - 1, i))
                return nil
            }
            return e
        }

        // Shift und Option loesen kein normales Tastendruck-Ereignis aus (nur
        // .flagsChanged) - deshalb ein eigener Beobachter, der auf das Einsetzen
        // ("steigende Flanke") der jeweiligen Taste reagiert.
        lastModifierFlags = []
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard let s = self else { return e }
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let pressedShift = flags.contains(.shift) && !s.lastModifierFlags.contains(.shift)
            let pressedOption = flags.contains(.option) && !s.lastModifierFlags.contains(.option)
            s.lastModifierFlags = flags
            if pressedShift || pressedOption {
                s.openWindowPickerForCurrentTarget()
            }
            return e
        }
        
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let s = self else { return }
            if !s.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { s.dismiss() }
            }
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isDismissing = true
        
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)

        // contentView und Beobachter bleiben bestehen - sie werden beim naechsten
        // Oeffnen wiederverwendet, das spart den kompletten Neuaufbau.
        dismissPanel(self, duration: 0.12) { self.orderOut(nil) }
    }

    /// Faerbt das Launcher-Glas und alle Auswahlringe live mit der neuen Akzentfarbe.
    func refreshColors() {
        cellPool.values.forEach { $0.refreshAccentColor() }
        closeButton?.needsDisplay = true
    }

    func refreshLanguage() {
        searchField?.placeholderString = L("search.placeholder")
    }

    /// Wie bei SnapPanel: der View-Typ der Panel-Flaeche kann sich aendern, deshalb
    /// wird das gecachte Chrome verworfen statt nur Farben nachzuziehen. Ist der
    /// Launcher gerade nicht offen, baut sich das naechste `present()` ohnehin neu auf.
    func refreshDesign() {
        chromeSize = .zero
        cellPool.values.forEach { $0.refreshDesign() }
        if let cv = contentView {
            buildChromeIfNeeded(width: cv.bounds.width, height: cv.bounds.height)
            rebuildGrid(pW: cv.bounds.width)
        }
    }
}

// MARK: - Einstellungsfenster

/// Eigenstaendiges Einstellungsfenster.
///
/// Bewusst ein Fenster statt eines Menueleisten-Menues: Ist das Symbol
/// ausgeblendet, gaebe es sonst keinen Weg mehr zu den Einstellungen.
final class SettingsWindowController: NSObject, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var pathsTable: NSTableView?
    private var paths: [String] = []
    private var removeButton: NSButton?

    private override init() {
        super.init()
        // Sprachwechsel baut die Beschriftungen neu auf.
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildIfVisible),
            name: .appLanguageDidChange, object: nil)
    }

    func show() {
        if window == nil { buildWindow() }
        reloadValues()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    @objc private func rebuildIfVisible() {
        guard window != nil else { return }
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        buildWindow()
        reloadValues()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Aufbau

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = L("settings.title")
        w.delegate = self
        w.isReleasedWhenClosed = false

        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        // --- Allgemein ---
        stack.addArrangedSubview(sectionHeader(L("settings.general")))
        stack.addArrangedSubview(checkbox(L("settings.startAtLogin"), #selector(toggleLogin), isLoginItemEnabled()))
        stack.addArrangedSubview(checkbox(L("settings.showMenuBarIcon"), #selector(toggleIcon), !GeneralSettings.isStatusIconHidden))
        stack.addArrangedSubview(checkbox(L("menu.showLauncher"), #selector(toggleLauncher), LauncherSettings.isEnabled))

        stack.addArrangedSubview(spacer(8))

        // --- Darstellung ---
        stack.addArrangedSubview(sectionHeader(L("menu.appearance")))
        stack.addArrangedSubview(row(L("menu.appearance"), appearancePopup()))
        stack.addArrangedSubview(row(L("settings.accentColor"), accentWell()))
        stack.addArrangedSubview(row(L("menu.language"), languagePopup()))

        stack.addArrangedSubview(spacer(8))

        // --- Suchpfade ---
        stack.addArrangedSubview(sectionHeader(L("menu.searchPaths")))
        stack.addArrangedSubview(pathsSection())

        w.contentView = root
        window = w
    }

    private func sectionHeader(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private func checkbox(_ title: String, _ action: Selector, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        return b
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let r = NSStackView(views: [l, control])
        r.orientation = .horizontal
        r.spacing = 12
        r.alignment = .centerY
        return r
    }

    // MARK: Steuerelemente

    private var appearanceButton: NSPopUpButton?
    private var languageButton: NSPopUpButton?
    private var colorWell: NSColorWell?

    private func appearancePopup() -> NSPopUpButton {
        let b = NSPopUpButton()
        b.target = self
        b.action = #selector(appearanceChanged(_:))
        for mode in DesignMode.allCases {
            b.addItem(withTitle: mode.menuTitle)
            b.lastItem?.representedObject = mode.rawValue
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 200).isActive = true
        appearanceButton = b
        return b
    }

    private func languagePopup() -> NSPopUpButton {
        let b = NSPopUpButton()
        b.target = self
        b.action = #selector(languageChanged(_:))
        b.addItem(withTitle: L("menu.language.system"))
        b.lastItem?.representedObject = AppLanguage.system.rawValue
        b.menu?.addItem(.separator())
        let all = AppLanguage.allCases.filter { $0 != .system }
            .sorted { $0.nativeName.localizedStandardCompare($1.nativeName) == .orderedAscending }
        for lang in all {
            b.addItem(withTitle: lang.nativeName)
            b.lastItem?.representedObject = lang.rawValue
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 200).isActive = true
        languageButton = b
        return b
    }

    private func accentWell() -> NSColorWell {
        let well = NSColorWell()
        well.color = accentColor()
        well.target = self
        well.action = #selector(accentChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 60).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorWell = well
        return well
    }

    private func pathsSection() -> NSView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.width = 400
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        pathsTable = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true

        let add = NSButton(title: L("menu.addFolder"), target: self, action: #selector(addPath))
        add.bezelStyle = .rounded
        let remove = NSButton(title: L("menu.remove"), target: self, action: #selector(removePath))
        remove.bezelStyle = .rounded
        remove.isEnabled = false
        removeButton = remove

        let buttons = NSStackView(views: [add, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let box = NSStackView(views: [scroll, buttons])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8
        return box
    }

    // MARK: Werte laden

    private func reloadValues() {
        paths = LauncherSettings.extraPaths
        pathsTable?.reloadData()
        removeButton?.isEnabled = pathsTable?.selectedRow ?? -1 >= 0

        if let b = appearanceButton {
            let current = DesignMode.current.rawValue
            b.selectItem(at: b.itemArray.firstIndex { ($0.representedObject as? String) == current } ?? 0)
        }
        if let b = languageButton {
            let current = AppLanguage.storedOverride.rawValue
            if let idx = b.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
                b.selectItem(at: idx)
            }
        }
        colorWell?.color = accentColor()
        colorWell?.isEnabled = DesignTokens.current().accentPickerEnabled
    }

    // MARK: Aktionen

    @objc private func toggleLogin(_ sender: NSButton) {
        toggleLoginItem()
        sender.state = isLoginItemEnabled() ? .on : .off
    }

    @objc private func toggleIcon(_ sender: NSButton) {
        GeneralSettings.isStatusIconHidden = (sender.state == .off)
    }

    @objc private func toggleLauncher(_ sender: NSButton) {
        LauncherSettings.isEnabled = (sender.state == .on)
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = DesignMode(rawValue: raw) else { return }
        DesignMode.setCurrent(mode)
        colorWell?.isEnabled = DesignTokens.current().accentPickerEnabled
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let lang = AppLanguage(rawValue: raw) else { return }
        AppLanguage.setOverride(lang)
    }

    @objc private func accentChanged(_ sender: NSColorWell) {
        setAccentColor(sender.color)
        NotificationCenter.default.post(name: .accentColorDidChange, object: nil)
    }

    @objc private func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("menu.addFolder")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { LauncherSettings.addPath(url.path) }
        reloadValues()
        AppCache.shared.reload()
    }

    @objc private func removePath() {
        guard let table = pathsTable, table.selectedRow >= 0, table.selectedRow < paths.count else { return }
        LauncherSettings.removePath(paths[table.selectedRow])
        reloadValues()
        AppCache.shared.reload()
    }

    // MARK: Tabelle

    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: (paths[row] as NSString).abbreviatingWithTildeInPath)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = paths[row]
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton?.isEnabled = (pathsTable?.selectedRow ?? -1) >= 0
    }
}

// MARK: - AppDelegate

// MARK: - Touch-Unterstuetzung (iPad als erweitertes Touch-Display)

/// C-Funktionszeiger fuer den AXObserver - muss global sein und darf nichts einfangen.
private func axWindowMovedCallback(observer: AXObserver, element: AXUIElement,
                                   notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    delegate.handleWindowMovedByTouch(element)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var snapPanel: SnapPanel!
    var assistPanel: SnapAssistPanel!
    var monitor: Any?
    var visible = false
    var dragging = false
    var dragPID: pid_t = 0
    var dragToken: UInt64 = 0
    var dragStartPos = NSPoint.zero
    var lastMouseDragPos = NSPoint.zero

    /// Rahmen des fokussierten Fensters im Moment des Mausklicks. Referenz fuer die
    /// Frage, ob waehrend des Ziehens tatsaechlich ein FENSTER bewegt wird.
    var dragStartWindowFrame: CGRect?
    /// Wird true, sobald sich das Fenster nachweislich bewegt hat. Erst dann darf
    /// das Snap-Panel erscheinen - eine aus dem Finder gezogene Datei laesst das
    /// Fenster stehen und soll den Manager folglich nicht ausloesen.
    var dragIsWindowMove = false
    private var windowMoveCheckInFlight = false
    private var baselineCaptureInFlight = false
    private var lastWindowMoveCheck: CFTimeInterval = 0

    // --- Touch-Pfad (Finger auf dem iPad-Display) ---
    // Fingereingabe erzeugt KEINE Mausereignisse und bewegt auch den Zeiger nicht.
    // Der einzige beobachtbare Kanal ist die Fensterposition selbst.
    private var touchObserver: AXObserver?
    private var touchObservedPID: pid_t = 0
    private var touchDragActive = false
    private var touchDragPID: pid_t = 0
    private var touchPollTimer: Timer?
    private var touchPollInFlight = false
    private var touchLastFrame: CGRect?
    private var touchStillSince: CFTimeInterval = 0
    private var touchMoveCount = 0
    private var touchTravelled: CGFloat = 0
    
    var loginMenuItem: NSMenuItem!
    var colorMenuItem: NSMenuItem!
    var hideIconMenuItem: NSMenuItem!

    /// Haelt die live-Beobachtung des System-Erscheinungsbilds am Leben - wird nur
    /// im Modus "Automatisch" gebraucht, damit ein Hell/Dunkel-Wechsel des Systems
    /// sofort durchschlaegt statt erst beim naechsten Oeffnen bemerkt zu werden.
    private var appearanceObservation: NSKeyValueObservation?

    func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        
        if !trusted {
            let alert = NSAlert()
            alert.messageText = L("alert.accessibility.title")
            alert.informativeText = L("alert.accessibility.body")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("alert.accessibility.button"))
            alert.runModal()
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        checkAccessibilityPermissions()
        setupMenu()
        applyStatusIconVisibility()

        // Nur relevant im Modus "Automatisch": ein Systemwechsel Hell/Dunkel soll
        // sofort durchschlagen, nicht erst beim naechsten Oeffnen der Panels.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self, DesignMode.current == .system else { return }
            DispatchQueue.main.async { self.designModeDidChange() }
        }

        // Wenn das Menueleisten-Symbol ausgeblendet ist, gibt es keinen Klickpunkt
        // mehr fuer die Einstellungen. Ein erneutes Oeffnen der App (z.B. ueber
        // Spotlight) bittet diese bereits laufende Instanz stattdessen per
        // Distributed Notification, ihr Menue mittig zu zeigen - siehe Entry Point.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowSettingsRequest),
            name: showSettingsRequestNotification, object: nil)

        snapPanel = SnapPanel()
        snapPanel.onSnapSelected = { [weak self] layout in
            guard let self = self else { return }
            self.snapPanel.hide()
            self.visible = false
            snapWindow(pid: self.dragPID, layout: layout)
            self.presentAssist(after: layout, excludingPID: self.dragPID)
        }
        
        assistPanel = SnapAssistPanel()

        // Beendete Apps aus dem Wiederherstellungs-Speicher werfen. Ohne das koennte
        // eine spaeter wiederverwendete PID ein voellig fremdes Fenster "zuruecksetzen".
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                WindowRestoreStore.shared.clear(app.processIdentifier)
            }
        }

        // Sobald die App-Liste steht, werden die Icon-Zellen im Leerlauf vorbereitet.
        AppCache.shared.onReload = { [weak self] in self?.assistPanel.prewarm() }
        AppCache.shared.startMonitoring()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            DispatchQueue.main.async { self?.handle(e) }
        }

        // Zweiter, eingabe-unabhaengiger Weg fuer Fingereingabe auf einem
        // Touch-Display: dort entstehen keine Mausereignisse, nur Fensterbewegungen.
        startTouchWindowTracking()

        // Einstellungen beim Oeffnen der App zeigen. Beim Autostart waere das
        // aufdringlich, deshalb dort unterdrueckt - erkennbar daran, dass macOS
        // die App in dem Fall ohne Nutzerinteraktion im Hintergrund startet.
        if !launchedAtLogin { SettingsWindowController.shared.show() }
    }

    /// Zeigt den App-Launcher direkt beim Loslassen an. Vorher lag hier eine fest
    /// verdrahtete Wartezeit von 0,55s - die Restflaeche steht aber sofort fest, das
    /// Panel muss nicht auf die Fensteranimation warten.
    func presentAssist(after layout: SnapLayout, excludingPID pid: pid_t) {
        guard LauncherSettings.isEnabled else { return }
        guard let scr = NSScreen.main, let r = leftoverRect(after: layout, screen: scr) else { return }
        assistPanel.present(in: r, screenFrame: scr.visibleFrame, excludingPID: pid)
    }

    /// Prueft nach dem Loslassen, ob ein zuvor gesnapptes Fenster weggezogen wurde.
    /// Wenn ja, bekommt es die Groesse von vor dem Snap zurueck - an der neuen Stelle.
    /// - Parameter pointer: Zeigerposition beim Loslassen. Bei Fingereingabe gibt es
    ///   keinen Zeiger (`NSEvent.mouseLocation` bleibt eingefroren stehen), deshalb
    ///   `nil` - dann wird das Fenster stattdessen um seine eigene Mitte aufgeklappt.
    func restoreIfDraggedAway(pid: pid_t, pointer: NSPoint?) {
        guard pid != 0, let entry = WindowRestoreStore.shared.entry(for: pid) else { return }
        guard let firstScreen = NSScreen.screens.first else { return }

        let screenH = firstScreen.frame.height
        let screen = pointer.flatMap { p in NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } }
            ?? NSScreen.main ?? firstScreen
        let visibleFrame = screen.visibleFrame

        // Das Auslesen ist ein synchroner IPC in die fremde App - nicht auf dem
        // Main-Thread, sonst haengt beim Loslassen kurz die gesamte Oberflaeche.
        DispatchQueue.global(qos: .userInitiated).async {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.3)

            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
                  let winRef = ref,
                  let current = getWindowFrame(win: winRef as! AXUIElement, screenH: screenH) else { return }

            DispatchQueue.main.async {
                let tolerance: CGFloat = 8

                // Hat der Nutzer zwischendurch selbst die Groesse geaendert? Dann ist
                // das sein neuer manueller Zustand - es gibt nichts wiederherzustellen.
                if abs(current.width - entry.snappedFrame.width) > tolerance
                    || abs(current.height - entry.snappedFrame.height) > tolerance {
                    WindowRestoreStore.shared.clear(pid)
                    return
                }

                // Unveraendert liegen geblieben? Dann war es kein Wegziehen.
                guard abs(current.minX - entry.snappedFrame.minX) > tolerance
                        || abs(current.minY - entry.snappedFrame.minY) > tolerance else { return }

                let w = entry.freeFrame.width
                let h = entry.freeFrame.height

                // Mit Zeiger: er soll relativ dieselbe Stelle der Titelleiste behalten,
                // damit das Fenster beim Aufklappen nicht unter der Maus wegspringt.
                // Ohne Zeiger (Finger): um die eigene Mitte aufklappen.
                var originX: CGFloat
                if let p = pointer {
                    let relX = current.width > 0 ? (p.x - current.minX) / current.width : 0.5
                    originX = p.x - relX * w
                } else {
                    originX = current.midX - w / 2
                }
                var originY = current.maxY - h // Oberkante beibehalten

                // In den sichtbaren Bereich klemmen; passt das Fenster gar nicht,
                // buendig oben links ansetzen statt negativ zu klemmen.
                originX = w >= visibleFrame.width
                    ? visibleFrame.minX
                    : min(max(originX, visibleFrame.minX), visibleFrame.maxX - w)
                originY = h >= visibleFrame.height
                    ? visibleFrame.maxY - h
                    : min(max(originY, visibleFrame.minY), visibleFrame.maxY - h)

                WindowRestoreStore.shared.clear(pid)
                animateFocusedWindow(pid: pid,
                                     to: CGRect(x: originX, y: originY, width: w, height: h))
            }
        }
    }

    /// Liest einmal pro Ziehgeste den Ausgangsrahmen des fokussierten Fensters.
    private func captureDragBaselineIfNeeded() {
        guard dragStartWindowFrame == nil, !baselineCaptureInFlight, dragPID != 0 else { return }
        baselineCaptureInFlight = true

        let pid = dragPID
        let token = dragToken
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frame = focusedWindowFrame(pid: pid, screenH: screenH, timeout: 0.15)
            DispatchQueue.main.async {
                guard let self, self.dragToken == token else { return }
                self.baselineCaptureInFlight = false
                self.dragStartWindowFrame = frame
            }
        }
    }

    /// Klaert waehrend des Ziehens, ob tatsaechlich ein FENSTER bewegt wird.
    ///
    /// Ohne diese Pruefung genuegte ein beliebiger Drag zum oberen Bildschirmrand,
    /// um den Manager zu oeffnen - auch das Ziehen einer Datei aus einem Finder-
    /// Fenster oder das Markieren von Text. Entscheidend ist: eine Datei zu ziehen
    /// laesst das Fenster stehen, ein Fenster zu ziehen bewegt es.
    ///
    /// Die Pruefung ist gedrosselt und wiederholt sich, statt beim ersten negativen
    /// Ergebnis dauerhaft abzuschalten - beim Beginn einer Ziehgeste kann das Fenster
    /// dem Zeiger noch um ein paar Millisekunden hinterherhinken.
    private func confirmWindowMove(on screen: NSScreen) {
        guard !windowMoveCheckInFlight, let startFrame = dragStartWindowFrame else { return }
        let now = CACurrentMediaTime()
        guard now - lastWindowMoveCheck > 0.05 else { return }
        lastWindowMoveCheck = now
        windowMoveCheckInFlight = true

        let pid = dragPID
        let token = dragToken
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Kurzes Timeout: waehrend einer laufenden Ziehgeste darf ein traeges
            // Fenster die Erkennung nicht ausbremsen.
            let current = focusedWindowFrame(pid: pid, screenH: screenH, timeout: 0.1)
            DispatchQueue.main.async {
                guard let self, self.dragToken == token else { return }
                self.windowMoveCheckInFlight = false
                guard let current, self.dragging, !self.visible else { return }

                let moved = abs(current.minX - startFrame.minX) > 6
                    || abs(current.minY - startFrame.minY) > 6
                guard moved else { return }

                self.dragIsWindowMove = true
                // Der Zeiger muss beim Bestaetigen noch am oberen Rand sein - sonst
                // poppt das Panel auf, nachdem der Nutzer laengst weggezogen ist.
                let mouse = NSEvent.mouseLocation
                guard screen.frame.maxY - mouse.y < 40 else { return }

                self.visible = true
                self.snapPanel.show(on: screen)
                self.assistPanel.prewarm()
            }
        }
    }

    // MARK: Touch-Pfad

    /// Beobachtet Fensterbewegungen der jeweils aktiven App. Notwendig, weil
    /// Fingereingabe komplett am Event-System vorbeilaeuft: der WindowServer
    /// verschiebt das Fenster selbst, ohne dass andere Apps davon etwas mitbekommen.
    func startTouchWindowTracking() {
        updateTouchObserver()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateTouchObserver() }
    }

    private func updateTouchObserver() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != touchObservedPID,
              pid != ProcessInfo.processInfo.processIdentifier else { return }

        if let old = touchObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(old), .defaultMode)
            touchObserver = nil
            touchObservedPID = 0
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, axWindowMovedCallback, &obs) == .success, let obs else { return }
        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, axApp, kAXWindowMovedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        touchObserver = obs
        touchObservedPID = pid
    }

    func handleWindowMovedByTouch(_ element: AXUIElement) {
        // Maus und Stift liefern echte Events - dort greift der bewaehrte Pfad.
        // Dieser hier ist ausschliesslich fuer Fingereingabe zustaendig.
        guard !dragging, !isProgrammaticMoveActive else { return }
        guard let screenH = NSScreen.screens.first?.frame.height,
              let frame = getWindowFrame(win: element, screenH: screenH) else { return }

        if let last = touchLastFrame {
            touchTravelled += hypot(frame.minX - last.minX, frame.minY - last.minY)
        }
        touchLastFrame = frame
        touchStillSince = 0
        touchMoveCount += 1

        if !touchDragActive {
            touchDragActive = true
            touchDragPID = touchObservedPID
        }

        // Erst nach mehreren Meldungen und spuerbarer Strecke als Geste werten -
        // eine App, die ihr Fenster einmalig selbst umsetzt, soll nichts ausloesen.
        if touchMoveCount >= 3 && touchTravelled > 20 {
            updateTouchPanel(frame: frame)
        }
        startTouchPollIfNeeded()
    }

    /// Vergroesserungsfaktor fuer die Bedienung per Finger. Ein Fingerkuppen-
    /// Auflagepunkt ist deutlich groesser als ein Mauszeiger, deshalb waechst das
    /// Panel mitsamt Zonen, Abstaenden und Rundungen um die Haelfte.
    private static let touchUIScale: CGFloat = 1.5

    /// Ersatz fuer den Mauszeiger: die Mitte der Titelleiste des gezogenen Fensters.
    /// Dort liegt beim Ziehen der Finger - einen echten Zeiger gibt es nicht.
    private func touchProxyPoint(for frame: CGRect) -> NSPoint {
        NSPoint(x: frame.midX, y: frame.maxY - 14)
    }

    private func updateTouchPanel(frame: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let screen else { return }

        if !visible, screen.frame.maxY - frame.maxY < 40 {
            visible = true
            snapPanel.show(on: screen, scale: Self.touchUIScale)
            assistPanel.prewarm()
        }
        guard visible else { return }

        let proxy = touchProxyPoint(for: frame)
        if let l = snapPanel.snapLayoutAt(screenPoint: proxy) {
            snapPanel.showPreview(for: l)
        } else {
            snapPanel.hidePreview()
        }
    }

    private func startTouchPollIfNeeded() {
        guard touchPollTimer == nil else { return }
        // AX-Meldungen kommen nur etwa alle 100 ms und hoeren beim Loslassen
        // einfach auf. Fuer das Erkennen des Loslassens braucht es eine feinere,
        // eigene Abtastung der Fensterposition.
        touchPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.touchPollTick()
        }
    }

    private func stopTouchPoll() {
        touchPollTimer?.invalidate()
        touchPollTimer = nil
    }

    private func touchPollTick() {
        guard touchDragActive else { stopTouchPoll(); return }
        guard !touchPollInFlight else { return }
        touchPollInFlight = true

        let pid = touchDragPID
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let frame = focusedWindowFrame(pid: pid, screenH: screenH, timeout: 0.05)
            DispatchQueue.main.async {
                guard let self else { return }
                self.touchPollInFlight = false
                guard self.touchDragActive, let frame else { return }

                let last = self.touchLastFrame
                let still = last.map { abs(frame.minX - $0.minX) < 1 && abs(frame.minY - $0.minY) < 1 } ?? false

                if still {
                    if self.touchStillSince == 0 {
                        self.touchStillSince = CACurrentMediaTime()
                    } else if CACurrentMediaTime() - self.touchStillSince > 0.35 {
                        // Waehrend des Ziehens lagen zwischen zwei Bewegungen hoechstens
                        // ~285 ms. Bleibt das Fenster laenger stehen, wurde losgelassen.
                        self.finishTouchDrag(frame: frame)
                    }
                } else {
                    if let last { self.touchTravelled += hypot(frame.minX - last.minX, frame.minY - last.minY) }
                    self.touchLastFrame = frame
                    self.touchStillSince = 0
                    self.touchMoveCount += 1
                    if self.touchMoveCount >= 3 && self.touchTravelled > 20 {
                        self.updateTouchPanel(frame: frame)
                    }
                }
            }
        }
    }

    private func finishTouchDrag(frame: CGRect) {
        let pid = touchDragPID
        let wasVisible = visible
        touchDragActive = false
        touchLastFrame = nil
        touchStillSince = 0
        touchMoveCount = 0
        touchTravelled = 0
        stopTouchPoll()

        if wasVisible {
            let proxy = touchProxyPoint(for: frame)
            if let l = snapPanel.snapLayoutAt(screenPoint: proxy) ?? snapPanel.previewedLayout {
                snapPanel.hide()
                visible = false
                snapWindow(pid: pid, layout: l)
                presentAssist(after: l, excludingPID: pid)
                return
            }
            snapPanel.hide()
            visible = false
        }

        // Kein Snap-Ziel: eventuell wurde ein zuvor gesnapptes Fenster weggezogen
        // und soll seine urspruengliche Groesse zurueckbekommen.
        restoreIfDraggedAway(pid: pid, pointer: nil)
    }

    func handle(_ e: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let fromTop = screen.frame.maxY - mouse.y

        switch e.type {
        case .leftMouseDown:
            dragging = false
            dragStartPos = mouse
            lastMouseDragPos = mouse
            // CGWindowListCopyWindowInfo kostet einige Millisekunden und lief bisher bei
            // jedem Mausklick auf dem Main-Thread. Bis der Zeiger den oberen Rand
            // erreicht, ist das Ergebnis laengst da.
            dragPID = 0
            dragStartWindowFrame = nil
            dragIsWindowMove = false
            windowMoveCheckInFlight = false
            baselineCaptureInFlight = false
            lastWindowMoveCheck = 0
            dragToken &+= 1
            let token = dragToken
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let pid = findPIDUnderCursor(mouse)
                DispatchQueue.main.async {
                    guard let self, self.dragToken == token else { return }
                    self.dragPID = pid
                }
            }
            if assistPanel.isVisible { assistPanel.dismiss() }

        case .leftMouseDragged:
            if abs(mouse.x - lastMouseDragPos.x) < 2 && abs(mouse.y - lastMouseDragPos.y) < 2 { return }
            lastMouseDragPos = mouse
            
            dragging = true
            // Ausgangsrahmen einmal pro Ziehgeste erfassen - hier statt bei mouseDown,
            // damit ein simpler Klick keinen AX-Aufruf kostet. Das Fenster hat sich zu
            // diesem Zeitpunkt erst um wenige Pixel bewegt, taugt also als Referenz.
            captureDragBaselineIfNeeded()

            let dx = mouse.x - dragStartPos.x
            let dy = mouse.y - dragStartPos.y
            if fromTop < 40 && !visible && dragPID != 0 && sqrt(dx * dx + dy * dy) > 20 {
                if dragIsWindowMove {
                    visible = true
                    snapPanel.show(on: screen)
                    assistPanel.prewarm()
                } else {
                    // Noch nicht bestaetigt: nachsehen, ob sich das Fenster bewegt.
                    confirmWindowMove(on: screen)
                }
            }
            if visible {
                if let l = snapPanel.snapLayoutAt(screenPoint: mouse) {
                    snapPanel.showPreview(for: l)
                } else {
                    snapPanel.hidePreview()
                }
            }

        case .leftMouseUp:
            let wasDragging = dragging
            dragging = false

            guard visible else {
                // Kein Snap-Panel offen, aber es wurde gezogen: eventuell wurde ein
                // gesnapptes Fenster weggezogen und will seine alte Groesse zurueck.
                if wasDragging { restoreIfDraggedAway(pid: dragPID, pointer: NSEvent.mouseLocation) }
                break
            }

            // Praeziser Treffer zuerst; sonst gilt die sichtbare Vorschau. Dadurch
            // reicht das Loslassen - ein zusaetzlicher Klick auf die Zone entfaellt.
            if let l = snapPanel.snapLayoutAt(screenPoint: mouse) ?? snapPanel.previewedLayout {
                snapPanel.hide()
                visible = false
                snapWindow(pid: dragPID, layout: l)
                presentAssist(after: l, excludingPID: dragPID)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let s = self, !s.dragging, s.visible else { return }
                    s.visible = false
                    s.snapPanel.hide()
                }
            }
        default: break
        }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.offgrid", accessibilityDescription: nil)
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()

        // Sprachwechsel wirkt sofort auf Menue, Panel-Titel und Suchfeld - ohne
        // App-Neustart, anders als Apples eigener NSLocalizedString-Mechanismus.
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange),
                                               name: .appLanguageDidChange, object: nil)

        // Wechsel des Erscheinungsbilds baut beide Panels neu auf (Material kann
        // sich aendern) und faerbt die Zellen im Launcher-Pool nach.
        NotificationCenter.default.addObserver(self, selector: #selector(designModeDidChange),
                                               name: .designModeDidChange, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(statusIconVisibilityChanged),
                                               name: .statusIconVisibilityDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accentColorChanged),
                                               name: .accentColorDidChange, object: nil)
    }

    @objc private func languageDidChange() {
        rebuildMenu()
        snapPanel.refreshLanguage()
        assistPanel.refreshLanguage()
    }

    @objc private func statusIconVisibilityChanged() {
        applyStatusIconVisibility()
    }

    @objc private func accentColorChanged() {
        snapPanel.refreshColors()
        assistPanel.refreshColors()
    }

    @objc private func designModeDidChange() {
        rebuildMenu() // "Akzentfarbe aendern..." wird in Calm deaktiviert
        snapPanel.refreshDesign()
        assistPanel.refreshDesign()
    }

    /// Das Menueleisten-Symbol traegt nur noch zwei Eintraege: Alle Einstellungen
    /// liegen im eigenen Fenster, damit sie auch erreichbar bleiben, wenn das
    /// Symbol ausgeblendet ist.
    private func rebuildMenu() {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: L("menu.header"), action: nil, keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: L("menu.hint"), action: nil, keyEquivalent: ""))
        m.addItem(.separator())

        let settingsItem = NSMenuItem(title: L("menu.settings"), action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        m.addItem(settingsItem)

        m.addItem(.separator())
        m.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = m
    }

    @objc func showSettingsWindow() {
        SettingsWindowController.shared.show()
    }

    /// Untermenue mit den Erscheinungsbildern. "Automatisch" folgt live dem
    /// System-Hell/Dunkel-Umschalter, steht deshalb - wie "Systemsprache" im
    /// Sprachmenue - oben und durch eine Trennlinie abgesetzt von den vier
    /// fest gewaehlten Modi. Genau einer ist aktiv, Wechsel wirkt sofort ueber
    /// `designModeDidChange`.
    private func buildAppearanceMenu() -> NSMenu {
        let sub = NSMenu()
        let current = DesignMode.current

        let systemItem = NSMenuItem(title: DesignMode.system.menuTitle, action: #selector(selectAppearance(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.representedObject = DesignMode.system.rawValue
        systemItem.state = current == .system ? .on : .off
        sub.addItem(systemItem)

        sub.addItem(.separator())

        for mode in DesignMode.allCases where mode != .system {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = current == mode ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    // MARK: Menueleisten-Symbol aus-/einblenden

    func applyStatusIconVisibility() {
        statusItem.isVisible = !GeneralSettings.isStatusIconHidden
    }

    /// Reagiert auf die Distributed Notification eines zweiten, sofort wieder
    /// beendeten Prozesses (siehe Entry Point): das Symbol ist ausgeblendet, es
    /// gibt also keinen Klickpunkt - stattdessen erscheint das bestehende Menue
    /// mittig auf dem Hauptbildschirm, mit allen gewohnten Einstellungen.
    @objc private func handleShowSettingsRequest() {
        SettingsWindowController.shared.show()
    }

    /// Schaetzt ab, ob die App gerade beim Anmelden automatisch gestartet wurde -
    /// dann waere ein aufspringendes Einstellungsfenster aufdringlich.
    ///
    /// Bewusst eine Heuristik: macOS liefert keinen verlaesslichen Marker dafuer.
    /// (Geprueft und verworfen: `XPC_SERVICE_NAME` ist auch bei manuellem Start
    /// gesetzt und taugt nicht zur Unterscheidung.) `systemUptime` zaehlt nur die
    /// Wachzeit und bleibt nach dem Aufwachen aus dem Ruhezustand hoch - kurz nach
    /// dem Hochfahren ist der Wert also klein, sonst gross.
    private var launchedAtLogin: Bool {
        isLoginItemEnabled() && ProcessInfo.processInfo.systemUptime < 90
    }

    /// Wird aufgerufen, wenn die bereits laufende App erneut geoeffnet wird
    /// (Doppelklick im Finder, Spotlight, Dock) - dann sollen die Einstellungen
    /// erscheinen, so wie es der Nutzer erwartet.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DesignMode(rawValue: raw) else { return }
        DesignMode.setCurrent(mode)
    }

    /// Untermenue mit den drei Sprachoptionen. Sprachnamen selbst werden nicht
    /// uebersetzt (wie ueberall im System ueblich - "Deutsch" heisst auch im
    /// englischen Menue "Deutsch").
    private func buildLanguageMenu() -> NSMenu {
        let sub = NSMenu()
        let current = AppLanguage.storedOverride

        let systemItem = NSMenuItem(title: L("menu.language.system"), action: #selector(selectLanguage(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.representedObject = AppLanguage.system.rawValue
        systemItem.state = current == .system ? .on : .off
        sub.addItem(systemItem)

        sub.addItem(.separator())

        // Alle 34 Sprachen, alphabetisch nach Eigenname sortiert - genau wie
        // Apples eigener Sprachauswahl-Dialog es macht.
        let all = AppLanguage.allCases.filter { $0 != .system }
            .sorted { $0.nativeName.localizedStandardCompare($1.nativeName) == .orderedAscending }

        for language in all {
            let item = NSMenuItem(title: language.nativeName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = current == language ? .on : .off
            sub.addItem(item)
        }

        return sub
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        AppLanguage.setOverride(language)
    }

    @objc func handleToggleLogin() {
        toggleLoginItem()
        loginMenuItem.title = isLoginItemEnabled() ? L("menu.autostart.on") : L("menu.autostart.off")
    }
    
    @objc func showColorPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSColorPanel.shared
        panel.color = accentColor()
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        
        if let btn = statusItem.button, let win = btn.window {
            panel.setFrameOrigin(NSPoint(x: win.frame.midX - panel.frame.width / 2, y: win.frame.minY - panel.frame.height - 5))
        }
        
        panel.makeKeyAndOrderFront(nil)
    }
    
    @objc func colorChanged(_ sender: NSColorPanel) {
        setAccentColor(sender.color)
        snapPanel.refreshColors()
        assistPanel.refreshColors()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry Point

let running = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}

// Laeuft die App bereits, wird sie nicht neu gestartet: dieser zweite, ueberzaehlige
// Prozess bittet die laufende Instanz per Distributed Notification, ihr
// Einstellungsfenster zu zeigen, und beendet sich sofort selbst wieder.
// Das ist besonders wichtig, wenn das Menueleisten-Symbol ausgeblendet ist - dann
// waere das erneute Oeffnen der einzige Weg zu den Einstellungen.
if !running.isEmpty {
    DistributedNotificationCenter.default().postNotificationName(
        showSettingsRequestNotification, object: Bundle.main.bundleIdentifier,
        userInfo: nil, deliverImmediately: true)
    // Kurze Gnadenfrist, damit die Notification den laufenden Prozess sicher
    // erreicht, bevor dieser hier verschwindet.
    Thread.sleep(forTimeInterval: 0.15)
    exit(0)
}

for i in running { i.terminate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
