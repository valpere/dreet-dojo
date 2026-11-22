# DreetDojo — High-Level Design

Детальний дизайн MVP 1.0. Документ спирається на [use-cases.md](use-cases.md), [requirements.md](requirements.md) і [architecture.md](architecture.md).

Контракти нижче є цільовими сигнатурами. Пакети `runner`, `srs` і `sandbox` реалізуються вручну (див. `CLAUDE.md`), тому зміни їхніх контрактів спершу узгоджуються в цьому документі.

## 1. Структура репозиторію

```text
dreet-dojo/
├── cmd/dreet/            # CLI: serve, validate; DI; graceful shutdown
├── internal/
│   ├── api/              # HTTP-хендлери, DTO, мапінг помилок
│   ├── deck/             # завантаження і валідація карток
│   ├── session/          # оркестратор активної спроби
│   ├── runner/           # Runner, Registry, GoRunner
│   ├── sandbox/          # /work/<session_id>, запис коду, unified diff
│   ├── srs/              # schema.sql, Store, scheduler.go
│   ├── mock/             # фейки runner/srs/sandbox для --mock
│   └── web/              # //go:embed dist/* + SPA fallback
├── web/                  # Vite + TypeScript + CodeMirror 6
├── decks/go-drills-01/   # стартова колода
├── docs/
├── Dockerfile
└── docker-compose.yml
```

## 2. Формат колод

### 2.1 Файлова структура

```text
decks/
└── go-drills-01/                 # deck_id = ім'я директорії
    └── go-06-snake-step/         # директорія картки (ім'я довільне, id береться з meta.yaml)
        ├── meta.yaml
        ├── prompt.md             # умова, 3–8 рядків Markdown
        ├── go.mod                # module kata; go 1.26
        ├── kata.go               # стаб із TODO (EntryFile)
        ├── kata_test.go          # тести, включно з edge cases
        └── solution.go           # еталон
```

### 2.2 `meta.yaml`

```yaml
id: go-06                 # обов'язкове, унікальне в межах усіх колод
lang: go                  # обов'язкове; ключ у runner.Registry
title: "Змійка (2/3): один крок і зіткнення"
format: progressive       # cloze | spec | progressive | bugfix | skeleton
prereq: go-05             # опціонально; id іншої картки
order: 6                  # порядок видачі нових карток у колоді
target_sec: 600           # > 0
tags: [state, maps, queue]
entry_file: kata.go       # опціонально, за замовчуванням kata.go; лише ім'я файлу
hints:                    # 0..N, видаються по черзі
  - "Голова рухається першою; хвіст звільняється до перевірки зіткнення"
  - "Зберігайте зайняті клітинки в map[Point]struct{}"
```

### 2.3 Правила валідації (`deck.Validate`, `dreet validate`)

**Структурні.** Їх виконує `LoadAll` під час кожного завантаження.
1. Усі шість файлів на місці.
2. `id`, `lang`, `title`, `format` і `target_sec` задані. `format` належить до переліку, а `target_sec > 0`.
3. `id` унікальні в межах усіх колод.
4. `entry_file` — це ім'я файлу без розділювачів шляху, без `..` і не `*_test.go`.
5. `prereq` посилається на наявну картку, а граф `prereq` не має циклів.
6. `lang` зареєстровано в `runner.Registry`. Цю перевірку робить `cmd/dreet`, бо `deck` не залежить від `runner`.

**Поведінкові.** Тільки `dreet validate`. Кожна перевірка йде в окремій тимчасовій директорії поза `/work`.
1. Стаб, тобто `kata.go` разом із тестами, не проходить. Статус має бути `test_fail` або `compile_error`.
2. Еталон, тобто `solution.go`, скопійований як `entry_file`, разом із тестами дає статус `pass`. Гонок і попереджень при цьому немає.

Невалідна картка в режимі `serve` журналюється і виключається з видачі. Сервер через неї не падає.

## 3. Контракти модулів

### 3.1 `internal/deck`

```go
type Format string

const (
	FormatCloze       Format = "cloze"
	FormatSpec        Format = "spec"
	FormatProgressive Format = "progressive"
	FormatBugfix      Format = "bugfix"
	FormatSkeleton    Format = "skeleton"
)

type Card struct {
	ID        string
	DeckID    string
	Lang      string
	Title     string
	Format    Format
	PrereqID  string // "" якщо немає
	SortOrder int
	Tags      []string
	TargetSec int
	Hints     []string
	DirPath   string // шлях у /app/decks (read-only)
	EntryFile string // за замовчуванням "kata.go"
	PromptMD  string
	StubCode  string
	Solution  string // тримається лише в пам'яті; ніколи не пишеться в /work
}

type Loader interface {
	// LoadAll перечитує каталог і атомарно замінює індекс у пам'яті.
	// Повертає валідні картки; помилки окремих карток — через errors.Join.
	LoadAll(rootDir string) ([]Card, error)
	Get(cardID string) (Card, bool)
}
```

Реалізація безпечна для конкурентного виклику.

### 3.2 `internal/sandbox`

```go
type Workspace struct {
	SessionID string // 128 біт з crypto/rand, hex
	CardID    string
	Dir       string // /work/<session_id>
	EntryFile string // kata.go
}

type Manager interface {
	// Prepare копіює go.mod, EntryFile і *_test.go (без solution.go) у /work/<session_id>.
	// Тестові файли отримують права 0444.
	Prepare(card deck.Card) (Workspace, error)
	// WriteCode атомарно (temp-файл у тій самій директорії + rename) перезаписує лише EntryFile.
	WriteCode(ws Workspace, code string) error
	ReadCode(ws Workspace) (string, error)
	// Diff — чиста функція: unified diff між кодом користувача та еталоном.
	Diff(userCode, solutionCode string) string
	// Cleanup ідемпотентно видаляє директорію сесії.
	Cleanup(ws Workspace) error
}
```

Інваріанти:
- `solution.go` ніколи не копіюється в `Dir` (ADR-8).
- Шлях запису обчислюється як `filepath.Join(ws.Dir, ws.EntryFile)`. Перед записом перевіряється, що результат лежить усередині `ws.Dir`.
- Під час старту `serve` вміст `/work` очищається від залишків попередніх запусків.

### 3.3 `internal/runner`

```go
type Status string

const (
	StatusPass         Status = "pass"
	StatusCompileError Status = "compile_error"
	StatusTestFail     Status = "test_fail"
	StatusTimeout      Status = "timeout"
)

type Diagnostic struct {
	File     string // відносно workDir, напр. "kata.go"
	Line     int    // 1-based
	Col      int    // 1-based; 0 якщо невідомо
	Severity string // "error" | "warning"
	Message  string
}

type Result struct {
	Status      Status
	Duration    time.Duration // у DTO віддається як duration_ms (int64)
	Diagnostics []Diagnostic
	RawOutput   string // обрізається до 64 КБ
}

type Runner interface {
	Lang() string
	// Check повертає error лише для інфраструктурних збоїв (немає тулчейна, не вдалося стартувати).
	// Помилки коду користувача — це Result зі статусом, а не error.
	Check(ctx context.Context, workDir string) (Result, error)
}

type Registry interface {
	Get(lang string) (Runner, bool)
	Langs() []string
}
```

**GoRunner**
- Запускає `go test -race -json -count=1 -timeout=5s ./...` у `workDir`.
- Процес отримує окрему групу (`SysProcAttr{Setpgid: true}`). Загальний `context.WithTimeout` трохи довший за `-timeout`: він покриває ще й компіляцію. Коли контекст скасовано, викликається `syscall.Kill(-pgid, SIGKILL)` і процес чекається через `Wait`.
- Оточення: `CGO_ENABLED=1`, `GOPROXY=off`, `GOTOOLCHAIN=local`, `GOCACHE=/var/cache/go-build`, `GOTMPDIR=/tmp`.

Статус визначається з потоку подій `go test -json` за пріоритетом:

| Пріоритет | Умова | Статус |
| :---- | :---- | :---- |
| 1 | Контекст перевищив дедлайн, або у виводі є `panic: test timed out` | `timeout` |
| 2 | `Action == "build-fail"` або `build-output` з помилками компіляції | `compile_error`; рядки виду `./kata.go:18:12: msg` стають діагностиками |
| 3 | У виводі є `WARNING: DATA RACE` | `test_fail`; діагностика рівня `error` з посиланнями на рядки з трасування |
| 4 | `Action == "fail"` | `test_fail`; діагностики беруться з рядків `kata_test.go:N:` / `kata.go:N:` у виводі `t.Error`/`t.Fatal` |
| 5 | `Action == "pass"` на рівні пакета | `pass` |

### 3.4 `internal/srs`

**Схема (`internal/srs/schema.sql`).** Мітки часу зберігаються як Unix-секунди (`INTEGER`).

```sql
CREATE TABLE IF NOT EXISTS card_state (
    card_id          TEXT PRIMARY KEY,
    deck_id          TEXT    NOT NULL,
    prereq_card_id   TEXT,
    sort_order       INTEGER NOT NULL DEFAULT 0,
    tags_json        TEXT    NOT NULL DEFAULT '[]',
    reps             INTEGER NOT NULL DEFAULT 0,   -- серія успішних повторень підряд
    lapses           INTEGER NOT NULL DEFAULT 0,
    interval_days    REAL    NOT NULL DEFAULT 0.0,
    ease_factor      REAL    NOT NULL DEFAULT 2.5,
    due_at           INTEGER NOT NULL DEFAULT 0,   -- 0 = нова картка
    last_reviewed_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_card_state_due ON card_state (due_at, sort_order);

CREATE TABLE IF NOT EXISTS attempts (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    card_id        TEXT    NOT NULL,
    started_at     INTEGER NOT NULL,
    finished_at    INTEGER NOT NULL,
    elapsed_sec    INTEGER NOT NULL,
    target_sec     INTEGER NOT NULL,
    compile_errors INTEGER NOT NULL DEFAULT 0,
    test_fails     INTEGER NOT NULL DEFAULT 0,
    hints_used     INTEGER NOT NULL DEFAULT 0,
    status         TEXT    NOT NULL CHECK (status IN ('pass', 'giveup')),
    grade          INTEGER NOT NULL CHECK (grade BETWEEN 1 AND 4),
    FOREIGN KEY (card_id) REFERENCES card_state(card_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_attempts_card_time ON attempts (card_id, finished_at DESC);
```

Під час відкриття з'єднання виконуються `PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;`.

**Синхронізація.** `SyncCards` робить `INSERT … ON CONFLICT(card_id) DO UPDATE` і оновлює лише метадані: `deck_id`, `prereq_card_id`, `sort_order`, `tags_json`. SRS-поля не змінюються. Картки, зниклі з диска, лишаються в БД, щоб зберегти історію, але у видачу не потрапляють: `NextDue` фільтрує за переданим набором `card_id`.

**Контракт:**

```go
var ErrNoCardsDue = errors.New("no cards due for review")

type Grade int

const (
	GradeAgain Grade = 1
	GradeHard  Grade = 2
	GradeGood  Grade = 3
	GradeEasy  Grade = 4
)

type DeckCardMeta struct {
	CardID    string
	DeckID    string
	PrereqID  string
	SortOrder int
	Tags      []string
}

type AttemptInput struct {
	CardID        string
	StartedAt     time.Time
	FinishedAt    time.Time
	TargetSec     int
	CompileErrors int
	TestFails     int
	HintsUsed     int
	Passed        bool // false == giveup
}

type CardState struct {
	CardID       string
	DeckID       string
	Reps         int
	Lapses       int
	IntervalDays float64
	EaseFactor   float64
	DueAt        time.Time // zero == нова
}

type NextOptions struct {
	Ahead     bool // Practice Ahead
	NewPerDay int  // ліміт нових карток на добу
}

type Stats struct {
	DueToday         int
	ReviewedToday    int
	CleanCompileRate float64 // частка спроб із compile_errors == 0 за 30 днів
	WeakTags         []TagStat
}

type TagStat struct {
	Tag      string
	AvgGrade float64
	Attempts int
}

type Store interface {
	SyncCards(ctx context.Context, cards []DeckCardMeta) error
	NextDue(ctx context.Context, now time.Time, opts NextOptions) (CardState, error)
	RecordAttempt(ctx context.Context, in AttemptInput) (CardState, Grade, error)
	Stats(ctx context.Context, now time.Time) (Stats, error)
	Close() error
}

// scheduler.go — чисті функції без БД.
func EvaluateGrade(in AttemptInput) Grade
func ScheduleSM2(st CardState, g Grade, now time.Time, rnd func() float64) CardState
```

`RecordAttempt` виконується в одній транзакції: `EvaluateGrade`, потім `ScheduleSM2`, потім `INSERT attempts` і `UPDATE card_state`. `rnd` ін'єктується, щоб jitter був детермінованим у тестах.

**Оцінка (`EvaluateGrade`).** Правила перевіряються згори вниз, спрацьовує перше.

| Оцінка | Умова | Зміст |
| :---- | :---- | :---- |
| 1 Again | `!Passed` **або** `hints_used >= 2` **або** `compile_errors >= 5` | Навичка не відтворилася |
| 2 Hard | `hints_used == 1` **або** `elapsed > 1.5 × target` **або** `compile_errors >= 3` **або** `test_fails >= 4` | Згадав, але з тертям |
| 4 Easy | `compile_errors == 0` **і** `test_fails <= 1` **і** `elapsed <= 0.8 × target` | Чисто й швидше за норматив |
| 3 Good | Усе інше при `Passed` | Робоча норма |

**Планування (`ScheduleSM2`).** Умови `reps == …` перевіряються до оновлення `reps`.

| Оцінка | reps / lapses | Новий інтервал (дні) | Новий EF |
| :---- | :---- | :---- | :---- |
| 1 Again | `reps = 0`, `lapses += 1` | 1.0 | `max(1.3, EF − 0.20)` |
| 2 Hard | `reps += 1` | `reps == 0` ⇒ 1.0; інакше `max(1.0, I × 1.2)` | `max(1.3, EF − 0.15)` |
| 3 Good | `reps += 1` | `reps == 0` ⇒ 1.0; `reps == 1` ⇒ 3.0; інакше `I × EF` | `EF` |
| 4 Easy | `reps += 1` | `reps == 0` ⇒ 4.0; `reps == 1` ⇒ 6.0; інакше `I × EF × 1.3` | `min(3.0, EF + 0.15)` |

Після таблиці застосовуються ще три правила:
- `I = min(60.0, I)`.
- Якщо `I >= 4.0`, то `I ×= 0.95 + 0.1 × rnd()`.
- `due_at = now + I × 86400`, а `last_reviewed_at = now`.

**Черга (`NextDue`).**
1. Прострочені: `due_at > 0 AND due_at <= now`, порядок `ORDER BY due_at ASC, ease_factor ASC`.
2. Нові: `reps = 0 AND lapses = 0 AND due_at = 0`, причому `prereq_card_id IS NULL` або батьківська картка має `reps >= 1`. Порядок `ORDER BY deck_id, sort_order`. Видаються, лише поки кількість карток, чия перша спроба завершилася сьогодні, менша за `NewPerDay`.
3. Якщо нічого не знайдено, повертається `ErrNoCardsDue`. З `Ahead` замість цього видається картка з мінімальним `due_at > now`.

«Сьогодні» рахується за локальною добою контейнера (`TZ`, за замовчуванням UTC).

**Статистика (`Stats`).** Вікно — 30 днів.
- `DueToday`: прострочені на кінець доби плюс доступні нові в межах залишку ліміту.
- `ReviewedToday`: спроби, завершені сьогодні.
- `CleanCompileRate`: частка спроб з `compile_errors == 0`.
- `WeakTags`: 5 тегів з найнижчим `AvgGrade`.

### 3.5 `internal/session`

```go
type Attempt struct {
	Card             deck.Card
	WS               sandbox.Workspace
	StartedAt        time.Time
	CompileErrors    int
	TestFails        int
	HintsUsed        int
	Finished         bool   // pass або giveup
	FinalStatus      string // "pass" | "giveup"
	UnlockedSolution bool
}

type Service interface {
	Current(ctx context.Context) (CardView, error)          // ErrNoActiveAttempt
	Next(ctx context.Context, ahead bool) (CardView, error) // srs.ErrNoCardsDue
	Run(ctx context.Context, cardID, code string) (RunOutcome, error)
	Hint(ctx context.Context, cardID string) (HintView, error)
	GiveUp(ctx context.Context, cardID string) (GiveUpOutcome, error)
	Diff(ctx context.Context, cardID string) (DiffView, error)
	Stats(ctx context.Context) (srs.Stats, error)
}

var (
	ErrNoActiveAttempt = errors.New("no active attempt for this card") // 409
	ErrSolutionLocked  = errors.New("solution locked until attempt is finished") // 403
	ErrHintsExhausted  = errors.New("no more hints") // 404
	ErrCardNotFound    = errors.New("card not found") // 404
)
```

Правила:
- Одночасно існує одна спроба (`*Attempt` під `sync.Mutex`). `Run` серіалізується, тож паралельних прогонів на одній пісочниці не буває.
- Час береться з ін'єктованого `clock func() time.Time`.
- `Run`, `Hint` і `GiveUp` на завершеній спробі або з чужим `cardID` повертають `ErrNoActiveAttempt`.
- `timeout` збільшує `TestFails`.
- `Diff` працює з поточною або щойно завершеною спробою.

### 3.6 `internal/api` і `internal/web`

- Маршрутизація стандартним `http.ServeMux` з шаблонами `METHOD /path`.
- Тіло запиту обмежено `http.MaxBytesReader` до 256 КБ. Перевищення дає 400 `bad_request`.
- `internal/web`: шлях поза `/api/` віддає файл з `embed.FS`. Якщо файлу немає, віддається `index.html` (SPA fallback). Для `assets/*` з хешем у назві ставиться `Cache-Control: immutable`.

### 3.7 `web/` — стерильний редактор

- **Розкладка одного вікна:**
  - ліворуч умова (`prompt.md`), таймер і підказки;
  - по центру редактор;
  - знизу вивід тестів і діагностики;
  - `Alt+D` замінює редактор на `MergeView` (`@codemirror/merge`).
- **Набір розширень CodeMirror** — лише явний список:
  - дозволено: `lineNumbers`, `history`, `drawSelection`, `indentOnInput`, `bracketMatching`, `syntaxHighlighting`, `go()`, `lintGutter` з діагностиками від бекенду, власний `keymap`;
  - **не використовуються:** `basicSetup` (він тягне `autocompletion` і `closeBrackets`), `autocompletion`, `closeBrackets`, сніпети, будь-які LSP-клієнти.
- Для `contenteditable` вимикаються `spellcheck`, `autocorrect` і `autocapitalize`.
- Хоткеї `Ctrl+S`, `Alt+H`, `Alt+D` і `Alt+N` перехоплюються з `preventDefault`.
- Таймер рахується від `started_at`, який повертає сервер.
- На старті UI викликає `GET /api/session/current`. Якщо відповідь 204, далі викликає `GET /api/session/next`.

## 4. Основні потоки

### 4.1 Старт картки — `GET /api/session/next`
1. `deck.LoadAll`, потім `srs.SyncCards`. Синхронізація запускається на старті `serve` і в кожному `Next`.
2. `srs.NextDue(now, {Ahead, NewPerDay})` повертає `card_id`, далі `deck.Get(card_id)`.
3. Якщо є попередня спроба, виконується `sandbox.Cleanup(prev.WS)`. Ця спроба не записується.
4. `sandbox.Prepare(card)` створює `/work/<session_id>`.
5. Ініціалізується `Attempt{StartedAt: now}`.
6. Відповідь: `{id, lang, title, format, prompt_md, code, target_sec, hints_total, started_at, srs_meta}`.

### 4.2 Перевірка — `POST /api/attempt/run`

```text
Web UI (Ctrl+S) ── POST {card_id, code} ──▶ api ──▶ session.Run
  1. перевірити активну незавершену спробу з цим card_id (інакше 409)
  2. sandbox.WriteCode(ws, code)
  3. runner.Get(card.Lang).Check(ctx, ws.Dir)
  4. status != pass → compile_errors++ | test_fails++ → Result
  5. status == pass → elapsed = now − started_at
                      (state, grade) = srs.RecordAttempt(...)   [одна TX]
                      Finished = true, UnlockedSolution = true
                      → Result + grade + srs_next_days
```

### 4.3 Підказка — `POST /api/attempt/hint`
Якщо `HintsUsed < len(card.Hints)`, повертається `card.Hints[HintsUsed]`, а `HintsUsed` збільшується. Інакше `ErrHintsExhausted`.

### 4.4 Здача — `POST /api/attempt/giveup`
`srs.RecordAttempt(Passed: false)` дає оцінку 1. Потім `Finished = true`, `UnlockedSolution = true`.

### 4.5 Рев'ю еталона — `GET /api/attempt/diff`
1. Якщо `UnlockedSolution` не встановлено, повертається `ErrSolutionLocked` (403).
2. `sandbox.ReadCode(ws)`, далі `card.Solution` з пам'яті `deck`, далі `sandbox.Diff`.
3. Відповідь: `{user_code, solution_code, unified_diff}`.

### 4.6 Валідація — `dreet validate --decks <dir>`
`deck.LoadAll` виконує структурні правила. Потім для кожної картки створюються дві тимчасові директорії, `stub` і `solution`, і для кожної викликається `Runner.Check`. Звіт друкується в stdout. Код виходу: 0, якщо все валідне, 1, якщо є невалідні картки, 2, якщо помилка інфраструктури.

## 5. HTTP API

Усі відповіді мають тип `application/json; charset=utf-8`. Формат помилки: `{"error": {"code": "<code>", "message": "<text>"}}`.

| Ендпоінт | Запит | 200 OK | Інші коди |
| :---- | :---- | :---- | :---- |
| `GET /api/health` | — | `{"status":"ok","langs":["go"]}` | — |
| `GET /api/session/current` | — | як `session/next`, де `code` — поточний код із пісочниці, плюс `finished: bool` | 204, якщо немає спроби |
| `GET /api/session/next` | `?ahead=true` (опц.) | `{id, lang, title, format, prompt_md, code, target_sec, hints_total, started_at, srs_meta}` | 204, якщо черга порожня |
| `POST /api/attempt/run` | `{card_id, code}` | `{status, duration_ms, diagnostics[], raw_output, grade?, srs_next_days?}` | 400 `bad_request`, 409 `no_active_attempt` |
| `POST /api/attempt/hint` | `{card_id}` | `{hint_index, hints_total, text}` (`hint_index` 1-based) | 404 `hints_exhausted`, 409 `no_active_attempt` |
| `POST /api/attempt/giveup` | `{card_id}` | `{status:"giveup", grade:1, srs_next_days:1}` | 409 `no_active_attempt` |
| `GET /api/attempt/diff` | `?card_id=…` | `{user_code, solution_code, unified_diff}` | 403 `solution_locked`, 404 `not_found` |
| `GET /api/stats` | — | `{due_today, reviewed_today, clean_compile_rate, weak_tags:[{tag, avg_grade, attempts}]}` | 500 `internal` |

Додаткові формати:
- `srs_meta = {reps, lapses, ease_factor, interval_days, is_new}`.
- `started_at` — RFC 3339.
- `diagnostics[] = {file, line, col, severity, message}`.
- `srs_next_days` — ціле число, округлене вгору.

Неочікувані збої повертаються як 500 `internal`. Подробиці пишуться в журнал сервера, а не у відповідь.

## 6. Конфігурація `dreet serve`

| Прапорець | За замовчуванням | Призначення |
| :---- | :---- | :---- |
| `--addr` | `127.0.0.1:8787` (у контейнері `0.0.0.0:8787`) | Адреса HTTP |
| `--data` | `/data` | Каталог SQLite (`dreet.db`) |
| `--work` | `/work` | Корінь пісочниць |
| `--decks` | `/app/decks` | Каталог колод |
| `--new-per-day` | `3` | Ліміт нових карток на добу |
| `--mock` | `false` | Фейки `runner`/`srs`/`sandbox` з `internal/mock` |

`dreet validate` приймає `--decks`.

Сервер завершується коректно (graceful shutdown) за `SIGINT`/`SIGTERM`: `http.Server.Shutdown`, потім `Cleanup` активної пісочниці, потім `Store.Close`.

## 7. Відхилення від початкового ТЗ і уточнення

Вихідне ТЗ лежить у `../context/Відновлення_навичок_лайв-кодингу_на_Go.md`. Порівняно з ним цей документ змінює таке:

1. **Назви.** `drill-dojo`/`drill-engine` замінено на `dreet-dojo`/`dreet`, `go-fluency-01` — на `go-drills-01`, `/data/drill.db` — на `/data/dreet.db`.
2. **Go 1.26** замість 1.24, згідно з конвенцією проєкту.
3. **`GET /api/session/current` (FR-15).** У ТЗ кожен `session/next` прибирав попередню спробу. Тоді перезавантаження сторінки скидало б таймер, а це суперечить ADR-4.
4. **`giveup` замість `gave_up`** у відповіді API, щоб збігатися зі статусом у БД.
5. **`Result.Duration`** у ТЗ мав тег `json:"duration_ms"` на `time.Duration`, а це серіалізувало б наносекунди. Тепер у DTO йде окреме поле `duration_ms` (int64).
6. **Таймаут `go test -timeout`** проявляється як `panic: test timed out` з `Action: "fail"`. Його явно віднесено до `timeout` (пріоритет 1 у §3.3), інакше AC-4 не виконується.
7. **`timeout` збільшує `test_fails`.** У ТЗ це не було визначено.
8. **`DeckCardMeta`** у ТЗ згадувався, але не був визначений. Тепер визначений, а `NextDue` отримав `NextOptions`.
9. **`GOCACHE` на read-only rootfs** потребує записуваного тому (ADR-2).
10. **`closeBrackets` заборонено** в редакторі як допомогу, що виходить за межі «стерильного» набору.
11. **Уточнено переліки** сторонніх залежностей (YAML-парсер) і змінних оточення `GoRunner`.

## 8. Відкриті питання

1. **Права на `./data`.** Контейнер працює як UID 10001, а bind-mount `./data` належить користувачу хоста. Можна зробити `chown 10001 ./data` перед стартом або перевизначати `user:` у compose під UID хоста.
2. **Пропуск картки через `Alt+N` посеред спроби.** Зараз така спроба не записується, а картка лишається в черзі. Чи потрібен окремий статус `skip` з оцінкою 1?
3. **Часовий пояс доби** для `NewPerDay` і `ReviewedToday`: брати `TZ` контейнера чи окремий прапорець?
