# Redroid-Lab

Une boîte à outils pour exécuter et analyser un conteneur [redroid](https://github.com/remote-android/redroid-doc) Android 14 épinglé sur un hôte Linux x86_64 : données persistantes, accélération GPU Intel, ADB et scrcpy limités à la loopback, traduction des applications ARM64 et accès fonctionnel à un vrai contrôleur Bluetooth physique.

Le projet est parti d'une image de passthrough Bluetooth et devient un laboratoire
général pour explorer des applications Android : capture de paquets réseau,
inspection d'applications avec les droits root et workflows de rétro-ingénierie
similaires.

## Périmètre

| Capacité | État |
| --- | --- |
| Image redroid 14 épinglée avec données persistantes, GPU Intel, scrcpy | Disponible |
| Traduction des applications ARM64 (`libndk_translation`) | Disponible |
| Bluetooth physique en passthrough (HAL Linux-HCI d'AOSP) | Disponible |
| Capture de paquets réseau depuis le conteneur | Prévu |
| Outillage d'investigation d'applications avec root | Prévu |

Les lignes « Prévu » sont des objectifs ; aucune n'est encore implémentée.

Contributeurs et agents de codage IA : voir [AGENTS.md](AGENTS.md).

## Bluetooth physique

Le Bluetooth physique n'est pas pris en charge par redroid en l'état : l'image
amont utilise un contrôleur simulé. Redroid-Lab remplace cette simulation par le
petit HAL Linux-HCI (`btlinux`) d'AOSP. L'intégration fonctionne sur la machine de
référence, mais reste une configuration hors arbre et privilégiée, à évaluer en
conséquence.

Références amont :

- [documentation redroid et support du native-bridge](https://github.com/remote-android/redroid-doc#native-bridge-support)
- [limitation du Bluetooth physique dans redroid](https://github.com/remote-android/redroid-doc/issues/353)
- [implémentation HCI btlinux d'AOSP](https://android.googlesource.com/platform/system/bt/+/android-11.0.0_r48/vendor_libs/linux/interface/bluetooth_hci.cc)

## État de validation

| Plateforme | Validation effectuée | État |
| --- | --- | --- |
| Arch Linux x86_64, Intel AX211 | Compilation complète, démarrage Android, GPU Intel, vidéo/audio scrcpy, APK JNI ARM64 uniquement, vraie recherche Bluetooth et restauration de BlueZ | Vérifié |
| Ubuntu 22.04 LTS | Installation propre de l'ensemble des dépendances de l'hôte ; audit de syntaxe Bash 5.1 et des chemins de commandes | Compatible ; test matériel encore nécessaire |
| Ubuntu 24.04 LTS | Installation propre de l'ensemble des dépendances de l'hôte ; audit de syntaxe Bash 5.2 et des chemins de commandes | Compatible ; test matériel encore nécessaire |
| Debian | Correspondance des paquets et indications Binder implémentées | Au mieux ; non testé sur matériel |

Les vérifications Ubuntu confirment que les dépendances et les interfaces shell
de l'installation sont disponibles sur les deux versions LTS. Elles ne
remplacent pas un test de bout en bout sur le noyau, le GPU, le contrôleur USB
et les périphériques d'une autre machine. Lancez le preflight sur chaque nouvel
hôte avant de compter sur le Bluetooth.

## Architecture

```text
Android framework and netd ── Docker bridge ── host networking
              │
              └─ btlinux HAL ── host network namespace ── HCI_CHANNEL_USER ── hci0

ADB/scrcpy ── 127.0.0.1:5555 only
```

Android reste dans le namespace réseau de Docker, ce qui empêche `netd` de
modifier les interfaces physiques ou les routes de politique de l'hôte. Seul le
HAL btlinux entre dans le namespace réseau de l'hôte, ce qui est nécessaire pour
ouvrir les sockets HCI Bluetooth de Linux. Le contrôleur est exclusif : BlueZ et
Android ne peuvent pas le posséder en même temps.

## Prérequis de l'hôte

- Linux x86_64 avec systemd et Docker
- IPC Binder et BinderFS dans le noyau en cours d'exécution
- nœud de rendu DRM Intel sur `/dev/dri/renderD128`
- un contrôleur Bluetooth exposé en `hci0` et piloté par `btusb`
- environ 10 Go d'espace libre pour les images, les entrées de compilation et le cache
- un accès HTTPS sortant pendant la compilation initiale

Les valeurs par défaut du dépôt identifient l'Intel AX211 de référence par son
identifiant USB `8087:0033`. Sur une autre machine, vérifiez l'adaptateur visé et
mettez à jour ou videz `BT_EXPECTED_USB_ID` dans `redroid.env`. Le vider désactive la
garde d'identité matérielle ; cela ne rend pas les adaptateurs non pris en
charge sûrs pour autant.

### Ubuntu 22.04 et 24.04

`./redroid.sh setup` installe les paquets manquants depuis les dépôts Ubuntu
standards. Avant de le lancer, activez Docker et donnez à l'utilisateur qui
lance le script l'accès au démon :

```sh
sudo systemctl enable --now docker.service bluetooth.service
sudo usermod -aG docker "$USER"
```

Reconnectez-vous après avoir changé de groupe. Si `scrcpy` n'est pas visible dans une
installation Ubuntu personnalisée ou minimale, activez le dépôt Universe :

```sh
sudo apt install software-properties-common
sudo add-apt-repository universe
sudo apt update
```

Ubuntu fournit normalement Binder par le paquet de modules supplémentaires du
noyau en cours. Si le setup signale que BinderFS est indisponible :

```sh
sudo apt install "linux-modules-extra-$(uname -r)"
sudo modprobe binder_linux devices=binder,hwbinder,vndbinder
grep binder /proc/filesystems
```

Ne changez pas de noyau par précaution. Utilisez d'abord le noyau en cours et
n'installez un autre noyau compatible Binder que si le preflight le rend
nécessaire.

### Arch Linux

Le script installe les paquets manquants avec `pacman` et vérifie le support Binder
du noyau en cours. Docker doit tourner et être accessible à l'utilisateur qui
lance le script.

## Démarrage rapide

```sh
./redroid.sh setup
./redroid.sh start
./redroid.sh screen
```

Pour arrêter Android et rendre l'adaptateur Bluetooth à Linux :

```sh
./redroid.sh stop
```

`start` ne réussit qu'après le démarrage d'Android, la mise à disposition du
contrôleur HCI physique, un Bluetooth annoncé `ON`, des instantanés réseau de
l'hôte inchangés et la réussite de l'APK de test ARM64 optionnel. Tout échec de
démarrage supprime le conteneur et restaure l'état précédent de BlueZ et de
l'alimentation de l'adaptateur.

## Référence des commandes

| Commande | Rôle |
| --- | --- |
| `./redroid.sh setup` | Installe les dépendances manquantes, compile l'image overlay épinglée et, en option, l'APK de test ARM64 |
| `./redroid.sh start` | Réserve `hci0`, démarre Android et valide le réseau, le Bluetooth et la traduction ARM64 |
| `./redroid.sh stop` | Supprime Android et restaure l'état précédent de BlueZ et de l'adaptateur |
| `./redroid.sh screen` | Ouvre scrcpy ; utilise l'AAC sur les versions récentes et le mode vidéo/entrée seul sur les paquets Ubuntu plus anciens |
| `./redroid.sh status` | Affiche l'état du conteneur, d'Android, de l'ABI, de BlueZ et de btlinux |
| `./redroid.sh logs` | Affiche les diagnostics Bluetooth et enregistre les données HCI snoop quand elles existent |

Les opérations de cycle de vie utilisent un verrou et un fichier d'état privé.
Des `stop` répétés sont sans danger, et un démarrage interrompu est récupéré à la
commande de cycle de vie suivante.

## Configuration

Les valeurs par défaut sont dans `redroid.env` :

- noms de l'image de base épinglée et de l'image locale
- nom du conteneur et port ADB de la loopback
- adaptateur Bluetooth et identifiant USB attendu
- dossier des données persistantes
- résolution d'affichage, densité et fréquence d'images
- réglages du GPU et du native-bridge
- délai de démarrage et chemin du namespace réseau de l'hôte

Pour des réglages propres à une machine, copiez le fichier en
`redroid.local.env` (ignoré par Git) et sélectionnez-le explicitement :

```sh
cp redroid.env redroid.local.env
REDROID_CONFIG=./redroid.local.env ./redroid.sh setup
REDROID_CONFIG=./redroid.local.env ./redroid.sh start
```

Utilisez la même configuration pour chaque commande de cycle de vie.

Les données Android persistent dans `data/`. Installez des applications directement
avec :

```sh
adb -s 127.0.0.1:5555 install -r /path/to/application.apk
```

Aucun service Google ni Play Store n'est inclus.

## Support des applications ARM

L'image épinglée contient `libndk_translation` et les bibliothèques invitées ARM64.
Le setup annonce et vérifie `arm64-v8a` ; le code JNI ARM64 uniquement a été testé
avec succès.

L'image ne contient pas le traducteur 32 bits nécessaire aux APK ARMv7
uniquement. Elle n'annonce donc pas `armeabi-v7a`, ce qui évite des installations
qui échoueraient plus tard à l'exécution. Préférez les APK fournissant
`arm64-v8a` ou x86/x86_64.

Quand un SDK Android, un NDK et des build-tools locaux sont détectés, le setup
compile un petit APK de test ARM64 uniquement depuis les sources du dépôt, et
`start` l'installe, le lance, le vérifie et le supprime automatiquement. Le SDK
Android n'est pas nécessaire autrement.

## Comportement Bluetooth et sécurité

`start` masque à l'exécution puis arrête les deux noms d'unité systemd de BlueZ
avant de couper `hci0`. Android ouvre ensuite le contrôleur via
`HCI_CHANNEL_USER`. Pendant que redroid tourne :

- les claviers, souris, appareils audio et autres connexions Bluetooth de Linux
  sont indisponibles.
- D-Bus ne peut pas réactiver BlueZ et reprendre le contrôleur.
- les magasins de clés Bluetooth d'Android et de Linux restent séparés.

Évitez d'appairer le même périphérique séparément dans Android et dans BlueZ.
Les deux piles utilisent l'adresse publique du contrôleur mais conservent des
clés de liaison différentes, ce qui peut invalider un appairage existant.

`stop` libère le canal HCI, restaure l'alimentation de l'adaptateur avant de
redémarrer BlueZ, et vérifie l'état final. Une réinitialisation `btusb` encadrée est
disponible en secours pour les contrôleurs qui ne se remettent pas proprement.

## Modèle de sécurité

Le conteneur est privilégié et le HAL Bluetooth reçoit l'accès au namespace
réseau de l'hôte. Considérez l'image et les applications Android installées
comme du code de confiance.

ADB n'est publié que sur `127.0.0.1` ; `ADB_HOST` est refusé s'il est changé pour une
adresse hors loopback. Le script prend des instantanés des adresses physiques,
des routes principales, des règles de politique et de l'état nftables avant le
démarrage, et les valide pendant le boot et la restauration.

N'exposez pas le port 5555 à travers un autre proxy, une règle de pare-feu ou un
transfert SSH sans comprendre qu'ADB donne un contrôle étendu sur l'instance
Android.

## Dépannage

Commencez par :

```sh
./redroid.sh status
./redroid.sh logs
```

Vérifications courantes :

```sh
docker info
grep binder /proc/filesystems
ls -l /dev/dri/renderD128
readlink -f /sys/class/bluetooth/hci0/device
ss -ltn 'sport = :5555'
```

Si le démarrage échoue, ne lancez pas BlueZ à la main pendant qu'un rollback est
en cours. Laissez le script finir, puis lancez `./redroid.sh stop` s'il faut
recommencer la récupération. Les diagnostics Bluetooth incluent
`dumpsys bluetooth_manager`, un logcat filtré, et un fichier HCI snoop dans
`.runtime/` quand Android en produit un.

Sur les versions récentes de scrcpy, `screen` choisit l'encodeur AAC disponible
d'Android ; l'encodeur Opus par défaut est absent de cette image redroid. Ubuntu
22.04 et 24.04 empaquettent actuellement des versions plus anciennes de scrcpy,
sans transfert audio. Le script détecte cette capacité et lance le miroir
vidéo/entrée sans audio au lieu de passer des options non supportées.

## Reproductibilité et hygiène du dépôt

La compilation épingle le digest de l'image redroid, celui du constructeur
Debian, les sources AOSP btlinux, le snapshot VNDK et la somme de contrôle du
NDK Android. Elle valide les arbres de sources, les dépendances ELF et les
symboles indéfinis forts contre l'image de base exacte. Un checkout AOSP complet
n'est pas nécessaire.

Git exclut les données Android persistantes, l'état de propriété à l'exécution,
les logs, les APK générés, le matériel de signature, les caches et les
surcharges de configuration locales (y compris les notes d'agent `*.local.md`). Le contexte de compilation Docker exclut
les mêmes contenus propres à l'hôte. Vérifiez `git status --ignored` avant le
premier commit pour confirmer qu'aucune donnée d'application ni aucun élément
d'appairage ne sera partagé.
