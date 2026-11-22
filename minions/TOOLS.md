# TOOLS.md — посіпаки dreet-dojo

Помічники агента для власної роботи. Сервіс від них не залежить; у hooks, CI чи сервіси їх не підключати. Bash + jq, без Python.

- `minions/spec-measure.sh [git-rev] [req-uc|hld ...]` — знімає набори специфікацій з `docs/` на ревізії (за замовчуванням `HEAD`; `req-uc` = requirements.md + use-cases.md, `hld` = hld.md) у read-only `../context/tumanomir/specs/`. Знімок тієї самої ревізії використовується повторно. Потім по черзі запускає `tumanomir measure` з `.tumanomir.yaml` цього каталогу: корпус `corpus.jsonl` дописується з дедупом за spec_hash і приладом. Повний JSON, stderr і рядок `runs.tsv` зберігаються в `reports/`, а на екран друкується таблиця verdict / D_pair / CI / кластери / H_norm. Невідомий набір або порожній знімок дає exit 2, ще до будь-якого виміру.
- `minions/pr-land.sh <PR>` — зливає PR після рев'ю. Якщо якась перевірка `fail` чи `pending`, відмовляє з exit 1. Інакше робить squash-merge з `--delete-branch`, перевіряє стан `MERGED`, переходить на `main` з `pull --ff-only` і друкує 3 останні коміти та рядок `tumanomir check docs/`. Рев'ю саме не запускає.
