# R4SRV.R4X

Gemeinsamer R4OS-Serverzugang fuer App Center, Updates und Benchmarks.
Der Dienst liest das explizite Transportprofil, das jeweilige Registry-Ziel
und die lokal geschuetzte Registrierungskonfiguration. Er registriert eine
Quell-IP einmal je Ziel-IP, Profil und aktivem Netzwerkpfad. Anfragen werden
im Dienst serialisiert; parallele Konsumenten teilen einen laufenden Versuch.

Version, Imports, Zielpfad und Image-Scope stehen in `module.R4MF`.
Der hostneutrale Build startet mit `Build.sh` oder `Build.bat`.


Ab0.1.1 initialisiert R4SRV bei fehlenden Registrierungsdaten die offiziellen
PUBLIC-Ziele automatisch ueber geprueftes HTTPS. Der Server gibt einen
installationsbezogenen REGISTRATION_READ-Nachweis aus. Das gemeinsame SDK
prueft dessen exakten Vertrag und publiziert ihn create-only atomar unter
C:\R4OS\SECRETS\PUBLIC.R4S. Vorhandene lokale R4OSSERVER.R4S-Daten haben
Vorrang; LAN, angepasste Ziele und beschaedigte vorhandene Dateien werden
nicht auf PUBLIC umgestellt oder ueberschrieben. CA, IP-SAN und Zeit werden
normal geprueft; Redirects sind ausgeschlossen.

Bootstrap und Registrierung haben jeweils5sBudget. Ein fehlgeschlagener
Netzversuch wird fuer dieselbe IP/dasselbe Profil5sgeteilt; jeder Konsument
behaelt sein eigenes Zielportfeld. Netzwerk-/Profilwechsel verwerfen die
Caches. Der Dienst serialisiert den Versuch, waehrend Konsumenten normal
abbrechen/joinen koennen; eine schon begonnene begrenzte Einrichtung darf
fuer den naechsten Konsumenten atomar fertig werden. Keine Ausgabe von
Nachweisen in Console oder Logs. Build.sh test prueft den Cachebesitz,
SDK transport-parity-test den Dokument-/Persistenzvertrag.
