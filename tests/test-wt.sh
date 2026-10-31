#!/usr/bin/env bash
# Test harness for wt. Usage: test-wt.sh [bash-binary]  (WT_BIN overrides the script under test)
set -u
SH=${1:-bash}
WT_BIN=${WT_BIN:-$(cd "$(dirname "$0")/.." && pwd -P)/bin/wt}
WT="$SH $WT_BIN"
PASS=0 FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { # check DESC CMD... (expects success)
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
check_fail() { # check_fail DESC CMD... (expects non-zero)
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi
}
contains() { # contains DESC HAYSTACK NEEDLE
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (brak '$3' w: $2)" ;; esac
}

mkrepo() {
  local t
  t=$(mktemp -d) || exit 1
  t=$(cd "$t" && pwd -P)
  git -C "$t" init -q -b main
  git -C "$t" config user.name t
  git -C "$t" config user.email t@t
  printf 'a\n' > "$t/a.txt"
  git -C "$t" add a.txt
  git -C "$t" commit -q -m init
  printf '%s' "$t"
}

echo "== bash: $SH =="
R=$(mkrepo)
trap 'rm -rf "$R"' EXIT
cd "$R" || exit 1

echo "-- usage"
out=$($WT 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "help exit 1" || bad "help exit $rc"
contains "help lista komend" "$out" "new <temat>"
$WT bogus >/dev/null 2>&1; [ $? -eq 1 ] && ok "nieznana komenda exit 1" || bad "nieznana komenda"

echo "-- new: walidacja"
check_fail "zła nazwa (spacja)" $WT new "a b"
check_fail "zła nazwa (..)" $WT new "a/../b"
check_fail "zła nazwa (start -)" $WT new "-x"
check_fail "brak argumentu" $WT new

echo "-- new: sukces"
touch .env
printf 'WT_LINK=.env .nieistnieje\n' > .git/wt.conf
out=$(TMUX_PANE=%7 CLAUDE_SESSION_ID=sess-1 $WT new feat-a 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "new exit 0" || bad "new exit $rc: $out"
contains "new pokazuje gałąź" "$out" "gałąź: feat-a"
contains "new pokazuje cd" "$out" "cd $R/.claude/worktrees/feat-a"
check "worktree istnieje" test -d .claude/worktrees/feat-a
check "gałąź istnieje" git rev-parse --verify -q refs/heads/feat-a
check "symlink .env" test -L .claude/worktrees/feat-a/.env
check_fail "brak linku dla nieistniejącego" test -e .claude/worktrees/feat-a/.nieistnieje
own=$(cat .claude/worktrees/feat-a/.wt-owner)
contains "owner: sesja" "$own" '"session":"sess-1"'
contains "owner: pane" "$own" '"pane":"%7"'
contains "owner: pid" "$own" '"pid":'
check "exclude: .wt-owner" grep -qxF ".wt-owner" .git/info/exclude
check "exclude: katalog worktree" grep -qxF "/.claude/worktrees/" .git/info/exclude
check "exclude: symlink .env" grep -qxF "/.env" .git/info/exclude
[ -z "$(git status --porcelain)" ] && ok "git status czysty w bazie" || bad "git status brudny: $(git status --porcelain)"
[ -z "$(git -C .claude/worktrees/feat-a status --porcelain)" ] && ok "git status czysty w worktree" || bad "worktree brudny"

echo "-- new: odmowy"
check_fail "ścieżka/gałąź już istnieje" $WT new feat-a
git branch other
check_fail "gałąź istnieje bez worktree" $WT new other
echo b >> a.txt
out=$($WT new feat-dirty 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "odmowa przy brudnej bazie" || bad "brudna baza zaakceptowana"
contains "pokazuje status --short" "$out" "M a.txt"
git checkout -q a.txt
echo junk > untracked.txt
check "nietrackowane nie blokują" $WT new feat-b
rm untracked.txt

echo "-- new: zagnieżdżona nazwa i WT_DIR poza repo"
check "nazwa z /" $WT new area/feat-c
check "katalog area/feat-c" test -d .claude/worktrees/area/feat-c
EXT=$(mktemp -d); EXT=$(cd "$EXT" && pwd -P)
printf 'WT_DIR=%s\nWT_LINK=.env\n' "$EXT/wts" > .git/wt.conf
check "WT_DIR absolutny" $WT new feat-ext
check "worktree poza repo" test -d "$EXT/wts/feat-ext"
check_fail "bez wpisu exclude dla zewn. katalogu" grep -q "$EXT" .git/info/exclude
rm -rf "$EXT"
git worktree prune

echo "-- new: WT_POST_NEW"
printf 'WT_POST_NEW=touch post-ran\n' > .git/wt.conf
check "post_new ok" $WT new feat-post
check "post_new wykonany" test -f .claude/worktrees/feat-post/post-ran
printf 'WT_POST_NEW=exit 3\n' > .git/wt.conf
out=$($WT new feat-postfail 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "post_new błąd = exit 3" || bad "post_new błąd exit $rc"
check "worktree zostaje po błędzie post_new" test -d .claude/worktrees/feat-postfail
rm .git/wt.conf

echo "-- list"
out=$($WT list 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "list exit 0" || bad "list exit $rc"
contains "nagłówek" "$out" "GALAZ"
contains "wiersz feat-a" "$out" "feat-a"
contains "wiersz zagnieżdżony" "$out" "area/feat-c"
case "$out" in *"main"*) bad "list pokazuje główny checkout" ;; *) ok "list pomija główny checkout" ;; esac
echo x > .claude/worktrees/feat-a/new.txt
git -C .claude/worktrees/feat-a add new.txt
git -C .claude/worktrees/feat-a commit -q -m c1
echo y > .claude/worktrees/feat-a/dirty.txt
line=$($WT ls 2>&1 | grep '^feat-a ')
contains "ahead=1" "$line" " 1 "
contains "brudne=1" "$line" " 1 "
contains "właściciel zajęty (żyje pid $$?)" "$line" "wolny"
# live owner: write own pid
printf '{"session":"","pid":%s,"pane":"%%9","time":"x","user":"u"}\n' "$$" > .claude/worktrees/feat-a/.wt-owner
line=$($WT list 2>&1 | grep '^feat-a ')
contains "właściciel zajęty" "$line" "zajęty (pid $$, %9)"

echo "-- błędy na czerwono"
out=$(WT_COLOR=always $WT new "a b" 2>&1)
case "$out" in *$'\033[31mwt: '*$'\033[0m'*) ok "die: czerwony przy WT_COLOR=always" ;; *) bad "die: brak koloru: $out" ;; esac
out=$(WT_COLOR=always NO_COLOR=1 $WT new "a b" 2>&1)
case "$out" in *$'\033'*) bad "NO_COLOR ignorowany" ;; *) ok "NO_COLOR wyłącza kolor" ;; esac
out=$($WT new "a b" 2>&1)
case "$out" in *$'\033'*) bad "kolor bez tty" ;; *) ok "bez tty brak kolorów" ;; esac

echo "-- list --porcelain"
out=$($WT list --porcelain 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "porcelain exit 0" || bad "porcelain exit $rc"
line=$(printf '%s\n' "$out" | grep "	feat-a	")
contains "porcelain ścieżka" "$line" "$R/.claude/worktrees/feat-a	feat-a"
n=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
[ "$n" -eq 6 ] && ok "porcelain 6 pól" || bad "porcelain pól: $n"
case "$out" in *GALAZ*) bad "porcelain bez nagłówka" ;; *) ok "porcelain bez nagłówka" ;; esac
check_fail "list: nieznana opcja" $WT list --nope

echo "-- new: --target / --title"
git branch dev-x
out=$($WT new feat-t --target dev-x --title "Mój tytuł" --no-fetch 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "new --target/--title exit 0" || bad "new --target exit $rc: $out"
contains "new od gałęzi docelowej" "$out" "od dev-x"
[ "$(git config branch.feat-t.wt-target)" = dev-x ] && ok "target zapisany w git config" || bad "target w config"
[ "$(git config branch.feat-t.wt-title)" = "Mój tytuł" ] && ok "tytuł zapisany w git config" || bad "tytuł w config"
check_fail "new --target nieistniejąca gałąź" $WT new feat-u --target brak-takiej --no-fetch
check_fail "new --target bez wartości" $WT new feat-u --target
git worktree remove --force .claude/worktrees/feat-t && git branch -q -D feat-t
[ -z "$(git config --get branch.feat-t.wt-target)" ] && ok "config znika z gałęzią" || bad "config został po usunięciu gałęzi"

echo "-- ui"
UIBIN=$(dirname "$WT_BIN")/wt-ui
check "wt-ui istnieje i jest wykonywalny" test -x "$UIBIN"
check "wt-ui kompiluje się" python3 -m py_compile "$UIBIN"
out=$(python3 - "$UIBIN" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("wt_ui", sys.argv[1])
spec = importlib.util.spec_from_loader("wt_ui", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
rows = m.parse_list("/p/a\tfeat-a\t2 hours ago\t3\t1\tzajęty (pid 5, %1)\nśmieci\n")
assert len(rows) == 1 and rows[0]["branch"] == "feat-a" and rows[0]["owner"].startswith("zajęty"), rows
c = m.parse_collisions("KOLIZJA a ↔ b:\n  x.txt\n  y/z.txt\nbrak\n")
assert c["a"][0][0] == "b" and c["b"][0][0] == "a" and c["a"][0][1] == ["x.txt", "y/z.txt"], c
assert m.parse_base("repo:  /r\nbaza:  main\n") == "main"
import json, tempfile, os, time
assert m.parse_branch_config("branch.feat.x.wt-title Moj task\nbranch.b.wt-title \n", "wt-title") == {"feat.x": "Moj task"}
assert m.fmt_age(None) == "?" and m.fmt_age(100, 130) == "teraz" and m.fmt_age(0, 7200) == "2h" and m.fmt_age(0, 86400 * 3) == "3d"
d = tempfile.mkdtemp()
open(os.path.join(d, ".wt-owner"), "w").write('{"pid":1,"time":"2020-01-02T03:04:05+0000"}')
assert abs(m.created_ts(d) - 1577934245) < 1
assert m.created_ts(d + "/nie-ma") is None
ok_ = {"conclusion": "SUCCESS", "status": "COMPLETED"}
assert m.ci_state([]) == "none" and m.ci_state([ok_]) == "green"
assert m.ci_state([ok_, {"status": "IN_PROGRESS", "conclusion": ""}]) == "yellow"
assert m.ci_state([ok_, {"status": "COMPLETED", "conclusion": "FAILURE"}, {"status": "QUEUED"}]) == "red"
assert m.ci_state([{"state": "PENDING"}]) == "yellow" and m.ci_state([{"state": "ERROR"}]) == "red"
prs = m.parse_prs(json.dumps([
    {"number": 5, "headRefName": "a", "isDraft": False, "state": "MERGED", "mergeable": "UNKNOWN", "statusCheckRollup": []},
    {"number": 9, "headRefName": "a", "isDraft": True, "state": "OPEN", "mergeable": "CONFLICTING", "statusCheckRollup": [ok_]},
    {"number": 7, "headRefName": "b", "isDraft": False, "state": "CLOSED"}, {"headRefName": "x"}, "junk"]))
assert prs["a"]["number"] == 9 and prs["a"]["draft"] and prs["a"]["ci"] == "green" and prs["a"]["mergeable"] == "CONFLICTING", prs
assert prs["b"]["state"] == "CLOSED" and "x" not in prs
assert m.parse_prs("nie json") == {} and m.parse_prs("{}") == {}
assert m.check_list([{"name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"}, {"context": "ci/x", "state": "PENDING"}, "x"]) == [("build", "green"), ("ci/x", "yellow")]
assert m.parse_conflict_files("abc123\nsrc/a.txt\nb.txt\n\nAuto-merging") == ["src/a.txt", "b.txt"] and m.parse_conflict_files("abc") == []
print("PARSERY-OK")
PY
)
contains "parsery wt-ui" "$out" "PARSERY-OK"
LD=$(mktemp -d)
ln -s "$WT_BIN" "$LD/wt"
out=$(cd "$R" && "$SH" "$LD/wt" ui </dev/null 2>&1); rc=$?
case "$out" in *"brak pliku"*) bad "ui przez symlink nie znalazł wt-ui: $out" ;; *) ok "ui przez symlink znajduje wt-ui" ;; esac
rm -rf "$LD"
CP=$(mktemp -d); cp "$WT_BIN" "$CP/wt"
out=$(cd "$R" && "$SH" "$CP/wt" ui 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "ui bez wt-ui obok: błąd" || bad "ui bez wt-ui obok: rc=$rc"
contains "ui bez wt-ui komunikat" "$out" "brak pliku"
rm -rf "$CP"

echo "-- z wnętrza worktree"
out=$(cd .claude/worktrees/feat-a && $WT list 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "list z worktree" || bad "list z worktree exit $rc"
contains "ten sam wynik" "$out" "area/feat-c"
out=$(cd .claude/worktrees/feat-a && $WT new from-inside 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "new z worktree" || bad "new z worktree: $out"
check "worktree w MAIN, nie zagnieżdżony" test -d .claude/worktrees/from-inside

echo "-- test: wykrywanie i uruchamianie"
T3=$(mkrepo)
cd "$T3" || exit 1
out=$($WT test 2>&1); rc=$?
[ "$rc" -eq 127 ] && ok "brak komendy = exit 127" || bad "brak komendy exit $rc"
contains "instrukcja .wt-test" "$out" ".wt-test"

printf 'printf "args=%%s\\n"\n' > .wt-test
out=$($WT test a "b c" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok ".wt-test exit 0" || bad ".wt-test exit $rc"
contains "przekazuje arg 1" "$out" "args=a"
contains "przekazuje arg ze spacją" "$out" "args=b c"

printf '# komentarz\n\nexit 5\n' > .wt-test
$WT test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "propaguje kod wyjścia 5 (pomija komentarz)" || bad "kod wyjścia $rc"

printf 'pwd -P\n' > .wt-test
git add .wt-test && git commit -q -m t
$WT new t3 >/dev/null 2>&1
mkdir -p .claude/worktrees/t3/sub
out=$(cd .claude/worktrees/t3/sub && $WT test 2>/dev/null)
[ "$out" = "$T3/.claude/worktrees/t3" ] && ok "cwd = korzeń worktree" || bad "cwd='$out'"

printf 'echo z-env\n' > .git/wt.conf
printf 'WT_TEST=echo z-configu\n' > .git/wt.conf
out=$($WT test 2>&1); contains "WT_TEST z .git/wt.conf wygrywa z .wt-test" "$out" "z-configu"
out=$(WT_TEST='echo z-env' $WT test 2>&1); contains "env wygrywa z configiem" "$out" "z-env"
rm .git/wt.conf .wt-test

detect() { # detect DESC FILE-SETUP EXPECTED
  local d R3 o
  R3=$(mkrepo); (
    cd "$R3" || exit 1
    eval "$2"
    $WT test 2>&1
  ) > "$R3.out" 2>&1
  o=$(cat "$R3.out")
  contains "$1" "$o" "$3"
  rm -rf "$R3" "$R3.out"
}
detect "npm test" 'printf "{\"scripts\":{\"test\":\"echo npm-ran\"}}" > package.json' "wt test: npm test"
detect "pnpm test" 'printf "{\"scripts\":{\"test\":\"x\"}}" > package.json; touch pnpm-lock.yaml' "wt test: pnpm test"
detect "package.json bez skryptu test = brak" 'printf "{\"scripts\":{}}" > package.json' "nie wykryto"
detect "uv run pytest" 'touch pyproject.toml' "wt test: uv run pytest"
detect "cargo test" 'touch Cargo.toml' "wt test: cargo test"
detect "go test" 'touch go.mod' "wt test: go test ./..."
detect "make test" 'printf "test:\n\t@echo make-ran\n" > Makefile' "make-ran"
detect "Makefile bez celu test = brak" 'printf "build:\n\t@true\n" > Makefile' "nie wykryto"
cd "$R" || exit 1
rm -rf "$T3"

echo "-- status"
T4=$(mkrepo)
cd "$T4" || exit 1
printf 's\n' > shared.txt; printf 'm\n' > "my file.txt"
git add -A >/dev/null; git commit -q -m files
out=$($WT status 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "status bez worktree exit 0" || bad "status exit $rc"
contains "mniej niż dwa (0)" "$out" "mniej niż dwa worktree"
$WT new s1 >/dev/null 2>&1; $WT new s2 >/dev/null 2>&1; $WT new s3 >/dev/null 2>&1
W=$T4/.claude/worktrees
# s1: committed change; s2: uncommitted change to same files + untracked u.txt; s3: untracked u.txt only
echo c1 >> "$W/s1/shared.txt"; echo c1 >> "$W/s1/my file.txt"
git -C "$W/s1" commit -q -am s1
echo c2 >> "$W/s2/shared.txt"; echo c2 >> "$W/s2/my file.txt"; echo u > "$W/s2/u.txt"
echo u > "$W/s3/u.txt"
TD=$(mktemp -d)
out=$(TMPDIR=$TD $WT status 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "status exit 0" || bad "status exit $rc"
contains "kolizja s1 ↔ s2" "$out" "KOLIZJA s1 ↔ s2:"
contains "plik wspólny shared.txt" "$out" "  shared.txt"
contains "plik ze spacją" "$out" "  my file.txt"
contains "kolizja s2 ↔ s3 (nietrackowane)" "$out" "KOLIZJA s2 ↔ s3:"
contains "u.txt wspólny" "$out" "  u.txt"
case "$out" in *"KOLIZJA s1 ↔ s3"*) bad "fałszywa kolizja s1 ↔ s3" ;; *) ok "brak kolizji s1 ↔ s3" ;; esac
contains "status kończy się listą" "$out" "GALAZ"
[ -z "$(ls -A "$TD")" ] && ok "trap EXIT sprząta tmp" || bad "tmp nie wyczyszczony: $(ls -A "$TD")"
rm -rf "$TD"
# no-collision case: disjoint files
git -C "$W/s2" checkout -q -- . ; rm -f "$W/s2/u.txt" "$W/s3/u.txt"
echo only3 > "$W/s3/only3.txt"; echo only2 > "$W/s2/only2.txt"
git -C "$W/s1" reset -q --hard HEAD~1 2>/dev/null
out=$($WT status 2>&1)
contains "brak wspólnych plików" "$out" "brak wspólnych plików"
case "$out" in *KOLIZJA*) bad "kolizja mimo rozłącznych plików" ;; *) ok "żadnej kolizji" ;; esac
cd "$R" || exit 1
rm -rf "$T4"

echo "-- new: synchronizacja bazy z upstreamem"
FC=""
mkbare_remote() { # mkbare_remote REPO: bare remote as origin, main pushed with upstream
  local b
  b=$(mktemp -d); b=$(cd "$b" && pwd -P)
  git init -q --bare -b main "$b"
  git -C "$1" remote add origin "$b"
  git -C "$1" push -q -u origin main 2>/dev/null
  printf '%s' "$b"
}
remote_commit() { # remote_commit BARE FILE TEXT: push a commit from a throwaway clone, print its sha
  local c
  c=$(mktemp -d)
  git clone -q "$1" "$c/c" 2>/dev/null
  git -C "$c/c" config user.name t; git -C "$c/c" config user.email t@t
  printf '%s\n' "$3" > "$c/c/$2"
  git -C "$c/c" add "$2"; git -C "$c/c" commit -q -m "remote $2"
  git -C "$c/c" push -q origin main 2>/dev/null
  git -C "$c/c" rev-parse HEAD
  rm -rf "$c"
}
fresh() { FR=$(mkrepo); FB=$(mkbare_remote "$FR"); FC="$FC $FR $FB"; cd "$FR" || exit 1; }

fresh; out=$($WT new f-none 2>&1)
contains "up-to-date: bez komunikatów o zmianie" "$out" "cd $FR"
case "$out" in *zaktualizowana*|*UWAGA*) bad "up-to-date: niepotrzebny komunikat: $out" ;; *) ok "up-to-date: cisza" ;; esac

fresh; sha=$(remote_commit "$FB" r1.txt one)
out=$($WT new f-ahead 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "zdalny do przodu: exit 0" || bad "exit $rc: $out"
contains "komunikat o aktualizacji" "$out" "zaktualizowana o 1 commit(ów)"
[ "$(git rev-parse main)" = "$sha" ] && ok "lokalny main przewinięty" || bad "main nie przewinięty"
[ "$(git -C .claude/worktrees/f-ahead rev-parse HEAD)" = "$sha" ] && ok "worktree od nowego commita" || bad "worktree od starego commita"
check "plik zdalny w głównym checkoucie" test -f r1.txt
check "plik zdalny w worktree" test -f .claude/worktrees/f-ahead/r1.txt

fresh; git checkout -q -b other; sha=$(remote_commit "$FB" r2.txt two)
out=$($WT new f-nocheck 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "main nie wyciągnięty: exit 0" || bad "exit $rc: $out"
[ "$(git rev-parse main)" = "$sha" ] && ok "ref main przesunięty" || bad "ref main nie przesunięty: $out"
[ "$(git symbolic-ref --short HEAD)" = other ] && ok "główny checkout został na other" || bad "checkout się zmienił"
check_fail "pliki głównego checkoutu nietknięte" test -f r2.txt
[ "$(git -C .claude/worktrees/f-nocheck rev-parse HEAD)" = "$sha" ] && ok "worktree od nowego commita (main nie wyciągnięty)" || bad "worktree od starego commita"

fresh; echo l > l.txt; git add l.txt; git commit -q -m local; lsha=$(git rev-parse HEAD)
out=$($WT new f-local 2>&1)
contains "lokalne przed zdalnym" "$out" "1 commit(ów) przed origin/main"
[ "$(git -C .claude/worktrees/f-local rev-parse HEAD)" = "$lsha" ] && ok "worktree z lokalnej bazy" || bad "worktree nie z lokalnej bazy"

fresh; echo l > l.txt; git add l.txt; git commit -q -m local; before=$(git rev-parse main)
remote_commit "$FB" r3.txt three >/dev/null
out=$($WT new f-div 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "rozjazd: exit 0" || bad "rozjazd exit $rc"
contains "rozjazd: ostrzeżenie" "$out" "rozjechały"
[ "$(git rev-parse main)" = "$before" ] && ok "rozjazd: main bez zmian" || bad "rozjazd: main ruszony"
check "rozjazd: worktree powstał" test -d .claude/worktrees/f-div

fresh; git remote set-url origin /nonexistent/repo
out=$($WT new f-off 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "niedostępny remote: exit 0" || bad "niedostępny remote exit $rc"
contains "niedostępny remote: ostrzeżenie" "$out" "UWAGA: fetch"
check "niedostępny remote: worktree powstał" test -d .claude/worktrees/f-off

fresh; git remote set-url origin ssh://nohost/x; t0=$SECONDS
out=$(GIT_SSH_COMMAND='sleep 30 #' WT_FETCH_TIMEOUT=2 $WT new f-hang 2>&1); rc=$?
[ $((SECONDS - t0)) -lt 12 ] && ok "zawieszony fetch przerwany limitem czasu" || bad "fetch trwał $((SECONDS - t0))s"
[ "$rc" -eq 0 ] && ok "zawieszony fetch: exit 0" || bad "exit $rc"
contains "zawieszony fetch: ostrzeżenie" "$out" "UWAGA: fetch"
check "zawieszony fetch: worktree powstał" test -d .claude/worktrees/f-hang

fresh; before=$(git rev-parse main); remote_commit "$FB" r4.txt four >/dev/null
$WT new --no-fetch f-nf1 >/dev/null 2>&1
[ "$(git rev-parse main)" = "$before" ] && ok "--no-fetch przed nazwą" || bad "--no-fetch nie zadziałał (przed)"
$WT new f-nf2 --no-fetch >/dev/null 2>&1
[ "$(git rev-parse main)" = "$before" ] && ok "--no-fetch po nazwie" || bad "--no-fetch nie zadziałał (po)"
printf 'WT_FETCH=0\n' > .git/wt.conf
$WT new f-nf3 >/dev/null 2>&1
[ "$(git rev-parse main)" = "$before" ] && ok "WT_FETCH=0 w .git/wt.conf" || bad "WT_FETCH=0 nie zadziałało"
contains "wt config pokazuje WT_FETCH" "$($WT config 2>&1)" "WT_FETCH"
rm .git/wt.conf
$WT new f-nf4 >/dev/null 2>&1
[ "$(git rev-parse main)" != "$before" ] && ok "po usunięciu configu fetch działa" || bad "fetch nie wrócił"

check_fail "nieznana opcja" $WT new --bogus x
check_fail "dwie nazwy" $WT new a b
check_fail "sama flaga bez nazwy" $WT new --no-fetch

# wt config --porcelain: key<TAB>source<TAB>value<TAB>default, one row per key, order of ALL_KEYS
out=$($WT config --porcelain 2>&1)
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 6 ] && ok "config --porcelain: 6 wierszy" || bad "config --porcelain: liczba wierszy ($out)"
[ "$(printf '%s\n' "$out" | head -n1 | awk -F'\t' '{print NF}')" = 4 ] && ok "config --porcelain: 4 pola" || bad "config --porcelain: liczba pól"
[ "$(printf '%s\n' "$out" | awk -F'\t' '{print $1}' | tr '\n' ' ')" = "WT_DIR WT_BASE WT_LINK WT_FETCH WT_TEST WT_POST_NEW " ] && ok "config --porcelain: kolejność kluczy" || bad "config --porcelain: kolejność kluczy"
contains "config --porcelain: domyślna WT_DIR" "$out" "$(printf 'WT_DIR\tdomyślna\t.claude/worktrees\t.claude/worktrees')"
contains "config --porcelain: puste pole bez (puste)" "$out" "$(printf 'WT_BASE\tdomyślna\t\t')"
printf 'WT_DIR=../x-wt\nWT_TEST=echo a\tb\n' > .git/wt.conf
printf 'WT_LINK=.env.local\nWT_POST_NEW=evil\n' > .wt.conf
out=$(WT_FETCH=0 $WT config --porcelain 2>/dev/null)
contains "config --porcelain: źródło .git/wt.conf" "$out" "$(printf 'WT_DIR\trepo (.git/wt.conf)\t../x-wt\t.claude/worktrees')"
contains "config --porcelain: źródło .wt.conf" "$out" "$(printf 'WT_LINK\trepo (.wt.conf)\t.env.local\t.env .venv')"
contains "config --porcelain: źródło env" "$out" "$(printf 'WT_FETCH\tenv\t0\t1')"
contains "config --porcelain: tab w wartości zamieniony na spację" "$out" "$(printf 'WT_TEST\trepo (.git/wt.conf)\techo a b\t')"
case "$out" in *evil*) bad "config --porcelain: WT_POST_NEW z .wt.conf ma być zignorowany" ;; *) ok "config --porcelain: komenda z .wt.conf zignorowana" ;; esac
rm -f .git/wt.conf .wt.conf
check_fail "config: nieznana opcja" $WT config --bogus

# wt config set / unset: private .git/wt.conf only, atomic, comments kept
echo "-- config set/unset"
rm -f .git/wt.conf .wt.conf
cval() { $WT config --porcelain 2>/dev/null | awk -F'\t' -v k="$1" '$1 == k {print $3}'; }
csrc() { $WT config --porcelain 2>/dev/null | awk -F'\t' -v k="$1" '$1 == k {print $2}'; }
$WT config set WT_POST_NEW 'npm install' >/dev/null 2>&1
[ "$(cval WT_POST_NEW)" = "npm install" ] && ok "set: wartość widoczna w config" || bad "set: wartość ($(cval WT_POST_NEW))"
[ "$(csrc WT_POST_NEW)" = "repo (.git/wt.conf)" ] && ok "set: źródło .git/wt.conf" || bad "set: źródło"
[ ! -e .wt.conf ] && ok "set: nie tworzy wspólnego .wt.conf" || bad "set: powstał .wt.conf"
printf '# moj komentarz\nWT_FETCH=0\nWT_DIR=../a\nWT_DIR=../b\n\n# koniec\n' > .git/wt.conf
$WT config set WT_DIR ../c-wt >/dev/null 2>&1
[ "$(grep -c '^WT_DIR=' .git/wt.conf)" = 1 ] && ok "set: duplikaty klucza zwinięte do jednej linii" || bad "set: duplikaty"
[ "$(cval WT_DIR)" = "../c-wt" ] && ok "set: nowa wartość" || bad "set: WT_DIR ($(cval WT_DIR))"
grep -q '^# moj komentarz$' .git/wt.conf && grep -q '^# koniec$' .git/wt.conf && grep -q '^WT_FETCH=0$' .git/wt.conf \
  && ok "set: komentarze i inne klucze zachowane" || bad "set: zgubione linie"
out=$($WT config set WT_DIR ../c-wt 2>&1); contains "set: ta sama wartość = bez zmian" "$out" "bez zmian"
$WT config set WT_TEST '"cytat"' >/dev/null 2>&1
[ "$(cval WT_TEST)" = '"cytat"' ] && ok "set: wartość w cudzysłowach przeżywa zapis i odczyt" || bad "set: cudzysłowy ($(cval WT_TEST))"
$WT config set WT_TEST '' >/dev/null 2>&1
[ -z "$(cval WT_TEST)" ] && [ "$(csrc WT_TEST)" = "repo (.git/wt.conf)" ] && ok "set: pusta wartość" || bad "set: pusta wartość"
$WT config unset WT_DIR >/dev/null 2>&1
[ "$(cval WT_DIR)" = ".claude/worktrees" ] && [ "$(csrc WT_DIR)" = "domyślna" ] && ok "unset: wraca do domyślnej" || bad "unset: nie wróciło ($(cval WT_DIR))"
grep -q '^# moj komentarz$' .git/wt.conf && ok "unset: komentarze zachowane" || bad "unset: zgubiony komentarz"
out=$($WT config unset WT_DIR 2>&1); contains "unset: brak klucza = nic do usunięcia" "$out" "nic do usunięcia"
rm -f .git/wt.conf
out=$($WT config unset WT_DIR 2>&1); contains "unset: brak pliku = nic do usunięcia" "$out" "nic do usunięcia"
[ ! -e .git/wt.conf ] && ok "unset: nie tworzy pliku" || bad "unset: utworzył plik"
ls .git/wt.conf.* >/dev/null 2>&1 && bad "pliki tymczasowe zostały" || ok "brak plików tymczasowych po zapisie"
check_fail "set: nieznany klucz" $WT config set WT_NOPE x
check_fail "unset: nieznany klucz" $WT config unset WT_NOPE
check_fail "set: brak wartości" $WT config set WT_DIR
check_fail "set: wartość z nową linią" $WT config set WT_TEST "$(printf 'a\nb')"
check_fail "set: WT_FETCH=2" $WT config set WT_FETCH 2
check_fail "set: WT_BASE nieistniejąca" $WT config set WT_BASE nie-ma-takiej
check "set: WT_BASE istniejąca" $WT config set WT_BASE main
check "set: WT_BASE pusta" $WT config set WT_BASE ""
check_fail "set: WT_LINK z .." $WT config set WT_LINK "../x"
check_fail "set: WT_LINK absolutna" $WT config set WT_LINK "/etc/passwd"
check "set: WT_LINK poprawna" $WT config set WT_LINK ".env .env.local"
check_fail "set: WT_DIR puste" $WT config set WT_DIR ""
check_fail "set: WT_DIR z ~" $WT config set WT_DIR "~/wt"
check_fail "set: WT_DIR = główny checkout" $WT config set WT_DIR "."
check_fail "set: WT_DIR = katalog nadrzędny checkoutu" $WT config set WT_DIR ".."
check_fail "set: WT_DIR = /" $WT config set WT_DIR "/"
check_fail "set: WT_DIR w .git" $WT config set WT_DIR ".git/wt-x"
$WT new cfg-w1 --no-fetch >/dev/null 2>&1
check_fail "set: WT_DIR wewnątrz istniejącego worktree" $WT config set WT_DIR ".claude/worktrees/cfg-w1/sub"
out=$($WT config set WT_DIR ../cfg-moved 2>&1); contains "set WT_DIR: ostrzeżenie o starych worktree" "$out" "zostają w starym miejscu"
[ -d .claude/worktrees/cfg-w1 ] && ok "set WT_DIR: istniejące worktree nietknięte" || bad "set WT_DIR: ruszył worktree"
rm -f .git/wt.conf
$WT drop cfg-w1 >/dev/null 2>&1
out=$(WT_DIR=/tmp/env-wt $WT config set WT_DIR ../zz 2>&1); contains "set: ostrzeżenie, gdy env przesłania" "$out" "przesłonięte przez: env"
rm -f .git/wt.conf
printf 'WT_BASE=nie-ma-takiej\n' > .git/wt.conf
out=$($WT config 2>&1); rc=$?
[ "$rc" = 0 ] && contains "config z błędną WT_BASE nadal działa" "$out" "WT_BASE" || bad "config z błędną WT_BASE: rc=$rc"
check "set naprawia błędną WT_BASE" $WT config set WT_BASE main
rm -f .git/wt.conf

cd "$R" || exit 1
# shellcheck disable=SC2086
rm -rf $FC

echo "-- drop"
D=$(mkrepo); DO=$(mktemp -d)
cd "$D" || exit 1
git init -q --bare "$DO"
git remote add origin "$DO"; git push -q origin main 2>/dev/null
check_fail "drop bez argumentu" $WT drop
check_fail "drop nieistniejący" $WT drop nie-ma
# worktrees get a dead owner pid (creator subshell exits), like a finished session
newd() { ( $WT new "$@" >/dev/null 2>&1; true ); }
newd d1 --no-fetch --title "T"
out=$($WT drop d1 --check 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -d .claude/worktrees/d1 ] && ok "drop --check nic nie usuwa" || bad "drop --check: rc=$rc $out"
out=$($WT drop d1 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "drop czysty exit 0" || bad "drop czysty rc=$rc: $out"
check_fail "drop: katalog zniknął" test -e .claude/worktrees/d1
check_fail "drop: gałąź zniknęła" git rev-parse --verify --quiet refs/heads/d1
[ -z "$(git config --get-regexp '^branch\.d1\.' 2>/dev/null)" ] && ok "drop: config wt-* skasowany" || bad "drop: config został"
# dirty
newd d2 --no-fetch; echo x > .claude/worktrees/d2/u.txt
out=$($WT drop d2 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "drop brudny: odmowa" || bad "drop brudny przeszedł"
contains "drop brudny: komunikat" "$out" "niezacommitowane"
check "drop brudny: worktree zostaje" test -d .claude/worktrees/d2
# unmerged commits
newd d3 --no-fetch
echo c > .claude/worktrees/d3/c.txt; git -C .claude/worktrees/d3 add c.txt; git -C .claude/worktrees/d3 commit -q -m c
out=$($WT drop d3 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "drop niezmergowany: odmowa" || bad "drop niezmergowany przeszedł"
contains "drop niezmergowany: komunikat" "$out" "niezmergowanych"
out=$($WT drop d3 --merged-pr 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ -d .claude/worktrees/d3 ] && ok "--merged-pr bez upstreamu: odmowa, nic nie usunięte" || bad "--merged-pr bez upstreamu: rc=$rc $out"
git -C .claude/worktrees/d3 push -q -u origin d3 2>/dev/null
out=$($WT drop d3 --merged-pr 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e .claude/worktrees/d3 ] && ok "drop --merged-pr (PR zmergowany) usuwa" || bad "drop --merged-pr rc=$rc $out"
# merged locally
newd d4 --no-fetch
echo m > .claude/worktrees/d4/m.txt; git -C .claude/worktrees/d4 add m.txt; git -C .claude/worktrees/d4 commit -q -m m
git merge -q --ff-only d4
out=$($WT drop d4 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "drop po zmergowaniu do targetu" || bad "drop po merge rc=$rc $out"
# live owner (a different process than the caller)
newd d5 --no-fetch
sleep 30 & SLP=$!
printf '{"session":"","pid":%s,"pane":"","time":"x","user":"u"}\n' "$SLP" > .claude/worktrees/d5/.wt-owner
out=$($WT drop d5 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "drop żywy właściciel: odmowa" || bad "drop żywy właściciel przeszedł"
contains "drop właściciel: komunikat" "$out" "zajęty"
kill "$SLP" 2>/dev/null; wait "$SLP" 2>/dev/null
out=$($WT drop d5 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "drop po śmierci właściciela" || bad "drop martwy właściciel rc=$rc $out"
# inside the worktree itself
newd d6 --no-fetch
out=$(cd .claude/worktrees/d6 && $WT drop d6 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "drop z wnętrza worktree: odmowa" || bad "drop z wnętrza przeszedł"
# custom target: unmerged relative to wt-target
git branch dev-y; newd d7 --no-fetch --target dev-y
echo q > .claude/worktrees/d7/q.txt; git -C .claude/worktrees/d7 add q.txt; git -C .claude/worktrees/d7 commit -q -m q
git merge -q --ff-only d7 2>/dev/null
out=$($WT drop d7 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "drop liczy względem wt-target" "$out" "'dev-y'" || bad "drop zignorował wt-target"
cd "$R" || exit 1
rm -rf "$D" "$DO"

echo "-- ui: akcje (czyste funkcje)"
out=$(python3 - "$UIBIN" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("wt_ui", sys.argv[1])
spec = importlib.util.spec_from_loader("wt_ui", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
row = {"branch": "feat-a", "path": "/r/wt/feat-a"}
meta = {"title": "Mój tytuł", "target": "dev"}
def pr(**kw):
    d = {"number": 7, "draft": False, "state": "OPEN", "mergeable": "MERGEABLE", "ci": "green", "url": "", "checks": [], "base": "dev"}
    d.update(kw); return d
def plan(kind, p=None, status="ok", gh=True, meta=meta):
    return m.plan_action(kind, row, meta, p, "main", status, gh, "WT")
r = plan("push")
assert [s["argv"] for s in r["steps"]] == [["git", "push", "-u", "origin", "feat-a"],
    ["gh", "pr", "create", "--draft", "--base", "dev", "--head", "feat-a", "--title", "Mój tytuł", "--body", ""]], r
assert not any("--force" in a or "-f" == a for s in r["steps"] for a in s["argv"])
r = plan("push", meta={})
assert r["steps"][1]["argv"][r["steps"][1]["argv"].index("--title") + 1] == "feat-a" and "main" in r["steps"][1]["argv"]
assert len(plan("push", pr())["steps"]) == 1 and len(plan("push", gh=False, status="off")["steps"]) == 1
assert "error" in plan("push", status="err") and "error" in plan("push", status="loading")
assert plan("ready", pr(draft=True))["steps"][0]["argv"] == ["gh", "pr", "ready", "7"]
assert plan("ready", pr())["steps"][0]["argv"] == ["gh", "pr", "ready", "7", "--undo"]
assert "error" in plan("ready") and "error" in plan("ready", pr(state="MERGED")) and "error" in plan("ready", pr(), gh=False)
assert plan("merge", pr())["steps"][0]["argv"] == ["gh", "pr", "merge", "7", "--merge"]
for bad in (pr(draft=True), pr(state="CLOSED"), pr(mergeable="CONFLICTING"), pr(mergeable="UNKNOWN"), pr(ci="red")):
    assert "error" in plan("merge", bad), bad
    assert "error" in plan("mergedrop", bad), bad
assert "error" in plan("merge")
r = plan("merge", pr(ci="yellow")); assert "UWAGA" in " ".join(r["lines"])
r = plan("mergedrop", pr())
assert [s["argv"] for s in r["steps"]] == [["WT", "drop", "feat-a", "--merged-pr", "--check"],
    ["gh", "pr", "merge", "7", "--merge"], ["WT", "drop", "feat-a", "--merged-pr"]], r
assert plan("drop")["steps"][0]["argv"] == ["WT", "drop", "feat-a"]
assert plan("drop", pr(state="MERGED"))["steps"][0]["argv"] == ["WT", "drop", "feat-a", "--merged-pr"]
assert plan("drop", status="err", gh=False)["steps"]
assert m.display_cmd(["WT", "drop", "a b"], "WT") == "wt drop 'a b'"
assert plan("close", pr())["steps"][0]["argv"] == ["gh", "pr", "close", "7"]
assert "error" in plan("close") and "error" in plan("close", pr(state="MERGED")) and "error" in plan("close", pr(), gh=False)
assert set(m.ACTION_KEYS.values()) | set(m.PR_KEYS.values()) == {"push", "ready", "merge", "close", "drop", "mergedrop"}
assert not {ord(c) for c in "ntcrqgGjk/ "} & set(m.ACTION_KEYS)
assert not {ord(c) for c in "qgGjkhr/ "} & set(m.PR_KEYS)
assert [h for h, _ in m.MENU][0] == "Wybrane worktree" and any(k == "p" for k, _ in m.PR_MENU)
assert any("close" in d for _, d in m.PR_MENU) and any(k == "h/Esc" for k, _ in m.PR_MENU)
def st(p=None, status="ok", gh=True, dirty="0"):
    return m.pr_menu_state({"branch": "feat-a", "path": "/r", "dirty": dirty}, p, status, gh)
dis = lambda x: sorted(k for k, v in x.items() if v)
assert dis(st()) == ["M", "c", "d", "m"] and st()["p"] is None                  # no PR: only push
assert dis(st(pr(draft=True))) == ["M", "m"] and "ready" in st(pr(draft=True))["m"][0]  # draft: no merge
c = st(pr(mergeable="CONFLICTING")); assert dis(c) == ["M", "m"] and "konflikty" in c["m"][0] and "konflikty" in c["m"][1]
assert dis(st(pr(ci="red"))) == ["M", "m"] and dis(st(pr(mergeable="UNKNOWN"))) == ["M", "m"]
assert dis(st(pr())) == [] and dis(st(pr(ci="yellow"))) == []                  # healthy PR: all enabled
assert dis(st(pr(), dirty="3")) == ["M"]                                         # dirty worktree: no merge+drop
assert dis(st(pr(state="MERGED"))) == ["M", "c", "d", "m"] and dis(st(pr(state="CLOSED"))) == ["M", "c", "d", "m"]
assert dis(st(pr(), status="loading")) == ["M", "c", "d", "m", "p"] and dis(st(pr(), status="err")) == ["M", "c", "d", "m", "p"]
assert dis(st(gh=False, status="off")) == ["M", "c", "d", "m"]
assert m.parse_updown("2\t3\n") == (2, 3) and m.parse_updown("") is None and m.parse_updown("x y") is None
items = m.parse_config("WT_DIR\tdomyślna\t.claude/worktrees\t.claude/worktrees\nWT_BASE\tenv\t\t\nzepsute\n")
assert [i["key"] for i in items] == ["WT_DIR", "WT_BASE"] and items[1] == {"key": "WT_BASE", "source": "env", "value": "", "default": ""}
desc, notes = m.config_notes(items[1])
assert desc and any("środowiskow" in t for t, _ in notes) and any("dozwolony." in t for t, _ in notes)
_, notes = m.config_notes({"key": "WT_POST_NEW", "source": "repo (.git/wt.conf)", "value": "x", "default": ""})
assert any("niedozwolony" in t for t, _ in notes) and not any("środowiskow" in t for t, _ in notes)
assert any(k == "C" for _, es in m.MENU for k, _ in es)
assert m.conf_problems("# c\nWT_DIR=x\n  WT_FETCH = 0\n\nWT_FTCH=1\nbez-rownosci\n") == [
    "linia 5: nieznany klucz WT_FTCH (zignorowany)", "linia 6: brak '=' (zignorowana)"]
assert m.conf_problems("") == []
print("KEYS:" + " ".join(sorted(m.CONFIG_HELP)))
print("SAFE:" + " ".join(sorted(k for k, (_, ok) in m.CONFIG_HELP.items() if ok)))
print("AKCJE-OK")
PY
)
contains "plan_action i pochodne" "$out" "AKCJE-OK"
ui_keys=$(printf '%s\n' "$out" | sed -n 's/^KEYS://p')
cfg_keys=$($WT config --porcelain | awk -F'\t' '{print $1}' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$ui_keys" = "$cfg_keys" ] && ok "ui: CONFIG_HELP pokrywa wszystkie klucze wt config" || bad "ui: klucze configu ($ui_keys) != ($cfg_keys)"
ui_safe=$(printf '%s\n' "$out" | sed -n 's/^SAFE://p')
wt_safe=$(sed -n 's/^SAFE_KEYS="\(.*\)"$/\1/p' "$WT_BIN" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$ui_safe" = "$wt_safe" ] && ok "ui: klucze dozwolone we wspólnym .wt.conf zgodne z SAFE_KEYS" || bad "ui: SAFE ($ui_safe) != SAFE_KEYS ($wt_safe)"

echo "-- ui: edycja configu (pty)"
out=$(python3 - "$WT_BIN" "$(cd "$(dirname "$WT_BIN")" && pwd -P)/wt-ui" <<'PY'
import os, pty, sys, time, select, subprocess, tempfile, re, struct, fcntl, termios, shutil
wt, ui = sys.argv[1], sys.argv[2]
repo = tempfile.mkdtemp()
def sh(*a): subprocess.run(a, check=True, capture_output=True, cwd=repo)
sh("git", "init", "-q", "-b", "main"); sh("git", "config", "user.email", "a@b"); sh("git", "config", "user.name", "a")
sh("git", "commit", "-q", "--allow-empty", "-m", "i")
conf = repo + "/.git/wt.conf"
pid, fd = pty.fork()
if pid == 0:
    os.chdir(repo)
    env = {k: v for k, v in os.environ.items() if not k.startswith("WT_")}
    env.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", WT_CMD=wt, VISUAL=repo + "/ed.sh")
    os.execve(sys.executable, [sys.executable, ui], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
buf = b""
def pump(t):
    global buf
    end = time.time() + t
    while time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try: buf += os.read(fd, 65536)
            except OSError: return
def txt(): return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-B]|\x1b[=>]", b"", buf).decode("utf8", "replace")
def rd(): return open(conf).read() if os.path.exists(conf) else ""
def key(b, t=0.8): os.write(fd, b); pump(t)
res = []
pump(1.5)
key(b"C"); key(b"jjj", 0.3)                                  # WT_FETCH
key(b"\r"); key(b"\x7f0\r", 1.2); res.append(("set", rd() == "WT_FETCH=0\n"))
key(b"\r"); buf = b""; key(b"\x7f2\r", 1.2)
res.append(("error-modal", "przyjmuje 0 albo 1" in txt() and rd() == "WT_FETCH=0\n"))
key(b"\r", 0.5)                                             # dismiss the modal
key(b"d", 0.5); key(b"n", 0.5); res.append(("unset-declined", rd() == "WT_FETCH=0\n"))
key(b"d", 0.5); key(b"y", 1.2); res.append(("unset", rd() == ""))
ed = repo + "/ed.sh"
open(ed, "w").write('#!/bin/sh\nprintf "WT_FETCH=0\\nWT_FTCH=1\\n" >> "$1"\n')
os.chmod(ed, 0o755)
buf = b""; key(b"E", 1.5)
res.append(("editor-file", rd() == "WT_FETCH=0\nWT_FTCH=1\n"))
res.append(("editor-typo-warning", "nieznany klucz WT_FTCH" in txt()))
key(b"\x1b", 1.0); key(b"q", 0.5)
shutil.rmtree(repo, ignore_errors=True)
print(" ".join("%s=%s" % (n, "ok" if v else "FAIL") for n, v in res))
PY
)
case "$out" in *FAIL*|"") bad "ui: edycja configu ($out)" ;; *) ok "ui: edycja configu (set, błąd, odmowa, unset): $out" ;; esac

echo "-- ui: smoke w pty z fałszywym gh"
SB=$(mktemp -d); mkdir -p "$SB/bin"
cat > "$SB/bin/gh" <<'GH'
#!/bin/sh
echo "$*" >> "$FAKE_GH_DIR/calls.log"
P="$FAKE_GH_DIR/prs.json"
case "$1 $2" in
  "pr list") cat "$P" ;;
  "pr create") printf '[{"number":1,"headRefName":"feat-ui","baseRefName":"main","isDraft":true,"state":"OPEN","mergeable":"MERGEABLE","statusCheckRollup":[],"url":"https://example.invalid/pr/1"}]' > "$P" ;;
  "pr ready") case "$*" in *--undo*) sed 's/"isDraft":false/"isDraft":true/' "$P" > "$P.n" ;; *) sed 's/"isDraft":true/"isDraft":false/' "$P" > "$P.n" ;; esac; mv "$P.n" "$P" ;;
  "pr merge") sed 's/"state":"OPEN"/"state":"MERGED"/' "$P" > "$P.n"; mv "$P.n" "$P" ;;
esac
exit 0
GH
chmod +x "$SB/bin/gh"
cat > "$SB/drive.py" <<'PY'
import fcntl, os, pty, select, struct, sys, termios, time
wt_sh, wt_bin, cwd, scen = sys.argv[1:5]
gd = os.environ["FAKE_GH_DIR"]
def log():
    try: return open(gd + "/calls.log").read()
    except OSError: return ""
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.environ["TERM"] = "xterm-256color"
    os.execvp(wt_sh, [wt_sh, wt_bin, "ui"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: return
            if not d: return
            buf += d
def send(s): os.write(fd, s.encode())
def until(cond, to=10):
    end = time.time() + to
    while time.time() < end:
        pump(0.2)
        if cond(): return True
    return False
def count(s): return log().count(s)
def act(key, confirm=True):
    send(" "); pump(0.3); send("p"); pump(0.3)  # Space menu -> PR submenu
    send(key); pump(0.6)
    if confirm: send("y")
res = []
pump(2)
if scen == "full":
    act("p"); res.append(("create", until(lambda: "pr create" in log())))
    until(lambda: count("pr list") >= 2); pump(1)
    res.append(("create-args", "--draft --base main --head feat-ui --title Tytul UI" in log()))
    n = count("pr merge"); act("m", confirm=False); pump(1); send("\r"); pump(0.5)
    res.append(("merge-refused-draft", count("pr merge") == n))
    act("d"); res.append(("ready", until(lambda: "pr ready 1\n" in log()))); until(lambda: count("pr list") >= 4); pump(1)
    act("d"); res.append(("undo", until(lambda: "pr ready 1 --undo" in log()))); until(lambda: count("pr list") >= 5); pump(1)
    act("d"); until(lambda: log().count("pr ready 1\n") >= 2); until(lambda: count("pr list") >= 6); pump(1)
    act("M"); res.append(("merge", until(lambda: "pr merge 1 --merge" in log())))
    res.append(("dropped", until(lambda: not os.path.exists(cwd + "/.claude/worktrees/feat-ui"), 10)))
else:  # noorigin: push fails, must show an error and survive
    act("p"); pump(2)
    res.append(("no-create", "pr create" not in log()))
    send("\r"); pump(0.5)
send("q"); pump(1)
try:
    _, st = os.waitpid(pid, os.WNOHANG)
except ChildProcessError:
    st = 0
res.append(("alive-then-quit", True))
for k, v in res: print(("OK " if v else "NO ") + k)
PY
mkui() { # mkui DIR-VAR: repo + worktree feat-ui with one commit
  local t; t=$(mkrepo); (cd "$t" && ( $WT new feat-ui --no-fetch --title "Tytul UI" >/dev/null 2>&1; true )
  echo f > "$t/.claude/worktrees/feat-ui/f.txt"; git -C "$t/.claude/worktrees/feat-ui" add f.txt
  git -C "$t/.claude/worktrees/feat-ui" commit -q -m f); printf '%s' "$t"
}
U=$(mkui); UO=$(mktemp -d); git init -q --bare "$UO"
git -C "$U" remote add origin "$UO"; git -C "$U" push -q origin main 2>/dev/null
mkdir "$SB/gh1"; printf '[]' > "$SB/gh1/prs.json"
out=$(cd "$SB" && PATH="$SB/bin:$PATH" FAKE_GH_DIR="$SB/gh1" python3 "$SB/drive.py" "$SH" "$WT_BIN" "$U" full 2>&1)
for k in create create-args merge-refused-draft ready undo merge dropped alive-then-quit; do
  case "$out" in *"OK $k"*) ok "ui smoke: $k" ;; *) bad "ui smoke: $k ($out)" ;; esac
done
check "ui smoke: gałąź wypchnięta do lokalnego origin" git --git-dir="$UO" rev-parse --verify --quiet refs/heads/feat-ui
check_fail "ui smoke: gałąź lokalna usunięta po merge+drop" git -C "$U" rev-parse --verify --quiet refs/heads/feat-ui
U2=$(mkui); mkdir "$SB/gh2"; printf '[]' > "$SB/gh2/prs.json"
out=$(cd "$SB" && PATH="$SB/bin:$PATH" FAKE_GH_DIR="$SB/gh2" python3 "$SB/drive.py" "$SH" "$WT_BIN" "$U2" noorigin 2>&1)
case "$out" in *"OK no-create"*"OK alive-then-quit"*) ok "ui smoke: brak origin = błąd w modalu, bez crasha" ;; *) bad "ui smoke noorigin ($out)" ;; esac
rm -rf "$SB" "$U" "$U2" "$UO"

echo "-- poza repo"
out=$(cd / && $WT list 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "poza repo exit 1" || bad "poza repo exit $rc"
contains "poza repo komunikat" "$out" "nie jesteś w repo git"

echo
echo "WYNIK: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
