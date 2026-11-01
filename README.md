# R4SRV.R4X

Gemeinsamer R4OS-Serverzugang fuer App Center, Updates und Benchmarks.
Der Dienst liest das explizite Transportprofil, das jeweilige Registry-Ziel
und die lokal geschuetzte Registrierungskonfiguration. Er registriert eine
Quell-IP einmal je Ziel-IP, Profil und aktivem Netzwerkpfad. Anfragen werden
im Dienst serialisiert; parallele Konsumenten teilen einen laufenden Versuch.

Version, Imports, Zielpfad und Image-Scope stehen in `module.R4MF`.
Der hostneutrale Build startet mit `Build.sh` oder `Build.bat`.
