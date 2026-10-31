# wt: menedżer git worktree

`wt` to pojedynczy skrypt bash do pracy na wielu featurach równolegle. Każdy feature dostaje własny worktree (fizycznie osobne pliki), więc dwie sesje nie nadpisują sobie nawzajem zmian. Powrót na gałąź bazową ma iść jedną bramką: `wt merge` (testy, rebase, testy, `merge --ff-only`).

Pełny opis działania, konfiguracji i planów jest w [docs/wt-manager.md](docs/wt-manager.md).

## Stan projektu

| Komenda | Stan |
| --- | --- |
| `wt new`, `wt list`, `wt status`, `wt test`, `wt config` (też `set`/`unset`) | gotowe i przetestowane |
| `wt ui` | gotowe: interfejs w terminalu (wymaga `python3`), testowane tylko ręcznie i pty-smoke |
| `wt drop` | gotowe i przetestowane (patrz "Usuwanie worktree" niżej) |
| `wt merge` | jeszcze niezaimplementowane (komenda zwraca błąd "jeszcze niezaimplementowana"); zmergowanie robi się ręcznie gitem albo przez PR w `wt ui` |

## Wymagania

- `bash` 3.2 lub nowszy (domyślny `/bin/bash` na macOS wystarcza)
- `git` 2.31 lub nowszy (starszy też zadziała dzięki fallbackowi, ale nie był testowany)
- macOS. Testy przechodziły na macOS (bash 3.2 i bash 5.3). Na Linuksie skrypt nie był jeszcze uruchamiany, więc jego działanie tam nie jest potwierdzone.
- opcjonalnie `shellcheck` (tylko do rozwijania skryptu) i `tmux`

## Instalacja

Skrypt to `bin/wt` plus `bin/wt-ui` (interfejs `wt ui`, Python 3, bez zależności). `wt ui` szuka `wt-ui` obok prawdziwego pliku `wt`, więc przy kopiowaniu skopiuj oba pliki. Zalecana instalacja to symlink, bo `git pull` aktualizuje wtedy zainstalowaną wersję automatycznie.

```bash
git clone https://github.com/AdamStrzelec/worktree-manager ~/repozytoria/worktree-manager
```

```bash
cd ~/repozytoria/worktree-manager && mkdir -p ~/.local/bin && ln -sf "$(pwd)/bin/wt" ~/.local/bin/wt
```

Upewnij się, że `~/.local/bin` jest w `PATH`. Sprawdź:

```bash
command -v wt
```

Jeśli nic nie wypisze, dodaj katalog do `PATH` (zsh):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Dla bash użyj `~/.bashrc` (Linux) albo `~/.bash_profile` (macOS) zamiast `~/.zshrc`. Jeśli linia już tam jest, nie dopisuj jej drugi raz.

Weryfikacja instalacji (w dowolnym repo git):

```bash
cd <jakies-repo> && wt config
```

Powinno wypisać repo, gałąź bazową, katalog worktree i tabelę ustawień. Poza repo git dostaniesz komunikat "nie jesteś w repo git", co jest poprawnym zachowaniem.

## Szybki start

```bash
cd <twoje-repo>
```

Baza musi być czysta w plikach trackowanych (nietrackowane pliki nie przeszkadzają). Potem:

```bash
wt new moj-feature
```

Komenda tworzy gałąź `moj-feature` od gałęzi bazowej (`main`, a jak jej nie ma, `master`) i worktree w `<repo>/.claude/worktrees/moj-feature`. Na końcu wypisuje linię `cd <ścieżka>`.

Zanim worktree powstanie, `wt new` pobiera zmiany ze zdalnego repo (`git fetch`) i, jeśli lokalna baza jest tylko w tyle, przewija ją do przodu (`--ff-only`). Brak upstreamu, brak sieci albo rozjazd historii nie przerywają działania: worktree powstaje wtedy z lokalnej bazy, z ostrzeżeniem. Pomija się to flagą `wt new moj-feature --no-fetch` albo `WT_FETCH=0` w configu. Szczegóły w [docs/wt-manager.md](docs/wt-manager.md). Wejdź tam i pracuj normalnie gitem:

```bash
cd <ścieżka z ostatniej linii>
```

Przydatne komendy podczas pracy:

```bash
wt test
```

```bash
wt list
```

```bash
wt status
```

- `wt test` uruchamia testy w bieżącym worktree (komenda z konfiguracji, z pliku `.wt-test` albo wykryta automatycznie).
- `wt list` pokazuje worktree: wiek ostatniego commita, liczbę commitów ponad bazą, liczbę brudnych plików i właściciela.
- `wt status` wykrywa kolizje: pliki zmieniane jednocześnie w więcej niż jednym worktree.
- `wt ui` otwiera interfejs: lista worktree po lewej, szczegóły i kolizje po prawej. Klawisze: `j`/`k` lub strzałki, `g`/`G`, `n` nowy worktree, `t` testy, `c` podmenu Kopiuj (`cd`, URL PR), `o` podmenu Otwórz (VS Code, PR w przeglądarce), `p` otwiera podmenu PR (push/PR, draft/ready, merge, merge + usuń, zamknij), `x` usuń worktree, `C` ekran konfiguracji, `Space` menu skrótów, `r` odśwież, `/` filtr, `q` wyjście. Pełna lista w [docs/wt-manager.md](docs/wt-manager.md).
- `wt list --porcelain` daje wyjście dla skryptów: ścieżka, gałąź, wiek, ahead, brudne, właściciel, rozdzielone tabulatorem.

Komendy działają z dowolnego miejsca repo, także z wnętrza worktree.

## Konfiguracja (opcjonalna)

Bez żadnej konfiguracji `wt` działa na wartościach domyślnych. Ustawienia konkretnego repo możesz trzymać w prywatnym pliku `.git/wt.conf` (nie jest wersjonowany):

```
WT_DIR=../moje-repo-worktrees
WT_TEST=npm test
WT_POST_NEW=npm install
```

| Klucz | Domyślnie | Znaczenie |
| --- | --- | --- |
| `WT_DIR` | `.claude/worktrees` | gdzie tworzyć worktree (względem głównego checkoutu albo absolutnie) |
| `WT_BASE` | autodetekcja | gałąź bazowa |
| `WT_LINK` | `.env .venv` | pliki symlinkowane z głównego checkoutu do nowego worktree |
| `WT_COPY` | brak | pliki KOPIOWANE z głównego checkoutu (np. `.env.local`), niezależne od oryginału, bez nadpisywania |
| `WT_FETCH` | `1` | `0` wyłącza pobieranie zmian z upstreamu przed `wt new` |
| `WT_TEST` | brak (autodetekcja) | komenda testowa |
| `WT_POST_NEW` | brak | komenda uruchamiana po `wt new` w nowym worktree |
| `WT_PRE_DROP` | brak | komenda przed `wt drop`; błąd blokuje usunięcie |
| `WT_POST_DROP` | brak | komenda po udanym usunięciu worktree; błąd tylko ostrzega |

Wspólne ustawienia całego zespołu mogą trafić do `.wt.conf` w repo, ale tylko klucze `WT_DIR`, `WT_BASE`, `WT_LINK`, `WT_COPY` i `WT_FETCH`. Komendy (`WT_TEST`, `WT_POST_NEW`, `WT_PRE_DROP`, `WT_POST_DROP`) są z tego pliku ignorowane ze względów bezpieczeństwa. Wspólną komendę testową zapisz w pliku `.wt-test` (jedna linia).

Sprawdzenie, co jest ustawione i skąd pochodzi każda wartość:

```bash
wt config
```

Zmiana wartości bez ręcznej edycji pliku (zapis do prywatnego `.git/wt.conf`): `wt config set KLUCZ WARTOŚĆ`, `wt config unset KLUCZ`, albo klawisz `C` w `wt ui`. Hooki `drop` dostają zmienne `WT_NAME`, `WT_PATH`, `WT_BRANCH`, `WT_MAIN`; przepis na sesję tmux jest w [docs/wt-manager.md](docs/wt-manager.md).

## Usuwanie worktree i akcje na PR

`wt drop <temat>` usuwa worktree (`git worktree remove`, bez force) i gałąź (`git branch -d`, nigdy `-D`) oraz kasuje `branch.<n>.wt-*` z configu. Odmawia, gdy: są niezacommitowane zmiany, gałąź ma commity niezmergowane do targetu (`wt-target`, a bez niego bazy), właściciel (`.wt-owner`) żyje (poza procesem, który sam wywołuje `drop`), albo stoisz w tym worktree. Odmawia też, gdy w worktree działają procesy (np. `npm run dev`; wykrywane przez `lsof`); `--stop-procs` zatrzymuje je SIGTERM-em i dopiero usuwa (w `wt ui` pyta o to po błędzie). Opcje: `--check` (tylko sprawdza, nic nie usuwa), `--merged-pr` (wywołujący zapewnia, że PR jest zmergowany na GitHubie, więc commity niezmergowane lokalnie są dozwolone; gałąź i tak musi być zmergowana do swojego upstreamu lub HEAD, bo inaczej `branch -d` odmówi).

W `wt ui` na sfokusowanym worktree klawisz `p` otwiera podmenu PR (`x` usuwa worktree wprost; wszystko też pod Spacją). Każda akcja pokazuje modal z opisem i dokładną komendą, a błędy trafiają do czerwonego modala:

| W podmenu `p` | Akcja |
| --- | --- |
| `p` | `git push -u origin <gałąź>` i, jeśli nie ma otwartego PR, `gh pr create --draft` (base z `wt-target`, tytuł z `wt-title` lub nazwa gałęzi) |
| `d` | draft <-> ready (`gh pr ready` / `--undo`) |
| `m` | `gh pr merge <nr> --merge` (tylko otwarty, nie draft, bez konfliktów, CI nie czerwone) |
| `x` | `wt drop` (z `--merged-pr`, gdy PR jest zmergowany) |
| `M` | sprawdzenie `wt drop --check`, merge PR, potem `wt drop` |
| `c` | zamknięcie PR |

Push i `gh` żyją wyłącznie w `wt-ui`, po potwierdzeniu, nigdy z force. Stan PR zawsze pochodzi z GitHuba (po akcji UI odpytuje `gh` ponownie). Wymaga `gh` w PATH i `gh auth login`; bez tego akcje na PR pokazują czytelny błąd (sam push działa bez `gh`).

## Sprzątanie ręczne

Zmergowanie gałęzi na bazę i usunięcie worktree możesz też zrobić ręcznie, z głównego checkoutu:

```bash
git merge --ff-only moj-feature
```

```bash
git worktree remove <ścieżka-worktree> && git branch -d moj-feature
```

Skrypt `bin/wt` nigdy nie robi `push`, `reset --hard`, `git add -A` ani force; push i `gh` to jawne akcje w `wt ui`.

## Aktualizacja i odinstalowanie

Przy instalacji przez symlink wystarczy zaktualizować repo:

```bash
git -C ~/repozytoria/worktree-manager pull
```

Odinstalowanie usuwa tylko symlink. Worktree i gałęzie utworzone w Twoich repo zostają:

```bash
rm ~/.local/bin/wt
```

W każdym repo, w którym używałeś `wt`, w pliku `.git/info/exclude` zostają wpisy dodane przez `wt new` (`.wt-owner`, symlinki, katalog worktree). Są nieszkodliwe, można je usunąć ręcznie.

## Testy

Testy działają na tymczasowych repo (`mktemp -d`) i nie dotykają Twoich projektów. Uruchamiają skrypt `bin/wt` z tego repo, nie zainstalowaną kopię.

```bash
bash tests/test-wt.sh
```

Test pod bashem 3.2 (macOS):

```bash
bash tests/test-wt.sh /bin/bash
```

Wynik kończy się linią `WYNIK: N ok, 0 fail`. Zmienna `WT_BIN` pozwala wskazać inny plik skryptu do przetestowania.

Analiza statyczna (jeśli masz zainstalowany `shellcheck`):

```bash
shellcheck -s bash bin/wt
```

## Ograniczenia

- Repo bare i repo bez żadnego commita nie są obsługiwane.
- `wt status` nie obsługuje nazw plików zawierających znak nowej linii.
- `wt new` odmawia przy niezacommitowanych zmianach w plikach trackowanych bazy.
- Synchronizacja bazy korzysta z `perl` (limit czasu `git fetch`). Bez `perl` fetch działa bez limitu czasu.
- Pole `pid` w `.wt-owner` to proces nadrzędny wywołujący `wt` (powłoka lub sesja), a nie sam `wt`, który kończy się od razu.
