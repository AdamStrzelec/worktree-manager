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

echo "-- new: WT_COPY"
printf 'SECRET=1\n' > .env.local
mkdir -p cfgdir && printf 'a\n' > cfgdir/x.txt
printf 'WT_COPY=.env.local cfgdir .brak\n' > .git/wt.conf
check "copy: new" $WT new feat-copy
[ -f .claude/worktrees/feat-copy/.env.local ] && [ ! -L .claude/worktrees/feat-copy/.env.local ] && ok "copy: zwykły plik, nie symlink" || bad "copy: plik"
check "copy: katalog skopiowany" test -f .claude/worktrees/feat-copy/cfgdir/x.txt
printf 'ZMIENIONE\n' >> .claude/worktrees/feat-copy/.env.local
[ "$(cat .env.local)" = "SECRET=1" ] && ok "copy: kopia niezależna od oryginału" || bad "copy: oryginał zmieniony"
check "copy: brakujący plik pomijany" test ! -e .claude/worktrees/feat-copy/.brak
case "$(git -C .claude/worktrees/feat-copy status --short)" in *env.local*) bad "copy: plik widoczny w git status" ;; *) ok "copy: plik w exclude (git status czysty)" ;; esac
rm -rf cfgdir .env.local .git/wt.conf

echo "-- drop: procesy w worktree"
$WT new pr-a --no-fetch >/dev/null 2>&1
(cd .claude/worktrees/pr-a && exec sleep 120) &
SLP=$!
sleep 1
HL2=$(mktemp -d)/hk.log
printf 'WT_PRE_DROP=echo ran >> %s\n' "$HL2" > .git/wt.conf
out=$($WT drop pr-a 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "proc: drop odmawia i listuje pid" "$out" "pid $SLP" || bad "proc: drop nie odmówił"
check "proc: worktree zostaje" test -d .claude/worktrees/pr-a
[ ! -s "$HL2" ] && ok "proc: żadna logika (hook) się nie wykonała" || bad "proc: hook odpalony mimo procesów"
check_fail "proc: --check też odmawia" $WT drop pr-a --check
$WT drop pr-a --stop-procs >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "proc: --stop-procs usuwa" || bad "proc: --stop-procs exit $rc"
kill -0 "$SLP" 2>/dev/null && bad "proc: proces nadal żyje" || ok "proc: proces zatrzymany"
wait "$SLP" 2>/dev/null
check "proc: worktree usunięte" test ! -d .claude/worktrees/pr-a
rm -f .git/wt.conf

echo "-- drop: hooki"
HL=$(mktemp -d)/hook.log
$WT new hk-ok >/dev/null 2>&1
printf 'WT_PRE_DROP=echo pre $WT_NAME $WT_BRANCH >> %s; test -d "$WT_PATH"\nWT_POST_DROP=echo post $WT_NAME $(basename "$WT_MAIN") >> %s; test ! -d "$WT_PATH"\n' "$HL" "$HL" > .git/wt.conf
check "hook: drop z hookami" $WT drop hk-ok
[ "$(cat "$HL")" = "$(printf 'pre hk-ok hk-ok\npost hk-ok %s' "$(basename "$PWD")")" ] && ok "hook: kolejność i zmienne" || bad "hook: log ($(cat "$HL" 2>&1))"
$WT new hk-veto >/dev/null 2>&1
printf 'WT_PRE_DROP=exit 1\nWT_POST_DROP=echo post >> %s\n' "$HL" > .git/wt.conf
: > "$HL"
check_fail "hook: PRE wetuje drop" $WT drop hk-veto
check "hook: worktree zostaje po wecie" test -d .claude/worktrees/hk-veto
[ ! -s "$HL" ] && ok "hook: POST nie odpala po wecie" || bad "hook: POST po wecie"
printf 'WT_POST_DROP=exit 5\n' > .git/wt.conf
check "hook: błąd POST nie przerywa" $WT drop hk-veto
check "hook: worktree usunięte mimo błędu POST" test ! -d .claude/worktrees/hk-veto
$WT new hk-chk >/dev/null 2>&1
printf 'WT_PRE_DROP=echo x >> %s\n' "$HL" > .git/wt.conf
: > "$HL"; $WT drop hk-chk --check >/dev/null 2>&1
[ ! -s "$HL" ] && ok "hook: --check nie odpala hooków" || bad "hook: --check odpalił hook"
$WT drop hk-chk >/dev/null 2>&1
printf 'WT_PRE_DROP=evil\n' > .wt.conf; rm .git/wt.conf
case "$($WT config --porcelain 2>/dev/null | grep '^WT_PRE_DROP')" in *evil*) bad "hook: PRE z .wt.conf" ;; *) ok "hook: PRE z .wt.conf zignorowany" ;; esac
rm -f .wt.conf

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
# autorefresh: os.stat fingerprint of .git changes on commit / worktree add, not on idle
out=$(cd "$R" && python3 - "$UIBIN" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys, os, subprocess, tempfile, time
loader = importlib.machinery.SourceFileLoader("wt_ui", sys.argv[1])
spec = importlib.util.spec_from_loader("wt_ui", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
d = tempfile.mkdtemp()
g = lambda *a, cwd=d: subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True)
g("init", "-q", "-b", "main"); g("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "a")
paths = lambda: m.watch_paths(os.path.join(d, ".git"), [m.worktree_gitdir(d)] +
                              [m.worktree_gitdir(os.path.join(d, "w"))] * os.path.isdir(os.path.join(d, "w")))
fp = m.fingerprint(paths())
assert m.fingerprint(paths()) == fp, "idle fingerprint changed"
time.sleep(0.01); g("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "b")
fp2 = m.fingerprint(paths()); assert fp2 != fp, "commit not detected"
time.sleep(0.01); g("worktree", "add", "-q", "w", "-b", "w")
assert m.fingerprint(paths()) != fp2, "worktree add not detected"
assert m.worktree_gitdir(os.path.join(d, "w")) == os.path.realpath(os.path.join(d, ".git", "worktrees", "w")) or \
       m.worktree_gitdir(os.path.join(d, "w")).endswith(os.path.join(".git", "worktrees", "w"))
assert m.worktree_gitdir("/nie/ma") is None
os.environ["X_T"] = "abc"; assert m.env_seconds("X_T", 30) == 30
os.environ["X_T"] = "-1"; assert m.env_seconds("X_T", 30) == 30
os.environ["X_T"] = "0"; assert m.env_seconds("X_T", 30) == 0
print("AUTOREFRESH-OK")
PY
)
contains "autorefresh: stat-check wykrywa commit i nowy worktree" "$out" "AUTOREFRESH-OK"
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
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 9 ] && ok "config --porcelain: 9 wierszy" || bad "config --porcelain: liczba wierszy ($out)"
[ "$(printf '%s\n' "$out" | head -n1 | awk -F'\t' '{print NF}')" = 4 ] && ok "config --porcelain: 4 pola" || bad "config --porcelain: liczba pól"
[ "$(printf '%s\n' "$out" | awk -F'\t' '{print $1}' | tr '\n' ' ')" = "WT_DIR WT_BASE WT_LINK WT_COPY WT_FETCH WT_TEST WT_POST_NEW WT_PRE_DROP WT_POST_DROP " ] && ok "config --porcelain: kolejność kluczy" || bad "config --porcelain: kolejność kluczy"
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
echo "-- set WT_DIR --move"
MV=$(cd "$(mktemp -d)" && pwd -P)
$WT drop cfg-w1 >/dev/null 2>&1
$WT new mv-a --no-fetch >/dev/null 2>&1
$WT new mv/nested --no-fetch >/dev/null 2>&1
printf 'dirty\n' > .claude/worktrees/mv-a/untracked.txt
mkdir -p "$MV/taken/mv-a"
check_fail "move: cel istnieje = odmowa" $WT config set WT_DIR "$MV/taken" --move
[ ! -f .git/wt.conf ] && ok "move: odmowa nie zapisała configu" || bad "move: config zapisany mimo odmowy"
check_fail "move: --move tylko dla WT_DIR" $WT config set WT_FETCH 0 --move
$WT config set WT_DIR "$MV/new" --move > "$MV/out" 2>&1; rc=$?; out=$(cat "$MV/out")
[ "$rc" -eq 0 ] && ok "move: exit 0" || bad "move: exit $rc ($out)"
check "move: worktree w nowym miejscu" test -f "$MV/new/mv-a/untracked.txt"
check "move: zagnieżdżona nazwa zachowana" test -d "$MV/new/mv/nested"
check "move: stare miejsce puste" test ! -d .claude/worktrees/mv-a
mvn=$(git worktree list --porcelain | grep -c "^worktree $MV/new/mv")
[ "$mvn" = 2 ] && ok "move: git zna nowe ścieżki" || bad "move: git worktree list ($mvn; $(git worktree list --porcelain | grep ^worktree | tr '\n' ' '))"
rm -f "$MV/new/mv-a/untracked.txt"
$WT drop mv-a > "$MV/drop" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "move: wt drop działa po przeniesieniu" || bad "move: drop ($(cat "$MV/drop"))"
$WT drop mv/nested >/dev/null 2>&1
rm -f .git/wt.conf; rm -rf "$MV"; git worktree prune
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
assert set(m.CONFIG_BRIEF) == set(m.CONFIG_HELP) and all(b and ex for b, ex in m.CONFIG_BRIEF.values())
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

echo "-- ui: WT_DIR z przeniesieniem (pty)"
out=$(python3 - "$WT_BIN" <<'PY'
import os, pty, sys, time, select, subprocess, tempfile, struct, fcntl, termios
W = sys.argv[1]
repo = os.path.realpath(tempfile.mkdtemp()); dest = os.path.realpath(tempfile.mkdtemp()) + "/wts"
env = {**os.environ, "GIT_AUTHOR_NAME": "a", "GIT_AUTHOR_EMAIL": "a@a", "GIT_COMMITTER_NAME": "a", "GIT_COMMITTER_EMAIL": "a@a"}
sh = lambda c: subprocess.run(c, shell=True, cwd=repo, env=env, capture_output=True, text=True)
sh("git init -q -b main && git commit -q --allow-empty -m i"); sh("'%s' new mvx --no-fetch" % W)
open(repo + "/.claude/worktrees/mvx/.wt-owner", "w").write('{"pid":999999}')  # dead owner
pid, fd = pty.fork()
if pid == 0:
    os.chdir(repo); os.environ["TERM"] = "xterm-256color"; os.execv(W, ["wt", "ui"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
def k(b, t=0.6):
    os.write(fd, b); e = time.time() + t
    while time.time() < e:
        if select.select([fd], [], [], 0.1)[0]:
            try: os.read(fd, 65536)
            except OSError: return
k(b"", 1.5); k(b"C"); k(b"\r"); k(b"\x7f" * 30 + dest.encode() + b"\r"); k(b"y", 1.5); k(b"\x1b"); k(b"q")
print("MOVED:%s" % (os.path.isdir(dest + "/mvx") and not os.path.isdir(repo + "/.claude/worktrees/mvx")))
PY
)
contains "ui: zmiana WT_DIR + y przenosi worktree" "$out" "MOVED:True"

echo "-- ui: drop z procesami (pty)"
out=$(python3 - "$WT_BIN" <<'PY'
import os, pty, sys, time, select, subprocess, tempfile, struct, fcntl, termios
W = sys.argv[1]
repo = os.path.realpath(tempfile.mkdtemp())
env = {**os.environ, "GIT_AUTHOR_NAME": "a", "GIT_AUTHOR_EMAIL": "a@a", "GIT_COMMITTER_NAME": "a", "GIT_COMMITTER_EMAIL": "a@a"}
sh = lambda c: subprocess.run(c, shell=True, cwd=repo, env=env, capture_output=True, text=True)
sh("git init -q -b main && git commit -q --allow-empty -m i"); sh("'%s' new prx --no-fetch" % W)
open(repo + "/.claude/worktrees/prx/.wt-owner", "w").write('{"pid":999999}')
subprocess.run("sleep 987 </dev/null >/dev/null 2>&1 &", shell=True, cwd=repo + "/.claude/worktrees/prx")  # orphaned like a real dev server
time.sleep(0.5)
pid, fd = pty.fork()
if pid == 0:
    os.chdir(repo); os.environ["TERM"] = "xterm-256color"; os.execv(W, ["wt", "ui"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
def k(b, t=0.6):
    os.write(fd, b); e = time.time() + t
    while time.time() < e:
        if select.select([fd], [], [], 0.1)[0]:
            try: os.read(fd, 65536)
            except OSError: return
k(b"", 1.5); k(b"x", 0.8); k(b"y", 2); k(b"y", 3); k(b"q")
time.sleep(0.5)
left = subprocess.run(["pgrep", "-f", "sleep 987"], capture_output=True, text=True).stdout.split()
print("GONE:%s KILLED:%s" % (not os.path.isdir(repo + "/.claude/worktrees/prx"), not left))
for p in left: os.kill(int(p), 15)
PY
)
contains "ui: drop z procesami zatrzymuje i usuwa" "$out" "GONE:True KILLED:True"

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
key(b"C"); key(b"jjjj", 0.3)                                 # WT_FETCH
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

echo "-- profiles: moduł"
PROFBIN=$(dirname "$WT_BIN")/wt-profiles
check "wt-profiles kompiluje się" python3 -m py_compile "$PROFBIN"
out=$(python3 - "$PROFBIN" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys, json, os, tempfile
loader = importlib.machinery.SourceFileLoader("wt_profiles", sys.argv[1])
spec = importlib.util.spec_from_loader("wt_profiles", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
d = tempfile.mkdtemp()
def w(name, data):
    p = os.path.join(d, name)
    with open(p, "w") as f:
        f.write(data if isinstance(data, str) else json.dumps(data))
    return p
def errs(g, p):
    try:
        m.load(g, p); return []
    except m.ProfileError as e:
        return e.errors
G = {"version": 1, "defaultMode": "feature",
     "variables": {"model": {"label": "Model", "choices": ["opus", "sonnet"], "default": "opus"}},
     "prompts": {"review": "Przejrzyj {branch} vs {base}"},
     "modes": {"feature": {"label": "F", "actions": ["rules", "deps", "dev", "tmux", "claude", "git"]},
               "bare": {"actions": []}},
     "actions": {
        "rules": {"type": "file", "path": "docs/RULES-{mode}.md", "content": "b={branch} {{x}}"},
        "deps": {"type": "shell", "run": "npm ci"},
        "dev": {"type": "shell", "run": "echo {name}", "needs": ["deps"]},
        "tmux": {"type": "tmux-session"},
        "claude": {"type": "tmux-window", "window": "claude", "run": "claude --model {model} {prompt:review}",
                   "beforeDrop": {"sendKeys": "/exit"}},
        "git": {"type": "tmux-window", "window": "git", "run": "lazygit"}}}
g = w("g.json", G)
none = os.path.join(d, "nie-ma.json")
# no files at all
assert m.load(none, none) == (None, {}, [])
cfg, origin, warn = m.load(g, none)
assert warn == [] and cfg["defaultMode"] == "feature" and origin["actions.git"] == "global"
# project layer: replace action, null removes, defaultMode wins
P = {"version": 1, "defaultMode": "bare", "actions": {"git": {"type": "tmux-window", "window": "git", "run": "tig"}},
     "modes": {"bare": None, "mini": {"actions": ["deps"]}}}
P["defaultMode"] = "mini"
cfg2, origin2, _ = m.load(g, w("p.json", P))
assert cfg2["actions"]["git"]["run"] == "tig" and origin2["actions.git"] == "project"
assert "bare" not in cfg2["modes"] and cfg2["defaultMode"] == "mini" and origin2["defaultMode"] == "project"
# resolve
ctx = {"name": "feat/x y", "branch": "feat/x y", "path": "/r/wt/x", "base": "main", "repo": "my.repo"}
plan = m.resolve(cfg, ctx, None, ["model=sonnet"], [])
byid = {a: (k, dict(f)) for k, a, f in plan}
assert [a for _, a, _ in plan] == ["rules", "deps", "dev", "tmux", "claude", "git"]
assert byid["rules"][1]["path"] == "docs/RULES-feature.md" and byid["rules"][1]["content"] == "b=feat/x y {x}"
assert byid["dev"][1]["run"] == "echo 'feat/x y'", byid["dev"]
assert byid["claude"][1]["run"] == "claude --model sonnet 'Przejrzyj feat/x y vs main'", byid["claude"]
assert byid["claude"][1]["needs"] == "tmux" and byid["claude"][1]["beforeDrop.sendKeys"] == "/exit"
assert byid["tmux"][1]["session"] == "my-repo/feat/x y" and byid["tmux"][1]["attach"] == "0"
# --skip drops dependents transitively (explicit needs + implicit window->session)
plan = m.resolve(cfg, ctx, "feature", [], ["deps", "tmux"])
kinds = {a: k for k, a, _ in plan}
assert kinds == {"rules": "action", "deps": "skip", "dev": "skip", "tmux": "skip", "claude": "skip", "git": "skip"}, kinds
assert dict(plan[2][2])["reason"] == "pominięta (wymaga deps)" and dict(plan[2][2])["label"] == "dev"
assert m.resolve(cfg, ctx, "bare") == []
for args in (("nie-ma", [], []), ("feature", ["model=gpt"], []), ("feature", ["x=1"], []), ("feature", [], ["zzz"])):
    try:
        m.resolve(cfg, ctx, *args); raise AssertionError(args)
    except m.ProfileError:
        pass
# encoding: NUL fields, empty key ends record
enc = m.encode_plan([("action", "a", [("run", "x\ty\nz")]), ("skip", "b", [("reason", "r")])])
assert enc == "action\0a\0run\0x\ty\nz\0\0skip\0b\0reason\0r\0\0", repr(enc)
# validation errors
assert any("linii 1" in e for e in errs(w("bad.json", '{"version": 1,}'), none))
assert any("version" in e for e in errs(w("v.json", {"version": 2}), none))
def bad(mutate, needle):
    c = json.loads(json.dumps(G)); mutate(c)
    e = errs(w("x.json", c), none)
    assert any(needle in x for x in e), (needle, e)
bad(lambda c: c["actions"]["deps"].update(type="nope"), "nieznany \"type\"")
bad(lambda c: c["actions"]["deps"].pop("run"), "wymagane pole \"run\"")
bad(lambda c: c["actions"]["rules"].update(path="../x"), "ścieżką względną")
bad(lambda c: c["actions"]["rules"].update(path="/etc/x"), "ścieżką względną")
bad(lambda c: c["actions"]["deps"].update(run="{oops}"), "nieznany placeholder {oops}")
bad(lambda c: c["prompts"].update(r2="{prompt:review}"), "nieznany placeholder")
bad(lambda c: c["actions"]["dev"].update(needs=["git"]), "musi stać wcześniej")
bad(lambda c: c["actions"]["dev"].update(needs=["dev"]), "samej siebie")
bad(lambda c: c["modes"]["bare"].update(actions=["dev"]), "której nie ma w trybie")
bad(lambda c: c["modes"]["bare"].update(actions=["git"]), "wymaga wcześniejszej akcji tmux-session")
bad(lambda c: c["modes"]["bare"].update(actions=["zzz"]), "nieznana akcja")
bad(lambda c: c["modes"]["bare"].update(actions=["deps", "deps"]), "dwa razy")
bad(lambda c: c["actions"]["git"].update(window="claude"), "okno \"claude\"")
bad(lambda c: c["variables"]["model"].update(default="x"), "nie należy do")
bad(lambda c: c["variables"].update(name={"choices": ["a"]}), "niedozwolona nazwa")
bad(lambda c: c.update(defaultMode="zzz"), "defaultMode")
bad(lambda c: c["actions"]["claude"].update(beforeDrop={"keys": "x"}), "beforeDrop")
# unknown keys only warn
c = json.loads(json.dumps(G)); c["extra"] = 1; c["actions"]["deps"]["foo"] = 1
_, _, warn = m.load(w("u.json", c), none)
assert len(warn) == 2, warn
assert m.session_name("a.b", "c:d") == "a-b/c-d"
print("PROFILES-OK")
PY
)
contains "moduł wt-profiles" "$out" "PROFILES-OK"

echo "-- profiles: wt profiles"
PX=$(mktemp -d)
out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT profiles 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "profiles bez plików exit 0" || bad "profiles bez plików exit $rc"
contains "profiles bez plików komunikat" "$out" "brak plików profili"
mkdir -p "$PX/wt"
printf '%s\n' '{"version":1,"defaultMode":"f","modes":{"f":{"label":"Funkcja","actions":["s"]}},"actions":{"s":{"type":"shell","run":"true"}}}' > "$PX/wt/profiles.json"
out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT profiles 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "profiles list exit 0" || bad "profiles list exit $rc: $out"
contains "profiles list tryb" "$out" "Funkcja"
contains "profiles list źródło" "$out" "[globalne]"
out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT profiles check 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "profiles check OK" || bad "profiles check exit $rc: $out"
printf '%s\n' '{"version":1,"actions":{"s":{"type":"zly"}}}' > "$R/.git/wt-profiles.json"
out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT profiles check 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "profiles check błąd exit != 0" || bad "profiles check przepuścił błąd"
contains "profiles check komunikat" "$out" "actions.s [projekt]"
rm -f "$R/.git/wt-profiles.json"; rm -rf "$PX"
check_fail "profiles zła podkomenda" $WT profiles bogus

echo "-- profiles: wt new z akcjami"
PX=$(mktemp -d); mkdir -p "$PX/wt"
cat > "$PX/wt/profiles.json" <<'JSON'
{"version": 1, "defaultMode": "f",
 "variables": {"greet": {"choices": ["hej", "siema"]}},
 "modes": {
   "f": {"actions": ["rules", "deps", "dev", "solo"]},
   "ok": {"actions": ["rules"]},
   "tm": {"actions": ["t"]}},
 "actions": {
   "rules": {"type": "file", "label": "Zasady", "path": "notes/RULES.md", "content": "{greet} {branch}\n"},
   "deps": {"type": "shell", "label": "Zależności", "run": "echo instaluje; echo zle >&2; exit 3"},
   "dev": {"type": "shell", "run": "touch dev-ran", "needs": ["deps"]},
   "solo": {"type": "shell", "run": "printf '%s|%s' \"$WT_NAME\" \"$WT_MODE\" > solo-ran"},
   "t": {"type": "tmux-session"}}}
JSON
out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT new prof-a --no-fetch 2>&1); rc=$?
P1="$R/.claude/worktrees/prof-a"
[ "$rc" -eq 3 ] && ok "new z błędną akcją zwraca jej kod" || bad "new exit $rc: $out"
check "worktree zostaje mimo błędu" test -d "$P1"
[ "$(cat "$P1/notes/RULES.md" 2>/dev/null)" = "hej prof-a" ] && ok "akcja file z placeholderami" || bad "RULES.md: $(cat "$P1/notes/RULES.md" 2>&1)"
check_fail "zależna akcja pominięta" test -e "$P1/dev-ran"
[ "$(cat "$P1/solo-ran" 2>/dev/null)" = "prof-a|f" ] && ok "niezależna akcja wykonana z env" || bad "solo-ran: $(cat "$P1/solo-ran" 2>&1)"
contains "podsumowanie błąd" "$out" "BŁĄD Zależności (kod 3)"
contains "podsumowanie pominięta" "$out" "dev: pominięta (nie powiodło się: deps)"
contains "output akcji w terminalu" "$out" "instaluje"
st=$(cat "$P1/.wt-actions" 2>/dev/null)
contains ".wt-actions tryb" "$st" "mode=f"
contains ".wt-actions ok" "$st" "action.rules.status=ok"
contains ".wt-actions failed" "$st" "action.deps.status=failed"
contains ".wt-actions kod" "$st" "action.deps.code=3"
contains ".wt-actions skipped" "$st" "action.dev.status=skipped"
contains "log stderr" "$(cat "$P1/.wt-actions.log" 2>/dev/null)" "zle"
[ -z "$(git -C "$P1" status --porcelain --ignored=no)" ] || [ "$(git -C "$P1" status --porcelain | grep -v -e dev-ran -e solo-ran)" = "" ] \
  && ok "pliki akcji wykluczone z gita" || bad "status: $(git -C "$P1" status --porcelain)"
rm -f "$P1/solo-ran"
out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT new prof-b --no-fetch --mode ok --set greet=siema 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "new --mode --set exit 0" || bad "new --mode exit $rc: $out"
[ "$(cat "$R/.claude/worktrees/prof-b/notes/RULES.md" 2>/dev/null)" = "siema prof-b" ] && ok "--set podstawia zmienną" || bad "--set"
out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT new prof-c --no-fetch --skip deps 2>&1)
contains "--skip pomija akcję" "$out" "Zależności: pominięta (--skip)"
contains "--skip pomija zależne" "$out" "dev: pominięta (wymaga deps)"
check_fail "nieznany tryb" env XDG_CONFIG_HOME="$PX" $WT new prof-d --no-fetch --mode zzz
check_fail "zła wartość --set" env XDG_CONFIG_HOME="$PX" $WT new prof-d --no-fetch --set greet=zzz
out=$(cd "$R" && PATH=/usr/bin:/bin XDG_CONFIG_HOME="$PX" $WT new prof-d --no-fetch --mode tm 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "akcje tmux bez tmux: błąd" || bad "akcje tmux bez tmux przeszły"
contains "akcje tmux bez tmux: komunikat" "$out" "brak tmux w PATH"
check_fail "bez worktree po błędzie profilu" test -e "$R/.claude/worktrees/prof-d"
check_fail "bez gałęzi po błędzie profilu" git -C "$R" rev-parse --verify --quiet refs/heads/prof-d
check_fail "--mode bez pliku profili" env XDG_CONFIG_HOME="$PX/nic" $WT new prof-e --no-fetch --mode f
out=$(cd "$R" && XDG_CONFIG_HOME="$PX/nic" $WT new prof-e --no-fetch 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "new bez profili jak dawniej" || bad "new bez profili exit $rc: $out"
check_fail "bez profili brak .wt-actions" test -e "$R/.claude/worktrees/prof-e/.wt-actions"
for w in prof-a prof-b prof-c prof-e; do git -C "$R" worktree remove --force ".claude/worktrees/$w" && git -C "$R" branch -q -D "$w"; done
rm -rf "$PX"

echo "-- profiles: tmux"
if command -v tmux >/dev/null 2>&1; then
  export WT_TMUX_SOCKET="wt-test-$$"
  TM() { tmux -L "$WT_TMUX_SOCKET" "$@"; }
  PX=$(mktemp -d); mkdir -p "$PX/wt"
  cat > "$PX/wt/profiles.json" <<'JSON'
{"version": 1, "defaultMode": "t",
 "modes": {"t": {"actions": ["sess", "cl", "bad", "after"]}},
 "actions": {
   "sess": {"type": "tmux-session"},
   "cl": {"type": "tmux-window", "window": "claude", "run": "sh -c 'read x; echo \"$x\" > ../typed-{name}'",
          "beforeDrop": {"sendKeys": "koniec"}},
   "bad": {"type": "shell", "run": "exit 4"},
   "after": {"type": "tmux-window", "window": "git", "run": "sleep 300"}}}
JSON
  RN=$(basename "$R" | tr '.:' '--')
  out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT new tm-a --no-fetch 2>&1); rc=$?
  PT="$R/.claude/worktrees/tm-a"
  [ "$rc" -eq 4 ] && ok "tmux: kod nieudanej akcji shell" || bad "tmux new exit $rc: $out"
  check "tmux: sesja istnieje" TM has-session -t "=$RN/tm-a"
  wins=$(TM list-windows -t "=$RN/tm-a" -F '#{window_name}' 2>&1 | tr '\n' ' ')
  contains "tmux: okna shell, claude, git" "$wins" "shell claude git"
  pp=$(TM list-panes -t "=$RN/tm-a:shell" -F '#{pane_current_path}' 2>/dev/null)
  [ "$(cd "$pp" 2>/dev/null && pwd -P)" = "$PT" ] && ok "tmux: katalog okna = worktree" || bad "tmux: katalog $pp"
  contains "tmux: komunikat attach" "$out" "tmux attach -t '$RN/tm-a'"
  contains ".wt-actions sesja" "$(cat "$PT/.wt-actions")" "tmux_session=$RN/tm-a"
  contains ".wt-actions sendkeys" "$(cat "$PT/.wt-actions")" "action.cl.sendkeys=koniec"
  out=$(cd "$R" && $WT drop tm-a --check 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "tmux: drop --check nie blokuje się na procesach sesji" || bad "drop --check exit $rc: $out"
  contains "tmux: --check zapowiada zamknięcie" "$out" "sesja tmux do zamknięcia"
  check "tmux: --check nie zamyka sesji" TM has-session -t "=$RN/tm-a"
  sleep 1
  out=$(cd "$R" && $WT drop tm-a 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "tmux: drop exit 0" || bad "tmux drop exit $rc: $out"
  check_fail "tmux: sesja zamknięta" TM has-session -t "=$RN/tm-a"
  check_fail "tmux: worktree usunięty" test -d "$PT"
  contains "tmux: sendKeys wysłane" "$out" "wysyłam do okna"
  [ "$(cat "$R/.claude/worktrees/typed-tm-a" 2>/dev/null)" = "koniec" ] && ok "tmux: program odebrał sendKeys" || bad "sendKeys nie dotarło"
  # Session already gone: drop must still work quietly.
  out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT new tm-b --no-fetch --skip bad 2>&1)
  TM kill-session -t "=$RN/tm-b" 2>/dev/null
  out=$(cd "$R" && $WT drop tm-b 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "tmux: drop bez żywej sesji" || bad "drop bez sesji exit $rc: $out"
  # A process outside the session still blocks the drop.
  out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT new tm-c --no-fetch --skip bad 2>&1)
  (cd "$R/.claude/worktrees/tm-c" && exec sleep 30) & SP=$!
  sleep 0.5
  out=$(cd "$R" && $WT drop tm-c 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "tmux: obcy proces blokuje drop" || bad "obcy proces nie zablokował"
  check "tmux: sesja nietknięta po odmowie" TM has-session -t "=$RN/tm-c"
  kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
  out=$(cd "$R" && $WT drop tm-c 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "tmux: drop po zakończeniu obcego procesu" || bad "drop tm-c exit $rc: $out"
  # drop run from inside the worktree's own session is refused (it would kill itself).
  out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT new tm-d --no-fetch --skip bad 2>&1)
  TM send-keys -t "=$RN/tm-d:shell" "cd '$R' && $WT drop tm-d > '$PX/in-sess.out' 2>&1; echo \$? > '$PX/in-sess.rc'" Enter
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -f "$PX/in-sess.rc" ] && break; sleep 0.3; done
  [ "$(cat "$PX/in-sess.rc" 2>/dev/null)" = 1 ] && ok "tmux: drop z wnętrza sesji odmawia" || bad "drop z wnętrza: rc=$(cat "$PX/in-sess.rc" 2>&1)"
  contains "tmux: komunikat w sesji" "$(cat "$PX/in-sess.out" 2>/dev/null)" "jesteś w sesji tmux"
  check "tmux: sesja przeżyła odmowę" TM has-session -t "=$RN/tm-d"
  out=$(cd "$R" && $WT drop tm-d 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "tmux: drop z zewnątrz po odmowie" || bad "drop tm-d exit $rc: $out"
  TM kill-server 2>/dev/null
  unset WT_TMUX_SOCKET
  rm -rf "$PX"
else
  echo "  (pomijam: brak tmux)"
fi

echo "-- profiles: UI"
out=$(python3 - "$UIBIN" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("wt_ui", sys.argv[1])
spec = importlib.util.spec_from_loader("wt_ui", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
st = m.parse_actions("mode=f\naction.a.status=ok\naction.a.label=Zasady\ntmux_session=r/x\n"
                     "action.b.status=failed\naction.b.code=3\naction.c.status=skipped\naction.c.reason=r\nśmieci\n")
assert st["mode"] == "f" and st["session"] == "r/x", st
assert [a["id"] for a in st["actions"]] == ["a", "b", "c"] and st["actions"][1]["code"] == "3", st
assert st["actions"][0]["label"] == "Zasady" and st["actions"][2]["reason"] == "r"
log = "=== a (shell) ===\nx\n=== a: kod 0 ===\n=== b (shell) ===\n1\n\n2\n3\n4\n=== b: kod 3 ===\n"
assert m.log_tail(log, "b") == ["2", "3", "4"] and m.log_tail(log, "a") == ["x"] and m.log_tail(log, "z") == []
assert m.new_args("f", {"model": "opus"}, {"model": "opus"}, []) == ["--mode", "f"]
assert m.new_args("f", {"model": "opus", "k": "a"}, {"model": "sonnet", "k": "a"}, ["git"]) == \
    ["--mode", "f", "--set", "model=sonnet", "--skip", "git"]
row = {"path": "/p", "branch": "b"}
assert m.open_menu_state(row, None, "ok", True)["t"][0] == "brak sesji"
assert m.open_menu_state(row, None, "ok", True, "r/b", False)["t"][0] == "sesja zamknięta"
assert m.open_menu_state(row, None, "ok", True, "r/b", True)["t"] is None
assert m.load_profiles_module() is not None
base = {"defaultMode": "a", "variables": {"v": {"choices": ["x", "y"], "default": "x"}},
        "modes": {"a": {"actions": ["s"]}, "b": {"actions": []}}, "actions": {}, "prompts": {}}
o = m.profile_override(None, base, base, {"defaultMode": "b", "variables": {"v": "y"}, "modes": {"a": []}})
assert o == {"version": 1, "defaultMode": "b", "variables": {"v": {"choices": ["x", "y"], "default": "y"}},
             "modes": {"a": {"actions": []}}}, o
merged = dict(base, defaultMode="b")
o = m.profile_override({"version": 1, "defaultMode": "b", "extra": 1}, base, merged, {"defaultMode": "a"})
assert o == {"version": 1, "extra": 1}, o
o = m.profile_override({"version": 1, "modes": {"a": {"actions": []}}}, base, base, {"modes": {"a": ["s"]}})
assert o == {"version": 1}, o
print("UI-PROFILES-OK")
PY
)
contains "UI: parsery akcji" "$out" "UI-PROFILES-OK"
PX=$(mktemp -d); mkdir -p "$PX/wt"
printf '%s\n' '{"version":1,"defaultMode":"f","modes":{"f":{"actions":["s"]}},"actions":{"s":{"type":"shell","run":"touch ran"}}}' > "$PX/wt/profiles.json"
out=$(cd "$R" && XDG_CONFIG_HOME="$PX" $WT new np-a --no-fetch --no-profile 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--no-profile exit 0" || bad "--no-profile exit $rc: $out"
check_fail "--no-profile nie uruchamia akcji" test -e "$R/.claude/worktrees/np-a/ran"
check_fail "--no-profile z --mode" env XDG_CONFIG_HOME="$PX" $WT new np-b --no-fetch --no-profile --mode f
git -C "$R" worktree remove --force .claude/worktrees/np-a && git -C "$R" branch -q -D np-a
rm -rf "$PX"

echo "-- profiles: UI (pty)"
PX=$(mktemp -d); mkdir -p "$PX/wt"
printf '%s' '{"version":1,"defaultMode":"f","variables":{"greet":{"label":"Powitanie","choices":["hej","siema"]}},"modes":{"f":{"label":"Funkcja","description":"Funkcja z testem","actions":["rules","dep"]}},"actions":{"rules":{"type":"file","label":"Zasady","path":"R.md","content":"{greet}"},"dep":{"type":"shell","label":"Zależna","run":"touch dep-ran","needs":["rules"]}}}' > "$PX/wt/profiles.json"
cat > "$PX/drive.py" <<'PY'
import fcntl, os, pty, select, struct, sys, termios, time, re
wt_bin, cwd = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd); os.environ["TERM"] = "xterm-256color"; os.environ["WT_UI_POLL"] = "0"
    os.execvp(os.environ.get("WT_SH", "bash"), [os.environ.get("WT_SH", "bash"), wt_bin, "ui"])
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
def until(txt, to=8):
    end = time.time() + to
    while time.time() < end:
        pump(0.2)
        if txt.encode() in buf: return True
    return False
def mark(name, ok): print(("OK " if ok else "FAIL ") + name)
pump(2)
send("n"); pump(0.8)
send("ui-a"); pump(0.3)
send("\r"); pump(0.3); send("\r"); pump(0.8)
mark("picker trybu", until("Tryb nowego worktree"))
mark("opis trybu", until("Funkcja z testem"))
send("\r"); pump(0.8)
mark("formularz akcji", until("Akcje: Funkcja"))
mark("zmienna", until("< hej >"))
send(" "); pump(0.3)       # uncheck first action (Zasady)
mark("zależna oznaczona", until("pominięta: wymaga odznaczonej"))
send("j"); send("j"); pump(0.3); send("l"); pump(0.3)  # variable -> siema
buf = b""
send("\r")
mark("wt new uruchomione", until("--set greet=siema", 10))
mark("koniec", until("[koniec, kod 0]", 15))
buf = b""
send("\r")
mark("panel akcji profilu", until("Akcje profilu", 6))
send("q"); pump(1)
PY
UT=$(mkrepo)
out=$(WT_SH="$SH" XDG_CONFIG_HOME="$PX" python3 "$PX/drive.py" "$WT_BIN" "$UT" 2>&1)
for w in "picker trybu" "opis trybu" "formularz akcji" "zmienna" "zależna oznaczona" "wt new uruchomione" "koniec" "panel akcji profilu"; do
  contains "UI pty: $w" "$out" "OK $w"
done
contains "UI pty: --skip z odznaczenia" "$(cat "$UT/.claude/worktrees/ui-a/.wt-actions" 2>/dev/null)" "action.rules.reason=pominięta (--skip)"
rm -rf "$PX" "$UT"

echo "-- profiles: UI ekran P (pty)"
PX=$(mktemp -d); mkdir -p "$PX/wt"
printf '%s' '{"version":1,"defaultMode":"a","variables":{"greet":{"label":"Powitanie","choices":["hej","siema"]}},"modes":{"a":{"label":"Alfa","actions":["s1","s2"]},"b":{"label":"Beta","actions":[]}},"actions":{"s1":{"type":"shell","label":"Pierwsza","run":"true"},"s2":{"type":"shell","label":"Druga","run":"true","needs":["s1"]}}}' > "$PX/wt/profiles.json"
cat > "$PX/drivep.py" <<'PY'
import fcntl, os, pty, select, struct, sys, termios, time
wt_bin, cwd = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd); os.environ["TERM"] = "xterm-256color"; os.environ["WT_UI_POLL"] = "0"
    os.execvp(os.environ.get("WT_SH", "bash"), [os.environ.get("WT_SH", "bash"), wt_bin, "ui"])
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
def until(txt, to=8):
    end = time.time() + to
    while time.time() < end:
        pump(0.2)
        if txt.encode() in buf: return True
    return False
def mark(name, ok): print(("OK " if ok else "FAIL ") + name)
pump(2)
send("P"); mark("ekran", until("Tryb domyślny"))
send("l"); pump(0.4)                  # default mode a -> b
send("j"); send("l"); pump(0.4)       # greet hej -> siema
send("j"); send("\r"); pump(0.6)      # mode Alfa: edit actions
mark("edytor akcji", until("Akcje trybu: Alfa"))
send(" "); send("\r"); pump(0.6)      # drop s1 -> s2 needs s1 -> invalid
send("s"); mark("błąd walidacji", until("nie zapisano", 4))
send("\r"); pump(0.4)
send("\r"); pump(0.6); send(" "); send("j"); send(" "); send("\r"); pump(0.6)  # s1 back on, s2 off
buf = b""
send("s"); mark("zapisane", until("profile zapisane", 4))
send("q"); pump(1)
PY
UT=$(mkrepo)
out=$(WT_SH="$SH" XDG_CONFIG_HOME="$PX" python3 "$PX/drivep.py" "$WT_BIN" "$UT" 2>&1)
for w in "ekran" "edytor akcji" "błąd walidacji" "zapisane"; do
  contains "UI P: $w" "$out" "OK $w"
done
got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("defaultMode"), d["variables"]["greet"]["default"], d["modes"]["a"]["actions"], sorted(d))' "$UT/.git/wt-profiles.json" 2>&1)
contains "UI P: minimalny zapis" "$got" "b siema ['s1'] ['defaultMode', 'modes', 'variables', 'version']"
check "UI P: wt profiles check po zapisie" sh -c "cd '$UT' && XDG_CONFIG_HOME='$PX' $WT profiles check"
rm -rf "$PX" "$UT"

echo
echo "WYNIK: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
