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
      'browser.lead': 'Mac host’ta tarayıcıdan sekiz sekme ve on ajan başlatıcı. Loopback 9475, Tailscale veya Cloudflare Access. IPA yok. Altı haneli kodla eşle.',
      'browser.p1title': 'Host’tan eşle',
      'browser.p1': 'Vamp Host’taki QR’ı tara ya da altı haneli kodu yaz. On dakikada sona erer. Tarayıcı LAN’da veya tailnet’te kalır.',
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
      'download.lead': 'Ad-hoc imzalı. SHA-256’yı doğrula. Vamp Control hâlâ build 43.',
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
      'footer.meta': 'yerel öncelikli · eş onaylı · ajan dostu'
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
