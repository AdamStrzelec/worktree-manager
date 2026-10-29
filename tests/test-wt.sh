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

echo "-- poza repo"
out=$(cd / && $WT list 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "poza repo exit 1" || bad "poza repo exit $rc"
contains "poza repo komunikat" "$out" "nie jesteś w repo git"

echo
echo "WYNIK: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
