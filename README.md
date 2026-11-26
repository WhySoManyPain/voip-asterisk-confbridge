# VoIP konferenční ústředna Asterisk (`ConfBridge` + `Music on Hold`)

Kompletní postup nasazení, konfigurace, ladění zvuku a ověření funkčnosti VoIP ústředny **Asterisk PBX** v kontejneru Docker na systému **Fedora Linux** se zvukovým serverem **PipeWire**, USB-C sluchátky **Apple EarPods** a dvěma souběžně běžícími SIP klienty (**Linphone** a **Twinkle**).

## Cíl projektu a architektura

Projekt demonstruje konferenční místnost `ConfBridge` na klapce `8000` s parametrem `music_on_hold_when_empty=yes` a automatickým nahráváním hovoru:
* **1 účastník v místnosti (`1001`):** Asterisk automaticky přehrává hudbu při čekání (*Music on Hold*).
* **2 účastníci v místnosti (`1001` + `1002`):** Hudba při čekání se vypne a oba účastníci spolu komunikují v konferenčním mostu.
* **Odchod 2. účastníka (`1002`):** Prvnímu účastníkovi (`1001`) se opět automaticky spustí hudba při čekání.

| Komponenta | Role | SIP účet / Klapka | Lokální UDP port | Zvukové rozhraní |
| :--- | :--- | :--- | :--- | :--- |
| **Asterisk PBX (Docker)** | VoIP ústředna (`network_mode: host`) | `8000` (ConfBridge), `8001` (Echo) | `5060` (RTP `10000–10020`) | — |
| **Linphone 6.2.5 (AppImage)** | Softphone 1 (hlavní účastník) | `1001` (heslo `voip1001`) | `5064` | `PulseAudio: EarPods` |
| **Twinkle 1.11.0** | Softphone 2 (druhý účastník) | `1002` (heslo `voip1002`) | `5062` | `ALSA: default` (PipeWire) |

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
Definice UDP transportu na portu `5060` a dvou koncových bodů (`1001`, `1002`) s kodeky `ulaw` a `alaw`:

```ini
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

[1001]
type=endpoint
context=internal
disallow=all
allow=ulaw,alaw
auth=1001-auth
aors=1001

[1001-auth]
type=auth
auth_type=userpass
password=voip1001
username=1001

[1001]
type=aor
max_contacts=1
remove_existing=yes

[1002]
type=endpoint
context=internal
disallow=all
allow=ulaw,alaw
auth=1002-auth
aors=1002

[1002-auth]
type=auth
auth_type=userpass
password=voip1002
username=1002

[1002]
type=aor
max_contacts=1
remove_existing=yes
```

### `confbridge.conf` – Konferenční místnost, nahrávání a hudba při čekání
Zapnutí automatického nahrávání (`record_conference=yes`), hudby při čekání osamoceného účastníka (`music_on_hold_when_empty=yes`) a DTMF nabídky (`*1` ztlumení mikrofonu, `*2` opuštění konference):

```ini
[general]

[default_bridge]
type=bridge
record_conference=yes
record_file=/tmp/konference_nahravka.wav

[default_user]
type=user
music_on_hold_when_empty=yes
music_on_hold_class=default
announce_join_leave=no
dtmf_passthrough=yes

[default_menu]
type=menu
*1=toggle_mute
*2=leave_conference
```

### `extensions.conf` – Číslovací plán (Dialplan)
Směrování přímých hovorů mezi linkami `1001` a `1002`, vstupu do konferenční místnosti na klapce `8000` a testovací ozvěny na klapce `8001`:

```ini
[internal]
exten => 1001,1,Dial(PJSIP/1001,30)
 same => n,Hangup()

exten => 1002,1,Dial(PJSIP/1002,30)
 same => n,Hangup()

exten => 8000,1,Answer()
 same => n,ConfBridge(8000,default_bridge,default_user,default_menu)
 same => n,Hangup()

exten => 8001,1,Answer()
 same => n,Echo()
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

## 4. Kontrola a nastavení audia na Fedoře (PipeWire + Apple EarPods USB-C)

Výpis hardwarových karet v ALSA a aktivních zvukových zařízení v PipeWire:

```bash
aplay -l && arecord -l
wpctl status | grep -A 15 "Audio"
```

Odtlumení mikrofonu USB-C sluchátek EarPods v PipeWire a nastavení hlasitosti na 100 %:

```bash
wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0
wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 1.0
wpctl get-volume @DEFAULT_AUDIO_SOURCE@
```

Odemčení a zesílení hardwarového ovládání mikrofonu přímo na zvukové kartě sluchátek (`card 1`) přes `amixer`:

```bash
command -v amixer >/dev/null || sudo dnf install -y alsa-utils
for ctrl in $(amixer -c 1 scontrols | sed -n "s/Simple mixer control '\([^']*\)'.*/\1/p"); do
  amixer -c 1 sset "$ctrl" 100% unmute cap 2>/dev/null || amixer -c 1 sset "$ctrl" 100% unmute 2>/dev/null
done
amixer -c 1
```

Testovací 3sekundový záznam z mikrofonu EarPods přes PipeWire a kontrola úrovně signálu:

```bash
pw-record --target=@DEFAULT_AUDIO_SOURCE@ /tmp/earpods_test.wav &
PID=$!; sleep 3; kill $PID
paplay /tmp/earpods_test.wav
```

---

## 5. Nastavení dvou souběžných softphone klientů

Aby oba klienti běželi současně bez konfliktu o port `5060` (obsazený Asteriskem) a bez automatického přidržení hovoru, používá každý klient vlastní lokální SIP port.

### Softphone 1: Linphone 6.2.5 AppImage (Linka `1001`, port `5064`)
Vyhledání staženého AppImage, změna lokálního portu na `5064` v konfiguračních souborech Linphone a spuštění aplikace:

```bash
which linphone 2>/dev/null || flatpak list --app | grep -i linphone || find ~ -maxdepth 3 -iname "*linphone*" 2>/dev/null
killall -9 Linphone-6.2.5-x86_64.AppImage linphone 2>/dev/null || true

python3 -c '
import os, re
for path in [os.path.expanduser("~/.config/linphone/linphone.conf"), os.path.expanduser("~/.config/linphone/linphonerc")]:
    if os.path.exists(path):
        txt = open(path, encoding="utf-8").read()
        if "[sip]" in txt:
            txt = re.sub(r"(?m)^sip_port=.*", "sip_port=5064", txt)
            if "sip_port=5064" not in txt:
                txt = txt.replace("[sip]\n", "[sip]\nsip_port=5064\n", 1)
        else:
            txt += "\n[sip]\nsip_port=5064\n"
        open(path, "w", encoding="utf-8").write(txt)
'

chmod +x ~/Downloads/Linphone-6.2.5-x86_64.AppImage
~/Downloads/Linphone-6.2.5-x86_64.AppImage &
```

Nastavení v rozhraní Linphone:
1. **Přihlášení účtu:** Username `1001`, Password `voip1001`, Domain `127.0.0.1`, Transport `UDP`.
2. **Settings → Audio:** Playback device `PulseAudio: EarPods Analog Stereo`, Capture device `PulseAudio: EarPods Mono`.

### Softphone 2: Twinkle (Linka `1002`, port `5062`)
Nastavení lokálního portu `5062` a sdíleného zvukového rozhraní `alsa:default` (aby neblokoval USB kartu sluchátek pro Linphone):

```bash
killall twinkle 2>/dev/null || true
sed -i 's/^dev_ringtone=.*/dev_ringtone=alsa:default/; s/^dev_speaker=.*/dev_speaker=alsa:default/; s/^dev_mic=.*/dev_mic=alsa:default/; s/^sip_port=.*/sip_port=5062/' ~/.twinkle/twinkle.sys
twinkle &
```

Nastavení v rozhraní Twinkle:
* V menu **File → Change user** aktivovat pouze profil **`1002`** (heslo `voip1002`, doména `127.0.0.1`).

---

## 6. Průběh testu a diagnostika RTP provozu

1. **Vstup 1. účastníka:** Z **Linphone (`1001`)** vytočit `8000` → ve sluchátkách se ozve hudba při čekání (*Music on Hold*).
2. **Vstup 2. účastníka:** Z **Twinkle (`1002`)** vytočit `8000` → hudba při čekání se zastaví a hlas z mikrofonu EarPods se přenáší do konference a nahrává.
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
