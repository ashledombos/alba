# Alba: application delivery policy

*Can we trust Flathub, and should OpenMandriva run its own Flatpak repository?*

An atomic image moves applications out of the OS. The base image stays small and
immutable; graphical applications arrive through Flatpak. That makes "which
Flatpak remote do we preconfigure, and on whose authority" a distribution-level
decision rather than an implementation detail, which is why this note exists
next to [PITCH.md](PITCH.md).

Nothing is wired in yet: `Containerfile.alba` does not even install flatpak
(only `demo/Containerfile.apps` does, for demonstration). The decision is open.

## 1. What Flathub actually guarantees

Flathub's build chain is stronger than its reputation among sceptics suggests:

- Applications are built **on Flathub infrastructure** by `flatpak-builder`, from
  a public manifest, **with no network access during the build**. Sources are
  validated against checksums recorded in the manifest, and the manifest's git
  commit is recorded in the build.
- The repository is **signed with Flathub's key**; Flatpak/OSTree verifies the
  signature on install and on every update.
- Applications run **sandboxed**, with host access mediated by portals, and the
  requested permissions are shown on the application page.
- New submissions go through **human review**.

That is a real supply chain, comparable to a distribution's own build system,
and better than "download a tarball from the vendor's website".

## 2. What it does not guarantee

- **"Verified" only means identity.** The badge says the developer proved
  ownership of the App ID. It says nothing about code audit, maintenance quality
  or vulnerabilities.
- **Unverified applications are packaged by third parties.** Measured against
  the Flathub search API on 2026-08-02:

  | Set | Applications |
  |---|---|
  | Whole catalogue | 3285 |
  | Verified | 2132 (65%) |
  | Free licence (FLOSS) | 2954 (90%) |
  | Verified **and** FLOSS | 1990 (61%) |

  So roughly **1150 applications, a third of the catalogue, are packaged by
  someone other than the upstream developer**. Most are packaged in good faith.
  None of them is packaged by us.
- **About 6% use `extra-data`**: a proprietary binary downloaded on the user's
  machine at install time. The unpacking sandbox is locked down and cannot be
  modified by the app author, but the payload is not built by Flathub.
- A few **trusted partners** (Mozilla, OBS Studio and others) upload builds
  produced by their own CI rather than Flathub's.
- **Broad permissions are common.** `--filesystem=host` or session bus access
  hollow out the sandbox, and end-of-life runtimes are still in use.
- **There is no legal curation.** Flathub deliberately mixes free and
  proprietary software. Fedora Legal refused to enable it by default for that
  reason. The same question applies to the OpenMandriva Association, and it is
  not a technical one.

**Verdict.** Flathub is trustworthy as a *build chain*, much less so as a
*catalogue*. The risk for Alba is not that Flathub turns malicious; it is that a
distribution which preconfigures the remote implicitly endorses several thousand
packages it does not control, does not review and cannot support.

## 3. The cheap answer: server-side subsets

Flathub publishes filtered views of its own repository, computed server side.
They cost us nothing to use. Verified against `https://dl.flathub.org/repo/summary.idx`
on 2026-08-02, which lists `verified`, `floss` and `verified_floss` subsummaries
for every architecture:

```sh
flatpak remote-add --subset=verified_floss flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
# widening later is one command, no reinstall:
flatpak remote-modify --subset= flathub
```

A local **filter file** (`--filter`, `flatpak-remote(5)`) can narrow this further
to an explicit allow-list, which is what Fedora does for the applications it
ships out of the box.

**Proposed default for Alba: `verified_floss`.** It removes exactly the two
categories we cannot defend, third-party packaging and non-free licensing, and
it still leaves about 2000 applications. Widening to the full catalogue stays a
documented one-liner, so we protect the default without patronising the user.

## 4. Wiring it into a bootc image

Two constraints specific to image mode, worth writing down before anyone
implements this:

- **A remote can be preconfigured declaratively.** Flatpak reads
  `flatpakrepo(5)` files from `/usr/share/flatpak/remotes.d/` and
  `/etc/flatpak/remotes.d/` (the latter wins on conflict). The `[Flatpak Repo]`
  group accepts `Url`, `GPGKey`, `Title`, `DefaultBranch` and, decisively here,
  **`Subset`**. So the policy lives in `/usr/share/flatpak/remotes.d/`, that is
  in the image, versioned in the Containerfile, and immutable at runtime, while
  the user can still override it under `/etc`.
- **Installed applications cannot be baked in.** System Flatpaks live in
  `/var/lib/flatpak`, and `/var` is machine-local state in bootc, recreated from
  tmpfiles. Shipping a default application set therefore requires a first-boot
  systemd unit, exactly as Aurora and Bazzite do. Keep that set very small.

## 5. An OpenMandriva repository: what it would take

Yes, and it is cheaper than people assume, for one architectural reason worth
stating plainly:

> **A Flatpak repository is an OSTree repository, which is to say static files
> served over plain HTTP.**

The OMV mirror network already does exactly that, and the download portal already
carries checksums and Metalink. By contrast, an **OCI remote** (`oci+https://`,
the Fedora model) requires both the registry `/v2/` API and the Flatpak index
endpoint (`/index/static`), which neither GHCR nor Harbor provides natively.
Conclusion: GHCR is right for Alba's bootc images, and wrong for a Flatpak
repository. Our mirrors are right for the Flatpak repository.

Tooling, in order of ambition:

- **Minimal, and enough to start**: `flatpak-builder --repo=`, `ostree summary -u`,
  a GPG signature, publication by rsync into the existing download space.
- **flat-manager** (what Flathub itself runs): upload API, build queues, tokens,
  delta generation. Worth it the day several people publish, not before.

Costs and traps to accept up front:

- a dedicated GPG signing key, published in the `.flatpakrepo`, kept off hodo
  (this joins the offsite key-custody work, and it is the one real prerequisite);
- **`summary` coherence**: the summary must never be cached ahead of the objects
  it references, or clients see an inconsistent repository. Relevant precisely
  because we would serve it from mirrors;
- static deltas cost disk space on every mirror;
- **the actual cost is maintenance, not infrastructure.** Hosting an application
  means tracking its security updates. Forever.

Guiding principle for the content: **duplicate nothing that is on Flathub**. What
justifies an OMV repository is OMV branding and the welcome application, OMV
applications absent from Flathub, and the occasional rebuild we have a specific
reason to own.

## 6. The Clang question

Two very different things get called "building our Flatpaks with Clang":

- **Compiling the application with Clang** is easy: the
  `org.freedesktop.Sdk.Extension.llvm*` SDK extensions exist for that. But the
  application then runs on a freedesktop runtime built with GCC, which supplies
  the overwhelming majority of the code in the sandbox. The benefit is close to
  nil.
- **Clang all the way down** means our own runtime, built from OMV RPMs, on the
  Fedora Flatpaks model (`org.fedoraproject.Platform`, applications relocated
  into `/app` through dedicated RPM macros). That is a permanent, staffed
  programme: runtime lifecycle, security updates, per-application spec forks,
  and for a Plasma distribution an `org.kde.Platform` equivalent on top. Fedora
  runs it with a constituted SIG and is currently retreating from it in favour
  of filtered Flathub.

**Position.** OpenMandriva's Clang identity belongs in the base image, where it
is already real: Alba's six RPM bricks are built with the native OMV toolchain,
and so is everything in the 221-package base. It does not belong in applications
packaged by other people. And it answers the wrong question anyway: recompiling
an application tells you nothing about who packaged it, which is the actual trust
problem with Flathub.

## 7. Proposal

1. **Preconfigure Flathub in `verified_floss`** through
   `/usr/share/flatpak/remotes.d/`, with the full catalogue one documented
   `flatpak remote-modify --subset=` away.
2. **Stand up a small OpenMandriva repository**: static signed OSTree, served by
   the existing mirrors, strictly OMV-specific content, minimal tooling first.
3. **Do not build `org.openmandriva.Platform`.** Revisit only if the Association
   ever commits people to it.
4. **Take one question to the TC**, because it outlives Alba: what is
   OpenMandriva's official position on enabling by default a catalogue that mixes
   free and proprietary software, and on shipping third-party packaging under our
   name?

## Verification status

Checked live on 2026-08-02: the `verified` / `floss` / `verified_floss`
subsummaries exist in Flathub's `summary.idx`; the catalogue counts come from
the Flathub search API; `--subset` and `remotes.d` behaviour come from
`flatpak-remote-add(1)` and `flatpak-remote(5)`.

Still to confirm on the machine, before this note drives any code: the behaviour
of `--subset` on the flatpak version currently in ROME, and the real reduction in
`flatpak remote-ls` inside the Alba VM (the server-side subset is computed from
repository metadata and may not match the search facets exactly).
