<img src="logo.png" alt="Sensmos" height="72">

# Sensmos — Whitepaper (PL)

**Zdecentralizowana sieć czujników, która mierzy realny świat, oddaje dane ludziom, którzy je wytwarzają, i nagradza realny fizyczny wkład tokenem GALU.**

> Wersja 1.0 · GALU na Polygonie · Kontrakt [`0x9d797D0E642D9EADdbDbD34ACFCFd07bf0043c6C`](https://polygonscan.com/token/0x9d797D0E642D9EADdbDbD34ACFCFd07bf0043c6C)
> Dokument opisowy, nie porada finansowa. Podane parametry to wartości wdrożone i mogą być strojone przez operatora (patrz §6, §10).

---

## Streszczenie

Wielkie firmy mierzą autostrady i centra miast. Prawie nikt nie mierzy *Twojej* ulicy — jakości jej prądu, zasięgu, powietrza. Sensmos zamienia tani ESP32 w noda, który mierzy realny świat lokalnie, publikuje na wspólnej żywej mapie, może handlować danymi peer-to-peer i zarabia **GALU** za prawdziwy, poświadczony wkład. Te same nody tworzą też siatkę pomiarową: sondują siebie nawzajem i publiczne usługi między krajami (ICMP, TCP, DNS, HTTP), budując żywy obraz zdrowia internetu widziany **z realnych domów, nie z centrów danych** — drugą, sieciową płaszczyznę tej samej tkanki. Urządzenie nie zależy od chmury, tożsamość powstaje na układzie, a ekonomia nagród jest **fizycznie pokryta** on-chain: każda jednostka nagrody ma pokrycie w tokenach realnie trzymanych w kontrakcie — żadnej wirtualnej rezerwy. Ten dokument opisuje sieć, jej architekturę, model anty-sybil i ekonomię emisji GALU dokładnie tak, jak są wdrożone.

---

## 1. Problem

Dane o środowisku, sieci energetycznej i łączności są skupione w rękach kilku instytucji, zbierane tam gdzie to komercyjnie wygodne, i rzadko wracają do ludzi, których dotyczą. A pasjonat z mikrokontrolerem za 20 zł zmierzy swoje otoczenie lepiej niż jakikolwiek satelita — tylko nie ma wspólnej tkanki, do której mógłby publikować, motywacji by node żył, ani sposobu by udowodnić, że odczyt jest prawdziwy, a nie sfałszowany.

Sensmos zamyka trzy luki naraz:

1. **Tkanka** — żywa, publiczna mapa, gdzie publiczne odczyty każdego noda składają się na wspólny obraz okolicy.
2. **Motywacja** — token nagradzający uptime i *rzadkość pokrycia* (mierzenie tam, gdzie nikt inny), a nie spekulację.
3. **Dowód fizyczności** — ceremonia atestacji urządzenia, by jedna tożsamość nagrodowa = jeden realny node, nie farma symulatorów.

---

## 2. Sieć

### Nody i encje
Node publikuje odczyty jako **encje**, grupowane po prefiksie `entity_id`:

| Prefiks | Znaczenie | Na mapie? | Nagradzane? |
|---------|-----------|-----------|-------------|
| `pub.*` | natywne pomiary z whitelisty sieci (prąd, klimat, sygnał…) | tak | tak |
| `own.*` | Twoje własne / z integracji | jako dane własne noda, bez historii | nie |
| `sub.* · get.* · msg.*` | subskrypcje, pobrania z web, wiadomości | bufor lokalny | nie |
| `tmp.*` | bufor roboczy skryptów | nie | nie |

### Żywa mapa
Każdy publiczny odczyt zasila żywą mapę, feed zdarzeń i heatmapę wartości. Każdy node ma obszar **pokrycia**, którego promień wynika czysto z gęstości: node zajmuje ciaśniejszy promień tylko wtedy, gdy otacza go wystarczająco wielu realnych sąsiadów (próg sąsiadów rośnie, im ciaśniejszy promień) — samotny node w nieobsłużonym regionie pokrywa szeroki obszar, a gęste skupisko kurczy się do ciasnych kółek.

### Płaszczyzna sieciowa (checknet)
Poza pomiarami każdy node uczestniczy w **siatce pomiarowej**: pinguje nody w innych krajach i zestaw publicznych/anycastowych celów (ICMP) oraz wykonuje lekkie sondy **TCP connect**, **DNS resolve + integralność** i **HTTP status/TTFB**. Backend agreguje wyniki w pasma opóźnień kraj↔kraj rysowane na żywo na mapie, plus sieciowe score'y per node (ping, jitter, loss, zasięg). Ponieważ sondy wychodzą z realnych łączy domowych, a nie z centrów danych, obraz opóźnień, osiągalności i integralności DNS pokazuje internet **taki, jakim naprawdę doświadczają go ludzie** — punkt obserwacyjny, którego komercyjne sieci monitoringu nie kupią. Monitoring kierowany (obserwacja *własnego* serwera z wielu krajów naraz) budowany jest na tej samej płaszczyźnie — patrz roadmapa (§9).

### Rynek danych P2P
Node może **subskrybować** odczyty innego noda (`sub.*`), rozliczane dobowo w GALU, z prywatnym prefiksem, którego backend nigdy nie pozna. To strona popytowa ekonomii: dane, które mają dla kogoś wartość, płyną wprost między urządzeniami.

---

## 3. Architektura

```
ESP32 node ──podpisany batch──▶ Backend ──▶ PostgreSQL
   ▲  │ (lokalne HTTP API,                   │
   │  │  provisioning BLE)         ┌─────────┴─────────┐
   │  ▼                            ▼                   ▼
 Home Assistant             Żywa mapa / API       Polygon
 / ESPHome                  (przeglądarka, apka) (kontrakt GALU)
```

- **Firmware (Arduino-ESP32).** Czyta czujniki, ma **silnik skryptów na brzegu** — reguły do 4 kroków (`if → akcja`: webhook, push, fetch z web, ping/monitor, wiadomość do innego noda) działające lokalnie, bez chmury. Wystawia lokalne HTTP API w sieci LAN.
- **Backend (Node.js · PostgreSQL · ethers v6).** Przyjmuje podpisane batche przez WebSocket, liczy dobową *epokę* (scoring + pula nagród + Merkle), serwuje mapę/ranking/statystyki i wysyła rooty on-chain.
- **Apka mobilna (Flutter).** Portfel self-custody, onboarding noda przez BLE, żywa mapa, claim/deposit.
- **Integracja Home Assistant (HACS).** Wnosi dane noda do HA i karmi noda danymi z HA — w pełni lokalnie, bez brokera.

---

## 4. Tożsamość, zaufanie i anty-sybil

- **Tożsamość na urządzeniu.** Każdy node generuje parę kluczy `secp256k1` lokalnie i **podpisuje każdy batch**. Klucz prywatny nigdy nie trafia do obrazu firmware ani nie opuszcza układu.
- **Geolokalizacja app-proof.** Pozycja noda jest ustawiana wyłącznie z GPS telefonu zebranego **wewnątrz ceremonii atestacji** (kotwica dowodu), opcjonalnie rozmywana 200–800 m dla prywatności; czytelne miasto liczy serwer. Deklarowana pozycja jest dodatkowo **krzyżowo sprawdzana z punktem wyjścia noda do sieci** (kraj i odległość geo-IP) — GPS niespójny z tym, skąd node faktycznie się łączy, jest odrzucany. Pozycji nie da się wpisać ręcznie.
- **Atestacja urządzenia.** Ceremonia przez Bluetooth z rundami czasowymi i podwójnym podpisem dowodzi `1 device_id = 1 fizyczny node`, zabijając farmy symulatorów. **Tylko poświadczone („trusted") nody liczą się do emisji.**
- **Cap wspólnego łącza.** Waga nagrody zawiera czynnik zależny od **publicznego IP wyjściowego** noda: dwa nody za jednym łączem zachowują ~0,95 każdy, a czynnik łagodnie maleje, im więcej nodów dzieli to samo IP. Co kluczowe, opiera się on na twardych faktach sieciowych, **nie na portfelu** — zakładanie nowych portfeli go nie resetuje. Razem z geograficzną rzadkością (§5) czyni to farmę stłoczonych nodów nieopłacalną, nie ruszając prawdziwych domów z kilkoma nodami.

Razem czyni to fałszowanie kosztownym: żeby udawać nagrody, potrzebujesz realnego sprzętu, realnego klucza, realnego telefonu w realnej lokalizacji, przechodzącego challenge w czasie rzeczywistym — a każde kolejne stłoczone urządzenie zarabia wyraźnie mniej.

---

## 5. Ekonomia GALU

### Zasada nadrzędna
**Lifetime entitlement adresu może wzrosnąć tylko o tyle, ile pula ma fizyczne pokrycie w GALU.** Wypłacalność egzekwowana on-chain dwukrotnie: claim wymaga `balanceOf(pula) ≥ wypłata`, a mint wymaga `balanceOf(pula) ≥ totalEntitlement − totalClaimed` po dodruku. Żadnej wirtualnej rezerwy — pula *to* GALU trzymane w kontrakcie.

### Epoka (raz na ~24 h)
Dla każdego zaufanego, aktywnego noda z min. `MIN_PINGS` pingami:

```
waga       = scarcity × kategorie × uptime × aktywność × łącze
per_node   = BASE                       gdy trusted ≤ THRESHOLD
           = BASE × THRESHOLD / trusted  gdy trusted > THRESHOLD  (decay)
fresh_mint = min(trusted × per_node, MAX_EPOCH_MINT, cap_left)   ← zawsze pełny do capa
reserve    = recycle + external                                 ← worek fizycznych GALU
release    = RELEASE_RATE × reserve                             ← dolewka, max 5%/epokę
burn       = BURN_RATE × release                                ← deflacja
pula       = fresh_mint + (release − burn)
team       = TEAM_FEE × pula                                    ← Model B (w drzewie Merkle)
reward_i   = (pula − team) × waga_i / Σwag                      ← udział; może przekroczyć BASE
```

Nagroda noda to **udział w puli wg wagi** — lepiej położony, z wyższym uptime bierze większy kawałek kosztem słabszych, a nie przez dodruk nowych tokenów.

Czynniki wagi, dokładnie jak wdrożone:

- **scarcity** jest *geograficzna*: backend liczy innych aktywnych nodów w adaptacyjnym promieniu pokrycia noda, a mnożnik spada **liniowo od 1,5 (sam w regionie) do podłogi 0,8** w gęstych obszarach. Uwaga: schodzi *poniżej* 1,0 — redundantne pokrycie jest aktywnie karane, nie tylko pozbawione bonusu. Bycie tam, gdzie nikt inny nie mierzy, to najsilniejsza dźwignia.
- **kategorie** — +10% za każdą realną kategorię pomiarową (prąd / środowisko / dom), cap 1,3×. Wbudowana telemetria sieciowa się nie liczy.
- **uptime** — odsetek dostarczonych pingów.
- **aktywność** — +2% za żywą encję, cap 1,1×.
- **łącze** — czynnik wspólnego IP (§4): 1,0 dla jedynego noda na łączu, łagodnie malejący gdy kilka nodów dzieli jedno IP wyjściowe.

Maksimum ≈ 2,14× (pełny uptime, jedyny node na łączu); node stłoczony w zatłoczonym miejscu na wspólnym łączu może spaść wyraźnie poniżej 1×.

### Trzy wejścia, jedno wyjście
| Źródło | Co to | Inflacja? |
|--------|-------|-----------|
| **mint** | świeża emisja do hard capa (bootstrap) | tak |
| **recycle** | wydatki w sieci (query, subskrypcje, wiadomości) wracające do puli | nie |
| **external** (`fundPool`) | przychód (np. sprzedaż danych) → kupione GALU z rynku → pula | **nie** |

Recycle i external lądują w jednej **rezerwie**; tylko ~5% dolewane jest do nagród co epokę, wygładzając skoki. Jedyne wyjście to **claim**.

### Wypłaty cumulative
Nagrody rozdawane są jako **cumulative Merkle drop**: root koduje *lifetime* entitlement adresu, kontrakt śledzi ile już odebrano i wypłaca różnicę. Jedna transakcja odbiera całą zaległość, podwójne claimy są niemożliwe z konstrukcji, a pominięty submit on-chain leczy się sam w kolejnej epoce.

### Cykl życia i „real yield"
| Faza | Warunek | Źródło nagród |
|------|---------|---------------|
| Rampa | < THRESHOLD nodów | głównie świeży mint |
| Decay | > THRESHOLD nodów | mint (capnięty) + dolewka |
| Post-cap | wymintowany hard cap | recycle + **przychód (fundPool)** |

Po cap nie ma inflacji. Aktywna, przychodowa sieć dalej płaci nagrody z recyklu wydatków i odkupionych tokenów — *real yield* pokryty realną wartością, presja kupna zamiast rozwodnienia. Martwa sieć bez przychodu po prostu schnie do zera.

---

## 6. Tokenomika (wartości wdrożone)

| Parametr | Wartość | Gdzie egzekwowane |
|----------|---------|-------------------|
| Token | GALU, ERC-20 na Polygonie | kontrakt |
| Hard cap (`MAX_SUPPLY`) | **40 000 000** | stała kontraktu, niezmienna |
| Sufit mintu/epokę (`MAX_EPOCH_MINT`) | **40 000** | stała kontraktu |
| Bazowa nagroda | 10 GALU / node / epokę | konfig. BE |
| Próg decay | 4 000 nodów | konfig. BE |
| Dolewka z rezerwy (`RELEASE_RATE`) | 5% / epokę | konfig. BE |
| Burn (`BURN_RATE`) | 10% dolewki | konfig. BE |
| Udział teamu | 5% puli — *Model B*, claimowany jak każdy adres | konfig. BE |
| Udział dostawcy danych | 30% wydatku za dane | konfig. BE |
| Min / max pingów | 24 / 96 na epokę | konfig. BE |
| Liczone nody | tylko trusted (poświadczone) | anty-sybil |

Wartości z konfigu BE są strojone na żywo i mogą taperować w czasie (nominalna kwota znaczy mniej niż wartość — emisję można zmniejszać wraz ze wzrostem sieci i ceny tokena). Dwie stałe kontraktu (cap, sufit mintu) są niezmienne.

**Team (Model B).** 5% dla teamu jest *częścią puli*, siedzi w drzewie Merkle jako zwykły adres i jest claimowane jak node — bez osobnego mintu na wierzchu.

---

## 7. Bezpieczeństwo i governance

**Inwarianty on-chain (testy obowiązkowe):**
- Wypłacalność: po mincie i burn `balanceOf(pula) ≥ totalEntitlement − totalClaimed`; claim wymaga `balanceOf ≥ wypłata`.
- Breaker inflacji: mint/epokę `≤ MAX_EPOCH_MINT × span`; `ERC20Capped` pilnuje capa 40M.
- Rate-limity: minimalny odstęp między mintami epok i ograniczony przeskok numeru epoki — limitują, jak szybko skompromitowany klucz mintera mógłby działać.
- Anti double-spend: saldo do wydania odejmuje już odebrane (z eventu `Claimed`).
- Precyzja: kwoty liści i suma entitlement liczone identycznie, więc suma liści = `totalEntitlement` co do weia.

**Role.** *Minter* (gorący klucz operacyjny, którym podpisuje backend) jest osobny od *ownera* (zimny klucz, który może pauzować i wymieniać mintera, docelowo multisig + timelock).

**Uczciwy model zaufania.** Jak każdy system merkle-reward / airdrop, kontrakt sam nie zweryfikuje, że opublikowany root jest „uczciwy" — egzekwuje wypłacalność i rate-limity, ale treść roota jest zaufana minterowi. To standardowa postawa na starcie. Ścieżka utwardzania: owner → multisig + timelock, publiczne dane nagród do weryfikacji przez społeczność, monitoring off-chain z pauzą jako bezpiecznikiem, segregacja depozytów userów, a docelowo dowody optymistyczne (challengeable) lub zero-knowledge poprawności wyliczenia — w miarę wzrostu wartości.

---

## 8. Zastosowania

- **Jakość prądu** — napięcie i stabilność sieci; wykrywaj spadki, skoki i awarie u siebie.
- **Zasięg i sygnał** — realna mapa siły WiFi/radia tam, gdzie ludzie mieszkają.
- **Klimat i środowisko** — temperatura, wilgotność, ciśnienie, jakość powietrza z dowolnego czujnika.
- **Zdrowie internetu** — siatka nodów mierzy opóźnienia między krajami, integralność DNS i osiągalność usług z realnych łączy domowych; ta sama płaszczyzna działa jako domowy uptime-monitor Twoich serwerów.
- **Automatyka na brzegu** — lokalne reguły `if → akcja`, webhooki, push, oraz pełnoprawny most Home Assistant / ESPHome.
- **Dane peer** — subskrybuj odczyty sąsiada albo sprzedaj swoje do sieci.

---

## 9. Roadmap

1. **Live (teraz).** Kontrakt wdrożony i zweryfikowany na Polygonie; dobowe epoki mintują i publikują cumulative rooty; firmware, apka, integracja HA i dokumentacja protokołu open-source. Ambientowa siatka pomiarowa (node↔node ICMP + sondy TCP/DNS/HTTP) działa na całej flocie i zasila żywą mapę.
2. **Wzrost.** Onboarding realnych nodów, utwardzenie strony popytowej (marketplace danych / przychód → `fundPool`), dopieszczenie UX konsumenckiego.
3. **Network intelligence.** Zamiana siatki pomiarowej w produkt: **monitoring kierowany** — obserwuj *własny* serwer z wielu krajów naraz (uptime, TTFB, odpowiedzi DNS, alerty), plus publiczny **Radar internetu** i API datasetów. Otwarcie na klientów zewnętrznych jest twardo bramkowane dwoma zabezpieczeniami: kryptograficznie **podpisane joby sond** (node wykonuje tylko to, co podpisał backend) oraz **weryfikacja własności celu** — sieć sonduje wyłącznie to, czego kontrolę klient udowodni.
4. **Utwardzenie zaufania.** Owner → multisig + timelock, audyt zewnętrzny, publiczne zbiory danych nagród + monitoring.
5. **Weryfikowalność.** Przesunięcie oracle nagród z „zaufanego" ku „challengeable / dowodliwemu", gdy wartość to uzasadni.

---

## 10. Czynniki ryzyka i zastrzeżenie

GALU to token nagrodowy w sieci, nie instrument inwestycyjny; nic tu nie jest obietnicą wartości ani zwrotu. Ekonomia jest wczesna i parametry mogą się zmieniać. Kluczowe ryzyka: model zaufanego mintera do czasu utwardzenia (§7); kompromitacja klucza on-chain; ryzyko smart-kontraktu przed audytem; niepewność regulacyjna wokół tokenów; oraz zależność od działania backendu w fazie scentralizowanej. Firmware i integracja Home Assistant działają w pełni lokalnie i nie wymagają warstwy tokenowej.

---

*Część projektu Sensmos — patrz [README](README.md), [EMISSION_MODEL.md](EMISSION_MODEL.md), [HOW_IT_WORKS.md](HOW_IT_WORKS.md). Strona: https://sensmos.com · Discord: https://discord.gg/ukea386Kqx*
