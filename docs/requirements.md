# DreetDojo — Requirements

Вимоги до MVP 1.0. Сценарії: [use-cases.md](use-cases.md). Архітектура: [architecture.md](architecture.md).
Детальний дизайн: [hld.md](hld.md).

## Розмітка

Документ розмічено у форматі [tumanomir](https://github.com/valpere/tumanomir) для детермінованого виміру точності специфікації (`tumanomir check docs/`).

- `[REQ-…]` на початку пункту списку **визначає** вимогу. Кожна вимога має принаймні одне трасування:
  - `-> [FUN-…]` — функція, тип або ендпоінт;
  - `-> [LOG-…]` — структурний інваріант коду;
  - `-> [PHY-…]` — фізичний артефакт: конфіг, команда, вимір.
- В інших місцях вимоги згадуються **без дужок** (наприклад, REQ-FR-07). ID у дужках будь-де в тексті tumanomir порахує як нове визначення.
- `@schema` / `@constraint` — машиночитна модель даних.

## Призначення

Це локальний контейнеризований тренажер, щоб відновлювати й підтримувати навичку активного програмування (*coding fluency*). Він поєднує три речі:
- інтервальне повторення (SRS);
- таймовані мікро-вправи, які перевіряє реальний компілятор і тести;
- «стерильний» редактор без автодоповнення й AI.

Базова мова MVP — Go. Архітектура закладає розширення на інші мови та альтернативні клієнти.

## 0. Модель даних

Це канонічна **логічна** модель. Фізичні назви колонок SQLite наведено в hld.md §3.4 (наприклад, `tags` зберігається як `tags_json TEXT`). Go-типи можуть містити лише підмножину полів, потрібну конкретному пакету (hld.md §3). Формати HTTP описано в hld.md §5.

@schema CardMeta {
  id: String @constraint(required, unique: "across all decks"),
  lang: String @constraint(required, rule: "registered in runner.Registry"),
  title: String @constraint(required),
  format: Enum["cloze","spec","progressive","bugfix","skeleton"] @constraint(required),
  prereq: String? @constraint(rule: "id of an existing card; prereq graph is acyclic"),
  order: Int @constraint(default: 0),
  target_sec: Int @constraint(required, min: 1),
  tags: [String] @constraint(default: []),
  entry_file: String @constraint(default: "kata.go", rule: "bare file name; no path separators, no '..', not *_test.go"),
  hints: [String] @constraint(default: [], rule: "served in order, one per request")
}

@schema CardFiles {
  meta: "meta.yaml" @constraint(required),
  prompt: "prompt.md" @constraint(required),
  module: "go.mod" @constraint(required, rule: "module kata; go 1.26"),
  stub: "<entry_file>" @constraint(required, rule: "must fail its tests"),
  tests: "*_test.go" @constraint(required, min: 1, rule: "read-only in the sandbox"),
  solution: "solution.go" @constraint(required, rule: "must pass under -race; never copied into /work")
}

@schema CardState {
  card_id: String @constraint(primary_key),
  deck_id: String,
  prereq_card_id: String?,
  sort_order: Int,
  tags: [String],
  reps: Int @constraint(min: 0, rule: "consecutive successful reviews; reset to 0 on grade 1"),
  lapses: Int @constraint(min: 0),
  interval_days: Float @constraint(range: [0, 60]),
  ease_factor: Float @constraint(default: 2.5, range: [1.3, 3.0]),
  due_at: Timestamp @constraint(rule: "0 = new card"),
  last_reviewed_at: Timestamp?,
  active: Bool @constraint(default: true, rule: "false when the card is gone from disk")
}

@schema Attempt {
  id: Int @constraint(primary_key, autoincrement),
  card_id: String @constraint(foreign_key: "CardState.card_id"),
  started_at: Timestamp,
  finished_at: Timestamp,
  elapsed_sec: Int @constraint(min: 0),
  target_sec: Int @constraint(min: 1),
  compile_errors: Int @constraint(min: 0),
  test_fails: Int @constraint(min: 0, rule: "timeout also increments"),
  hints_used: Int @constraint(min: 0),
  status: Enum["pass","giveup"],
  grade: Int @constraint(range: [1, 4])
}

@schema CheckResult {
  status: Enum["pass","compile_error","test_fail","timeout"],
  duration_ms: Int @constraint(min: 0),
  diagnostics: [Diagnostic],
  raw_output: String @constraint(max_bytes: 65536)
}

@schema Diagnostic {
  file: String @constraint(rule: "relative to the sandbox dir"),
  line: Int @constraint(min: 1),
  col: Int @constraint(min: 0, rule: "0 = unknown"),
  severity: Enum["error","warning"],
  message: String
}

## 1. Функціональні вимоги

### Колоди та формати вправ

1. [REQ-FR-01] Система завантажує декларативні колоди з файлової системи (CardFiles). Нові або змінені картки підхоплюються без перезбирання образу: синхронізація відбувається на старті `serve` і в кожному запиті наступної картки.
   -> [FUN-FR-01] deck.Loader.LoadAll(rootDir string) ([]deck.Card, error), що викликається з session.Service.Next
2. [REQ-FR-02] Поле `format` підтримує 5 типів вправ:
   - `cloze`: заповнити пропуск;
   - `spec`: від ТЗ до коду;
   - `progressive`: ланцюжок етапів через `prereq`;
   - `bugfix`: знайти й виправити баг;
   - `skeleton`: оголосити контракти й типи.

   -> [FUN-FR-02] deck.Format з константами FormatCloze, FormatSpec, FormatProgressive, FormatBugfix, FormatSkeleton
3. [REQ-FR-03] Команда `dreet validate` гарантує інваріант кожної картки:
   - стаб не проходить тести;
   - еталон проходить тести під `-race` без гонок і попереджень;
   - граф `prereq` коректний: посилання ведуть на наявні картки, циклів немає.

   -> [FUN-FR-03] `dreet validate --decks <dir>` у cmd/dreet із кодами виходу 0 (все валідне), 1 (є невалідні картки), 2 (збій інфраструктури)

### Стерильний редактор і UX одного вікна

4. [REQ-FR-04] Веб-інтерфейс збирає в одному вікні редактор, панель умови з таймером і підказками, вивід тестів і переглядач diff. Перемикатися в термінал не потрібно.
   -> [LOG-FR-04] web/: одна сторінка (умова | редактор | вивід), за `Alt+D` редактор замінюється на MergeView (hld.md §3.7)
5. [REQ-FR-05] Редактор працює в «стерильному режимі»:
   - **дозволено:** підсвітку синтаксису, автовідступи, підсвітку парних дужок, інлайн-маркери помилок від раннера;
   - **заборонено:** автодоповнення, LSP, сніпети, AI-підказки, автозакриття дужок.

   -> [LOG-FR-05] web/: явний allowlist розширень CodeMirror (hld.md §3.7); `basicSetup`, `autocompletion` і `closeBrackets` не імпортуються
6. [REQ-FR-06] Основний цикл керується з клавіатури: `Ctrl+S` перевіряє рішення, `Alt+H` дає підказку, `Alt+D` показує diff, `Alt+N` видає наступну картку.
   -> [FUN-FR-06] web/ keymap: Ctrl+S → POST /api/attempt/run, Alt+H → POST /api/attempt/hint, Alt+D → GET /api/attempt/diff, Alt+N → POST /api/session/next
7. [REQ-FR-07] Еталон (`solution.go`) не віддається через API і не копіюється в пісочницю, доки поточна спроба не завершиться (`pass` або `giveup`). Навмисне читання еталона кодом вправи з диска виходить за межі цієї вимоги (див. модель загроз в architecture.md §5.1).
   -> [LOG-FR-07] sandbox.Manager.Prepare не копіює solution.go; session.Service.Diff повертає ErrSolutionLocked (403), доки Attempt.UnlockedSolution == false

### Виконання коду та діагностика

8. [REQ-FR-08] Go-вправу перевіряє реальний компілятор командою `go test -race -json -count=1 -timeout=5s ./...` в ізольованій тимчасовій директорії, без завантаження модулів (`GOPROXY=off`). Мережеву ізоляцію коду вправи MVP не гарантує (architecture.md §5.1).
   -> [FUN-FR-08] runner.GoRunner.Check(ctx context.Context, workDir string) (runner.Result, error) з оточенням GOPROXY=off, GOTOOLCHAIN=local
9. [REQ-FR-09] Ядро розрізняє 4 статуси перевірки (`pass`, `compile_error`, `test_fail`, `timeout`). Воно повертає масив структурованих діагностик (Diagnostic), щоб показати їх у рядках редактора.
   -> [FUN-FR-09] runner.Status, runner.Diagnostic, runner.Result; пріоритети визначення статусу наведено в hld.md §3.3
10. [REQ-FR-10] Коли спрацьовує таймаут, система примусово знищує процес разом із групою дочірніх процесів (PGID). Завислих або зомбі-процесів не лишається.
    -> [LOG-FR-10] GoRunner: SysProcAttr{Setpgid: true}; коли контекст скасовано, syscall.Kill(-pgid, SIGKILL), потім cmd.Wait

### Інтервальне повторення (SRS) та телеметрія

11. [REQ-FR-11] Оцінка 1–4 виводиться автоматично з об'єктивних метрик: `elapsed_sec` відносно `target_sec`, `compile_errors`, `test_fails`, `hints_used` і статусу спроби. Користувач оцінку не обирає.
    -> [FUN-FR-11] srs.EvaluateGrade(in srs.AttemptInput) srs.Grade (таблиця правил у hld.md §3.4)
12. [REQ-FR-12] Інтервали розраховує адаптований SM-2:
    - перші інтервали 1 → 3 дні;
    - `EF` у межах [1.3, 3.0], стартове значення 2.5;
    - максимальний інтервал 60 днів;
    - jitter ±5% для інтервалів від 4 днів.

    -> [FUN-FR-12] srs.ScheduleSM2(st srs.CardState, g srs.Grade, now time.Time, rnd func() float64) srs.CardState
13. [REQ-FR-13] Планувальник враховує залежності `prereq`: нова картка не видається, доки батьківська не має хоча б однієї спроби зі статусом `pass`. Подальші провали батьківської картки вже відкриту дочірню не блокують. Діє денний ліміт нових карток: конфігурований, за замовчуванням 3. Межа доби — 00:00 UTC.
    -> [FUN-FR-13] srs.Store.NextDue(ctx, now time.Time, opts srs.NextOptions) (srs.CardState, error), прапорець `dreet serve --new-per-day`
14. [REQ-FR-14] Статистика за 30 днів:
    - черга на сьогодні;
    - скільки карток пройдено сьогодні;
    - частка спроб без жодної помилки компіляції;
    - топ слабких тегів за середньою оцінкою.

    -> [FUN-FR-14] srs.Store.Stats(ctx, now time.Time) (srs.Stats, error), GET /api/stats
15. [REQ-FR-15] Активна спроба відновлюється після перезавантаження сторінки. Таймер і лічильники при цьому не скидаються, а UI отримує поточний код із пісочниці.
    -> [FUN-FR-15] session.Service.Current(ctx) (CardView, error), GET /api/session/current
16. [REQ-FR-16] Пропустити незавершену спробу не можна. Щоб перейти до наступної картки, спробу треба пройти (`pass`) або здати (`giveup`). Так `Alt+N` не скидає таймер і не дає обійти оцінку.
    -> [FUN-FR-16] session.Service.Next повертає ErrAttemptInProgress → 409 `attempt_in_progress`; ендпоінт POST /api/attempt/giveup

## 2. Нефункціональні вимоги

### Швидкодія

17. [REQ-NFR-01] Медіанний час `POST /api/attempt/run` для типової Go-вправи з `-race` — **≤ 500 мс**. Це досягається прогрітим `GOCACHE` і tmpfs для `/work` та `/tmp`.
    -> [PHY-NFR-01] вимір у межах REQ-AC-3: медіана `duration_ms` за 20 послідовних прогонів однієї картки в контейнері
18. [REQ-NFR-02] Холодний старт контейнера до готовності HTTP — **≤ 2 с**. JS-бандл фронтенду — **≤ 500 КБ** у gzip.
    -> [PHY-NFR-02] час від `docker compose up` до першої відповіді 200 від GET /api/health; `gzip -c web/dist/assets/*.js | wc -c` ≤ 512000

### Безпека та ізоляція

19. [REQ-NFR-03] Порт публікується виключно на `127.0.0.1:8787` хоста. Контейнер працює від непривілейованого користувача `dreet` (UID 10001) з такими налаштуваннями: `read_only: true`, `cap_drop: ALL`, `no-new-privileges: true`, `mem_limit: 1g`, `pids_limit: 128`, `cpus: 2.0`.
    -> [PHY-NFR-03] docker-compose.yml, сервіс `dreet`: `ports: ["127.0.0.1:8787:8787"]`, `user: "10001"`, плюс перелічені ключі
20. [REQ-NFR-04] Тестові файли пісочниці й каталог колод (`/app/decks`) доступні лише для читання. API пише тільки в цільовий файл вправи всередині `/work/<session_id>/`, і цей запис захищено від path traversal. Код вправи виконується з тими самими правами, що й `dreet` (модель загроз: architecture.md §5.1).
    -> [LOG-NFR-04] sandbox.Manager.WriteCode пише лише у filepath.Join(ws.Dir, ws.EntryFile) і перевіряє, що шлях лежить усередині ws.Dir; *_test.go мають права 0444; монтування `./decks:/app/decks:ro`

### Надійність даних

21. [REQ-NFR-05] SQLite працює в режимі WAL з `foreign_keys=ON` і `busy_timeout=5000`. Стан картки й запис спроби фіксуються в одній транзакції. Історія та розклад переживають перезапуск контейнера.
    -> [PHY-NFR-05] PRAGMA під час відкриття з'єднання в srs; srs.Store.RecordAttempt виконується в одній транзакції; іменований том `dreet-data` змонтовано в `/data`

### Розширюваність

22. [REQ-NFR-06] Нова мова (Python, Rust, TypeScript) не потребує змін у `srs`, `sandbox`, `api`, `session` чи схемі БД. Досить нової реалізації `Runner` і відповідного runtime-образу.
    -> [LOG-NFR-06] runner.Registry з ключем CardMeta.lang; session звертається лише до інтерфейсу runner.Runner; srs і sandbox не імпортують runner; api імпортує з runner лише типи-значення Result і Diagnostic
23. [REQ-NFR-07] Бізнес-логіка не прив'язана до HTTP. Поверх тих самих сервісів можна додати stdio JSON-RPC транспорт для плагінів редакторів (VS Code, Lite XL) без дублювання логіки.
    -> [LOG-NFR-07] internal/api викликає лише session.Service і не викликає deck, srs, sandbox чи runner; з srs і runner бере тільки типи-значення та sentinel-помилки (hld.md §3.6)

### Підтримуваність

24. [REQ-NFR-08] Бінарник `dreet` компілюється з `CGO_ENABLED=0`, SQLite підключено через pure-Go `modernc.org/sqlite`. HTTP працює на stdlib `net/http`, без веб-фреймворків. Кожна стороння залежність має письмове обґрунтування, чому stdlib не вистачає (architecture.md §4).
    -> [PHY-NFR-08] go.mod має рівно дві прямі (не `// indirect`) залежності: modernc.org/sqlite і go.yaml.in/yaml/v3; Dockerfile, стадія builder: `CGO_ENABLED=0 go build ./cmd/dreet`

## 3. Обмеження

25. [REQ-CON-01] Go **1.26+** для ядра і для `go.mod` карток.
    -> [PHY-CON-01] `go 1.26` у go.mod репозиторію і в go.mod кожної картки (перевіряє `dreet validate`)
26. [REQ-CON-02] Runtime-образ на Debian/glibc (`golang:1.26-bookworm` або новіший Debian-тег). **Alpine заборонено**, бо `-race` потребує glibc і CGO під час прогону тестів.
    -> [PHY-CON-02] Dockerfile: стадії builder і runtime-go мають базу `golang:<1.26+>-<debian-tag>` (bookworm, trixie…), а не `-alpine`
27. [REQ-CON-03] Фронтенд: TypeScript, Vite і CodeMirror 6. Важких UI-фреймворків (React, Angular, MUI) немає. Бандл вшивається в бінарник через `//go:embed`.
    -> [PHY-CON-03] web/package.json має залежності лише vite, typescript, @codemirror/*; internal/web містить `//go:embed dist/*`
28. [REQ-CON-04] Вправи MVP спираються лише на стандартну бібліотеку. Під час перевірки мережа не потрібна.
    -> [LOG-CON-04] `dreet validate` і GoRunner запускаються з GOPROXY=off, тож картка з не-stdlib імпортом не проходить валідацію

## 4. Межі MVP (Out of Scope для v1.0)

- Автентифікація, багатокористувацький режим, хмарна синхронізація.
- Генерація вправ через LLM у веб-інтерфейсі. Її винесено в офлайн-процес поза ядром.
- Зовнішні Go-модулі з мережі під час виконання вправ.
- Ізоляція коду вправи від еталонів, БД і мережі (окремий runner-контейнер). Для MVP діє модель чесного користувача, див. architecture.md §5.1.
- Нативні плагіни VS Code / Lite XL і stdio JSON-RPC транспорт. Архітектура їх передбачає, реалізація буде після валідації MVP.
- Інші мови, крім Go. Передбачено через `Runner`.
- FSRS замість SM-2. Планувальник ізольовано, тож заміна можлива пізніше.

## 5. Критерії приймання MVP

29. [REQ-AC-1] `docker compose up --build` піднімає контейнер на `127.0.0.1:8787` з усіма налаштуваннями REQ-NFR-03, а `GET /api/health` повертає `200`.
    -> [PHY-AC-1] `docker compose up -d --build && curl -fsS http://127.0.0.1:8787/api/health`; `docker inspect $(docker compose ps -q dreet)` показує ReadonlyRootfs=true, CapDrop=[ALL], User=10001
30. [REQ-AC-2] `dreet validate --decks /app/decks` проходить без помилок для стартової колоди `go-drills-01` з 15 Go-вправ.
    -> [PHY-AC-2] `docker compose exec dreet dreet validate --decks /app/decks` завершується з кодом 0, у звіті 15 валідних карток
31. [REQ-AC-3] У редакторі повністю відсутні автодоповнення, підказки сигнатур і AI-доповнення. `Ctrl+S` проганяє `go test -race` і показує інлайн-діагностики або зелене проходження. На типовій картці це займає **≤ 500 мс** (медіана).
    -> [PHY-AC-3] ручна перевірка в `chromium --app=http://127.0.0.1:8787`: під час набору не з'являється жодне спливне вікно; час вимірюється за PHY-NFR-01
32. [REQ-AC-4] Нескінченний цикл у коді вправи переривається приблизно через 5 с зі статусом `timeout`. Після цього `ps aux` у контейнері не показує завислих процесів.
    -> [PHY-AC-4] `for {}` у kata.go → POST /api/attempt/run повертає `status: "timeout"`; потім `docker compose exec dreet ps aux` не містить процесів `go` / `*.test`
33. [REQ-AC-5] Ланцюжок прогресивної кати (go-05 → go-06 → go-07) проходить коректно:
    - наступний етап розблоковується лише після `pass` попереднього;
    - історія зберігається після перезапуску контейнера;
    - side-by-side diff з `solution.go` відображається правильно.

    -> [PHY-AC-5] сценарій: `pass` go-05 → наступною видається go-06; `docker compose restart` → GET /api/stats показує ту саму історію; після `pass` за `Alt+D` відкривається MergeView
