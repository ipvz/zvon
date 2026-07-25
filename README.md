<p align="center">
  <img src="docs/hero.svg" alt="ZVON" width="760">
</p>

# ZVON

**Нативный macOS-ассистент для встреч и голосового ввода. Русский язык в приоритете, распознавание — на устройстве.**

ZVON слушает встречу с двух источников сразу — ваш микрофон и системный звук собеседника — и превращает разговор в живой транскрипт, тезисы и задачи. Отдельным горячим клавишем работает push-to-talk диктовка в стиле Wispr Flow: удерживаете клавишу, говорите, отпускаете — текст вставляется прямо в курсор. Речь распознаётся **полностью локально** (Parakeet TDT v3 через FluidAudio, CoreML на Apple Silicon); наружу — к вашему LLM-эндпоинту — уходят только производные тексты, и то лишь если вы его настроите.

<p align="center">
  <img src="docs/window.svg" alt="Главное окно ZVON — три колонки: сайдбар, записи, деталь встречи" width="940">
</p>

---

## ✦ Что это

ZVON — это одно окно и один плавающий виджет, закрывающие весь путь встречи:

- **Запись с ролями** — микрофон помечается как «Вы» (`Speaker.me`), системный звук как «Собеседник» (`Speaker.them`). Роли берутся из источника, а не из нейросетевой диаризации, поэтому разделение на двоих участников **100% точное**.
- **Живой транскрипт** — распознавание на устройстве, финальные строки + партиалы по каждому спикеру, глобальная временная шкала переживает паузу/возобновление.
- **✦ Итог** — LLM собирает тезисы, решения и темы (но **не** задачи).
- **Задачи только по голосу** — задача появляется, только когда вы произнесли триггер; никакой фоновой генерации из саммари.
- **Диктовка** — глобальный хоткей, вставка в курсор, опциональная AI-причёска текста.
- **Словарь, рецепты, вопросы по встрече и по всему архиву.**

> Целевой продукт собирается как **`ZVON.app`** (`PRODUCT_NAME=ZVON`), хотя проект и схема XcodeGen называются `Parley`, а bundle id — `com.parley.app`. Легаси-имя `Parley` всё ещё встречается в путях, комментариях и идентификаторах. Marketing version `0.1.0`, минимум macOS `14.0`.

---

## ✦ Ключевые возможности

| Раздел | Что делает | Настройка (по умолч.) |
|---|---|---|
| **Встречи** | Двухисточниковая запись (mic + system audio), роли Вы/Собеседник, live-метр по микрофону (у системного источника уровень не снимается), пауза/возобновление. | `captureMode = .micOnly` |
| **Диктовка** | Push-to-talk (`.hold`) или `.toggle`, сборка `.me`-финалов, вставка в курсор через `TextInserter`, история 100 сниппетов, счётчик слов за всё время. | hold-режим |
| **Итог / заметки** | `MeetingNotes`: `summary` (до 15 буллетов), `decisions`, `topics` (2–4 слова). Язык транскрипта, `temp 0.15`, `max 1600` токенов, одна ремонтная ретрай-попытка на битый JSON. | `summariesEnabled = on` |
| **Задачи** | Создаются **только** по произнесённому стему (`задач` / `напомн` / `не забуд`) из вашей речи, вопрос с `?` вето, LLM-гейт `parseTask` подтверждает. Кросс-митинговый агрегатор, экспорт в Markdown и Apple Reminders. | `taskExtractionEnabled = on` |
| **Словарь** | Локальная детерминированная коррекция (точный маппинг вариантов, regex фраз, fuzzy: транслит + Левенштейн ≥ 0.86) + инъекция канонических терминов в LLM-промпт как DATA. «Добавить в словарь» на лету. | `correctionEnabled`, `llmInjectEnabled = on` |
| **Рецепты** | Сохранённые prompt-линзы над материалами встречи: Письмо-follow-up, Протокол, Тезисы в Telegram, Черновик ТЗ/PRD, Разбор звонка. Кастомные рецепты, `temp 0.35`, markdown. | 5 встроенных |
| **Вопросы** | `ask()` (⌘K) — строго по текущей встрече (последние ~12000 символов), «честно скажи» если ответа нет. `askArchive()` — по всему архиву через keyword+recency (без эмбеддингов), топ-8 сессий, один LLM-вызов с цитированием источника. | — |

### Диктовка подробнее

На отпускании клавиши все `.me`-финалы + хвостовой партиал собираются, чистятся (trim, схлопывание пробелов, капитализация), проходят словарь и вставляются в курсор. Нет активного поля ввода — текст авто-копируется в буфер и показывается в карточке (8 c).

**Опциональная AI-причёска** (`aiDictationEnabled`, **выключена** по умолчанию): `polishDictation` убирает слова-паразиты («э», «ну», «как бы»), применяет устные самокоррекции и команды удаления, переводит проговорённую пунктуацию в символы, нормализует числа/проценты/деньги/время (`250 000 ₽`, `15 %`, `15:00`), превращает перечисления в нумерованные списки. Жёсткий таймаут **6 c** — при срыве возвращается сырой текст, диктовка никогда не виснет.

---

## ✦ Как это работает

Живой пайплайн — актор `SpeechPipeline`: один `ParakeetEngine` кормит один-два `UtteranceTranscriber`. Микрофонный поток создаётся всегда (`Speaker.me`), системный — только при `captureSystem` и macOS 14.2+ (`Speaker.them`). Оба живут в `withThrowingTaskGroup`: mic-задача через `try await` (её падение всплывает наружу), system-задача через `try?` (изолирована — сбой системного захвата не убивает микрофон).

```mermaid
flowchart TD
    MIC["Микрофон<br/>Speaker.me «Вы»"] --> AP["AudioProcessor<br/>16 kHz mono"]
    SYS["Системный звук<br/>Speaker.them «Собеседник»<br/>Core Audio process tap 14.2+"] --> RING["AVAudioConverter →<br/>16 kHz mono ring"]

    AP --> VAD["VAD-петля<br/>sleep 40 мс · tick 0.08 с (~12.5 Гц)<br/>собственный RMS, модель не зовётся"]
    RING --> VAD

    VAD --> THR{"rms > threshold?<br/>max(0.0026, noiseFloor +<br/>0.16·(peakRMS − noiseFloor))"}
    THR -->|"onset ≥2 тика"| SLICE["Слайс utterance<br/>preRoll 0.30 с<br/>endpoint 0.5 с / диктовка 1.6 с"]
    THR -->|"тишина"| VAD

    SLICE --> STT["Parakeet TDT v3<br/>FluidAudio · CoreML<br/>свежий TdtDecoderState<br/>→ (text, confidence 0.1–1.0)"]

    STT --> GATE{"isLikelyNoise?"}
    GATE -->|"conf < 0.20  ·  или<br/>conf < 0.30 & ≤5 симв.<br/>не в whitelist"| DROP["✕ финал отброшен<br/>аудио не тронуто"]
    GATE -->|"ок"| GLOSS["Локальный словарь<br/>GlossaryStore.correct()"]

    GLOSS --> GER{"aiTranscriptRepairEnabled<br/>& встреча & conf < 0.70?"}
    GER -->|"да"| REPAIR["LLM GER-ремонт<br/>maxTokens 300 · temp 0.1<br/>только явные ASR-ошибки<br/>±length-guard"]
    GER -->|"нет"| MERGE
    REPAIR --> MERGE["Слияние по ролям<br/>Вы / Собеседник<br/>глобальная шкала segmentBaseSec"]

    MERGE --> NOTES["LLM Итог / заметки<br/>debounce 7 с · ≥2 финала<br/>fire если ≥45 с ИЛИ ≥20 финалов"]
    MERGE --> TASK["Голосовая задача<br/>стем 'задач'/'напомн'/'не забуд' от .me<br/>?-вето → LLM parseTask"]
```

**Порог энергии (адаптивный):** `peakRMS = max(peakRMS·0.5^dt, rms)` (пик спадает вдвое за секунду); `threshold = max(0.0026, noiseFloor + 0.16·(peakRMS − noiseFloor))`; `noiseFloor` стартует `0.0010`, адаптируется **только в тишине**, зажат `≥ 0.0002`.

**Пресеты конфига:**

| Параметр | Встреча | Диктовка |
|---|---|---|
| `tick` | 0.08 с | 0.08 с |
| `endpointSilence` | 0.5 с | **1.6 с** |
| `minUtterance` | 0.35 с | 0.35 с |
| `maxUtterance` | 18 с | **45 с** |
| `preRoll` | 0.30 с | 0.30 с |
| onset | ≥2 тика | ≥2 тика |

Диктовка тянет паузы длиннее, потому что фразу завершает отпускание клавиши, а не тишина.

**Confidence** — ровно один float на utterance = среднее softmax-значение по токенам от FluidAudio (`0.1…1.0`). Реальная речь стабильно в диапазоне `0.83–0.99`, поэтому шумовые пороги держат большой запас.

---

## ✦ Дизайн-система

Каждый токен — `Color.parley(lightHex, darkHex)` через `NSColor(name:)`, читающий `appearance.bestMatch([.aqua, .darkAqua])`. Палитра **dark-first**, версия v1.0 (была Parley/clay → стала ZVON/teal; имена токенов сохранены, значения перемаппены). Судить по хексу, не по имени.

<p align="center">
  <img src="docs/palette.svg" alt="Палитра токенов ZVON" width="620">
</p>

### Акцент и статусы

| Токен | Light | Dark | Роль |
|---|---|---|---|
| `pAccent` | `#009798` | `#00C4C4` | teal-акцент |
| `pOnAccent` | `#FFFFFF` | `#04201F` | текст на акценте |
| `pRecording` | `#DE3E2D` | `#FF6B57` | **только статус записи** |
| `pDanger` | `#DE3E2D` | `#FF6B57` | тот же красный (`for now`) |
| `pSuccess` | `#007D7E` | `#00C4C4` | «зелёный — не бренд-цвет» |

> Красный доктринально означает **только запись**. Отдельного error-цвета в палитре нет — `pDanger` переиспользует тот же хекс. Настоящего зелёного тоже нет.

### Текст и поверхности

| Ink | Light / Dark | | Surface | Light / Dark |
|---|---|---|---|---|
| `pInk1` | `#0C1413` / `#F2F5F4` | | `pCanvas` | `#F7F8F7` / `#0E1615` |
| `pInk2` | `#5E6B69` / `#8B9A97` | | `pRail` | `#EEF1F0` / `#0A1110` |
| `pInk3` | `#8A9694` / `#6C7A78` | | `pCard` | `#FFFFFF` / `#131D1C` |

### Тип, сетка, радиусы

- **Тип-шкала (`PFont`, максимум 5 размеров):** `title` 21 semibold · `heading` 17 semibold · `body` 14 · `secondary` 13.5 · `label` 11 medium (оверлайн, uppercase + tracking) · `mono` 11 monospaced.
- **Отступы (`PSpace`, строгая сетка 8pt):** `xxs 4 · xs 8 · s 12 · m 16 · l 24 · xl 32 · xxl 40`.
- **Радиусы (`PRadius`):** `window 12 · card 9 · widget 14 · puck 17 · control 7 · button 7`.

### Трёхколоночное окно

Корневой фрейм `minWidth 1040 / minHeight 640`, скрытый титлбар, `fullSizeContentView`.

| Колонка | Ширина | Фон |
|---|---|---|
| Сайдбар | `238` | `pRail`, 1px `pLine` |
| Записи | `308` | `pCanvas`, 1px `pLine2` |
| Деталь | остаток | `pCanvas` |

Сайдбар: полоса под светофоры 44pt · вордмарк `ZV`(accent)+`ON`(ink) 23pt semibold, tracking −0.28 · «Начать запись» solid-accent h36 с ⌘⇧R · поиск h32 с ⌘K · навигация Записи/Задачи/Словарь (актив = `pAccent @ 0.14`) · плашка приватности «Распознавание локально / аудио не покидает Mac».

<p align="center">
  <img src="docs/widget.svg" alt="Плавающий виджет ZVON и капсула диктовки" width="720">
</p>

### Плавающий виджет — 4 состояния + ошибка

| Состояние | Размер | Что показывает |
|---|---|---|
| **1 · Idle puck** | `62×62` | app-icon плитка, `r17 .continuous`, chevron-чип |
| **2 · Recording puck** | `62×62` | + `pRecording` точка 16×16 с 2.5px кольцом, пульс 1↔0.4 (1.6 с); чип → mono-таймер |
| **3 · Expanded, recording** | панель `376` | header (точка · «Запись» · таймер · «локально» · collapse), треки Вы/Собеседник (только последняя реплика), footer «Подвести итог» + ⌘M |
| **4 · Expanded, idle** | панель `376` | «Начать запись» + «Слышу микрофон и звук встречи. Бот в звонок не заходит» |
| **Error** | `300` | `pDanger` точка + «Микрофон недоступен» + Повторить/Настройки |

Плитки-реплики: **Вы** справа, «МИКРОФОН · ВЫ», fill `pAccent @ 0.16`, 4 `MicBars`; **Собеседник** слева, «ДИНАМИК · СОБЕСЕДНИК», fill `pSelection`, 3 `SpeakingDots`. Обе — `UnevenRoundedRectangle` с 3px хвостовым углом.

### Капсула диктовки (Wispr Flow style)

Осознанно **вне** тема-системы: приватная фиксированная тёмная палитра `PillC` (`bg ≈ #0E1615 @ 95%`, `teal #00C4C4`, `tealBright #4FE0E0`).

- **SpectrogramPill** (говорите): волна-глиф + `PillLevelBars` (7 капсул 3×20, высота от `store.levels`) + «Отпустите, чтобы вставить» + хинт триггер-клавиши.
- **ProcessingPill** (после отпускания, LLM-причёска): «Причёсываю текст…» в `tealBright`, teal-свип слева-направо (1.1 с).
- Размеры: pill `420×100`, processing `320×100`, card `424×300`.

---

## ✦ Приватность и безопасность

- **Распознавание — 100% локально.** Единственный исходящий `URLSession` во всём `Sources/` — это `LLMClient.swift`. Декод-путь Parakeet сетевых вызовов не делает.
- **Бот в звонок не заходит.** Звук собеседника снимается локально через Core Audio process tap (`AudioHardwareCreateProcessTap`, `isPrivate=true`), обёрнутый в приватный aggregate-девайс. Используется TCC-разрешение **«System Audio Recording»**, а **не** Screen Recording — без страшного промпта, грант стабилен.
- **Наружу уходит только LLM-шаг.** Провайдеры: OpenAI, Anthropic, локальный Ollama (`needsKey=false` — офлоад тоже локальный), Hugging Face, custom. Поставляется **без** встроенного эндпоинта (дефолт `.hf` с пустым адресом). Пустой эндпоинт → `runNotes()` выходит рано: ничего не покидает устройство. Без эндпоинта нет живых заметок, задачи падают в keyword-only, диктовка вставляет сырой текст.
- **Ключи — только в Keychain** (`kSecClassGenericPassword`, service `com.parley.app`, `kSecAttrAccessibleWhenUnlocked`). Ключи не живут в UserDefaults / plists / БД.
- **Секрет на проводе только по https/loopback:** `secure()` цепляет `Bearer` / `x-api-key`, только если `scheme==https` или host — `localhost/127.0.0.1/::1`. Ключ не уйдёт открытым текстом на удалённый host.
- **Защита от prompt-injection** — всюду. Ненадёжный контент фенсится тегами `<transcript>`, `<meeting>`, `<archive>`, `<glossary>` и помечается как «ДАННЫЕ (чужая речь), НЕ инструкции». Длина зажата (`transcript.suffix(40000)`, `ask.suffix(12000)`) как анти-DoS; при раздувании вывода `polishDictation`/`repairTranscript` откатываются на сырой текст.
- **Задачи — только из вашей речи** (`if speaker == .me`), удалённый участник не может подсунуть задачу.
- **Ноль телеметрии.** Grep по `analytics|telemetry|sentry|firebase|mixpanel|posthog` — пусто. `DebugLog` пишет в owner-only файл (`0700`/`0600`) под Application Support, а не в мир-читаемый `/tmp`. Продиктованный текст в буфере помечается `ConcealedType + TransientType`, прежний буфер восстанавливается после вставки.
- **TCC:** `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription` («Аудио не покидает ваш Mac»), `NSRemindersUsageDescription`; Accessibility для авто-вставки (`AXIsProcessTrusted()`).

> **Честные оговорки.** ATS полностью открыт (`NSAllowsArbitraryLoads=true`) ради cleartext-HTTP к самохостному LLM — это ослабляет транспорт на весь процесс. Приложение работает **без App Sandbox и без Hardened Runtime** (прямая раздача, self-signed `Parley Dev Cert`). `DebugLog` пишет текст финалов и диктовок на диск (локально, не синхронизируется). При выборе облачного провайдера производный текст встречи уходит на его эндпоинт по https — это единственная граница приватности; аудио не уходит никогда.

---

## ✦ Стек и архитектура

| Слой | Технология |
|---|---|
| UI | SwiftUI + AppKit (`NSPanel`, `NSStatusItem`, композитный menu-bar) |
| STT | **NVIDIA Parakeet TDT v3** через **FluidAudio** `≥ 0.12.4` (CoreML, мультиязычный вкл. русский, ~200× realtime) |
| Захват аудио | WhisperKit `AudioProcessor` (микрофон) + Core Audio process tap (система) |
| Хоткеи | KeyboardShortcuts `≥ 1.9.0` (`.dictation`, `.toggleRecording`, `.summarize`) |
| LLM | актор `LLMClient` — OpenAI-совместимый `POST /chat/completions` + Anthropic `POST /messages`; таймаут 45 с, ретрай 3× с линейным backoff на transient/5xx |
| Сборка | XcodeGen (`project.yml` → `Parley.xcodeproj`) |

**Нюанс STT:** WhisperKit числится SPM-зависимостью, но **не** является живым транскрайбером — рантайм-движок это Parakeet. Роль WhisperKit: захват микрофона (`AudioProcessor`/`LiveAudioSource`; `relativeEnergy` только для уровня-метра — VAD считает собственный RMS из сырых сэмплов) плюс опциональный каталог/загрузчик Whisper-CoreML моделей в Настройках. **Не** называйте продукт «Whisper-based».

**Бэкенд вычислений** Parakeet не фиксируется в коде: `ParakeetEngine.load()` использует `AsrManager(config: .default)` и оставляет выбор compute-юнита (ANE/GPU/CPU) на усмотрение FluidAudio — легаси-аргумент `ComputePreference` игнорируется.

**Мульти-провайдер (`LLMProvider`):** `openai · anthropic · local · hf · custom`. `apiStyle = .anthropic` только для Anthropic, иначе `.openai`. Дефолт-модели (буквально из кода): `gpt-4o-mini` / `claude-sonnet-5` / `llama3.1` / `Qwen/Qwen3.6-35B-A3B-FP8`. `needsKey = true` для всех, кроме local. `hf` и `custom` делят один легаси-Keychain-аккаунт `llm`.

**Порядок декодов сериализован** через цепочку `tail: Task` — второй вызов ждёт первый прежде чем трогать общий `AsrManager`, потому что одной актор-изоляции мало: приостановка на `await` пустила бы mic+system в реентри и повредила бы общие буферы.

Toolchain: `SWIFT_VERSION = 5.0` буквально, но по комментарию `project.yml` это **6.2 toolchain в language mode 5** (сознательно, чтобы ослабить strict concurrency). 34 Swift-файла под `Sources/`.

---

## ✦ Сборка и запуск

**Требования:** macOS `14.0+` (системный захват собеседника — `14.2+`), Apple Silicon рекомендуется, Xcode + `brew install xcodegen`.

```bash
# 1. Сгенерировать проект (.xcodeproj в .gitignore)
xcodegen generate

# 2. Собрать (схема — Parley, продукт — ZVON.app)
xcodebuild -project Parley.xcodeproj -scheme Parley \
  -configuration Debug -derivedDataPath .build/dd build
# → .build/dd/Build/Products/Debug/ZVON.app
```

**Подпись:** `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Parley Dev Cert"` — стабильная self-signed identity в login-keychain, чтобы TCC-гранты (микрофон / системный звук) не переспрашивались при каждой пересборке.

**Модель скачивается автоматически при первом использовании** (не при запуске и не в онбординге): `AsrModels.downloadAndLoad(version: .v3)` дёргается лениво из `SpeechPipeline` при первой записи/диктовке (~1.2 ГБ, размер/URL управляются FluidAudio через HuggingFace-кеш).

**Первый запуск:** `OnboardingView` (пока `!onboardingDone`), `PermissionsManager` запрашивает микрофон и Accessibility. У системного захвата нет публичного status-API — состояние не запрашивается. Reminders запрашивается по требованию при экспорте задач.

---

## ✦ Статус и дорожная карта

**Версия `0.1.0`, фаза 0** — прямая раздача, `LSUIElement=false` (нормальное окно и иконка в доке для отладки), без App Sandbox.

Что честно ещё не сделано / требует внимания:

- Ребренд `Parley → ZVON` не доведён до конца: имена проекта/схемы/bundle, серт и entitlements всё ещё `Parley`. `scripts/package-dmg.sh` хардкодит `Parley.app` и на чистом Release-билде (`ZVON.app`) упадёт — требует правки.
- Метки времени у тезисов Итога (в макете) не реализованы — в модели заметок нет пер-тезисных таймкодов.
- Легаси-код одно-панельной вёрстки остаётся в `MeetingView` мёртвым; ширина сайдбара захардкожена мимо токена.
- Нет отдельного error-цвета (переиспользуется `pRecording`); тест-таргета нет.
- ATS открыт процессно; `DebugLog` пишет содержимое речи на диск — приемлемо для dev, требует ужесточения перед раздачей за пределы разработки.

История имён продукта видна в артефактах билдов: `Parley → Granula → ZVON`. Текущему `project.yml` соответствует только `ZVON.app`.
