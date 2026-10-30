# wt: menedżer git worktree

Stan na 2026-10-29. Skrypt: `bin/wt` (zainstalowany jako `~/.local/bin/wt`) (bash, zgodny z bash 3.2, sprawdzony też na bash 5.3 z Homebrew).

Cel: fizyczna izolacja plików między równoległymi sesjami (każdy feature we własnym worktree) i jedna bramka powrotu na gałąź bazową (`wt merge`: testy, rebase, testy, `merge --ff-only`).

## 1. Status prac

### Zrobione

| Slice | Zakres | Stan |
|---|---|---|
| 1 | Szkielet, `die`/`info`, parser configu, `wt config`, help | gotowe |
| 2 | `wt new`, `wt list` (`ls`), normalizacja ścieżek | gotowe |
| 3 | `wt test` (`.wt-test`, `WT_TEST`, autodetekcja) | gotowe |
| 4 | `wt status` (detektor kolizji) | gotowe |
| 2b | `wt new`: synchronizacja bazy z upstreamem (`fetch` + `ff-only`), `--no-fetch`, `WT_FETCH` | gotowe |

Weryfikacja: 126 testów w skrypcie testowym (0 błędów) na bash 5.3 i na `/bin/bash` 3.2, `bash -n` oraz `shellcheck` bez uwag.

### Do zrobienia

| Slice | Zakres |
|---|---|
| 5 | `wt merge <temat>` (bramka powrotu na bazę) |
| 6 | `wt drop <temat> [--yes]` (sprzątanie) |
| 7 | Końcowy przebieg: `bash -n`, `shellcheck`, pełne testy na obu wersjach basha |
| 8 | Blok komend do ręcznego uruchomienia (każda w jednej linii) |

### Otwarte decyzje

- Domyślny `WT_LINK`: teraz `.env .venv` (jak w prompcie). Opcja: `.env .env.local node_modules`. Dla FitDoctor `node_modules` ma być instalowane osobno w każdym worktree (`WT_POST_NEW=npm install`), więc `node_modules` nie powinno być w `WT_LINK`. Konfiguracja FitDoctor jest do zrobienia osobno.
- Czy `wt merge` ma przypominać o `npx cap sync ios` po zmianach w `ios/` lub `capacitor.config.*` (dodatek spoza promptu, nierozstrzygnięte).
- Konfiguracja pod FitDoctor (komenda testowa, `WT_DIR`, `WT_POST_NEW`) jeszcze nie ustawiona.
- Test na prawdziwym FitDoctor i z prawdziwym tmux nie był wykonany.

## 2. Zmodyfikowane pliki i ich zawartość

### `~/.local/bin/wt` (nowy, `chmod +x`)

Jedyny plik z kodem. Struktura:

- Nagłówek: `#!/usr/bin/env bash`, `set -uo pipefail`, wyciszenie SC2034 (zmienne czytane pośrednio przez `eval` na stałych nazwach kluczy).
- Wyjście: `die()` (stderr plus `exit 1`), `info()`.
- Config: `SAFE_KEYS`, `ALL_KEYS`, wartości domyślne `DEFAULT_*`, wartości efektywne `CFG_*` i źródła `SRC_*`, funkcje `set_cfg`, `parse_conf`, `load_config`.
- Repo i git: `repo_main`, `base_branch`, `resolve_wt_root`, `init_repo`, `norm_path`, `valid_name`, `tracked_clean`, `json_escape`, `add_exclude`, `owner_field`, `changed_files`, `detect_test_cmd`, `run_tests`.
- Komendy: `cmd_config`, `cmd_new`, `cmd_list`, `cmd_status`, `cmd_test`; `cmd_merge` i `cmd_drop` to na razie stuby ("jeszcze niezaimplementowana").
- Na końcu `case` dispatchujący komendy.

Zmienne globalne: `MAIN` (główny checkout), `BASE` (gałąź bazowa), `WT_ROOT` (rozwiązany katalog worktree).

### `~/.zshrc`

Nie zmieniony. Linia `export PATH="$HOME/.local/bin:$PATH"` już tam była (linia 27).

### Pliki w repozytorium

- `bin/wt`: źródło skryptu. Zainstalowana kopia to `~/.local/bin/wt` (na razie zwykła kopia pliku, bez symlinku, więc po zmianie w repo trzeba ją odświeżyć).
- `tests/test-wt.sh`: skrypt testowy. Uruchomienie: `bash tests/test-wt.sh [bash|/bin/bash]`. Domyślnie testuje `bin/wt` z repo, a zmienna `WT_BIN` pozwala wskazać inny plik. Każdy test działa na tymczasowym repo z `mktemp -d`, sprzątanym po zakończeniu.
- `docs/wt-manager.md`: ten dokument. Kopia robocza jest też w `~/moje_skroty/wt-manager.md`.

### Czego `wt` dotyka w repozytoriach

Tylko to, co wynika z komend. Nigdy `git add -A`, `reset --hard`, `push` ani force.

## 3. Komendy

### Dostępne teraz

| Komenda | Co robi pod spodem |
|---|---|
| `wt new <temat> [--no-fetch]` | Waliduje nazwę (regex `^[A-Za-z0-9][A-Za-z0-9._/-]*$`, bez `..`, `//`, końcowego `/` i `.lock`, plus `git check-ref-format`). Odmawia, gdy ścieżka lub gałąź istnieje albo baza ma zmiany w plikach trackowanych (pokazuje `git status --short`). Przed utworzeniem synchronizuje bazę z upstreamem (niżej). Wykonuje `git worktree add -b <temat> <WT_ROOT>/<temat> <baza>`. Linkuje symlinkami istniejące pliki z `WT_LINK`. Zapisuje `.wt-owner`. Dopisuje do `info/exclude`. Uruchamia `WT_POST_NEW`. Wypisuje gałąź, krótki hash bazy i `cd <ścieżka>` |
| `wt list` / `wt ls` | Czyta `git worktree list --porcelain`, pomija główny checkout. Kolumny: GALAZ, WIEK (`git log -1 --format=%cr`), AHEAD (`rev-list --count baza..gałąź`), BRUDNE (liczba linii `status --porcelain`), WLASCICIEL ("zajęty (pid N, panel)" jeśli `kill -0` na pid z `.wt-owner` się powiedzie, w przeciwnym razie "wolny") |
| `wt status` | Dla każdej pary worktree liczy wspólne zmienione pliki. Zmienione pliki to suma: `diff merge-base..HEAD`, `diff HEAD` i nietrackowane niezignorowane (`ls-files --others --exclude-standard`). Wypisuje `KOLIZJA a ↔ b:` z listą albo "brak wspólnych plików", na końcu `list`. Pliki tymczasowe w `mktemp -d`, sprzątane trapem EXIT |
| `wt test [args]` | Wybiera komendę testową: `WT_TEST` (zaufane źródła), potem pierwsza linia `.wt-test` w korzeniu worktree, potem autodetekcja. Uruchamia ją w korzeniu bieżącego worktree (`git rev-parse --show-toplevel`) z przekazaniem argumentów. Zwraca kod wyjścia komendy. Brak komendy to kod 127 z instrukcją |
| `wt config` | Pokazuje repo, bazę, katalog worktree oraz efektywne wartości wszystkich kluczy z informacją, skąd pochodzą |
| `wt` (bez argumentu) / nieznana komenda | Help na stderr (lista komend plus ścieżka repo), `exit 1` |

Autodetekcja komendy testowej (kolejność): `pnpm-lock.yaml` + `package.json` ze skryptem `test` → `pnpm test`; `package.json` ze skryptem `test` → `npm test`; `pyproject.toml` → `uv run pytest`; `Cargo.toml` → `cargo test`; `go.mod` → `go test ./...`; `Makefile` z celem `test` → `make test`. `package.json` bez skryptu `test` jest pomijany.

### Planowane

| Komenda | Plan |
|---|---|
| `wt merge <temat>` | (1) worktree czysty włącznie z nietrackowanymi, baza czysta w trackowanych, gałąź ma commity ponad bazą; (2) `wt test`, przy czerwonych błąd i baza nietknięta; (3) `git rebase <baza>` w worktree, przy konflikcie lista plików (`--diff-filter=U`) i instrukcja `--continue` / `--abort`; (4) `wt test` ponownie; (5) `git -C $MAIN merge --ff-only <temat>`, przy odmowie komunikat o powtórzeniu; (6) wypisanie nowego HEAD bazy i podpowiedź `wt drop`. Worktree zostaje |
| `wt drop <temat> [--yes]` | Bez `--yes` pokazuje rozmiar katalogu (bez symlinków), commity spoza bazy i niezacommitowane pliki, kończy błędem "nic nie usunięto". Z `--yes`: `git worktree remove --force`, gałąź kasowana przez `branch -d` tylko gdy wszystko jest na bazie, w przeciwnym razie zostaje i dostajesz instrukcję `branch -D` |

## 4. Konfiguracja: gdzie jest zapisywana

Nie ma żadnej globalnej mapy "repo X ma takie ustawienia". Konfiguracja jest w repo albo w jednym pliku globalnym z domyślnymi dla wszystkich repo.

| Miejsce | W gicie? | Jakie klucze | Kiedy używać |
|---|---|---|---|
| zmienna środowiskowa | nie | wszystkie | jednorazowe nadpisanie, np. `WT_DIR=... wt new x` |
| `<repo>/.git/wt.conf` | nie | wszystkie | Twoje prywatne ustawienia projektu. Znika razem z klonem |
| `<repo>/.wt.conf` | tak | tylko `WT_DIR`, `WT_BASE`, `WT_LINK` | wspólne dla zespołu. Klucze uruchamiające komendy są ignorowane z komunikatem |
| `<repo>/.wt-test` | tak | pierwsza linia = komenda testowa | wspólna komenda testowa. Linie puste i `#` są pomijane |
| `~/.config/wt/config` (lub `$XDG_CONFIG_HOME/wt/config`) | poza repo | wszystkie | Twoje domyślne dla wszystkich repo. Plik nie istnieje, dopóki go nie utworzysz |

Pierwszeństwo (od najsilniejszego): env, `.git/wt.conf`, `.wt.conf`, config globalny, wartości wbudowane. Dla komendy testowej: `WT_TEST`, potem `.wt-test`, potem autodetekcja.

Format: `KLUCZ=wartość`, jedna para na linię, komentarze `#`, opcjonalne cudzysłowy. Plik jest czytany własnym parserem, nigdy przez `source` ani `eval`.

| Klucz | Domyślnie | Znaczenie |
|---|---|---|
| `WT_DIR` | `.claude/worktrees` | katalog na worktree. Względny liczy się od głównego checkoutu, może wychodzić poza repo (`../x`) lub być absolutny |
| `WT_BASE` | puste (autodetekcja: `main`, `master`, bieżąca gałąź) | gałąź bazowa |
| `WT_LINK` | `.env .venv` | lista plików symlinkowanych z głównego checkoutu, tylko istniejące |
| `WT_FETCH` | `1` | `0` wyłącza synchronizację bazy z upstreamem w `wt new` (bezpieczny klucz, dozwolony też w `.wt.conf`) |
| `WT_TEST` | puste | komenda testowa (zaufane źródła) |
| `WT_POST_NEW` | puste | komenda po `wt new`, uruchamiana w nowym worktree (zaufane źródła). Przy błędzie worktree zostaje, a `wt new` zwraca ten sam kod wyjścia |

Zmienne środowiska czytane przez skrypt: `CLAUDE_SESSION_ID`, `TMUX_PANE`, `USER`, `XDG_CONFIG_HOME`, `WT_FETCH_TIMEOUT` (sekundy, domyślnie 20, limit czasu `git fetch`).

### Synchronizacja bazy w `wt new`

Baza to **lokalna** gałąź (`main`, `master` albo `WT_BASE`). Po sprawdzeniu, że baza jest czysta w plikach trackowanych, `wt new` robi (chyba że `--no-fetch` albo `WT_FETCH=0`):

1. Czyta upstream bazy z `branch.<baza>.remote` i `branch.<baza>.merge`. Brak upstreamu to informacja "brak upstreamu" i start z lokalnej bazy.
2. `git fetch <remote> <gałąź>` z limitem czasu (`FETCH_TIMEOUT`), bez pytań o hasło (`GIT_TERMINAL_PROMPT=0`). Polecenie działa we własnej grupie procesów, która po przekroczeniu limitu jest zabijana w całości (także zawieszony `ssh`).
3. Jeśli lokalna baza jest tylko **za** upstreamem, przewija ją do przodu: `git merge --ff-only` gdy baza jest wyciągnięta w głównym checkoucie, w przeciwnym razie `git fetch . <upstream>:refs/heads/<baza>` (przesuwa sam wskaźnik, bez ruszania plików).

| Sytuacja | Zachowanie |
|---|---|
| brak upstreamu | informacja, start z lokalnej bazy |
| fetch się nie udał (sieć, dostęp, limit czasu) | ostrzeżenie, start z lokalnej bazy, kod wyjścia 0 |
| baza zgodna z upstreamem | bez komunikatu |
| baza za upstreamem | przewinięcie i komunikat "zaktualizowana o N commit(ów)" |
| baza przed upstreamem | informacja o niewypchniętych commitach, start z lokalnej bazy |
| baza i upstream rozjechane | ostrzeżenie, nic nie zmieniam, start z lokalnej bazy |

`wt` nigdy nie robi `pull`, `push` ani merge innego niż `--ff-only`.

Przykładowy `.git/wt.conf` dla FitDoctor (do ustawienia):

```
WT_DIR=../fitdoctor-worktrees
WT_TEST=npm run test --workspace=nextjs-app
WT_POST_NEW=npm install
```

### Co `wt` zapisuje w repo i worktree

| Miejsce | Zawartość |
|---|---|
| `<WT_DIR>/<temat>/` | worktree (katalog z kodem) |
| `<worktree>/.wt-owner` | JSON: `session` (z `CLAUDE_SESSION_ID`), `pid` (to `$PPID`, czyli proces nadrzędny wywołujący `wt`, bo samo `wt` kończy się od razu), `pane` (z `TMUX_PANE`), `time`, `user` |
| `<worktree>/<link>` | symlinki do plików z `WT_LINK` |
| `<repo>/.git/info/exclude` | `.wt-owner`, `/<link>` dla każdego utworzonego symlinku (wzorzec `node_modules/` z `.gitignore` nie dopasowuje symlinka), a gdy `WT_DIR` leży w repo także `/<WT_DIR>/`. Wpisy są wspólne dla wszystkich worktree tego repo. Zapis chroniony blokadą `mkdir` (macOS nie ma `flock`) |
| `<repo>/.git/wt.lock` | chwilowy katalog blokady, usuwany po zapisie |

## 5. Przykładowy flow

### Pierwszy raz w nowym repo

```bash
# 1. wejdź do repo (główny checkout, gałąź bazowa czysta w plikach trackowanych)
cd ~/projekty/moje-repo

# 2. (opcjonalnie) sprawdź, co wt widzi
wt config

# 3. (opcjonalnie) ustaw prywatną konfigurację tego repo
cat >> .git/wt.conf <<'EOF'
WT_DIR=../moje-repo-worktrees
WT_TEST=npm test
WT_POST_NEW=npm install
EOF

# 4. utwórz worktree na feature
wt new auth-refactor
# wypisuje: gałąź, krótki hash bazy i linię "cd <ścieżka>"
```

### Praca nad featurem

```bash
cd ../moje-repo-worktrees/auth-refactor    # wejście do worktree (linia cd z kroku wyżej)
# ... edycje, normalne git add / git commit ...
wt test                                     # testy w tym worktree
wt status                                   # czy inne worktree nie ruszają tych samych plików
wt list                                     # przegląd: wiek, ahead, brudne, właściciel
```

### Kolejny feature, równolegle

```bash
cd ~/projekty/moje-repo                     # lub dowolny worktree tego repo; wt zawsze znajdzie główny checkout
wt new billing-fix                          # drugi worktree, druga sesja (osobny panel tmux)
wt status                                   # ostrzeże o KOLIZJI, jeśli oba ruszają te same pliki
```

### Powrót na bazę i sprzątanie (po slice 5 i 6)

```bash
cd ../moje-repo-worktrees/auth-refactor
git add <pliki> && git commit -m "..."      # worktree musi być czysty
wt merge auth-refactor                      # testy, rebase na bazę, testy, merge --ff-only
wt drop auth-refactor                       # bez --yes tylko podgląd
wt drop auth-refactor --yes                 # usunięcie worktree i gałęzi (gałąź tylko jeśli jest już na bazie)
```

### Zasady, o których warto pamiętać

- `wt new` próbuje najpierw zaktualizować lokalną bazę z upstreamu (patrz "Synchronizacja bazy"), ale nigdy nie blokuje się na błędach sieci.
- Nowy worktree powstaje od bazy, a baza nie może mieć niezacommitowanych zmian w plikach trackowanych. Nietrackowane pliki nie blokują.
- `wt merge` (po implementacji) nigdy nie zmieni bazy, jeśli testy są czerwone albo rebase ma konflikt.
- Wszystkie komendy działają z dowolnego miejsca repo, także z wnętrza worktree.
- Poza repo git każda komenda kończy się błędem "nie jesteś w repo git".
- Nieobsługiwane: repo bare, repo bez commitów, nazwy plików z nowym wierszem w `wt status`.
