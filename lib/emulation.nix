# Running Google's x86_64-only toolchain on a machine that is not x86_64.
#
# Everything Google publishes for Android is a `linux-x86_64` binary: the
# NDK's clang, aapt2, d8, CMake. Anywhere else they have to be emulated, and
# the emulator has to be a build input rather than a property of the machine
# — a sandboxed build cannot use the kernel's `binfmt_misc`, and a derivation
# should not depend on how a host is set up anyway.
{ pkgs }:
let
  inherit (pkgs) lib;
in
{
  # A shell fragment that refuses to build where emulation cannot be trusted.
  #
  # qemu presents a 4 KiB-page address space to an x86_64 guest. Where the host
  # cannot map at that granularity — a 16 KiB-page kernel, which is what Apple
  # Silicon runs — mappings that should be independent share a host page, and a
  # workload with enough mmap churn corrupts itself instead of failing. An `-O3`
  # compile of the SQLite amalgamation is enough:
  #
  #   libc++abi: Pure virtual function called!
  #   qemu: uncaught target signal 6 (Aborted) - core dumped
  #
  # Fourteen minutes in, with nothing naming the cause. Stopping at the start
  # with a sentence is strictly better, and this is the one check that cannot be
  # expressed as a dependency: it is a property of the running kernel.
  #
  # Verified rather than guessed. The Rust dependency layer of a Petros app
  # builds on an `ubuntu-24.04-arm` runner — aarch64, same wrappers, same pinned
  # qemu, 4 KiB pages — and aborts on a 16 KiB laptop.
  emulationGuard = ''
    if [ "$(getconf PAGESIZE)" != 4096 ]; then
      echo "" >&2
      echo "This kernel uses $(getconf PAGESIZE)-byte pages, and emulating an" >&2
      echo "x86_64 toolchain needs 4096." >&2
      echo "" >&2
      echo "qemu has to present a 4 KiB-page address space to the guest. It" >&2
      echo "cannot do that faithfully here, and the way it fails is silent:" >&2
      echo "a large compile corrupts itself rather than stopping, somewhere" >&2
      echo "in the middle, blaming nothing." >&2
      echo "" >&2
      echo "There is no 4 KiB kernel to boot on Apple Silicon — Fedora Asahi" >&2
      echo "ships a unified 16 KiB one and nixos-apple-silicon is 16 KiB only." >&2
      echo "What works:" >&2
      echo "" >&2
      echo "  - build on an x86_64 machine, where none of this is emulated:" >&2
      echo "      nix build .#packages.x86_64-linux.<output>" >&2
      echo "    with '--builders \"ssh://box x86_64-linux\"' to offload it," >&2
      echo "    or let CI do it" >&2
      echo "  - or run the build inside a 4 KiB microVM (muvm), which is how" >&2
      echo "    Fedora Asahi runs x86 binaries at all" >&2
      echo "" >&2
      exit 1
    fi
  '';

  # True where the machine doing the building is not the machine Google built
  # for, which is the only case where any of this changes anything.
  needsEmulation = pkgs.stdenv.buildPlatform.system != "x86_64-linux";

  # Every x86_64 host executable in `tree`, replaced by a wrapper that runs it
  # under a pinned `qemu-x86_64`. A farm of symlinks otherwise.
  #
  # Registering `binfmt_misc` for x86_64 is the other way to arrange this, and
  # is what this used to depend on — the kernel notices the ELF header and
  # hands the file to qemu, transparently, so nothing in the build has to know.
  #
  # Two things are wrong with it. It is a property of the machine rather than
  # of the derivation, which is the kind of thing nix exists to remove: a build
  # that works here and not there, with nothing in the expression to say why.
  # And inside a build sandbox it does not work at all — the emulated clang
  # starts, loads its libraries, and dies resolving its own libc:
  #
  #   clang: symbol lookup error: undefined symbol: ceilf, version GLIBC_2.2.5
  #
  # `undefined symbol` rather than `cannot open shared object file`, so a libm
  # *was* found and it was the wrong one. Which one the guest loader finds
  # depends on how it was invoked, and under `binfmt_misc` the kernel invokes
  # it — nothing in the build gets a say.
  #
  # It says nothing about whether the emulated toolchain is *fast*. It is not,
  # and it was not before: this changes who supplies qemu, not how much work it
  # has to do.
  emulateX86 = name: tree:
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.patchelf ]; } ''
      # A farm of symlinks rather than a copy: an SDK with an NDK in it is
      # several gigabytes and only the executables change.
      #
      # `find -L`, and that is the whole difficulty. The SDK is itself composed
      # out of *directory* symlinks: `ndk/27.1.12297006`, `platform-tools` and
      # each `build-tools` version are links into other store paths. A copy
      # that does not follow them stops at the link and wraps nothing that
      # matters — `cp -rs` reported seven binaries, all of them the ones
      # sitting loose in `bin`, and the NDK's sixty untouched behind a link.
      # On an x86_64 machine that still *works*, which is exactly how it would
      # have shipped.
      mkdir -p $out
      cd ${tree}

      # Is this a binary that has to be emulated? Four questions, cheapest
      # first: is it an ELF at all, is it 64-bit, is it x86-64 — and is it for
      # *this* machine rather than for a phone. That last one is not idle: the
      # NDK's sysroot carries a whole x86_64-android target, whose files answer
      # the first three exactly as the compiler does. What separates them is
      # the interpreter. nixpkgs patches a host binary's to a store loader;
      # Android's stays `/system/bin/linker64`, and a shared object has none.
      emulated() {
        local f=$1 hdr interp
        hdr=$(od -An -tu1 -j0 -N20 -- "$f" 2>/dev/null) || return 1
        set -- $hdr
        [ $# -ge 20 ] || return 1
        [ "$1 $2 $3 $4" = "127 69 76 70" ] || return 1
        [ "$5" = 2 ] || return 1
        [ "''${19}" = 62 ] || return 1
        interp=$(patchelf --print-interpreter "$f" 2>/dev/null) || return 1
        case "$interp" in /nix/store/*) return 0 ;; *) return 1 ;; esac
      }

      find -L . -type d -printf '%P\0' | while IFS= read -r -d ''' d; do
        mkdir -p "$out/$d"
      done

      wrapped=0
      linked=0
      while IFS= read -r -d ''' f; do
        src=$(readlink -f -- "./$f") || src=""

        if [ -n "$src" ] && [ -f "$src" ] && [ -x "$src" ] &&
           emulated "$src"; then
          # Both paths are settled here rather than worked out at run time,
          # and `-0` is the load-bearing half of it.
          #
          # A compiler has to know where it lives — clang reads its own path
          # to find its resource headers, its sysroot and the linker it
          # execs — and under emulation `/proc/self/exe` does not tell it, so
          # argv[0] is all it has. Given a bare name it looks along `$PATH`,
          # fails, and settles on the working directory:
          #
          #   InstalledDir: /nix/var/nix/builds/nix-build-ndk-check…
          #
          # from where it finds none of those things. Given this wrapper's own
          # path it finds all of them *in the farm*, which matters twice over:
          # the farm mirrors the whole toolchain, and every tool clang reaches
          # for there is a wrapper rather than a bare x86_64 binary. That is
          # what makes the linker work, since a process already inside qemu
          # cannot exec a foreign binary on its own.
          #
          # It also keeps the name: `clang++` is a symlink to `clang`, and the
          # driver reads the last component to decide which language it is
          # compiling.
          #
          # `NDK_EMULATION_DEBUG` exists because when this goes wrong it goes
          # wrong in the guest's dynamic loader, and the failure depends on the
          # environment it was called in rather than on the binary: the same
          # clang that the NDK check drives happily fails under cargo, which
          # sets `LD_LIBRARY_PATH` for a build script and hands it to every
          # child. Running it by hand afterwards proves nothing, because by
          # hand is the case that works. So the question has to be asked from
          # inside.
          #
          # `LD_BIND_NOW` is what makes an emulated toolchain work at all.
          #
          # Lazy binding resolves a PLT entry the first time it is called, in
          # `_dl_runtime_resolve` — and which of those trampolines glibc picks
          # depends on the CPU features it reads from `cpuid`, one of them
          # saving vector state with `xsavec`. Emulated, that goes wrong, and
          # it goes wrong as a *lookup failure* rather than a crash:
          #
          #   clang: symbol lookup error: undefined symbol: ceilf,
          #   version GLIBC_2.2.5
          #
          # which reads like a missing library and is nothing of the kind. The
          # same `ceilf` resolves without complaint when every entry is bound
          # at startup, which is what this asks for. Demonstrated on the
          # machine that fails: `clang --version` passes either way, because
          # nothing in it calls `ceilf`, and an `-O3` compile fails lazily and
          # succeeds eagerly.
          #
          # Only when unset, so a caller can ask for the lazy path back — which
          # the NDK check does, to keep the property under test rather than
          # merely commented.
          cat > "$out/$f" <<WRAPPER
      #!${pkgs.runtimeShell}
      [ -z "\''${LD_BIND_NOW+set}" ] && export LD_BIND_NOW=1
      [ -n "\''${NDK_EMULATION_DEBUG-}" ] && export LD_DEBUG=libs,versions
      exec ${pkgs.qemu-user}/bin/qemu-x86_64 -0 "$out/$f" "$src" "\$@"
      WRAPPER
          chmod +x "$out/$f"
          wrapped=$((wrapped + 1))
        else
          ln -s "''${src:-./$f}" "$out/$f"
          linked=$((linked + 1))
        fi
      done < <(find -L . ! -type d -printf '%P\0')

      echo "emulating $wrapped executables; $linked other files linked through"
      [ "$wrapped" -gt 0 ] || { echo "nothing was wrapped" >&2; exit 1; }
    '';
}
