# État de la CI GitHub Actions

## Ce qui est réglé

Le workflow ne se déclenchait pas : il écoutait `push` sur `main`, alors que la
branche par défaut du dépôt est `master`. Corrigé (commit « CI: declencher sur
master »). Depuis, chaque poussée lance bien le job `base`.

Les étapes `Set up job`, `checkout`, `Étiquettes de l'image` et `Libérer de
l'espace disque` passent. La brique `composefs` se construit intégralement
(6 RPM produits, `lib64composefs1`, `lib64composefs-devel`, etc.).

## Ce qui bloque

La brique `ostree` échoue au lien de `libostree-1.so.1.0.0`, en `%build` :

```
ld.lld: error: /usr/bin/../lib64/gcc/x86_64-openmandriva-linux-gnu/16.2.0/../../../../lib64/crti.o
        is incompatible with elf32-i386
ld.lld: error: src/libostree/.libs/libostree_1_la-ostree-core.o is incompatible with elf32-i386
[... 20 erreurs, puis « too many errors emitted »]
cc: error: linker command failed with exit code 1
slibtool-shared: error logged in slbt_exec_link_create_library(), line 369
```

Autrement dit, `ld.lld` a retenu **elf32-i386** comme cible, et déclare
incompatible *tout* ce qu'on lui donne, y compris le tout premier fichier
(`crti.o`, 64 bits). La ligne de lien produite par `slibtool-shared` contient
pourtant `-m64 -march=znver1`, et la compilation de chaque `.o` s'est bien faite
en 64 bits.

Deux runs successifs, échec identique au même endroit :

- run 35452447126 (échec en 5 min 51 s)
- run 35453023297 (échec en 4 min 45 s, avec le diagnostic ajouté)

## Piste explorée, et écartée par la mesure

Seule anomalie visible de la ligne de lien : `-L/usr/lib -larchive`, alors que
sur OMV x86_64 le 64 bits vit dans `/usr/lib64` et que `/usr/lib` est le
répertoire 32 bits. Hypothèse : une `libarchive` 32 bits traînant dans
`/usr/lib` aurait fait basculer l'inférence de cible de `lld`.

Un bloc `diagnostic_toolchain` a été ajouté à `tools/ci-build-rpms.sh` pour le
vérifier. Résultat, dans le conteneur `openmandriva/cooker:x86_64` du runner :

```
ls: cannot access '/usr/lib/libarchive*': No such file or directory
/usr/lib64/libarchive.so.13 -> libarchive.so.13.8.1
```

Il n'y a **aucune** `libarchive` 32 bits. L'hypothèse multilib est fausse ;
`-L/usr/lib` pointe sur un répertoire vide et ne peut pas expliquer la cible
elf32-i386. Le diagnostic est conservé dans le script : il tourne avant les
briques, ne coûte rien et ne peut pas interrompre le build.

Toolchain relevée dans le conteneur : clang 23.1.1 (cible
`x86_64-pc-linux-gnu`), LLD 23.1.1, gcc 16.2.0.

## Ce qui reste à trancher

L'explication tient probablement à `slibtool` : `composefs` (autotools/libtool
classique) se lie sans difficulté avec la même toolchain, `ostree` est la seule
brique qui passe par `slibtool-shared --prefer-sltdl`. Reste à savoir si c'est
une régression de cooker (clang 23 / slibtool récents) ou une particularité du
runner. Pistes non explorées, faute de pouvoir reproduire localement :

1. relancer le lien avec `-v` pour lire l'invocation réelle de `ld.lld` et voir
   d'où sort la cible 32 bits (un `-m elf_i386` explicite ?) ;
2. forcer `libtool` plutôt que `slibtool` sur la seule brique `ostree` ;
3. reconstruire la même brique sur clairdelune avec un cooker à jour, pour
   séparer « régression amont » de « particularité du runner ».

La reproduction locale n'a pas pu être tentée depuis cette session : `podman`
n'y est pas autorisé.
