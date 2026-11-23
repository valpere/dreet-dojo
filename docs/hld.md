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
│   ├── sandbox/          # /work/<session_id>, запис і читання коду
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
0. Розкладка рівно `<decks>/<deck_id>/<картка>/`: директорія картки — це директорія з `meta.yaml` на другому рівні. Інша вкладеність не підтримується.
1. Обов'язкові файли на місці: `meta.yaml`, `prompt.md`, `go.mod`, `<entry_file>`, щонайменше один `*_test.go`, `solution.go`.
2. `id`, `lang`, `title`, `format` і `target_sec` задані. `format` належить до переліку, а `target_sec > 0`.
3. `id` унікальні в межах усіх колод.
4. `entry_file` — це ім'я файлу із суфіксом `.go`, без розділювачів шляху, без `..`, не `*_test.go` і не `solution.go`.
5. `prereq` посилається на наявну картку, а граф `prereq` не має циклів.
6. `lang` зареєстровано в `runner.Registry`. Цю перевірку робить `cmd/dreet`, бо `deck` не залежить від `runner`.
7. `go.mod` містить лише `module kata` і директиву `go 1.26` (або новішу). `require`, `replace` і `toolchain` заборонені: вправи MVP спираються лише на stdlib (REQ-CON-04).

**Поведінкові.** Тільки `dreet validate`. Кожна перевірка йде в окремій тимчасовій директорії поза `/work`.
1. Стаб, тобто `<entry_file>` разом із тестами, не проходить. Статус має бути `test_fail` або `compile_error`.
2. Еталон, тобто `solution.go`, скопійований як `entry_file`, разом із тестами дає статус `pass`. Гонок і попереджень при цьому немає.

Невалідна картка в режимі `serve` журналюється і виключається з видачі. Сервер через неї не падає. Поведінкових перевірок `serve` не робить: після зміни картки автор запускає `dreet validate`.

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
	File     string // відносно workDir, напр. "kata.go": префікс workDir і "./" відрізаються
	Line     int    // 1-based
	Col      int    // 1-based; 0 якщо невідомо
	Severity string // "error" | "warning"
	Message  string
}

type Result struct {
	Status      Status
	Duration    time.Duration // у DTO віддається як duration_ms (int64)
	Diagnostics []Diagnostic
	RawOutput   string // конкатенація полів Output подій go test -json; понад 64 КБ лишається хвіст
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
- Процес отримує окрему групу (`SysProcAttr{Setpgid: true}`). Загальний дедлайн — 15 с: `-timeout=5s` на тести плюс запас на компіляцію з `-race`. `GoRunner` сам накладає його через `context.WithTimeout` на отриманий `ctx`, тож дедлайн діє й тоді, коли `session` від'єднав `ctx` від HTTP-запиту. Коли контекст скасовано, викликається `syscall.Kill(-pgid, SIGKILL)` і процес чекається через `Wait`. Після **кожного** `Wait` `Kill(-pgid, SIGKILL)` викликається ще раз (`ESRCH` ігнорується): якщо `go test -timeout` завершив тестовий процес сам, його нащадки інакше лишилися б жити (REQ-FR-10).
- Оточення: успадковується від `dreet` (`os.Environ()`), поверх нього задаються лише `CGO_ENABLED=1`, `GOPROXY=off`, `GOTOOLCHAIN=local` і `GORACE=atexit_sleep_ms=0`. Без останнього race-детектор чекає 1 с перед виходом тестового процесу, і REQ-NFR-01 недосяжна. `GOCACHE=/var/cache/go-build` і `GOTMPDIR=/tmp` задає `ENV` у Dockerfile, а не код, тож `dreet validate` працює й на хості з типовим кешем Go.
- Діагностики приймають обидві форми рядка: `kata.go:18:12: msg` і `./kata.go:18:12: msg`; абсолютні шляхи з трасувань `DATA RACE` перетворюються на відносні до `workDir`.

Статус визначається з потоку подій `go test -json` за пріоритетом:

| Пріоритет | Умова | Статус |
| :---- | :---- | :---- |
| 1 | Контекст перевищив дедлайн, або у виводі є `panic: test timed out` | `timeout` |
| 2 | `Action == "build-fail"` або `build-output` з помилками компіляції | `compile_error`; рядки виду `kata.go:18:12: msg` стають діагностиками |
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
    active           INTEGER NOT NULL DEFAULT 1,   -- 0 = картки вже немає на диску
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

**Синхронізація.** `SyncCards` робить `INSERT … ON CONFLICT(card_id) DO UPDATE` і оновлює лише метадані: `deck_id`, `prereq_card_id`, `sort_order`, `tags_json`. SRS-поля не змінюються. Передані картки отримують `active = 1`. Картки, яких немає в переданому наборі, отримують `active = 0`: вони лишаються в БД, щоб зберегти історію, але `NextDue` і `Stats` їх не враховують.

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
	Stats(ctx context.Context, now time.Time, newPerDay int) (Stats, error)
	Close() error
}

// scheduler.go — чисті функції без БД.
func EvaluateGrade(in AttemptInput) Grade
func ScheduleSM2(st CardState, g Grade, now time.Time, rnd func() float64) CardState
```

`RecordAttempt` виконується в одній транзакції: `EvaluateGrade`, потім `ScheduleSM2`, потім `INSERT attempts` і `UPDATE card_state`. `elapsed_sec = floor(FinishedAt − StartedAt)` у секундах обчислює сам `RecordAttempt`. Якщо транзакція не вдалася, повертається помилка, і в БД нічого не змінюється. `rnd` ін'єктується, щоб jitter був детермінованим у тестах.

**Оцінка (`EvaluateGrade`).** Правила перевіряються згори вниз, спрацьовує перше. `elapsed` — це `FinishedAt.Sub(StartedAt).Seconds()` як `float64`, а `target` — `TargetSec`.

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
- Якщо `I >= 4.0`, то `I ×= 0.95 + 0.1 × rnd()`.
- `I = min(60.0, I)`. Стеля застосовується **після** jitter, тож інтервал ніколи не перевищує 60 днів.
- `due_at = now + I × 86400`, а `last_reviewed_at = now`.

**Черга (`NextDue`).** `today_start` — 00:00 UTC поточної доби, `tomorrow_start = today_start + 86400`.
1. До повторення: `active = 1 AND due_at > 0 AND due_at < tomorrow_start`, порядок `ORDER BY due_at ASC, ease_factor ASC`. Строк рахується по добі, а не до секунди: картка з `due_at` сьогодні о 20:00 UTC видається вже зранку, як і рахує `DueToday`.
2. Нові: `active = 1 AND reps = 0 AND lapses = 0 AND due_at = 0`, причому `prereq_card_id IS NULL` або батьківська картка має хоча б одну спробу `pass` (`EXISTS (SELECT 1 FROM attempts WHERE card_id = prereq_card_id AND status = 'pass')`). `reps` для цього не годиться: це серія, яка скидається після оцінки Again, а Again можливий і при `pass`. Порядок `ORDER BY deck_id, sort_order`. Видаються, лише поки `new_today < NewPerDay`, де `new_today` — кількість різних `card_id`, у яких `MIN(attempts.finished_at) >= today_start`.
3. Якщо нічого не знайдено, повертається `ErrNoCardsDue`. З `Ahead` замість цього видається активна картка з мінімальним `due_at >= tomorrow_start`.

«Сьогодні» — це доба UTC: межа йде о 00:00 UTC. `TZ` контейнера на це не впливає, і прапорця для зміни часового поясу немає.

**Статистика (`Stats`).** Вікно — спроби з `finished_at >= now − 30 × 86400`; враховуються лише активні картки.
- `DueToday`: картки з п. 1 черги плюс менше з двох значень: `NewPerDay − new_today` і кількість нових карток, що проходять фільтр п. 2 разом із `prereq`. Від'ємне значення вважається 0.
- `ReviewedToday`: кількість різних `card_id` зі спробою (`pass` або `giveup`), завершеною після `today_start`.
- `CleanCompileRate`: частка спроб вікна з `compile_errors == 0`; 0, якщо спроб немає.
- `WeakTags`: спроба зараховується кожному тегу своєї картки; 5 тегів з найнижчим `AvgGrade`, за рівності — за назвою тегу за зростанням; теги без спроб у вікні не показуються.

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
	Grade            int    // 1..4 після завершення, 0 до нього
	NextDays         int    // ceil(interval_days) після завершення
	UnlockedSolution bool
}

type Service interface {
	Current(ctx context.Context) (CardView, error)          // ErrNoAttempt
	Next(ctx context.Context, ahead bool) (CardView, error) // srs.ErrNoCardsDue, ErrAttemptInProgress
	Run(ctx context.Context, cardID, code string) (RunOutcome, error)
	Hint(ctx context.Context, cardID string) (HintView, error)
	GiveUp(ctx context.Context, cardID, code string) (GiveUpOutcome, error)
	Diff(ctx context.Context, cardID string) (DiffView, error)
	Stats(ctx context.Context) (srs.Stats, error)
}

var (
	ErrNoAttempt         = errors.New("no attempt")                               // жодної спроби немає
	ErrNoActiveAttempt   = errors.New("no active attempt for this card")          // немає, завершена або чужий card_id
	ErrAttemptInProgress = errors.New("current attempt is not finished")
	ErrSolutionLocked    = errors.New("solution locked until attempt is finished")
	ErrHintsExhausted    = errors.New("no more hints")
)
```

Правила:
- Одночасно існує одна спроба (`*Attempt` під `sync.Mutex`). `Run` серіалізується, тож паралельних прогонів на одній пісочниці не буває.
- Час береться з ін'єктованого `clock func() time.Time`.
- `Run`, `Hint` і `GiveUp` без спроби, на завершеній спробі або з чужим `cardID` повертають `ErrNoActiveAttempt`.
- `Next` при незавершеній спробі повертає `ErrAttemptInProgress`. Пропуску картки немає: щоб перейти далі, треба `pass` або `GiveUp`. Інакше `Alt+N` скидав би таймер і давав обійти оцінку, а детермінована черга повертала б ту саму картку.
- `timeout` збільшує `TestFails`.
- `Run` виконує перевірку з контекстом, не прив'язаним до HTTP-запиту (`context.WithoutCancel`): від'єднання клієнта не скасовує прогін, і лічильники фіксуються однаково.
- `Run` з `pass` і `GiveUp` позначають спробу завершеною лише після успішного `RecordAttempt`. Якщо він повернув помилку, спроба лишається активною, еталон заблокованим, а клієнт отримує 500.
- `GiveUp` спершу записує переданий `code` через `sandbox.WriteCode`, щоб diff показав останню версію з редактора. Помилка запису повертається як є (500), і спроба лишається активною.
- `Diff` працює з поточною або щойно завершеною спробою. Без спроби або з чужим `cardID` повертає `ErrNoAttempt`. Після `Next` або перезапуску сервера попередня спроба вже недоступна.

### 3.6 `internal/api` і `internal/web`

- Маршрутизація стандартним `http.ServeMux` з шаблонами `METHOD /path`.
- Доменні помилки мапляться на HTTP **по ендпоінту** (таблиця в §5). Однакова помилка може давати різні коди залежно від ендпоінту, наприклад `ErrNoAttempt`: 204 для `current` і 404 для `diff`.
- Усе тіло запиту, разом з JSON-екрануванням і іншими полями, обмежено `http.MaxBytesReader` до 262144 байт. Перевищення, некоректний JSON або відсутнє обов'язкове поле (зокрема `card_id` у query `diff`) дають 400 `bad_request`.
- `internal/api` викликає лише `session.Service`. Імпортувати `srs` і `runner` дозволено тільки заради типів-значень (`srs.Stats`, `runner.Result`, `runner.Diagnostic`) і sentinel-помилок (`srs.ErrNoCardsDue`) для серіалізації й мапінгу кодів.
- `internal/web`: шлях поза `/api/` віддає файл з `embed.FS`. Якщо файлу немає, віддається `index.html` (SPA fallback). Для `assets/*` з хешем у назві ставиться `Cache-Control: immutable`.

### 3.7 `web/` — стерильний редактор

- **Розкладка одного вікна:**
  - ліворуч умова (`prompt.md`), таймер і підказки;
  - по центру редактор;
  - знизу вивід тестів і діагностики;
  - `Alt+D` замінює редактор на `MergeView` (`@codemirror/merge`).
- **Набір розширень CodeMirror** — лише явний список:
  - дозволено: `lineNumbers`, `history` з `historyKeymap`, `drawSelection`, `indentOnInput`, `bracketMatching`, `syntaxHighlighting(defaultHighlightStyle)`, `go()`, `lintGutter` разом із `setDiagnostics` (діагностики від бекенду, без `linter`), `defaultKeymap`, `indentWithTab`, власний `keymap`;
  - **не використовуються:** `basicSetup` (він тягне `autocompletion` і `closeBrackets`), `autocompletion` і `completionKeymap`, `closeBrackets` і `closeBracketsKeymap`, сніпети, будь-які LSP-клієнти.
- Для `contenteditable` вимикаються `spellcheck`, `autocorrect` і `autocapitalize`.
- Хоткеї `Ctrl+S`, `Alt+H`, `Alt+D` і `Alt+N` перехоплюються з `preventDefault`.
- Таймер рахується від `started_at`, який повертає сервер.
- На старті UI викликає `GET /api/session/current`. Якщо відповідь 204, наступну картку бере `POST /api/session/next`. Завершену спробу (`finished: true`) UI показує з оцінкою й доступним `Alt+D` і бере наступну картку лише за `Alt+N`.

## 4. Основні потоки

### 4.1 Старт картки — `POST /api/session/next`
1. Якщо попередня спроба не завершена, одразу повертається `ErrAttemptInProgress` (409), без читання диска й БД.
2. `deck.LoadAll`, потім `srs.SyncCards`. Синхронізація запускається на старті `serve` і в кожному `Next`.
3. `srs.NextDue(now, {Ahead, NewPerDay})` повертає `card_id`, далі `deck.Get(card_id)`.
4. `sandbox.Prepare(card)` створює `/work/<session_id>`. Якщо це не вдалося, повертається помилка (500), а попередня спроба лишається як була.
5. Лише тепер `sandbox.Cleanup(prev.WS)` прибирає пісочницю попередньої, завершеної спроби, і ініціалізується `Attempt{StartedAt: now}`.
6. Відповідь: CardView (§5).

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
`sandbox.WriteCode(ws, code)`, далі `srs.RecordAttempt(Passed: false)` дає оцінку 1. Лише після успішного запису `Finished = true`, `UnlockedSolution = true`.

### 4.5 Рев'ю еталона — `GET /api/attempt/diff`
1. Якщо `UnlockedSolution` не встановлено, повертається `ErrSolutionLocked` (403).
2. `sandbox.ReadCode(ws)`, далі `card.Solution` з пам'яті `deck`.
3. Відповідь: `{user_code, solution_code}`. Різницю обчислює `MergeView` на клієнті; серверного diff немає.

### 4.6 Валідація — `dreet validate --decks <dir>`
`deck.LoadAll` виконує структурні правила. Потім для кожної картки створюються дві тимчасові директорії, `stub` і `solution`, і для кожної викликається `Runner.Check`. Звіт друкується в stdout. Код виходу: 0, якщо все валідне, 1, якщо є невалідні картки або не знайдено жодної, 2, якщо помилка інфраструктури.

## 5. HTTP API

Усі відповіді мають тип `application/json; charset=utf-8`. Неочікувані збої повертаються як 500 `internal`. Подробиці пишуться в журнал сервера, а не у відповідь.

| Ендпоінт | Запит | 200 OK | Інші коди |
| :---- | :---- | :---- | :---- |
| `GET /api/health` | — | Health | — |
| `GET /api/session/current` | — | CardView (`code` — поточний код із пісочниці) | 204 (`ErrNoAttempt`) |
| `POST /api/session/next` | NextRequest | CardView | 204 (`ErrNoCardsDue`), 409 `attempt_in_progress` |
| `POST /api/attempt/run` | RunRequest | RunResponse | 400 `bad_request`, 409 `no_active_attempt` |
| `POST /api/attempt/hint` | CardRef | HintView | 404 `hints_exhausted`, 409 `no_active_attempt` |
| `POST /api/attempt/giveup` | GiveUpRequest | GiveUpResponse | 400 `bad_request`, 409 `no_active_attempt` |
| `GET /api/attempt/diff` | `?card_id=…` | DiffView | 400 `bad_request`, 403 `solution_locked`, 404 `not_found` (`ErrNoAttempt`) |
| `GET /api/stats` | — | StatsView | 500 `internal` |

Схеми запитів і відповідей (CheckResult і Diagnostic визначено в requirements.md §0):

@schema Error {
  error: { code: Enum["bad_request","no_active_attempt","attempt_in_progress","solution_locked","hints_exhausted","not_found","internal"], message: String }
}

@schema Health {
  status: "ok",
  langs: [String] @constraint(rule: "runner.Registry.Langs()")
}

@schema NextRequest {
  ahead: Bool? @constraint(default: false, rule: "Practice Ahead")
}

@schema CardRef {
  card_id: String @constraint(required)
}

@schema RunRequest {
  card_id: String @constraint(required),
  code: String @constraint(required, rule: "whole JSON request body <= 262144 bytes (§3.6)")
}

@schema GiveUpRequest {
  card_id: String @constraint(required),
  code: String @constraint(required, rule: "current editor content, written before the attempt closes; same body limit as RunRequest")
}

@schema CardView {
  id: String,
  lang: String,
  title: String,
  format: Enum["cloze","spec","progressive","bugfix","skeleton"],
  prompt_md: String,
  code: String,
  target_sec: Int,
  hints_total: Int,
  hints_used: Int,
  hints_shown: [String] @constraint(rule: "card.Hints[:hints_used]; restores revealed hints after reload without spending a new one"),
  started_at: String @constraint(format: "RFC 3339"),
  finished: Bool,
  final_status: Enum["pass","giveup"]? @constraint(rule: "only when finished"),
  grade: Int? @constraint(range: [1, 4], rule: "only when finished"),
  srs_next_days: Int? @constraint(rule: "only when finished"),
  srs_meta: { reps: Int, lapses: Int, ease_factor: Float, interval_days: Float, is_new: Bool }
}

@schema RunResponse {
  ...CheckResult,
  grade: Int? @constraint(range: [1, 4], rule: "only when status == pass"),
  srs_next_days: Int? @constraint(rule: "ceil(interval_days); only when status == pass")
}

@schema HintView {
  hint_index: Int @constraint(min: 1),
  hints_total: Int,
  text: String
}

@schema GiveUpResponse {
  status: "giveup",
  grade: 1,
  srs_next_days: 1
}

@schema DiffView {
  user_code: String,
  solution_code: String
}

@schema StatsView {
  due_today: Int,
  reviewed_today: Int,
  clean_compile_rate: Float @constraint(range: [0, 1]),
  weak_tags: [{ tag: String, avg_grade: Float, attempts: Int }] @constraint(max_items: 5, order: "avg_grade asc")
}

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
3. **`GET /api/session/current` (REQ-FR-15).** У ТЗ кожен `session/next` прибирав попередню спробу. Тоді перезавантаження сторінки скидало б таймер, а це суперечить ADR-4.
   - `session/next` тепер `POST`, бо має побічні ефекти (створює пісочницю й спробу).
   - Пропуску незавершеної спроби немає (409 `attempt_in_progress`). У ТЗ `next` мовчки викидав спробу, а детермінована черга одразу повертала ту саму картку з обнуленим таймером.
4. **`giveup` замість `gave_up`** у відповіді API, щоб збігатися зі статусом у БД.
5. **`Result.Duration`** у ТЗ мав тег `json:"duration_ms"` на `time.Duration`, а це серіалізувало б наносекунди. Тепер у DTO йде окреме поле `duration_ms` (int64).
6. **Таймаут `go test -timeout`** проявляється як `panic: test timed out` з `Action: "fail"`. Його явно віднесено до `timeout` (пріоритет 1 у §3.3), інакше REQ-AC-4 не виконується.
7. **`timeout` збільшує `test_fails`.** У ТЗ це не було визначено.
8. **`DeckCardMeta`** у ТЗ згадувався, але не був визначений. Тепер визначений, а `NextDue` отримав `NextOptions`. Для карток, зниклих з диска, додано `card_state.active`.
9. **Розблокування `prereq`** перевіряється наявністю спроби `pass`, а не `reps >= 1`. `reps` скидається після оцінки Again, тож прогресивний ланцюжок міг би заблокуватися назавжди.
10. **`GOCACHE` на read-only rootfs** потребує записуваного тому (ADR-2).
11. **`closeBrackets` заборонено** в редакторі як допомогу, що виходить за межі «стерильного» набору.
12. **Уточнено переліки** сторонніх залежностей (YAML-парсер) і змінних оточення `GoRunner`.
13. **Модель загроз.** ТЗ обіцяло, що код вправи не має доступу до еталона й мережі, але архітектура цього не забезпечувала. Тепер обмеження задокументовано явно (architecture.md §5.1, ADR-9), а формулювання REQ-FR-07, REQ-FR-08 і REQ-NFR-04 відповідають реальному захисту.
14. **`/data` — іменований том** `dreet-data`, а не bind-mount `./data`. Bind-mount належав би користувачу хоста або root, і UID 10001 не зміг би записати БД.
15. **Межа доби — 00:00 UTC** для `NewPerDay`, `ReviewedToday` і `DueToday`.
16. **Розмітка tumanomir.** Вимоги мають ID REQ-FR/NFR/CON/AC і трасування; модель даних і DTO описано через `@schema`. Додано вимогу REQ-FR-16 (заборона пропуску спроби), а в CardView — поле `hints_used`, бо без нього UI не відновить лічильник підказок після перезавантаження (REQ-FR-15).

17. **Рев'ю консиліуму (2026-11-23).** Сам документ і REQ уточнено так:
    - Видалено серверний unified diff: `MergeView` порівнює тексти сам.
    - `GORACE=atexit_sleep_ms=0`, точний дедлайн 15 с, повторний `Kill(-pgid)` після `Wait`, оточення `GoRunner` поверх `os.Environ()`.
    - Черга рахує строк повторення по добі UTC, як і `DueToday`. `Stats` отримує `newPerDay`, а агрегати мають точні визначення.
    - `next` перевіряє незавершену спробу першою і прибирає попередню пісочницю лише після успішного `Prepare`.
    - `giveup` приймає поточний код. `CardView` повертає показані підказки й результат завершеної спроби. Збій транзакції лишає спробу активною.
    - Звужено `entry_file` і формат `go.mod`. `validate` без жодної картки завершується з кодом 1.
    - REQ-NFR-06 більше не обіцяє незмінний `sandbox` для нової мови. Додано REQ-AC-6 для SRS.

## 8. Відкриті питання

Немає.
