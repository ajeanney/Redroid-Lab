# Redroid-Lab

Une boîte à outils pour exécuter et analyser un conteneur [redroid](https://github.com/remote-android/redroid-doc) Android 14 épinglé sur un hôte Linux x86_64 : données persistantes, accélération GPU, ADB et scrcpy limités à la loopback, traduction des applications ARM64, capture de paquets réseau et (en option) accès fonctionnel à un vrai contrôleur Bluetooth physique.

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
| Bluetooth optionnel : démarrage sans lui avec `start --no-bt` | Disponible |
| Capture de paquets réseau (pcap + HTTPS décodé), proxy transparent et installation d'APK | Disponible |
| Investigation d'applications avec root : hooking Frida et contournement du SSL pinning | Disponible |
| Instantanés nommés des données Android pour retrouver un état reproductible | Disponible |
| Extraction des APK installés et de leurs fragments, avec analyse apktool/jadx optionnelle | Disponible |

Les lignes « Prévu » sont des objectifs ; aucune n'est encore implémentée.

Contributeurs et agents de codage IA : voir [AGENTS.md](AGENTS.md).

## Bluetooth physique

Le passthrough Bluetooth est optionnel : `./redroid.sh start --no-bt` (ou
`BT_ENABLE=0` dans la configuration) démarre Android sans toucher à BlueZ ni à
l'adaptateur, ce qui permet d'utiliser le conteneur pour tout le reste, comme la
capture de paquets.

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
| Arch Linux x86_64, GPU AMD Lucienne, Bluetooth Realtek `0bda:2852` | Compilation, démarrage sur le GPU de l'hôte, propriétés du bridge ARM64, vraie recherche Bluetooth ayant trouvé des appareils proches, restauration de BlueZ, installation d'APK découpés, capture de paquets avec HTTPS décodé depuis une vraie application | Vérifié |

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

capture: tcpdump (container netns) ── full.pcap
         mitmproxy (Docker gateway) ◄── Android global proxy ── flows.mitm
transparent: nftables OUTPUT redirect ── mitmproxy (container netns) ── flows.mitm
```

Android reste dans le namespace réseau de Docker, ce qui empêche `netd` de
modifier les interfaces physiques ou les routes de politique de l'hôte. Seul le
HAL btlinux entre dans le namespace réseau de l'hôte, ce qui est nécessaire pour
ouvrir les sockets HCI Bluetooth de Linux. Le contrôleur est exclusif : BlueZ et
Android ne peuvent pas le posséder en même temps.

## Prérequis de l'hôte

- Linux x86_64 avec systemd et Docker
- IPC Binder et BinderFS dans le noyau en cours d'exécution
- nœud de rendu DRM sur `/dev/dri/renderD128` (Intel est la référence ; `setup` ne fait que prévenir pour les autres fabricants, et un GPU AMD démarre en mode hôte ; sinon, mettez `REDROID_GPU_MODE=guest` dans une configuration locale)
- pour le passthrough Bluetooth uniquement : un contrôleur exposé en `hciN` (tout fabricant ; `btusb` pour la réinitialisation de secours)
- pour la capture : `tcpdump`, `mitmproxy`, `editcap` de Wireshark et `nsenter` ; `setup` les installe sur Arch, Debian et Ubuntu, et `capture start` a besoin de `sudo` pour tcpdump
- pour Frida : `curl` et `xz` (installés par `setup`) ; `frida unpin`/`exec` utilisent `uvx` d'`uv` pour lancer le client hôte correspondant, sauf si une version déjà installée correspond à la version épinglée
- pour l'analyse statique optionnelle : les commandes hôte `apktool` et/ou `jadx`, avec leur environnement Java ; installez-les séparément, car `setup` ne les installe pas
- environ 10 Go d'espace libre pour les images, les entrées de compilation et le cache
- un accès HTTPS sortant pendant la compilation initiale

Le passthrough ne dépend pas d'un fabricant : il utilise le socket exclusif
`HCI_CHANNEL_USER` du noyau, donc tout contrôleur que Linux expose en `hciN`
devrait fonctionner (vérifié sur un Intel AX211 et un Realtek `0bda:2852`).
Réglez `BT_ADAPTER` sur le bon indice (`hci0` par défaut ; le HAL le lit dans une
propriété système, il n'a donc pas à valoir 0). Pour refuser tout contrôleur
autre qu'un seul connu, renseignez `BT_EXPECTED_USB_ID` (par exemple `8087:0033`)
dans `redroid.env` ; il est vide par défaut. Le firmware de l'adaptateur doit
déjà être chargé, ce que BlueZ fait en l'alimentant au démarrage. Un seul
adaptateur est transmis, et la réinitialisation `btusb` de secours ne
s'applique qu'aux contrôleurs USB.

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

Sans Bluetooth (BlueZ et l'adaptateur ne sont pas touchés) :

```sh
./redroid.sh start --no-bt
```

Pour arrêter Android (et toute capture en cours) et rendre l'adaptateur Bluetooth à Linux :

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
| `./redroid.sh start [--no-bt]` | Réserve `hci0` (sauf avec `--no-bt`), démarre Android et valide le réseau, le Bluetooth et la traduction ARM64 |
| `./redroid.sh stop` | Termine toute capture, supprime Android et restaure l'état précédent de BlueZ et de l'adaptateur |
| `./redroid.sh screen` | Ouvre scrcpy ; utilise l'AAC sur les versions récentes et le mode vidéo/entrée seul sur les paquets Ubuntu plus anciens |
| `./redroid.sh status` | Affiche l'état du conteneur, d'Android, de l'ABI, de BlueZ et de btlinux |
| `./redroid.sh logs` | Affiche les diagnostics Bluetooth et enregistre les données HCI snoop quand elles existent |
| `./redroid.sh install <apk\|dossier>...` | Installe un APK, plusieurs APK découpés, ou un dossier de fragments (`base.apk` + `split_config.*.apk`) |
| `./redroid.sh pull <paquet> [--apktool] [--jadx]` | Extrait les APK installés et leurs fragments ; décode les ressources/smali ou décompile le code Java en option |
| `./redroid.sh launch <paquet>` | Lance une application installée sans interface (à suivre avec `screen`) |
| `./redroid.sh snapshot save\|restore <nom>` | Sauvegarde ou remplace les données Android conteneur arrêté ; le redémarre s'il tournait auparavant |
| `./redroid.sh capture start [--no-mitm\|--transparent]` | Enregistre tout le trafic du conteneur dans `captures/<horodatage UTC>-<suffixe aléatoire>/` |
| `./redroid.sh capture stop` / `status` | Termine la session et écrit les artefacts / affiche la session active |
| `./redroid.sh frida start` / `stop` | Pousse et lance `frida-server` en root dans l'invité, redirigé vers la loopback de l'hôte / l'arrête |
| `./redroid.sh frida unpin <paquet>` | Lance une application avec le SSL pinning Java contourné, pour que `capture` puisse décoder son HTTPS |
| `./redroid.sh frida exec <outil> [args]` | Exécute n'importe quel outil Frida (`frida`, `frida-ps`, `frida-trace`, ...) contre l'invité |

Les opérations de cycle de vie utilisent un verrou et un fichier d'état privé.
Des `stop` répétés sont sans danger, et un démarrage interrompu est récupéré à la
commande de cycle de vie suivante.

## Configuration

Les valeurs par défaut sont dans `redroid.env` :

- noms de l'image de base épinglée et de l'image locale
- nom du conteneur et port ADB de la loopback
- adaptateur Bluetooth, identifiant USB attendu et `BT_ENABLE` (`1` par défaut)
- dossier de capture (`CAPTURE_DIR`) et port mitmproxy préféré (`MITM_PORT`)
- table de capture transparente (`CAPTURE_NFT_TABLE`) et groupe réservé au proxy (`MITM_GID`)
- port Frida redirigé vers l'hôte (`FRIDA_PORT`, loopback uniquement)
- dossier des données persistantes
- dossier des instantanés (`SNAPSHOT_DIR`, `./snapshots` par défaut)
- dossier d'extraction des APK (`PULL_DIR`, `./apps` par défaut)
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

Les données Android persistent dans `data/`. Installez des applications avec
`./redroid.sh install /chemin/vers/application.apk` (ou un dossier d'APK découpés).
Aucun service Google ni Play Store n'est inclus.

## Extraction d'applications et analyse statique

```sh
./redroid.sh pull com.exemple.appli
./redroid.sh pull com.exemple.appli --apktool --jadx
```

`pull` interroge Android avec `pm path` et copie chaque APK installé du paquet
dans un nouveau dossier privé `apps/<paquet>/<horodatage UTC>-<suffixe aléatoire>/`.
Les noms d'origine sont conservés, fragments compris ; le dossier complet peut
être passé à `./redroid.sh install <dossier>`. Chaque exécution crée un dossier
distinct et préserve les extractions précédentes. Seuls les APK installés sont
copiés, pas les bases de données, préférences ou modules à la demande absents.

Les outils hôte optionnels doivent déjà être dans le `PATH`. Avec `--apktool`,
[Apktool](https://apktool.org/docs/cli-parameters/) décode chaque APK dans
`apktool/<nom du fichier APK sans .apk>/`. Avec `--jadx`,
[JADX](https://github.com/skylot/jadx#usage) reçoit l'APK et tous les fragments
ensemble et écrit dans `jadx/`. Les deux options sont combinables. Le verrou du
cycle de vie est pris pendant l'extraction et libéré avant l'analyse.

Un outil manquant provoque un échec avant l'extraction. Les échecs de copie
renvoient un code non nul et laissent les fichiers incomplets sous le nom
`*.apk.part` ; ne réinstallez pas une extraction incomplète. Les échecs d'analyse
renvoient aussi un code non nul et conservent les APK extraits ainsi que les
résultats d'analyse pour inspection. Quand les deux outils sont demandés,
chacun est exécuté même si l'autre signale des erreurs.

`PULL_DIR` choisit le dossier racine ; les chemins relatifs partent du dépôt.
Les configurations locales existantes héritent de la valeur par défaut fournie.
`apps/` est exclu de Git et du contexte Docker, sources et ressources décodées
comprises ; excluez vous-même les emplacements personnalisés.

`pull <paquet> --report` réutilise le décodage Apktool (sans outil SDK distinct)
et exige Python hôte 3.9+. Il écrit `report.json` à côté des APK : activités/alias,
services, receivers et providers exportés, permissions et activation, liens VIEW,
permissions demandées/définies, indicateurs debuggable, sauvegarde et trafic en
clair, ainsi que les variantes XML de sécurité réseau décodées. Les valeurs
implicites historiques d’export et les manifests des fragments sont pris en
compte. Les éléments data des intent-filters restent groupés sans inventer des
URL. Les indicateurs référencés par ressource restent des chaînes ; les ressources
de sécurité non résolues portent `resolved: false`. Cet inventaire statique ne
prouve pas l’accessibilité : permissions, activation, receivers dynamiques,
contrôles dans le code et règles de sauvegarde de la plateforme restent à examiner.
`--report` se combine avec `--apktool`/`--jadx` ; les erreurs de décodage/rapport
renvoient un échec et conservent APK et résultats intermédiaires. Aucun rapport
n’est publié si le décodage échoue.

## Données privées des applications et différences

```sh
./redroid.sh appdata pull com.exemple.appli
# ... effectuez une action dans l’application ...
./redroid.sh appdata pull com.exemple.appli
./redroid.sh appdata diff com.exemple.appli
```

`pull` lit `/data/data/<paquet>` (utilisateur Android 0) en tar avec le root
invité puis extrait sous votre utilisateur hôte dans un dossier privé
`appdata/<paquet>/<horodatage UTC>-<suffixe aléatoire>/data/`. Préférences,
fichiers SQLite (WAL/SHM compris) et autres fichiers privés sont copiés sans
écraser les extractions précédentes. L’extracteur refuse les chemins et liens
sortant du dossier, les fichiers spéciaux et les écritures à travers un lien.
Les échecs conservent `data.part/`, exclu des comparaisons. Propriétaire et droits
sont ceux d’une copie privée pour investigation, pas d’une sauvegarde restaurable.

`diff` compare les deux dernières copies terminées, par date de fin, sans ADB.
Il liste ajouts/suppressions/modifications avec différences textuelles UTF-8 ;
les binaires (dont SQLite) et fichiers de plus de 1 Mio sont comparés par
SHA-256, sans analyse des lignes SQL. Des différences renvoient un succès ;
les copies absentes et erreurs de lecture échouent. Le verrou du cycle de vie
est pris, mais l’application continue : les écritures concurrentes peuvent
rendre les bases incohérentes. Immobilisez l’application vous-même pour une
copie cohérente ; utilisez les instantanés pour restaurer. Stockage externe et
autres utilisateurs sont exclus. `APPDATA_DIR` change la racine ; les anciennes
configurations locales héritent de la valeur par défaut. Le dossier par défaut
est exclu de Git/Docker ; excluez vos emplacements personnalisés. Ces copies
peuvent contenir des identifiants et jetons. Python hôte 3.9+ et root invité
sont nécessaires ; redroid fournit déjà le root.

## Instantanés

```sh
./redroid.sh snapshot save appli-propre
# ... installez des applications, connectez-vous, modifiez les réglages ...
./redroid.sh snapshot restore appli-propre
```

Les instantanés copient tout `REDROID_DATA_DIR` dans `snapshots/<nom>/data/`.
Les noms commencent par une lettre ou un chiffre et contiennent au plus 64
lettres, chiffres, points, tirets bas ou tirets. Les noms existants ne sont
jamais écrasés. Utilisez la même configuration et la même image pour sauvegarder
et restaurer ; seuls les fichiers de données Android sont conservés, pas
l'image ni la couche modifiable du conteneur.

Les deux commandes prennent le verrou du cycle de vie, terminent toute capture
en cours et arrêtent le conteneur existant avant la copie. Le conteneur n'est
redémarré et le boot Android vérifié que s'il tournait auparavant. Son mode
Bluetooth et l'état de réservation de l'hôte sont conservés ; les sessions de
capture et Frida doivent être relancées. Les instantanés fonctionnent aussi si
Android est déjà arrêté ou si le conteneur est absent.

La restauration **remplace toutes les données Android courantes**, applications,
identifiants, réglages et appairages Bluetooth compris. Elle prépare la copie à
côté du dossier de données avant de l'échanger ; un échec de copie préserve les
données courantes. Propriétaires, permissions, liens et attributs étendus sont
conservés avec `sudo cp -a`, en utilisant la copie sur écriture si le système de
fichiers le permet. Sinon, prévoyez la place pour une copie complète. Les dossiers
d'instantanés et de données ne doivent pas être imbriqués.

Si le redémarrage après une restauration terminée échoue, la commande conserve les données
précédentes dans `.redroid-restore.*/previous` à côté de `REDROID_DATA_DIR`.
Lancez `./redroid.sh stop` pour rendre les ressources à l'hôte avant
d'enquêter. Une interruption forcée ou une coupure peut aussi laisser des
dossiers temporaires à cet endroit ou dans `snapshots/.save-*` ; inspectez-les
avant toute récupération ou suppression manuelle.

Les instantanés contiennent les mêmes données privées et identifiants que
`data/`. Le dossier `snapshots/` par défaut et les dossiers temporaires de
restauration sont exclus de Git et du contexte Docker ; excluez vous-même les
emplacements personnalisés. Les dossiers d'instantanés créés ne sont accessibles
qu'à l'utilisateur appelant.

Les configurations locales existantes héritent du dossier d'instantanés par
défaut fourni, sauf si elles définissent elles-mêmes `SNAPSHOT_DIR`.

## Capture de paquets

```sh
./redroid.sh start --no-bt
./redroid.sh install ./fragments-de-l-appli/
./redroid.sh capture start       # --no-mitm : paquets bruts uniquement
./redroid.sh launch com.exemple.appli
# ... utilisez l'application avec ./redroid.sh screen ...
./redroid.sh capture stop
```

Chaque session est écrite dans `captures/<horodatage UTC>-<suffixe aléatoire>/` (ignoré par Git) :

| Fichier | Contenu |
| --- | --- |
| `full.pcap` | Tous les paquets du namespace réseau du conteneur (HTTPS, UDP/P2P, STUN/TURN, MQTT, DNS), capturés par `tcpdump` lancé avec `nsenter` |
| `flows.mitm` | Flux HTTP(S) décodés ; à lire avec `mitmweb --rfile` |
| `sslkeylog.txt` | Clés de session TLS de mitmproxy |
| `full-decrypted.pcapng` | `full.pcap` avec les clés injectées : Wireshark déchiffre l'HTTPS passé par le proxy |

Par défaut, mitmproxy écoute sur la passerelle Docker et le `http_proxy` global
d'Android pointe vers lui. Le CA de mitmproxy est copié dans les magasins de
confiance système et conscrypt de l'invité à chaque démarrage de capture.

Pour intercepter aussi les applications qui ignorent le proxy système :

```sh
./redroid.sh capture start --transparent
# ... relancez l'application pour ouvrir de nouvelles connexions ...
./redroid.sh capture stop
```

Ce mode lance mitmproxy dans le namespace réseau du conteneur, sous l'utilisateur
appelant, avec les capacités supprimées et un groupe de sockets réservé
(`MITM_GID`, `2147483647` par défaut). Une table nftables propre à la session
(`CAPTURE_NFT_TABLE`, `redroid_capture` par défaut) redirige les nouvelles
connexions TCP IPv4/IPv6 vers les ports 80 et 443 vers les écouteurs loopback du
proxy. Le trafic du proxy et les destinations loopback sont exclus pour éviter
les boucles. Aucun réglage du proxy système n'est requis ; il est temporairement
désactivé puis sa valeur précédente est restaurée à l'arrêt, comme en mode
proxy explicite. Le groupe réservé doit rester inutilisé par Android.

Lancez cette commande sous votre utilisateur habituel ; elle utilise sudo
seulement pour les opérations sur le namespace, le pare-feu et le module.

Les règles restent dans le namespace Android ; les règles nftables de l'hôte,
les routes et les paramètres de forwarding ne sont pas modifiés. Le module
hôte `nft_redir` est chargé si nécessaire, puis déchargé à l'arrêt seulement si
la capture l'a introduit. Le proxy utilise les fichiers de l'hôte mais n'entre
pas dans son namespace réseau. Ce mode exige `setpriv` et `lsns` d'util-linux,
`modprobe`/`rmmod` de kmod, le support noyau nftables NAT/redirect et une version
de mitmproxy acceptant plusieurs écouteurs `--mode`.

L'identité du namespace et le nom/propriétaire de la table sont conservés dans
la session. L'arrêt supprime la table avant de terminer le proxy ; `stop`,
les instantanés et le rollback de démarrage de capture utilisent ce même chemin.
Si le nettoyage échoue, l'état de capture est conservé : corrigez l'erreur et
relancez `capture stop`. Aucune table préexistante n'est écrasée ni supprimée.

Si Android est déjà arrêté, le nettoyage libère quand même les processus et
les règles de capture. Son proxy ne peut pas être restauré par ADB hors ligne ;
la valeur précédente reste dans `proxy.before` pour une récupération manuelle.

Ce mode ne contourne pas le pinning ni les magasins de CA propres aux
applications : utilisez Frida si nécessaire. QUIC/HTTP3 (UDP/443) est bloqué dans le namespace Android dans les deux modes
proxy pour inciter les applications à réessayer en TCP ; celles sans repli TCP
peuvent échouer. La table propre à la session est supprimée à l’arrêt. Les ports
non standards et les protocoles non HTTP restent bruts dans le pcap. Les
connexions déjà ouvertes doivent être recréées. `--no-mitm` et `--transparent`
sont incompatibles ; le mode brut ne modifie ni proxy ni pare-feu.


Pour ne proxifier qu’une application installée (utilisateur Android 0) :

```sh
./redroid.sh capture start --transparent --app com.exemple.appli
```

Le paquet et son UID exact sont conservés dans `app.package`/`app.uid`.
La redirection TCP et le blocage QUIC ciblent cet UID ; `flows.mitm` exclut les
autres UID. Le pcap garde tout le trafic. Les paquets partageant un UID restent
indissociables ; les processus isolés et les requêtes déléguées à d’autres UID
échappent au filtre. `--app` exige `--transparent`.


Les artefacts optionnels de chronologie rejoignent le dossier de capture :

```sh
./redroid.sh capture start --transparent --app com.exemple.appli --logcat --record --btsnoop
```

Les options sont indépendantes : `--logcat` exige `--app` et écrit le logcat
filtré par UID avec des dates epoch dans `logcat.log` ; `--record` lance scrcpy
sans affichage ni audio vers `screen.mkv` ; `--btsnoop` copie le journal HCI
existant à l’arrêt dans `btsnoop_hci.log` (avertissement s’il est absent).
La journalisation HCI doit être déjà activée ; le fichier circulaire peut
contenir des événements antérieurs ou perdre des événements à sa rotation.
La capture ne change aucun réglage Bluetooth. `timeline.tsv` conserve les dates
epoch de l’hôte, un échantillon encadré de l’horloge invitée et les marqueurs de
démarrage/arrêt. Pcap, flux, logcat et HCI gardent leurs dates propres ; la vidéo
part d’un temps relatif. L’alignement reste approximatif, dans la limite du
délai de démarrage du recorder, sans précision à l’image. Vérifiez le décalage
hôte/invité dans les échantillons. Arrêt et rollback terminent les processus ;
SIGINT permet à scrcpy de finaliser la vidéo. Il faut un scrcpy installé avec
`--no-playback` ou l’ancien `--no-display`. Un `screen` séparé permet les
interactions. Tous ces fichiers peuvent contenir des données privées.

`tcpdump` tourne en root via `sudo` puis abandonne ses privilèges au profit de
l'utilisateur appelant : les artefacts lui appartiennent. Les captures
contiennent des identifiants et des données personnelles déchiffrés : gardez
`captures/` privé.

## Investigation d'applications avec root (Frida)

```sh
./redroid.sh start --no-bt
./redroid.sh install ./une-appli.apk
./redroid.sh frida start
./redroid.sh capture start
./redroid.sh frida unpin com.exemple.appli   # bloquant ; reste attaché pendant l'utilisation de l'appli
# ... dans un autre terminal : ./redroid.sh screen ...
# Ctrl-C la commande unpin une fois terminé, puis :
./redroid.sh capture stop
./redroid.sh frida stop
```

`frida start` télécharge la version épinglée de `frida-server` (vérifiée contre
`build-inputs.env`), la pousse dans `/data/local/tmp` et la lance en root dans
l'invité ; le port du serveur n'est redirigé que vers la loopback de l'hôte.
`frida unpin` lance une application avec [frida/unpin.js](frida/unpin.js)
chargé, qui modifie le `TrustManager` de la plateforme, `SSLContext`, les
vérifications de pinning de la network-security-config et le
`CertificatePinner` d'OkHttp pour que le certificat CA de mitmproxy (installé
par `capture start`) soit accepté — cela referme la limite « applications qui
épinglent leurs certificats » mentionnée dans la section de capture
ci-dessus, pour les applications qui épinglent en Java. Les hooks ne
s'appliquent que tant que la commande reste attachée ; `frida exec` exécute
n'importe quel autre outil Frida (par ex. `frida-trace`) de la même façon.

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

Le conteneur est privilégié et, quand le Bluetooth est activé, le HAL Bluetooth
reçoit l'accès au namespace réseau de l'hôte (sans lui, le HAL n'a aucun
namespace à rejoindre et s'arrête).
Pendant une capture, le CA de mitmproxy n'est approuvé que par l'invité Android. Considérez l'image et les applications Android installées
comme du code de confiance.

ADB n'est publié que sur `127.0.0.1` ; `ADB_HOST` est refusé s'il est changé pour une
adresse hors loopback. Pendant que redroid tourne, une table nftables
(`NFT_TABLE`, `redroid_guard` par défaut) rejette aussi les paquets vers le port
ADB adressés à cet hôte mais arrivés par une interface autre que la loopback.
Elle filtre en `prerouting`, avant le DNAT de Docker, afin que les voisins du
réseau local ne puissent pas joindre la publication loopback en routant vers
`127.0.0.1` via l'hôte. `start` refuse de démarrer si une table de ce nom existe
déjà, et `stop` ne supprime que la table qu'il a créée. Le script prend des instantanés des adresses physiques,
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
