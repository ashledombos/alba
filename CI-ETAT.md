# État de la CI GitHub Actions

## Ce qui est réglé

Le workflow ne se déclenchait pas : il écoutait `push` sur `main`, alors que la
branche par défaut du dépôt est `master`. Corrigé (commit « CI: declencher sur
master »). Depuis, chaque poussée lance bien le job `base`.

Les briques `composefs` et `ostree` se construisent intégralement : 6 RPM pour
la première, 8 pour la seconde (`ostree`, `lib64ostree1`, `lib64ostree-devel`,
`lib64ostree-gir1.0`, `ostree-grub2`, plus les paquets de débogage).

## Le lien d'ostree en elf32-i386 : cause réelle

Symptôme : `libostree-1.so.1.0.0` ne se liait pas, `ld.lld` déclarant
incompatibles avec **elf32-i386** tous les fichiers reçus, y compris le tout
premier (`crti.o`, pourtant 64 bits).

La chaîne, mesurée sur clairdelune dans le même conteneur
`openmandriva/cooker:x86_64` (reproduction fidèle, hors runner) :

1. `libarchive.pc` d'OpenMandriva déclare `libdir=${exec_prefix}/lib`, alors que
   la bibliothèque 64 bits vit dans `/usr/lib64`. `pkg-config --libs libarchive`
   rend donc `-L/usr/lib -larchive` ;
2. `configure` recopie ce `-L/usr/lib` dans les `LIBS` d'ostree, et il se
   retrouve en **deuxième position** sur la ligne de lien, avant tous les
   `-L…/lib64` ;
3. sur OMV, `/usr/lib` est le répertoire 32 bits, et `glibc-devel` (tiré par les
   BuildRequires) y pose `/usr/lib/libc.so`, qui n'est pas une bibliothèque mais
   un script ld :

   ```
   OUTPUT_FORMAT(elf32-i386)
   GROUP ( /usr/lib/libc.so.6 /usr/lib/libc_nonshared.a AS_NEEDED ( /usr/lib/ld-linux.so.2 ) )
   ```

4. `ld.lld` résout `-lc` sur ce script, en applique l'`OUTPUT_FORMAT` et écrase
   ainsi le `-m elf_x86_64` que le driver clang lui avait bel et bien passé.
   Tout le reste devient « incompatible with elf32-i386 ».

L'invocation réelle du linker, obtenue en rejouant le lien avec `-v`, le montre
sans ambiguïté :

```
"/usr/bin/ld.lld" ... -m elf_x86_64 -shared -o .libs/libostree-1.so.1.0.0 \
  .../lib64/crti.o ... -L.libs -L/usr/lib -L/usr/lib64/clang/23/... -L/usr/lib64 ...
```

La bissection sur cette ligne est nette : en retirant le seul `-L/usr/lib`, le
lien aboutit ; en retirant les archives `--whole-archive`, le `--version-script`
ou les `-l` applicatifs, l'erreur persiste.

`slibtool` est donc hors de cause : il ne faisait que transmettre ce que
`configure` lui donnait. Et `composefs` passait parce qu'il n'utilise pas
libarchive, donc n'hérite d'aucun `-L/usr/lib`.

La piste multilib avait été écartée à tort : le diagnostic mesurait `/usr/lib`
**avant** `dnf builddep`, donc avant que la glibc 32 bits n'y soit installée.
Une mesure au mauvais moment vaut une mesure fausse.

## Correctif

Dans `ostree/ostree.spec`, `%configure` reçoit désormais
`OT_DEP_LIBARCHIVE_LIBS="-larchive"` : la variable est précachée, `PKG_CHECK_MODULES`
ne consulte plus `libarchive.pc`, et le `-L` fautif disparaît de la ligne de
lien. Le `-larchive` suffit, la bibliothèque étant dans le chemin par défaut.

Vérifié hors CI sur clairdelune (conteneur cooker, brique `ostree` seule) : les
8 RPM sont produits. Confirmé ensuite sur le runner, où la CI dépasse ostree et
s'arrête plus loin.

`tools/ci-build-rpms.sh` ne porte plus le diagnostic devenu inutile, mais
signale au passage les autres `.pc` dont le `libdir` pointe `/usr/lib` : c'est le
même piège qui attend la prochaine brique.

## bootc : LTO et régression rustc (réglé)

La brique suivante, `bootc`, échoue à la compilation de son `xtask` (cible
`manpages` du Makefile), sur une erreur interne du compilateur :

```
rustc-LLVM ERROR: expected function definition _RNvCs..._7___rustc12___rust_alloc
                 to have an associated value info.
error: could not compile `xtask` (bin "xtask")
make: *** [Makefile:44: manpages] Error 101
```

C'est une régression de la toolchain Rust de cooker, sans rapport avec le lien
d'ostree : le profil `release` de bootc compile en `-C lto=thin`, et l'ICE tombe
dans le codegen LTO. Correctif : `CARGO_PROFILE_RELEASE_LTO=false`, exporté en
`%build` ET en `%install` (chaque section de spec tourne dans un shell neuf, et
`make install` recompile `xtask` ; la première tentative, posée en `%build`
seul, a échoué pour cette raison au run 36008450889). À retirer quand cooker
aura corrigé son rustc.

Runs de référence : 35452447126 et 35453023297 (échec ostree, avant correctif),
36005802490 (ostree passé, échec bootc),
36019922314 (vert : 6 briques, lint 13/13, image poussée).

## Résultat

Premier run vert le 24-09 : `ghcr.io/ashledombos/alba-base`, tags
`20260924-f96f52c` et `latest`, lisibles sans authentification.
