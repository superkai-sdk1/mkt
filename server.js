const express = require("express");
const fs = require("fs");
const path = require("path");
const multer = require("multer");

const app = express();
const PORT = process.env.PORT || 3000;

const DATA_DIR = path.join(__dirname, "data");
const SITE_FILE = path.join(DATA_DIR, "site.json");
const AUTH_FILE = path.join(DATA_DIR, "auth.json");

if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

const DEFAULTS = {
  hero: {
    badge: "Открыт для новых клиентов",
    title: "Продвижение в\u00a0соцсетях",
    subtitle: "Аудит, стратегия и разбор вашего Instagram. Прозрачные цены, измеримый результат.",
    ctaText: "Смотреть услуги"
  },
  sections: {
    label: "Что я предлагаю",
    title: "Услуги и\u00a0цены",
    subtitle: "Выберите подходящий формат — от быстрого разбора до полной стратегии роста",
    tab1: "Услуги",
    tab2: "Закрытые каналы"
  },
  cta: {
    title: "Остались вопросы?",
    subtitle: "Напишите мне, и мы подберём подходящий формат работы под ваши задачи.",
    btnText: "Написать в Telegram",
    tgUrl: "https://t.me/MktRahim"
  },
  about: {
    name: "Rahim", initial: "R",
    bio: "SMM-специалист и маркетолог. Помогаю экспертам, предпринимателям и брендам выстраивать сильное присутствие в Instagram — от упаковки профиля до полной стратегии продвижения.",
    stat1Value: "50+", stat1Label: "проектов",
    stat2Value: "3+", stat2Label: "года опыта",
    stat3Value: "100%", stat3Label: "индивидуальный подход"
  },
  services: [
    { title: "Консультация", shortDesc: "Персональная сессия: разберём вашу стратегию, ответим на вопросы и составим план действий.", price: "20 000 ₽", desc: "Персональная сессия длительностью 60 минут. Разберём вашу текущую стратегию продвижения, ответим на все вопросы и составим пошаговый план действий." },
    { title: "Разбор шапки Instagram", shortDesc: "Анализ bio, аватара, ссылки и highlights — рекомендации по улучшению первого впечатления.", price: "2 000 ₽", desc: "Подробный анализ первого экрана вашего профиля: аватар, имя и юзернейм, описание bio, ссылка, актуальные Highlights." },
    { title: "Разбор страницы", shortDesc: "Детальный анализ контента, визуала и структуры вашего профиля с рекомендациями по росту.", price: "5 000 ₽", desc: "Детальный анализ вашего профиля целиком: визуальная сетка, качество контента, заголовки и тексты постов, использование Reels и Stories." },
    { title: "Полный аудит страницы", shortDesc: "Комплексная проверка: контент, охваты, вовлечённость, конкуренты. Подробный отчёт и стратегия.", price: "10 000 ₽", desc: "Комплексная проверка всех аспектов аккаунта: контент-стратегия, охваты и вовлечённость, анализ целевой аудитории, сравнение с конкурентами." },
    { title: "Google Gemini", shortDesc: "Годовая подписка на AI-ассистент — генерация контента, аналитика и автоматизация рутины.", price: "20 000 ₽ / год", desc: "Годовая подписка на AI-ассистент Google Gemini. Используйте его для генерации идей и текстов постов, анализа контента конкурентов, создания контент-планов.", featured: true, badge: "AI-инструмент" }
  ],
  channels: [
    { title: "Канал по SMM", shortDesc: "Тренды, шаблоны, разборы Reels — ежедневные материалы для роста в соцсетях.", price: "1 500 ₽ / мес", desc: "Закрытый Telegram-канал с ежедневными разборами трендов, готовыми шаблонами контент-планов, примерами успешных Reels и Stories." },
    { title: "Канал по маркетингу", shortDesc: "Воронки, кейсы, стратегии привлечения — всё для роста бизнеса и продаж.", price: "2 500 ₽ / мес", desc: "Закрытый канал для предпринимателей и маркетологов. Разборы воронок продаж, стратегии привлечения клиентов, анализ рекламных кампаний." },
    { title: "Канал по нейросетям", shortDesc: "Промпты, инструменты, автоматизация — AI для маркетинга и бизнеса.", price: "2 000 ₽ / мес", desc: "Всё о применении AI в маркетинге и бизнесе: промпты для ChatGPT, Gemini, Midjourney, автоматизация рутины, генерация контента." }
  ]
};

function loadSite() {
  try { return JSON.parse(fs.readFileSync(SITE_FILE, "utf8")); }
  catch { return JSON.parse(JSON.stringify(DEFAULTS)); }
}

function saveSite(data) {
  fs.writeFileSync(SITE_FILE, JSON.stringify(data, null, 2), "utf8");
}

function loadAuth() {
  try { return JSON.parse(fs.readFileSync(AUTH_FILE, "utf8")); }
  catch { return {}; }
}

function saveAuth(data) {
  fs.writeFileSync(AUTH_FILE, JSON.stringify(data, null, 2), "utf8");
}

if (!fs.existsSync(SITE_FILE)) saveSite(DEFAULTS);

function requireAuth(req, res, next) {
  const auth = loadAuth();
  if (!auth.passwordHash) return res.status(401).json({ error: "No password set" });
  const token = (req.headers.authorization || "").replace("Bearer ", "");
  if (token !== auth.passwordHash) return res.status(401).json({ error: "Unauthorized" });
  next();
}

app.use(express.json({ limit: "2mb" }));

function findAvatar() {
  try {
    return fs.readdirSync(DATA_DIR).find(f => f.startsWith("avatar."));
  } catch { return null; }
}

const upload = multer({
  storage: multer.diskStorage({
    destination: DATA_DIR,
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname).toLowerCase() || ".jpg";
      cb(null, "avatar" + ext);
    }
  }),
  limits: { fileSize: 2 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    cb(null, file.mimetype.startsWith("image/"));
  }
});

app.get("/api/data", (_req, res) => {
  const site = loadSite();
  site.hasAvatar = !!findAvatar();
  res.json(site);
});

app.get("/api/avatar", (_req, res) => {
  const file = findAvatar();
  if (!file) return res.status(404).end();
  res.sendFile(path.join(DATA_DIR, file));
});

app.get("/api/auth/status", (_req, res) => {
  res.json({ hasPassword: !!loadAuth().passwordHash });
});

app.post("/api/auth/setup", (req, res) => {
  if (loadAuth().passwordHash) return res.status(400).json({ error: "Password already set" });
  const { passwordHash } = req.body;
  if (!passwordHash || passwordHash.length < 10) return res.status(400).json({ error: "Invalid hash" });
  saveAuth({ passwordHash });
  res.json({ ok: true });
});

app.post("/api/auth/login", (req, res) => {
  const auth = loadAuth();
  if (req.body.passwordHash === auth.passwordHash) {
    res.json({ ok: true, token: auth.passwordHash });
  } else {
    res.status(401).json({ error: "Wrong password" });
  }
});

app.post("/api/auth/reset", (req, res) => {
  const auth = loadAuth();
  if (req.body.currentPasswordHash !== auth.passwordHash) {
    return res.status(401).json({ error: "Wrong password" });
  }
  saveAuth({});
  res.json({ ok: true });
});

app.post("/api/hero", requireAuth, (req, res) => {
  const site = loadSite();
  site.hero = req.body;
  saveSite(site);
  res.json({ ok: true });
});

app.post("/api/sections", requireAuth, (req, res) => {
  const site = loadSite();
  site.sections = req.body;
  saveSite(site);
  res.json({ ok: true });
});

app.post("/api/cta", requireAuth, (req, res) => {
  const site = loadSite();
  site.cta = req.body;
  saveSite(site);
  res.json({ ok: true });
});

app.post("/api/about", requireAuth, (req, res) => {
  const site = loadSite();
  site.about = req.body;
  saveSite(site);
  res.json({ ok: true });
});

app.post("/api/services", requireAuth, (req, res) => {
  const site = loadSite();
  site.services = req.body;
  saveSite(site);
  res.json({ ok: true });
});

app.post("/api/channels", requireAuth, (req, res) => {
  const site = loadSite();
  site.channels = req.body;
  saveSite(site);
  res.json({ ok: true });
});

app.post("/api/avatar", requireAuth, (req, res, next) => {
  const old = findAvatar();
  if (old) fs.unlinkSync(path.join(DATA_DIR, old));
  next();
}, upload.single("avatar"), (req, res) => {
  if (!req.file) return res.status(400).json({ error: "No file" });
  res.json({ ok: true });
});

app.delete("/api/avatar", requireAuth, (_req, res) => {
  const file = findAvatar();
  if (file) fs.unlinkSync(path.join(DATA_DIR, file));
  res.json({ ok: true });
});

app.use(express.static(__dirname));

app.listen(PORT, () => {
  console.log(`MKT server: http://localhost:${PORT}`);
});
