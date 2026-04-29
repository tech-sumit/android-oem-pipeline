#!/usr/bin/env python3
"""
fakejail: drop-in stand-in for nsjail when the container has no
CAP_SYS_ADMIN and the kernel rejects every CLONE_NEW* flag (RunPod /
Vast.ai / most managed Docker hosts). We materialize the bind-mount
semantics from -B / -R inside the sandbox directory and exec the
child directly, never calling clone() with a namespace flag.

Files are hardlinked, directories are symlinked. The hardlink path
matters for binaries with $ORIGIN-based DT_RPATH (Soong's host
toolchain does this heavily): with a hardlink, /proc/self/exe is
the sandbox path, so $ORIGIN/../lib64/libc++.so resolves to the
hardlinked libc++.so we placed in the sandbox. With a plain symlink
ld.so would dereference to the real path and miss the sandbox layout.

Honoured nsjail flags:
    -B SRC:DST       bind  (RW) -> hardlink/symlink DST -> SRC
    -R SRC:DST       bind  (RO) -> hardlink/symlink DST -> SRC
    -D DIR           chdir into DIR before exec
    -m TMPFS_SPEC    ignored (host /tmp is fine)
    --disable_*      ignored
    --skip_*         ignored
    -q -v -Mo -Me -Mr -Ml ignored
    everything after '--' is the inner cmd

Absolute DST paths (e.g. /bin /lib /usr) are left alone -- the host
filesystem already has them. The first -B whose DST equals the -D
workdir is treated as the sandbox root: we chdir into its SRC.
"""
import os
import shutil
import sys


def parse(argv):
    binds = []
    workdir = None
    inner = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--':
            inner = argv[i + 1:]
            break
        if a in ('-B', '-R'):
            spec = argv[i + 1]
            src, _, dst = spec.partition(':')
            binds.append((src, dst))
            i += 2
            continue
        if a == '-D':
            workdir = argv[i + 1]
            i += 2
            continue
        if a == '-m' or a == '-T':
            i += 2
            continue
        if a in ('-q', '-v', '-Mo', '-Me', '-Mr', '-Ml'):
            i += 1
            continue
        if a.startswith('--disable_') or a.startswith('--skip_'):
            i += 1
            continue
        i += 1
    return binds, workdir, inner


def main():
    binds, workdir, inner = parse(sys.argv[1:])
    if not inner:
        print('fakejail: missing inner command (no -- separator)',
              file=sys.stderr)
        sys.exit(2)

    sandbox_abs = None
    if workdir:
        for src, dst in binds:
            if dst == workdir or dst.rstrip('/') == workdir.rstrip('/'):
                sandbox_abs = src
                break
        if sandbox_abs is None:
            sandbox_abs = os.path.abspath(workdir)
            os.makedirs(sandbox_abs, exist_ok=True)
    else:
        sandbox_abs = os.getcwd()

    for src, dst in binds:
        if not dst or dst.startswith('/'):
            continue
        if workdir and (dst == workdir
                        or dst.rstrip('/') == workdir.rstrip('/')):
            continue

        if workdir and dst.startswith(workdir + '/'):
            dst_inside = dst[len(workdir) + 1:]
        else:
            dst_inside = dst

        if not os.path.exists(src):
            print(f'fakejail: src missing: {src}', file=sys.stderr)
            sys.exit(2)

        target = os.path.join(sandbox_abs, dst_inside)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.lexists(target):
            if os.path.islink(target) or os.path.isfile(target):
                os.remove(target)
            else:
                shutil.rmtree(target)

        if os.path.isdir(src) and not os.path.islink(src):
            os.symlink(src, target)
        else:
            try:
                os.link(src, target)
            except OSError as exc:
                if exc.errno in (18, 1):
                    os.symlink(src, target)
                else:
                    raise

    os.chdir(sandbox_abs)
    os.execvp(inner[0], inner)


if __name__ == '__main__':
    main()
