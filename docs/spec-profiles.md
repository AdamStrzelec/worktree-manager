# Spec: profile worktree (tryby, akcje, tmux)

Status: szkic do akceptacji. Data: 2026-11-02.

## 1. Cel

Użytkownik definiuje w pliku JSON **tryby** pracy (np. `feature`, `review`, `bare`). Tryb to zestaw **akcji**: pliki do utworzenia, sesja tmux z oknami, komendy (np. `claude`, `lazygit`). `wt new` wykonuje akcje wybranego trybu, a `wt drop` je sprząta. UI pokazuje tryby, akcje i zmienne z czytelnymi opisami i pozwala je zmieniać.

### Poza zakresem v1

- Akcje uruchamiane w innych momentach niż `new`/`drop` (np. przy merge).
- Profile w plikach commitowanych do repo (`.wt.conf` nadal nie uruchamia komend).
- Linux: nie testujemy, nie blokujemy.
- Edycja pliku globalnego z UI (tylko podgląd + jawna opcja „zapisz jako globalne” w v2).

## 2. Pliki i warstwy

| Plik | Rola |
|---|---|
| `$XDG_CONFIG_HOME/wt/profiles.json` (domyślnie `~/.config/wt/profiles.json`) | globalne tryby, akcje, zmienne |
| `<repo>/.git/wt-profiles.json` | nadpisania per projekt; tu zapisuje UI |
| `<worktree>/.wt-actions` | stan: co zostało uruchomione przy `new` (płaski format, czytany przez bash przy `drop`) |

Scalanie: plik projektu nadpisuje globalny **po kluczu najwyższego poziomu w każdej sekcji** (`modes.<id>`, `actions.<id>`, `variables.<id>`, `prompts.<id>`) – całym obiektem, bez głębokiego merge. `defaultMode` z projektu wygrywa. Wartość `null` w pliku projektu usuwa klucz odziedziczony z globalnego.

Oba pliki są zaufanym źródłem (nie są commitowane), więc mogą zawierać komendy.

## 3. Schemat (version 1)

```json
{
  "version": 1,
  "defaultMode": "feature",
  "variables": {
    "model": {
      "label": "Model Claude",
      "description": "Model używany przez sesję claude w tmux",
      "choices": ["opus", "sonnet"],
      "default": "opus"
    }
  },
  "modes": {
    "feature": {
      "label": "Nowa funkcja",
      "description": "Sesja tmux z claude i lazygit",
      "actions": ["rules", "tmux", "claude", "git"]
    },
    "bare": { "label": "Sam worktree", "description": "Bez dodatków", "actions": [] }
  },
  "actions": {
    "rules": {
      "type": "file",
      "label": "Plik zasad",
      "description": "Tworzy RULES.md w worktree",
      "path": "RULES.md",
      "content": "Branch {branch}, baza {base}\n"
    },
    "tmux": {
      "type": "tmux-session",
      "label": "Sesja tmux",
      "description": "Sesja {session} w katalogu worktree",
      "attach": false
    },
    "claude": {
      "type": "tmux-window",
      "label": "Claude",
      "description": "Okno z claude",
      "window": "claude",
      "run": "claude --model {model}",
      "beforeDrop": { "sendKeys": "/exit" }
    },
    "git": { "type": "tmux-window", "label": "Git", "window": "git", "run": "lazygit" },
    "deps": { "type": "shell", "label": "Instalacja zależności", "run": "npm ci" }
  },
  "prompts": {
    "review": "Przejrzyj zmiany względem {base}."
  }
}
```

### Pola wspólne akcji

| Pole | Wymagane | Znaczenie |
|---|---|---|
| `type` | tak | `file`, `shell`, `tmux-session`, `tmux-window` |
| `label` | nie (domyślnie id) | nazwa w UI |
| `description` | nie | opis w UI, może zawierać placeholdery |
| `optional` | nie (`false`) | `true`: w UI domyślnie odznaczona |
| `needs` | nie | lista id akcji, które muszą się udać przed tą |

### Typy akcji

- **`file`**: `path` (względna, bez `..`, jak walidacja `WT_LINK`), `content`. Nie nadpisuje istniejącego pliku (komunikat jak przy `WT_COPY`). Ścieżka trafia do `info/exclude`, żeby `git worktree remove` nie odmówił.
- **`shell`**: `run`, wykonywane `bash -c` w katalogu worktree.

### Błędy akcji i zależności

- Pole `needs` (lista id akcji, które stoją wcześniej na liście trybu; to wyklucza cykle): akcja startuje tylko, gdy wszystkie z `needs` mają status `ok`; inaczej status `skipped`. `tmux-window` ma domyślną zależność od `tmux-session` trybu.
- Akcje bez zależności od nieudanej akcji wykonują się normalnie. Worktree nigdy nie jest usuwany ani cofany z powodu błędu akcji.
- Statusy: `ok`, `failed` (kod wyjścia), `skipped` (powód: której zależności brak). Zapisywane do `.wt-actions` po każdej akcji, z ostatnimi 20 liniami stderr; pełny log w `<worktree>/.wt-actions.log` (oba w `info/exclude`).
- Terminal: podsumowanie na końcu `wt new` (✓/✗/–), kod wyjścia != 0, gdy jakakolwiek akcja ma `failed`.
- UI: w szczegółach worktree sekcja „Akcje” ze statusami i końcówką błędu; znacznik `!` na liście.
- Cykl w `needs` lub odwołanie do akcji spoza trybu = błąd walidacji (przed utworzeniem worktree), podobnie JSON, zmienne, brak `tmux`/`python3`.
- `WT_POST_NEW` zachowuje dotychczasowe zachowanie.

- **`tmux-session`**: tworzy sesję `{session}` (`tmux new-session -d -s ... -c <worktree>`). Jeśli już istnieje, nic nie robi. `attach: true` przełącza na nią na końcu `new` (`switch-client` w tmux, poza tmux tylko komunikat z komendą `tmux attach -t ...`, bo `wt` nie może przejąć terminala UI). Brak `tmux` w PATH: błąd walidacji przed utworzeniem worktree.
- **`tmux-window`**: wymaga akcji `tmux-session` w tym samym trybie (inaczej błąd walidacji). Tworzy okno `window`, a `run` wysyła przez `send-keys` + Enter, żeby po wyjściu z programu została powłoka. Opcjonalne `beforeDrop.sendKeys`: tekst wysłany do okna przed zamknięciem sesji.

### Placeholdery

`{name}`, `{branch}`, `{path}`, `{base}`, `{repo}` (basename głównego checkoutu), `{mode}`, `{session}`, `{<zmienna>}`, `{prompt:<id>}`. Nieznany placeholder = błąd walidacji. Wartości wstawiane do `run` są shell-quotowane (ochrona przed nazwą gałęzi ze spacją lub `;`). `{{` i `}}` dają dosłowne `{` i `}`. Prompty mogą używać tylko placeholderów wbudowanych i zmiennych.

### Nazwa sesji tmux

`{session}` = `{repo}/{name}` z `.` i `:` zamienionymi na `-`. Liczona w jednym miejscu i zapisywana do `.wt-actions`, żeby `drop` nigdy nie liczył jej ponownie (naprawia rozjazd z obecnego przepisu w docs).

## 4. CLI

```
wt new <name> [--mode <id>] [--set var=value]... [--skip <action>]...
wt profiles               # lista trybów i akcji po scaleniu, ze źródłem (globalne/projekt)
wt profiles check         # walidacja, kod != 0 przy błędach
```

- Bez pliku profili i bez `--mode`: zachowanie dokładnie jak dziś, bez Pythona.
- Plik istnieje, brak `--mode`: używany `defaultMode`. Brak `defaultMode`: żadne akcje (jak `bare`).
- `--mode` bez pliku albo nieznany tryb: błąd, worktree nie powstaje.
- `--set` dla nieznanej zmiennej lub wartości spoza `choices`: błąd przed utworzeniem worktree.
- Profile użyte, a brak `python3`: błąd „profile wymagają python3”, worktree nie powstaje.
- Kolejność w `new`: worktree, `WT_LINK`/`WT_COPY`, `.wt-owner`, **akcje profilu w kolejności z `actions` trybu**, `WT_POST_NEW`.

### Podział bash / Python

`bin/wt-profiles resolve` (osobny plik Pythona bez curses, importowany też przez UI) wczytuje i scala pliki, waliduje je i wypisuje plan jako pola rozdzielone NUL (`rodzaj id (klucz wartość)* ""`), z wartościami już po podstawieniu placeholderów; rodzaj `action` albo `skip` (z powodem). `--skip` usuwa też akcje zależne (przechodnio). Bash tylko wykonuje plan. Cała logika JSON-a jest w jednym miejscu, testowalna w Pythonie.

## 5. Drop

`.wt-actions` (zapisywany przy `new`, dopisywany do `info/exclude`):

```
mode=feature
tmux_session=worktree-manager/feat-x
tmux_window=claude
tmux_sendkeys.claude=/exit
```

Kolejność w `wt drop` (bez `--check`):

1. Istniejące sprawdzenia (czyste drzewo, zmergowana gałąź).
2. `beforeDrop.sendKeys` dla każdego okna, potem odczekanie do 3 s, aż proces w oknie się skończy.
3. `tmux kill-session` (jeśli `drop` działa wewnątrz tej sesji: najpierw `switch-client -l`, a gdy nie ma poprzedniej sesji, kill przez `run-shell -b` po zakończeniu `wt`).
4. Istniejące sprawdzenie żywych procesów / `stop_procs` – teraz już bez claude z tmux.
5. `WT_PRE_DROP`, `git worktree remove`, `WT_POST_DROP`, usunięcie gałęzi (bez zmian).

Drop nie potrzebuje Pythona ani pliku profili; wystarczy `.wt-actions`. Brak pliku = brak sprzątania (worktree sprzed tej funkcji). Sesja już nie istnieje = cisza.

Do sprawdzenia przy implementacji: czy krok 4 (wykrywanie procesów) obecnie stoi przed punktem, w którym można zamknąć tmux; jeśli tak, przestawić tak, żeby zamknięcie sesji było przed nim.

## 6. UI (`wt ui`)

- `n` (nowy worktree): po nazwie ekran **Tryb** – lista trybów (`label`, pod spodem `description`, znacznik źródła). Gdy pliku brak, ekran pomijany.
- Następnie ekran **Akcje** dla wybranego trybu: checkbox per akcja (`label`, `description` z podstawionymi wartościami), lista zmiennych z wartością, `←/→` zmienia wartość w `choices`. Enter tworzy worktree z odpowiednimi `--set`/`--skip`.
- `P` (nowy ekran **Profile**): podgląd scalonej konfiguracji; edycja `defaultMode`, domyślnych wartości zmiennych i listy akcji w trybie. Zapis tylko do `.git/wt-profiles.json`, jako minimalne nadpisanie (tylko zmienione klucze). Błędy walidacji pokazane przy pozycji.
- `o` → `t`: przełączenie na sesję tmux worktree (z `.wt-actions`), dziś wyłączone.
- Edycja `run`/`content` w UI: poza v1 (to edytuje się w pliku; UI pokazuje ścieżkę pliku).

## 7. Walidacja (`wt profiles check` i przed każdym `new`)

- `version` = 1; nieznane pola najwyższego poziomu = ostrzeżenie, nieznany `type` = błąd.
- Tryb odwołuje się do istniejącej akcji; `tmux-window` wymaga `tmux-session` w trybie; nazwy okien unikalne w trybie.
- `default` zmiennej należy do `choices`; `defaultMode` istnieje.
- Ścieżki `file` względne, bez `..`.
- Niepoprawny JSON: komunikat z numerem linii i kolumny (z `json.JSONDecodeError`).

## 8. Testy

- `tests/test-wt.sh`: `new`/`drop` z profilami, tmux na osobnym serwerze (`tmux -L wt-test-$$`, zmienna `WT_TMUX_SOCKET` używana tylko przez testy), regresja: bez pliku profili zachowanie identyczne jak dziś.
- Testy Pythona dla `--resolve`: scalanie warstw, `null`, placeholdery, quoting, walidacja.
- UI: pty-smoke na ekranie Tryb/Akcje.

## 9. Plan wdrażania (pionowe kawałki)

1. `--resolve` + scalanie + walidacja + `wt profiles [check]`; testy Pythona.
2. `wt new --mode` z akcjami `file` i `shell`; `.wt-actions`; testy bash.
3. `tmux-session` / `tmux-window` + sprzątanie w `drop`; testy na osobnym serwerze tmux.
4. `beforeDrop.sendKeys` + obsługa drop z wnętrza sesji.
5. UI: ekrany Tryb i Akcje w `n`; `o` → `t`.
6. UI: ekran Profile z zapisem do `.git/`.
7. Docs (`docs/wt-manager.md`, README), przykładowy `profiles.json`.

## 10. Decyzje

1. Nazwa sesji: `{repo}/{name}`.
2. `attach` domyślnie `false`.
3. Błąd akcji blokuje tylko zależne (`needs`); reszta leci; bez rollbacku; status w terminalu i w UI.
4. Prompty w v1 tylko jako `{prompt:<id>}` w `run`.
