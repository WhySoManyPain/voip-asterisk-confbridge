# VoIP konferenční ústředna Asterisk (`ConfBridge` + `Music on Hold`)

Kompletní postup nasazení, konfigurace, ladění zvuku a ověření funkčnosti VoIP ústředny **Asterisk PBX** v kontejneru Docker na systému **Fedora 44** a dvěma souběžně běžícími SIP klienty (**Linphone** a **Twinkle**).

## Cíl projektu a architektura

Projekt demonstruje konferenční místnost `ConfBridge` na klapce `8000` s parametrem `music_on_hold_when_empty=yes` a automatickým nahráváním hovoru:
* **1 účastník v místnosti (`1001`):** Asterisk automaticky přehrává hudbu při čekání (*Music on Hold*).
* **2 účastníci v místnosti (`1001` + `1002`):** Hudba při čekání se vypne a oba účastníci spolu komunikují v konferenčním mostu.
* **Odchod 2. účastníka (`1002`):** Prvnímu účastníkovi (`1001`) se opět automaticky spustí hudba při čekání.

| Komponenta | Role | SIP účet / Klapka | Lokální UDP port |
| :--- | :--- | :--- | :--- | :--- |
| **Asterisk PBX (Docker)** | VoIP ústředna (`network_mode: host`) | `8000` (ConfBridge) | `5060` (RTP `10000–10020`)
| **Linphone 6.2.5 (AppImage)** | Softphone 1 (hlavní účastník) | `1001` (heslo `voip1001`) | `5064` |
| **Twinkle 1.11.0** | Softphone 2 (druhý účastník) | `1002` (heslo `voip1002`) | `5062` |

---

## 1. Vytvoření struktury projektu a Docker kontejneru

Vytvoření pracovní složky projektu, adresáře pro konfiguraci Asterisku a složky `evidence` pro uložení výstupních důkazů:

```bash
mkdir -p ~/voip-asterisk-confbridge/{asterisk/config,evidence}
cd ~/voip-asterisk-confbridge
```

Vytvoření souboru `docker-compose.yml` s síťovým režimem `network_mode: host`, díky kterému kontejner sdílí síťové rozhraní hostitele bez problémů s NATem u SIP a RTP paketů:

```yaml
services:
  asterisk:
    image: andrius/asterisk:latest
    container_name: voip-asterisk
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./asterisk/config:/etc/asterisk
```

---

## 2. Konfigurační soubory ústředny Asterisk (`asterisk/config/`)

### `pjsip.conf` – SIP transport a registrace linek `1001` a `1002`
Definice UDP transportu a dvou koncových bodů (`1001`, `1002`) s kodeky `ulaw` a `alaw`:

```ini
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0


[endpoint-tpl](!)
type=endpoint
context=internal
disallow=all
allow=ulaw
allow=alaw
direct_media=no
dtmf_mode=rfc4733
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes


[auth-tpl](!)
type=auth
auth_type=userpass

[aor-tpl](!)
type=aor
max_contacts=1
remove_existing=yes

[1001](endpoint-tpl)
auth=auth1001
aors=1001
[auth1001](auth-tpl)
username=1001
password=voip1001
[1001](aor-tpl)

[1002](endpoint-tpl)
auth=auth1002  
aors=1002
[auth1002](auth-tpl)
username=1002
password=voip1002
[1002](aor-tpl)

```
### `musiconhold.conf` – Výběr hudby pro čekání na připojení druhého učastníka

```ini
[default]
mode=files
directory=/var/lib/asterisk/moh/
``` 

### `confbridge.conf` – Konferenční místnost, nahrávání a hudba při čekání
Zapnutí automatického nahrávání (`record_conference=yes`), zapnutí hudby při čekání osamoceného účastníka (`music_on_hold_when_empty=yes`) a DTMF nabídka:

```ini
[general]

[moje_konference]
  
type=bridge
; Nahrávání konference

record_conference=yes
record_file=/tmp/konference_nahravka.wav

[uzivatel]
type=user
; Hudba při čekání na spojení (MoH)
music_on_hold_when_empty=yes
music_on_hold_class=default
announce_join_leave=no

[moje_menu]
type=menu
; Dynamické menu DTMF
*=playback_and_continue(conf-username)
*1=toggle_mute
*2=leave_conference
*3=increase_listening_volume
*4=decrease_listening_volume
```

### `extensions.conf` – Číslovací plán (Dialplan)
Směrování přímých hovorů mezi linkami `1001` a `1002`, vstupu do konferenční místnosti na klapce `8000` a testovací ozvěny na klapce `8001`:

```ini
[internal]
exten => 8000,1,Answer()
 same => n,ConfBridge(1,moje_konference,uzivatel,moje_menu)
 same => n,Hangup()

```

### `rtp.conf`, `cdr.conf` a `cdr_csv.conf` – Mediální porty a logování hovorů
Vymezení rozsahu RTP portů `10000–10020` a aktivace ukládání historie hovorů (CDR) do CSV souboru:

```ini
; rtp.conf
[general]
rtpstart=10000
rtpend=10020
```

```ini
; cdr.conf
[general]
enable=yes
unanswered=yes
```

```ini
; cdr_csv.conf
[global]
usegmtime=no
loguniqueid=yes
loguserfield=yes
accountlogs=yes
```

---

## 3. Spuštění kontejneru, firewall a příprava CDR logu

Spuštění kontejneru na pozadí, otevření SIP a RTP portů ve firewallu Fedory a vytvoření zapisovatelného adresáře `/var/log/asterisk/cdr-csv` uvnitř kontejneru pro soubor `Master.csv`:

```bash
cd ~/voip-asterisk-confbridge
sudo docker compose up -d
sudo firewall-cmd --add-port=5060/udp --add-port=10000-10020/udp
sudo docker exec -u root voip-asterisk sh -c "mkdir -p /var/log/asterisk/cdr-csv && chown -R asterisk:asterisk /var/log/asterisk/cdr-csv"
```

Ověření běžícího kontejneru, obsazeného portu `5060` a registrovaných SIP linek:

```bash
sudo docker ps --filter name=voip-asterisk
sudo ss -ulnp | grep 5060
sudo docker exec voip-asterisk asterisk -rx "pjsip show endpoints"
```

---


## 5. Nastavení dvou souběžných softphone klientů

Aby oba klienti běželi současně bez konfliktu o port `5060` (obsazený Asteriskem) a bez automatického přidržení hovoru, používá každý klient vlastní lokální SIP port.

### Softphone 1: Linphone 6.2.5 AppImage (Linka `1001`, port `5064`)
Stažení a spuštění aplikace Linphone:

```bash
chmod +x ~/Downloads/Linphone-6.2.5-x86_64.AppImage
~/Downloads/Linphone-6.2.5-x86_64.AppImage 
```

Nastavení v rozhraní Linphone:
1. **Přihlášení účtu:** Username `1001`, Password `voip1001`, Domain `127.0.0.1`, Transport `UDP`.


### Softphone 2: Twinkle (Linka `1002`, port `5062`)
Stažení a spuštění Twinkle

```bash
sudo dnf install twinkle
twinkle 
```

Nastavení v rozhraní Twinkle:
* V menu **File → Change user** aktivovat pouze profil **`1002`** (heslo `voip1002`, doména `127.0.0.1`).

---

## 6. Průběh testu a diagnostika RTP provozu

1. **Vstup 1. účastníka:** Z **Linphone (`1001`)** vytočit `8000` → ve sluchátkách se ozve hudba při čekání (*Music on Hold*).
2. **Vstup 2. účastníka:** Z **Twinkle (`1002`)** vytočit `8000` → hudba při čekání se zastaví a hlas z mikrofonu  se přenáší do konference a nahrává.
3. **Odchod 2. účastníka:** V **Twinkle (`1002`)** hovor zavěsit → v **Linphone (`1001`)** se hudba při čekání opět automaticky spustí.
4. **Ukončení testu:** V **Linphone (`1001`)** hovor zavěsit → Asterisk uzavře WAV záznam konference a zapíše záznamy hovorů do `Master.csv`.

Diagnostika obousměrného toku RTP paketů v živé konzoli Asterisku:

```bash
sudo docker exec -it voip-asterisk asterisk -rvvv
# Příkazy uvnitř Asterisk CLI:
# rtp set debug on
# confbridge list
# rtp set debug off
```

---

## 7. Extrakce důkazů a nahrání na GitHub

Zkopírování nejnovější nahrávky konference a výpisu hovorů `Master.csv` z kontejneru do lokální složky `evidence/`:

```bash
mkdir -p ~/voip-asterisk-confbridge/evidence
sudo docker exec voip-asterisk sh -c 'cat "$(ls -t /tmp/konference_nahravka-*.wav /var/spool/asterisk/monitor/*.wav 2>/dev/null | head -n 1)"' > ~/voip-asterisk-confbridge/evidence/konference_final.wav
sudo docker cp voip-asterisk:/var/log/asterisk/cdr-csv/Master.csv ~/voip-asterisk-confbridge/evidence/Master.csv
```

Ověření přehratelnosti záznamu přes PipeWire, kontrola špičkové hlasitosti a výpis posledních řádků CDR logu:

```bash
paplay ~/voip-asterisk-confbridge/evidence/konference_final.wav
tail -n 5 ~/voip-asterisk-confbridge/evidence/Master.csv
```

Odeslání všech souborů do repozitáře na GitHubu:

```bash
cd ~/voip-asterisk-confbridge
git add README.md docker-compose.yml asterisk/config/ evidence/konference_final.wav evidence/Master.csv
git commit -m "Complete Asterisk ConfBridge setup, documentation and evidence"
git push
```

---

## Důkazy funkčnosti (Evidence)

* **Zvuková nahrávka konference:** [evidence/konference_final.wav](evidence/konference_final.wav) – zachycuje hudbu při čekání prvního účastníka, hlasovou komunikaci po připojení druhého účastníka i návrat hudby po jeho odpojení.
* **Výpis hovorů (CDR log):** [evidence/Master.csv](evidence/Master.csv) – záznam spojení obou linek (`1001`, `1002`) na konferenční klapku `8000` se stavem `ANSWERED`.
