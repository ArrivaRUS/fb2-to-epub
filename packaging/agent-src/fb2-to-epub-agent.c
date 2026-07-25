// fb2-to-epub-agent.c — the stable Full-Disk-Access "responsible target" of the
// fb2-to-epub LaunchAgent (v1.0.2, arch/plan-binrunner-synthesis.md).
//
// WHY A MACH-O BINARY (and not the old runner.sh):
//   macOS Tahoe (26.x) attributes a launchd agent's TCC request to the Mach-O
//   IMAGE of the responsible process. For a shebang script the image is
//   /bin/bash — the script's own path never reaches tccd ("AUTHREQ_SUBJECT
//   subject=/bin/bash", and platform binaries are silently denied), so a grant
//   given to runner.sh is dead as a class. Making ProgramArguments[0] point at
//   THIS binary makes the subject our own file: the user grants FDA to it once,
//   and the grant lives as long as the path AND the bytes stay stable (ad-hoc
//   designated requirement = cdhash of these bytes).
//
// WHY spawn+wait AND NOT exec (load-bearing, do not "simplify"):
//   exec would REPLACE this process image with /bin/bash — the TCC subject
//   would become /bin/bash again and the bug would be back. Instead we spawn
//   `/bin/bash <watcher>` as a CHILD and wait for it: this helper stays alive
//   as the responsible parent, and the children (bash → python3 → Calibre) are
//   attributed to it. Proven by the E1 tccd log (scratchpad/tcc_e1.log) and
//   re-proven by the T0 gate before integration.
//
// BYTE STABILITY (the second axis of the grant):
//   This source is compiled ONCE by packaging/agent-src/build-once.sh; the
//   resulting universal binary packaging/fb2-to-epub-agent is committed to git
//   and FROZEN. Rebuilding produces a new cdhash and silently kills every
//   user's grant — see packaging/agent-src/PROVENANCE.md before touching it.
//
// Behavior (parity with the old runner.sh unless stated):
//   • finds fb2-to-epub-watcher.sh NEXT TO ITSELF (own path via
//     _NSGetExecutablePath + realpath — not argv[0], which launchd/relative
//     invocations make unreliable);
//   • missing watcher → message to stderr + exit 1 (same as runner.sh);
//   • environment is inherited as-is (WATCH_DIR / PATH / CALIBRE_MACOS_DIR /
//     EBOOK_* / PYTHON3 come from the LaunchAgent's EnvironmentVariables);
//   • SIGTERM/SIGINT/SIGHUP are forwarded to the child so the watcher's traps
//     run (lock cleanup) exactly as when the watcher was the process itself;
//   • the child's exit code is mirrored (128+signal when it died of a signal);
//   • no stdout noise — stdout/stderr pass through to the agent's log file.
//
// No dependencies beyond libSystem. Keep this file as small as possible: any
// future change means a new cdhash and a re-grant for every user.

#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// Child pid for the signal forwarder. sig_atomic_t is int on macOS and pid_t
// fits; 0 = "not spawned yet". A signal that arrives before the spawn returns
// is remembered in g_pending_sig and delivered right after.
static volatile sig_atomic_t g_child = 0;
static volatile sig_atomic_t g_pending_sig = 0;

static void forward_signal(int sig) {
    pid_t child = (pid_t)g_child;
    if (child > 0) {
        kill(child, sig);            // async-signal-safe
    } else {
        g_pending_sig = sig;
    }
}

// Resolve our own absolute path. _NSGetExecutablePath is authoritative for the
// running image (works for absolute, relative and PATH-based invocations);
// realpath collapses symlinks so the watcher is looked up next to the REAL
// file. argv[0] is only a last-resort fallback.
static int resolve_self_path(const char *argv0, char *out, size_t outsz) {
    char buf[PATH_MAX];
    uint32_t sz = (uint32_t)sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) != 0) {
        if (argv0 == NULL || argv0[0] == '\0') return -1;
        strlcpy(buf, argv0, sizeof(buf));
    }
    if (realpath(buf, out) == NULL) {
        // realpath may fail on exotic mounts; fall back to the raw path.
        strlcpy(out, buf, outsz);
    }
    return 0;
}

int main(int argc, char *argv[]) {
    char self[PATH_MAX];
    if (resolve_self_path(argc > 0 ? argv[0] : NULL, self, sizeof(self)) != 0) {
        fprintf(stderr, "fb2-to-epub-agent: cannot resolve own path\n");
        return 1;
    }

    // dirname() may modify its argument and returns a pointer into it —
    // keep the copy alive for as long as `dir` is used.
    char selfcopy[PATH_MAX];
    strlcpy(selfcopy, self, sizeof(selfcopy));
    const char *dir = dirname(selfcopy);

    char watcher[PATH_MAX];
    int n = snprintf(watcher, sizeof(watcher), "%s/fb2-to-epub-watcher.sh", dir);
    if (n < 0 || (size_t)n >= sizeof(watcher)) {
        fprintf(stderr, "fb2-to-epub-agent: watcher path too long\n");
        return 1;
    }
    if (access(watcher, R_OK) != 0) {
        fprintf(stderr, "fb2-to-epub: watcher not found at %s\n", watcher);
        return 1;
    }

    // Install the forwarders BEFORE spawning so no termination request is lost.
    // No SA_RESTART: a forwarded signal interrupts waitpid with EINTR and the
    // loop below retries until the child actually exits.
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = forward_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    // spawn+wait, NOT exec — see the header comment. Environment inherited.
    char *child_argv[] = { "/bin/bash", watcher, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/bin/bash", NULL, NULL, child_argv, environ);
    if (rc != 0) {
        fprintf(stderr, "fb2-to-epub-agent: posix_spawn(/bin/bash %s): %s\n",
                watcher, strerror(rc));
        return 1;
    }
    g_child = (sig_atomic_t)pid;
    if (g_pending_sig != 0) kill(pid, (int)g_pending_sig);

    int status = 0;
    for (;;) {
        pid_t w = waitpid(pid, &status, 0);
        if (w == pid) break;
        if (w == -1 && errno == EINTR) continue;  // signal forwarded; keep waiting
        fprintf(stderr, "fb2-to-epub-agent: waitpid: %s\n", strerror(errno));
        return 1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
