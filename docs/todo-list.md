 TODO:
 Skroty dla pojedynczego wt w UI:
[ ] - mozliwosc spushowania i/lub utworzenia PR
[ ] - mozliwosc edycji PR - np. zmiana jego statusu na draft i zeby dzialalo to w obydwie strony czyli z poziomu wt UI -> zmienia sie na origin i odwrotnie + w task TUI
[ ] - mozliwosc zmergowania PR
[ ] - mozliwosc usuniecia worktree - jesli nie ma przeciwwskazan
[ ] - mozliwosc zmergowania + usuniecia worktree - jesli zostana spelnine odpowiednie warunki

Mozliwosc bezposredniego otwarcia z poziomu UI lub aliasem z poziomu terminala takich narzedzi jak:
[ ] - VS Code z worktree,
[ ] - terminal automatycznie utworzoną sesją w tmux dla naszego worktree o czym wspominam nizej
[ ] - Sesja Claude w tmux z przygotowanym odpowiednio promptem lub podlinkowanym taskiem

Edycja configu z poziomu UI
[ ] - mozliwosc zdefiniowania path do katalogu, w ktorym maja byc tworzone worktrees
[ ] - mozliwosc zdefiniowania jak maja byc obslugiwane niesledzone grzez git pliki z katalogu glownego w utworzonym worktree takie jak .env.local
[ ] - mozliwosc zdefiniowania jakie komendy sie maja odpalic po utworzeniu nowego worktree jak np. npm run dev itd.
[ ] - mozliwosc zdefiniowania czy i w jaki sposob maja sie tworzyc i USUWAC automatycznie inne rzeczy wraz z utworzeniem i usunieciem worktree jak np. sesje tmuxa wraz z odpowiednia nazwa itd. - DO USTALENIA

Tworzenie worktree z poziomu UI
[ ] - zamiast pojedynczego inputa do wpisywania nazwy nowego worktree dodac modal, w ktorym dodatkowo bedzie mozna wybrac target branch sposrod dostepnych
[ ] - Dodatkowy input na tytuł, który będzie sobie mozna wyświetlić w szczegółach worktree

Widok UI - ogolne poprawki
[ ] - dodac jakis autorefresh co okreslony interwal czasowy aby nam sie odswiezala zawartosci widoku panelu UI kiedy w krotkim czasie zostana dodane np. nowe commity lub niezacommitowane zmiany
[ ] - menu widoczne po nacisnieciu spacji ma miec te skroty odpowiednio pokategoryzowane wg zakresu dzialania i w oddzielnych kolumnach ktore to beda opisywac - np. Wybrane worktree (dla skrótów dotyczących sfokusowanego worktree z listy), Nawigacja (j/k gg/G), Widok (filtracja, sortowanie) itd.

Widok listy z utworzonymi worktreesami - szczegóły pojedynczego itemu i co sie ma w nim znajdowac
[x] - nazwa galezi (juz jest)
[ ] - Tytul taska - z task TUI
[ ] - info o PR - jesli jest utworzony PR - czyli jesli pr ma nr. 50 to ma sie wyświetlać "PR #50"
[ ] - info o statusie PR - np. ze ma status draft
[ ] - info o potencjalnych konfliktach do rozwiazania
[ ] - info o statusie CI - i jakas ikonka zielona, zolta lub czerwona w zaleznosci od statusu
[ ] - wiek czyli jak dawno temu zostal ten worktree utworzony
[ ] - pola ahead i brudne zostają tylko trzeba im lepsze tytuły wymyslić (rowniez w widoku szczegolow)
DO ZAPAMIETAMIN JEDNA RZECZ - te rzeczy, ktore wymienilem jako elementy pojedynczego itemu na liście nie muszą byc wyswietlane w pojedynczym wierszu na kazdy item, a np. w 2/3 wierszach bo tych worktrees raczej nie bedzie jakos bardzo duzo

Widok szczegółów dla sfokusowanego worktree
[ ] - Na gorze pomiedzy path'em do worktree a metadanymi ma sie wyswietlac tytul worktree, ktory podalismy w modalu podczas jego tworzenia
[ ] - pole wiek ma pokazywac to co teraz + ponizej w nastepnej linii dokladna data utworzenia
[ ] - Metadane o PR jeśli istnieje i te same co wymienilem wyzej czyli "#PR 50", jesli draft widoczne info, jesli konflikty to info ze ma konflikty + ktore pliki maja te konflikty, Bezposredni link do otwarcia sobie tego PR w przegladarce
[ ] - Info o CI - tutaj juz mozna dac bardziej dokladne info na temat poszczegolnych CI a nie tylko ikonke w danym kolorze

Integracja z Task TUI (nasze narzedzie utworzone na zdalnym userze ssh do zarzadzania taskami) - to na sam koniec jak juz wszystko powyzej bedzie zrobione
[ ] - automatyczne tworzenie nowego worktree u mnie w lokalnym repo kiedy to task dostanie odpowiedni status - DO SPRAWDZENIA
[ ] - automatyczne usuwanie worktree u mnie lokalnie kiedy tam status taska zostanie np. zmieniony na CLOSED - TEZ DO SPRAWDZENIA
I INNE RZECZY KTORE TRZEBA BEDZIE SPRAWDZIC PO DRODZE, A JESZCZE NAWET O NICH NIE POMYSLALEM
