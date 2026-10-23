# WiredHosting Pterodactyl Installer

Installeert [Pterodactyl](https://pterodactyl.io) (panel en/of Wings) op een schone server, via een **webinstaller in je browser** of gewoon in de terminal.

## Snel starten

Log als root in op je server via SSH en draai:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kekev2001/pterodactyl-installer/main/install.sh)
```

Je krijgt in je SSH sessie een link zoals:

```
https://203-0-113-10.sslip.io:8443/?t=geheimetoken
```

Open die link, vul alles in de wizard in en volg de installatie live. In de terminal kun je ook meekijken.

## Wat zit erin

- **Webinstaller met SSL**: de link heeft een echt Let's Encrypt certificaat via [sslip.io](https://sslip.io), zonder dat je een domein nodig hebt. Lukt dat niet (bv. poort 80 dicht), dan valt hij terug op een tijdelijk self-signed certificaat.
- **Gratis SSL voor het panel**: kies het sslip.io adres en het panel draait op `https://<ip-met-streepjes>.sslip.io`. Een eigen domein of alleen IP kan ook.
- **Alles zelf in te stellen**: databasenaam, database gebruiker en wachtwoord, naam van de database host, node naam, locatie, gameserver poorten, geheugen/schijf, Wings poorten.
- **Live voortgang**: voortgangsbalk, stappenlijst en live log in de browser. De installatie loopt door als je het tabblad of SSH sluit.
- **Automatisch**: node aanmelden bij het panel, database host in het panel zetten, firewall met alleen de nodige poorten (ook je gameserver poorten).
- **Veilig**: de webinstaller werkt alleen met de geheime link, sluit vanzelf een uur na afloop en zet de tijdelijke poort weer dicht.

## Opties

```bash
bash install.sh --web        # meteen de webinstaller
bash install.sh --cli        # alles in de terminal, zonder browser
bash install.sh --port 9443  # andere poort voor de webinstaller
bash install.sh --stop       # webinstaller stoppen en opruimen
```

## Benodigd

- Ubuntu 22.04 / 24.04 / 26.04, Debian 11 / 12 / 13 of RHEL / Rocky / AlmaLinux 8 / 9
- Root toegang
- Poort **80** en **8443** bereikbaar van buitenaf (ook in de firewall van je provider) voor de webinstaller en Let's Encrypt

## Bestanden

| Bestand | Wat |
| --- | --- |
| `install.sh` | Starter: haalt de installer op, regelt het certificaat en start de webinstaller |
| `installer.sh` | De eigenlijke installer (terminal of `--config` vanuit de webinstaller) |
| `web/server.py` | HTTPS server van de webinstaller (alleen Python standaardbibliotheek) |
| `web/index.html` | De wizard |

Na afloop staan alle gegevens in `/root/wiredhosting-panel.txt` en het log in `/var/lib/wiredhosting-installer/install.log`.

---

Copyright (c) 2026 WiredHosting. Alle rechten voorbehouden. Pterodactyl Panel en Wings zijn software van derden onder de MIT licentie.
