(() => {
  const root = document.documentElement;
  const themeButton = document.getElementById('theme-toggle');
  const themeIcon = document.getElementById('theme-icon');
  const languageButton = document.getElementById('language-toggle');
  const languageCode = document.getElementById('language-code');
  const menuButton = document.getElementById('menu-toggle');
  const mobileMenu = document.getElementById('mobile-menu');
  const year = document.getElementById('year');
  if (year) year.textContent = new Date().getFullYear();

  const renderTheme = (theme) => {
    root.dataset.theme = theme;
    if (themeIcon) themeIcon.textContent = theme === 'light' ? '☀' : '☾';
    if (themeButton) themeButton.setAttribute('aria-label', theme === 'light' ? 'Switch to dark theme' : 'Switch to light theme');
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme === 'light' ? '#f3eee4' : '#12110e');
  };
  const storedTheme = localStorage.getItem('vamp-theme');
  renderTheme(storedTheme === 'dark' ? 'dark' : 'light');
  themeButton?.addEventListener('click', () => {
    const next = root.dataset.theme === 'light' ? 'dark' : 'light';
    localStorage.setItem('vamp-theme', next);
    renderTheme(next);
  });

  const setMobileMenu = (open) => {
    if (!menuButton || !mobileMenu) return;
    mobileMenu.hidden = !open;
    mobileMenu.dataset.open = String(open);
    menuButton.setAttribute('aria-expanded', String(open));
    menuButton.setAttribute('aria-label', open ? 'Close navigation menu' : 'Open navigation menu');
    menuButton.textContent = open ? '×' : '☰';
  };
  menuButton?.addEventListener('click', () => setMobileMenu(mobileMenu.dataset.open !== 'true'));
  mobileMenu?.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => setMobileMenu(false)));

  const translations = {
    tr: {
      'nav.browser': 'Tarayıcı',
      'nav.compare': 'Karşılaştır',
      'nav.previews': 'Önizlemeler',
      'nav.download': 'İndir',
      'nav.cta': 'Vamp’ı al',
      'nav.github': 'GitHub’ı aç ↗',
      'hero.eyebrow': 'Uzaktan masaüstü · terminal · özel ağ',
      'hero.title1': 'Mac’in.',
      'hero.title2': 'Yanı başında.',
      'hero.copy': 'Mac’ini kontrol et, uzak bir terminal aç ya da Safari’yi istemci olarak eşle. LAN veya Tailscale. Hesap yok. Barındırılan aktarıcı yok. Her yeni cihaz senin onayını ister.',
      'hero.primary': 'Safari kontrolünü gör',
      'hero.note': 'Açık kaynaklı',
      'hero.noteStrong': '· hesap gerekmez.',
      'hero.connected': 'bağlı',
      'browser.kicker': 'Tarayıcı',
      'browser.title1': 'Safari istemcidir.',
      'browser.lead': 'Mac host’ta tarayıcıdan sekiz sekme ve on ajan başlatıcı. Loopback 9475, Tailscale veya Cloudflare Access. IPA yok. On iki haneli kodla eşle.',
      'browser.p1title': 'Host’tan eşle',
      'browser.p1': 'Vamp Host’taki QR’ı tara ya da on iki haneli kodu yaz. On dakikada sona erer. Tarayıcı LAN’da veya tailnet’te kalır.',
      'browser.p2title': 'Sekiz bağımsız sekme',
      'browser.p2': 'Aynı çalışma alanında görev sohbeti ve gerçek bir PTY. tmux ve screen bağlama. Pano iki yönlü.',
      'browser.p3title': 'On ajan başlatıcı',
      'browser.p3': 'OpenCode, Claude, Codex, ChatGPT CLI, Grok ve diğerleri — Vamp Terminal ile aynı başlatıcılar, IPA yan yüklemeden.',
      'browser.chipPair': 'eşleme kodu',
      'browser.cta': 'Mac host al',
      'hero.connectionLabel': 'Bağlantı onaylandı',
      'hero.direct': 'DOĞRUDAN',
      'hero.transport': 'Bağlantı',
      'hero.relay': 'Barındırılan aktarıcı',
      'hero.none': 'Yok',
      'compare.kicker': 'Karşılaştır',
      'compare.title1': 'Her uygulama ne yapar.',
      'compare.lead': 'Aynı anda tek bir Mac host. Safari, Mac host’ların içinde — ayrı indirme yok.',
      'compare.capability': 'Yetenek',
      'compare.screen': 'Uzak ekran kontrolü',
      'compare.terminal': 'Uzak terminal',
      'compare.optIn': 'isteğe bağlı',
      'compare.alwaysOn': 'her zaman açık',
      'compare.overlay': 'katman',
      'compare.eightTabs': '8 sekme',
      'compare.input': 'Klavye ve işaretçi',
      'compare.clipboard': 'Pano eşitleme',
      'compare.files': 'Dosya aktarımı',
      'compare.agents': 'Ajan başlatıcıları',
      'compare.cli': 'CLI',
      'compare.taskChat': 'görev sohbeti',
      'compare.tenLaunchers': '10 başlatıcı',
      'compare.browser': 'Safari kontrolü',
      'compare.platform': 'Platform',
      'compare.swipe': 'Tabloyu kaydır, tüm uygulamaları gör →',
      'download.kicker': 'İndirmeler',
      'download.title1': 'Güncel derlemeler.',
      'download.lead': 'Build 47 yayında. Yüklemeden önce SHA-256’yı doğrula.',
      'download.hosts': 'Hostlar',
      'download.clients': 'İstemciler',
      'download.safariNote': 'Safari kontrolü Mac host panosundadır (loopback 9475, Tailscale Serve veya Cloudflare Access). Ayrı istemci yoktur.',
      'download.releaseNote': 'Kaynak veya yan yükleme talimatları mı lazım?',
      'download.github': 'GitHub deposunu aç ↗',
      'app.host': 'Tam uzak ekran ve isteğe bağlı terminal. Aynı anda yalnızca bir macOS host çalıştır.',
      'app.terminalHost': 'Her zaman açık terminal ve Safari kontrolü. Ekran paylaşımı yok. Vamp Host’un yanında çalıştırma.',
      'app.linux': 'Yalnızca tarayıcıdan Python host. Vamp Control ve Vamp Terminal bağlanamaz.',
      'app.controlMac': 'Onaylı bir Mac’i başka bir Mac’ten kontrol et. Yalnızca terminal katmanı — ajan başlatıcı yok.',
      'app.controlIos': 'Dokunmatik uzak kontrol. Sekiz sekme ve ajanlar için Vamp Terminal’i yan yükle.',
      'app.terminalIos': 'Onaylı bir Mac host’ta sekiz sekme ve ajan başlatıcıları. Linux’a bağlanmaz.',
      'app.safari': 'Mac host panosunda sekiz sekme ve on ajan başlatıcı. Loopback 9475, Tailscale veya Cloudflare Access. IPA yok.',
      'app.noDownload': 'host’ta',
      'app.download': 'İndir',
      'app.checksum': 'SHA-256',
      'app.getIpa': 'IPA al',
      'app.platformMacHost': 'macOS · host',
      'app.platformMacClient': 'macOS · istemci',
      'app.platformLinux': 'Linux · tarayıcı host’u',
      'app.platformSafari': 'tarayıcı · yerleşik',
      'app.chipScreen': 'ekran',
      'app.chipTerminal': 'terminal',
      'app.chipTerminalOnly': 'yalnızca terminal',
      'app.chipHeadless': 'ekransız',
      'app.chipScreenView': 'ekran',
      'app.chipControl': 'kontrol',
      'app.chipSideloadable': 'yan yüklenebilir',
      'app.chipTabs': '8 sekme',
      'footer.copy': 'Mac, iPhone, iPad, Safari ve Linux için açık kaynaklı uzak masaüstü ve terminal araçları.',
      'footer.install': 'Kurulum belgeleri',
      'footer.security': 'Güvenlik',
      'footer.meta': 'yerel öncelikli · eş onaylı · barındırılan aktarıcı yok',
      'nav.assistant': 'Assistant', 'nav.stream': 'Stream', 'nav.control': 'Control',
      'nav.security': 'Güvenlik', 'nav.explore': 'Ürünleri keşfet',
      'home.eyebrow': 'AI yardımcısı · odaklı akış',
      'home.title1': 'Mac’inle çalış.', 'home.title2': 'Her yerden.',
      'home.copy': 'Özel bir AI yardımcısıyla çalış veya ihtiyaç duyduğun Mac yüzeyini telefonuna aktar. Ürün hesabı yok. Barındırılan aktarıcı yok. Her bağlantı sana ait.',
      'home.assistantCta': 'Assistant’ı keşfet', 'home.streamCta': 'Stream’i keşfet',
      'home.note': 'Açık kaynak · özel LAN veya Tailscale · barındırılan aktarıcı yok.',
      'home.statAssistant': 'AI çalışma alanı + uzaktan erişim', 'home.statStream': 'odaklı görsel istemci',
      'home.statControl': 'tam uzak masaüstü', 'home.statRelay': 'barındırılan aktarıcı',
      'families.kicker': 'Ürün aileleri', 'families.title': 'Doğru başlangıç noktasını seç.',
      'families.lead': 'Her aile tek bir işe odaklanır ve yalnızca açıkça desteklediği Mac tarafıyla eşleşir.',
      'families.assistant': 'Mac’te sohbet, yerel veya kendi anahtarınla modeller, Kod çalışma alanları, uzman botlar ve onaylı otomasyon. Kendi iOS ve tarayıcı uzaktan erişimi dahildir.',
      'families.assistantCta': 'Assistant ailesini aç →',
      'families.stream': 'iPhone ve iPad için odaklı görsel istemci. Vamp Host, Vamp Stream Host veya Assistant üzerinden tam ekranı ya da bir uygulama penceresini aç.',
      'families.streamCta': 'Stream ailesini aç →',
      'families.control': 'Vamp Control, Vamp Host için tam uzak masaüstü istemcisidir. Ulaşmak istediğin Mac’e Host’u kur; ardından başka bir Mac, iPhone veya iPad’den ekranı, klavyeyi, işaretçiyi, panoyu ve dosyaları kontrol et.',
      'families.controlCta': 'Control akışını gör →',
      'families.controlMacCta': 'macOS için Control ↓', 'families.controlIosCta': 'Control iOS IPA ↓',
      'families.host': 'Vamp Control ve Vamp Stream için Mac host’u. Güvenilir ağında onaylı ekran yakalama, klavye ve işaretçi girişi, pano eşitleme ve dosya aktarımı sağlar.',
      'families.hostCta': 'Mac için Vamp Host ↓',
      'browser.kicker': 'Tarayıcı erişimi', 'browser.familyTitle': 'Uygulama kurmadan güvenli erişim.',
      'browser.familyLead': 'Tarayıcı ikincil bir istemcidir: Assistant oturumları veya ilgili Vamp Host iş akışları için kullanılır.',
      'browser.assistantTitle': 'Assistant Remote Sessions',
      'browser.assistantCopy': 'Güvenilir bir tarayıcıyı Mac uygulamasıyla eşleyerek oturumları gör, canlı yanıtları izle, istem gönder, soruları yanıtla, işlemleri onayla ve pano ya da dosyaları taşı.',
      'browser.hostTitle': 'Vamp Host tarayıcı kontrolü',
      'browser.hostCopy': 'Host’un yalnızca loopback’te çalışan tarayıcı yüzeyini Tailscale Serve ile özel olarak aç. Genel internete port yönlendirme.',
      'browser.trustTitle': 'Eşleştir, doğrula, iptal et',
      'browser.trustCopy': 'Kısa ömürlü kodla eşleştir, cihaz kimliğini karşılaştır ve kaydedilen tarayıcı güvenini istediğin zaman Mac’ten kaldır.',
      'download.familyTitle': 'İki ana ürün. Net eşlikçiler.',
      'download.familyLead': 'Önce Mac tarafını seç, sonra ona ait iOS istemcisini yükle. Yüklemeden önce SHA-256 değerlerini doğrula.',
      'download.assistant': 'AI çalışma alanı, kendi iOS uygulaması ve tarayıcı Remote Sessions erişimi.',
      'download.assistantCta': 'Assistant indirmeleri →',
      'download.stream': 'iPhone ve iPad görsel istemcisi; Vamp Host, Vamp Stream Host veya Assistant ile çalışır.',
      'download.streamCta': 'Stream IPA’yı al →',
      'download.control': 'Vamp Host için tam uzak masaüstü istemcileri.', 'download.hostCta': 'Host ve Control’u al →',
      'footer.familyCopy': 'Mac, iPhone, iPad ve tarayıcı için özel Assistant ve Stream ürünleri.',

      'assistant.navMac': 'Mac', 'assistant.navRemote': 'iOS + tarayıcı', 'assistant.navFeatures': 'Yetenekler',
      'assistant.get': 'Assistant’ı al', 'assistant.eyebrow': 'Yerel AI yardımcısı · Apple Silicon',
      'assistant.title1': 'Yerelde düşün.', 'assistant.title2': 'Her yerde çalış.',
      'assistant.heroCopy': 'Vamp Assistant özel AI sohbetini, Kod çalışma alanlarını, uzman botları, tarayıcı ve simülatör araçlarını, onaylı Mac işlemlerini kendi iPhone, iPad ve tarayıcı uzaktan erişimiyle birleştirir.',
      'assistant.downloadMac': 'Mac için indir', 'assistant.mobileCta': 'Mobil erişimi gör',
      'assistant.note': 'Apple Silicon · macOS 15+ · yerel MLX/GGUF veya kendi sağlayıcın.',
      'assistant.statModels': 'MLX + GGUF modelleri', 'assistant.statProviders': 'uzak sağlayıcılar',
      'assistant.statBots': 'uzman bot', 'assistant.statRemotes': 'Mac · iOS · tarayıcı',
      'assistant.macKicker': 'Mac uygulaması', 'assistant.macTitle': 'Önce bir yardımcı. Gerektiğinde Kod.',
      'assistant.macLead': 'Sohbetle başla. İş dosya, kabuk komutu, test, tarayıcı durumu veya simülatör istediğinde bir proje aç.',
      'assistant.chatTitle': 'Yerel ve BYOK AI',
      'assistant.chatCopy': 'Apple Silicon’da MLX veya GGUF çalıştır ya da Keychain’de saklanan anahtarlarla OpenAI, Anthropic, Gemini, OpenRouter ve uyumlu sağlayıcıları bağla.',
      'assistant.codeTitle': 'Çalışma alanını bilen kodlama',
      'assistant.codeCopy': 'Açıkça seçilmiş proje içinde bağlam, güvenli dosya ve kabuk araçları, git geri dönüş noktaları, doğrulama, bellek, planlar ve sınırlı alt ajanlar kullan.',
      'assistant.toolsTitle': 'Tarayıcı ve Simülatör',
      'assistant.toolsCopy': 'Yerleşik tarayıcıyı incele ve kullan, iOS Simulator uygulamalarını oluştur ve sür, tanıları gözden geçir; değişiklik yapan her işlem görünür onaya bağlı kalsın.',
      'assistant.remoteKicker': 'Remote Sessions', 'assistant.remoteTitle': 'Masadan uzakta da aynı Assistant.',
      'assistant.remoteLead': 'Yerel iOS eşlikçisini veya güvenilir tarayıcıyı Mac uygulamasıyla eşleştir. Modeller, oturumlar, araçlar, izinler ve dosyalar için Mac yetkilidir.',
      'assistant.iosCopy': 'Sohbet veya Kod oturumlarını gör ve başlat, uzman botları çalıştır, yanıtları izle, soruları cevapla, işlemleri onayla; terminal, paylaşım araçları, tam ekran ve uygulama penceresi kontrolünü aç.',
      'assistant.iosDownload': 'iOS IPA’yı indir ↓', 'assistant.browserTitle': 'Tarayıcı uzaktan erişimi',
      'assistant.browserCopy': 'Oturumlar, canlı sohbet, istemler, onaylar, sorular, pano ve dosya aktarımı için eşlenmiş Remote Sessions sayfasını güvenilir bir tarayıcıda aç.',
      'assistant.galleryKicker': 'Assistant’ın içinde', 'assistant.galleryTitle': 'Yerel araçlar, canlı görünüm.',
      'assistant.galleryLead': 'Güncel koyu mod uygulaması, kendi iOS Simulator ve özel Tarayıcı panelleri açıkken—maket veya ilgisiz ekran yok.',
      'assistant.simTitle': 'iOS uygulamalarını oluştur ve incele', 'assistant.simCopy': 'Assistant’tan ayrılmadan aygıt başlat, derleme yükle, uygulamayı aç, ekran görüntüsü al ve görünen sonucu doğrula.',
      'assistant.browserToolTitle': 'Ajan kontrollü tarayıcı', 'assistant.browserToolCopy': 'Gerçek web sayfalarını aynı Assistant çalışma alanında aç, incele, gezin ve doğrula.',
      'assistant.pairTitle': 'Özel uzak eşleme', 'assistant.pairCopy': 'Tek kullanımlık kod, kayıtlı güven ve Mac’ten iptal.',
      'assistant.securityTitle': 'Görünür sınırlarla güçlü.',
      'assistant.securityLead': 'İşlemi Mac yönetir. Uzak istemciler iş isteyebilir; çalışma alanı sınırı, Keychain saklama, onaylar ve iptal yerelde kalır.',
      'assistant.securityEyebrow': 'Sahibi tarafından kontrol edilir', 'assistant.securityCallout': 'Uzak ekran, uzak izin değildir.',
      'assistant.securityCalloutCopy': 'Hassas araçlar, pano, dosyalar, Mac kontrolü ve çalışma alanı değişiklikleri Mac uygulamasının açık politika ve izin denetimlerine bağlıdır.',
      'assistant.guard1Title': 'Özel eşleme', 'assistant.guard1Copy': 'Güvenilir LAN veya Tailscale kullan; kayıtlı cihazları istediğin zaman kaldır.',
      'assistant.guard2Title': 'Keychain sırları', 'assistant.guard2Copy': 'Sağlayıcı anahtarları, şifreleme anahtarları ve uzak token’lar platform deposunda kalır.',
      'assistant.guard3Title': 'Çalışma alanı sınırı', 'assistant.guard3Copy': 'Kod araçları yalnızca seçtiğin proje içinde çalışır.',
      'assistant.guard4Title': 'Onaylı işlemler', 'assistant.guard4Copy': 'Yazma, komut, tarayıcı ve bilgisayar kontrolü çalışmadan önce görünür.',
      'assistant.downloadTitle': 'Assistant iki tarafta.', 'assistant.downloadLead': 'Önce Mac uygulamasını kur, Remote Sessions’ı aç, ardından imzasız iOS eşlikçisini veya tarayıcıyı eşle.',
      'assistant.macCardTitle': 'Yerel Apple Silicon uygulaması.', 'assistant.macCardCopy': 'macOS 15 veya yenisi gerekir. Doğrudan derleme imzalıdır ancak notarize değildir; açmadan önce SHA-256’yı doğrula.',
      'assistant.iosCardTitle': 'Yerel uzak eşlikçi.', 'assistant.iosCardCopy': 'iOS veya iPadOS 18 gerekir. IPA imzasızdır; AltStore, SideStore, Sideloadly veya kendi profilinle yeniden imzalanmalıdır.',
      'assistant.downloadDmg': 'DMG’yi indir ↓', 'assistant.downloadIpa': 'IPA’yı indir ↓',
      'assistant.footer': 'Mac, iPhone, iPad ve tarayıcı için özel AI yardımcısı.',

      'stream.navHosts': 'Uyumlu host’lar', 'stream.navSetup': 'Kurulum', 'stream.navCompatibility': 'Uyumluluk',
      'stream.get': 'Stream’i al', 'stream.eyebrow': 'Odaklı görsel kontrol · iPhone + iPad',
      'stream.title1': 'Mac’in.', 'stream.title2': 'Yalnızca gereken.',
      'stream.heroCopy': 'Vamp Stream tam Mac ekranı veya tek bir uygulama penceresi için özel görsel istemcidir. Güvenilir LAN ya da özel tailnet üzerinde Vamp Host, Vamp Stream Host veya Assistant ile eşleştir.',
      'stream.downloadIpa': 'Stream IPA’yı indir', 'stream.chooseHost': 'Bir host seç',
      'stream.note': 'İmzasız IPA · aygıtın için yeniden imzala · barındırılan aktarıcı yok.',
      'stream.statHosts': 'uyumlu Mac host’u', 'stream.statVideo': 'donanım videosu', 'stream.statNetwork': 'LAN veya Tailscale', 'stream.statNative': 'iPhone + iPad',
      'stream.hostKicker': 'Mac tarafını seç', 'stream.hostTitle': 'Üç host. Tek odaklı istemci.',
      'stream.hostLead': 'İşe uyan host’u seç. Stream desteklenen yüzeyi keşfeder ve kullanılamayan kontrolleri göstermez.',
      'stream.fullHostCopy': 'Tam uzak masaüstü host’u. Stream ekran, klavye ve işaretçi için Vamp’ın imzalı eşleme ve kimlik doğrulamalı WebRTC yolunu kullanır.',
      'stream.miniHostCopy': 'Stream için üretilmiş hafif menü çubuğu host’u. Daha geniş Vamp Host yüzeyi olmadan görsel akış ve giriş sağlar.',
      'stream.miniLink': 'Vamp Stream Host’u keşfet →',
      'stream.assistantHostCopy': 'Tam ekran veya uygulama penceresi H.264 akışı ve kontrol için Assistant’ın kimlik doğrulamalı özel Remote Sessions uç noktasına bağlan.',
      'stream.assistantLink': 'Assistant’ı keşfet →',
      'stream.setupKicker': 'Kurulum', 'stream.setupTitle': 'Yükle. Eşle. İzle.',
      'stream.setupLead': 'İlk bağlantı güven kurar; sonraki bağlantılar sen kaldırana kadar kayıtlı kimliği kullanır.',
      'stream.step1Title': 'İki tarafı da yükle', 'stream.step1Copy': 'Vamp Stream’i iPhone veya iPad için yeniden imzala; ardından Mac’e Host, Vamp Stream Host veya Assistant yükle.',
      'stream.step2Title': 'Yalnız gereken izinleri ver', 'stream.step2Copy': 'Ekran Kaydı videoyu açar. Erişilebilirlik yalnız klavye veya işaretçi kontrolü için gerekir.',
      'stream.step3Title': 'Eşlemeyi doğrula', 'stream.step3Copy': 'Onaydan önce gösterilen cihaz kimliğini veya eşleme kodunu iki tarafta karşılaştır.',
      'stream.step4Title': 'Bir yüzey seç', 'stream.step4Copy': 'Tam ekranı veya Assistant ile tek bir uygulama penceresini aç.',
      'stream.compatKicker': 'Uyumluluk', 'stream.compatTitle': 'Bağlantı yolunu bil.',
      'stream.compatLead': 'İki yol da kimlik doğrulamalı ve özeldir; ancak ayrı protokoller ve ayrı güven depoları kullanır.',
      'stream.tableHost': 'Mac host’u', 'stream.tableTransport': 'Aktarım', 'stream.tableSurface': 'Görsel yüzey', 'stream.tableTrust': 'Güven',
      'stream.fullDisplay': 'Tam ekran', 'stream.hostTrust': 'Vamp host kimliği', 'stream.miniTrust': 'Ayrı Vamp Stream Host kimliği',
      'stream.assistantSurface': 'Tam ekran veya uygulama penceresi', 'stream.assistantTrust': 'Assistant eşleme + token',
      'stream.securityTitle': 'Ağ ve kimlikle özel.', 'stream.securityLead': 'Her host’u güvenilir LAN veya özel Tailscale ağında tut. Portlarını asla genel internete yönlendirme.',
      'stream.guard1Title': 'Açık onay', 'stream.guard1Copy': 'Bekleyen bağlantı Mac’te doğrulanana kadar güvenilir değildir.',
      'stream.guard2Title': 'Kimlik doğrulamalı video', 'stream.guard2Copy': 'Video ve giriş yalnızca seçilen host protokolü istemciyi doğruladıktan sonra taşınır.',
      'stream.guard3Title': 'İptal edilebilir cihazlar', 'stream.guard3Copy': 'Kaydedilen Stream cihazını onu onaylayan host’tan kaldır.',
      'stream.guard4Title': 'Genel aktarıcı yok', 'stream.guard4Copy': 'Vamp proje tarafından işletilen bir aktarıcı veya genel port yönlendirme gerektirmez.',
      'stream.downloadTitle': 'Stream ve tek bir host ile başla.', 'stream.downloadLead': 'iOS derlemesi AltStore tipi yeniden imzalama için imzasızdır. Yüklemeden önce sağlama toplamlarını doğrula.',
      'stream.streamCardTitle': 'Görsel istemci.', 'stream.streamCardCopy': 'iPhone veya iPad’e yükle, kendi profilinle yeniden imzala ve yalnızca kontrol ettiğin bir Mac ile eşle.',
      'stream.miniCardTitle': 'Hafif host.', 'stream.miniCardCopy': 'Mac tarafında yalnız görsel akış gerektiğinde küçük menü çubuğu host’unu kullan.',
      'stream.downloadMini': 'Vamp Stream Host DMG’yi indir', 'stream.footer': 'iPhone ve iPad için odaklı görsel kontrol.',

      'mini.navSurface': 'Yüzey', 'mini.navPermissions': 'İzinler', 'mini.get': 'Vamp Stream Host’u al',
      'mini.eyebrow': 'Hafif macOS host’u · Stream için', 'mini.title1': 'Host’u', 'mini.title2': 'küçük tut.',
      'mini.heroCopy': 'Vamp Stream Host, Vamp Stream için odaklı menü çubuğu host’udur. Ekranını yakalar, onaylı klavye ve işaretçi girişini kabul eder; geniş Vamp Host özelliklerini dışarıda bırakır.',
      'mini.downloadDmg': 'Vamp Stream Host DMG’yi indir', 'mini.getStream': 'Vamp Stream’i al',
      'mini.note': 'macOS · menü çubuğu uygulaması · yalnız özel LAN veya Tailscale.',
      'mini.statMenu': 'menü çubuğu yüzeyi', 'mini.statTransport': 'imzalı aktarım', 'mini.statPermissions': 'macOS izni', 'mini.statHost': 'aynı anda host',
      'mini.surfaceKicker': 'Odaklı yüzey', 'mini.surfaceTitle': 'Stream’in gerektirdiği her şey. Fazlası yok.',
      'mini.surfaceLead': 'Tam host panosu açmadan erişilebilirlik, izinler, eşleme istekleri, onaylı cihazlar ve çalışma kontrollerini gör.',
      'mini.pairTitle': 'Her yeni cihazı doğrula', 'mini.pairCopy': 'Bekleyen cihazı ve parmak izini incele. Yalnız Vamp Stream ile bağımsız karşılaştırmadan sonra onayla.',
      'mini.videoTitle': 'Ekranı aktar', 'mini.videoCopy': 'Mac ekranını yakala ve kimliği doğrulanmış Stream istemcisine Vamp’ın imzalı WebRTC yoluyla kodla.',
      'mini.inputTitle': 'İzin verildiğinde kontrol et', 'mini.inputCopy': 'Klavye ve işaretçi komutlarını yalnız güven kurulduktan ve macOS Erişilebilirlik izni verildikten sonra ilet.',
      'mini.permissionsKicker': 'macOS izinleri', 'mini.permissionsTitle': 'İki izin, iki net iş.',
      'mini.permissionsLead': 'Sistem Ayarları’nda izinleri Vamp Stream Host’a ver. Host hazır oluşu bildirir, onayı asla atlamaz.',
      'mini.screenTitle': 'Video için gerekli.', 'mini.screenCopy': 'Ekran Kaydı olmadan Stream Mac ekranını alamaz. macOS isterse izin değişikliğinden sonra Vamp Stream Host’u yeniden başlat.',
      'mini.accessTitle': 'Kontrol için gerekli.', 'mini.accessCopy': 'Giriş olmadan görüntüleme sürebilir. Klavye ve işaretçi kontrolü Vamp Stream Host için açık Erişilebilirlik izni gerektirir.',
      'mini.securityTitle': 'Küçük uygulama, eksiksiz güven sınırı.', 'mini.securityLead': 'Vamp Stream Host kendi kimliğini ve güvenilen eş deposunu tutar. Vamp Host onayını devralmaz.',
      'mini.limitEyebrow': 'Önemli çalışma sınırı', 'mini.limitTitle': 'Aynı anda tek Mac host çalıştır.',
      'mini.limitCopy': 'Vamp Stream Host ve Vamp Host sinyal ve veri portlarını paylaşır. Birini başlatmadan diğerini durdur; portları genel internete asla açma.',
      'mini.guard1Title': 'Ayrı kimlik', 'mini.guard1Copy': 'Stream Vamp Host’a güvense bile Vamp Stream Host ile doğrudan eşleştir.',
      'mini.guard2Title': 'İmzalı eşleme', 'mini.guard2Copy': 'Keşif, sinyalleşme ve veri yolu onaylı eşin kimliğini doğrular.',
      'mini.guard3Title': 'Özel ağ', 'mini.guard3Copy': 'Genel yönlendirme olmadan güvenilir LAN veya Tailscale kullan.',
      'mini.guard4Title': 'İptal edilebilir güven', 'mini.guard4Copy': 'Onaylı Stream cihazlarını Vamp Stream Host açılır penceresinden kaldır.',
      'mini.downloadTitle': 'Hafif host’u Stream ile eşleştir.', 'mini.downloadLead': 'DMG sağlama toplamını doğrula, Vamp Stream Host’u kur, gereken izinleri ver ve kimliğini kontrol ettikten sonra Stream’i onayla.',
      'mini.macCardTitle': 'Odaklı Mac host’u.', 'mini.macCardCopy': 'Kendi paketi, kimliği, izinleri ve güven deposu olan özel menü çubuğu uygulaması.',
      'mini.buildTitle': 'Özel şemayı derle.', 'mini.sourceLink': 'Kaynağı aç ↗',
      'mini.footer': 'Vamp Stream için tasarlanmış hafif Mac host’u.'
    }
  };
  let currentLanguage = localStorage.getItem('vamp-lang') === 'tr' ? 'tr' : 'en';
  const originalText = new Map();
  document.querySelectorAll('[data-i18n]').forEach((element) => originalText.set(element, element.innerHTML));
  const renderLanguage = (language) => {
    currentLanguage = language;
    document.documentElement.lang = language;
    document.querySelectorAll('[data-i18n]').forEach((element) => {
      const key = element.dataset.i18n;
      if (language === 'tr' && translations.tr[key]) element.innerHTML = translations.tr[key];
      else element.innerHTML = originalText.get(element);
    });
    if (languageCode) languageCode.textContent = language === 'tr' ? 'EN' : 'TR';
    if (languageButton) languageButton.setAttribute('aria-label', language === 'tr' ? 'Switch to English' : "Türkçe'ye geç");
    localStorage.setItem('vamp-lang', language);
  };
  renderLanguage(currentLanguage);
  languageButton?.addEventListener('click', () => renderLanguage(currentLanguage === 'tr' ? 'en' : 'tr'));

  const applyRelease = (release) => {
    if (!release || !release.assets) return;
    document.querySelectorAll('[data-release-link]').forEach((link) => {
      const asset = release.assets[link.dataset.releaseLink];
      if (!asset) return;
      link.href = asset.url;
      link.removeAttribute('aria-disabled');
    });
    document.querySelectorAll('[data-release-sha256]').forEach((link) => {
      const asset = release.assets[link.dataset.releaseSha256];
      if (!asset?.sha256Url) return;
      link.href = asset.sha256Url;
      link.hidden = false;
    });
    document.querySelectorAll('[data-release-version]').forEach((element) => {
      const asset = release.assets[element.dataset.releaseVersion];
      if (asset?.label) element.textContent = asset.label;
    });
    const footerRelease = document.querySelector('[data-release-footer]');
    if (footerRelease && release.tag) footerRelease.textContent = release.tag.replace(/^vamp-terminal-/, '');
  };
  fetch('/release.json', {cache:'no-store'}).then((response) => response.ok ? response.json() : null).then(applyRelease).catch(() => {});
})();
