#define _GNU_SOURCE
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#include <time.h>
#include <unistd.h>
#include "native_health.h"

/* A test build uses a synthetic filesystem and shorter, equivalent deadlines. */
#ifndef DEVICE_ROOT
#define DEVICE_ROOT ""
#endif
#ifndef INIT_SHA
#define INIT_SHA "a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35"
#define UI_SHA "7a158227890ddd5dc247ab1d198cef3cf69a13d2667892a980effc2a9f509ca0"
#define SDK_SHA "7847ec604e7549c76da1b9e94326ce525ba7ea1fd51ee8e4422668d63f894fb7"
#endif
#ifndef TRIAL_MS
#define TRIAL_MS 120000
#define STARTUP_MS 20000
#define HEARTBEAT_MS 5000
#define COMMAND_MS 10000
#define POLL_MS 100
#endif
#define RECOVERY DEVICE_ROOT "/data/openu60-ui/recovery/"
#define INIT DEVICE_ROOT "/etc/init.d/zte_topsw_devui"
#define PROGRAM DEVICE_ROOT "/usr/bin/zte_topsw_devui"
#define SDK DEVICE_ROOT "/usr/lib/libzte_SDKowrt.so"
#define HEARTBEAT DEVICE_ROOT "/tmp/openu60-ui.heartbeat"
#define UI_STATUS DEVICE_ROOT "/tmp/openu60-native-ui.status"
#define UI_FAULT DEVICE_ROOT NATIVE_FAULT_PATH
#define REQUEST RECOVERY "restore.request"
#define ENABLED RECOVERY "enabled.sha256"
#define RUNNING RECOVERY "running"
#define OUTCOME RECOVERY "last-result"
#define LOCK DEVICE_ROOT "/tmp/openu60-ui.guard.lock"

static volatile sig_atomic_t interrupted;
static void on_signal(int number) { interrupted = number; }
static long long monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) { perror("clock_gettime"); exit(1); }
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static void poll_pause(void) {
    struct timespec pause = {POLL_MS / 1000, (POLL_MS % 1000) * 1000000};
    nanosleep(&pause, NULL);
}
static int wait_bounded(pid_t child, int timeout_ms) {
    int status;
    long long deadline = monotonic_ms() + timeout_ms;
    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        if (result < 0 && errno != EINTR) return 1;
        if (monotonic_ms() >= deadline) {
            kill(-child, SIGKILL);
            kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            fprintf(stderr, "Recovery command exceeded its deadline\n");
            return 1;
        }
        poll_pause();
    }
}
static int matches(const char *path, const char *expected) {
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC)) return 0;
    pid_t child = fork();
    if (!child) {
        setpgid(0, 0);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[0]); close(pipefd[1]);
        execlp("sha256sum", "sha256sum", path, (char *)NULL);
        _Exit(127);
    }
    close(pipefd[1]);
    if (child < 0) { close(pipefd[0]); return 0; }
    /* sha256sum output for these fixed public paths fits in the pipe. */
    int status = wait_bounded(child, COMMAND_MS);
    char output[512];
    ssize_t length = status ? -1 : read(pipefd[0], output, sizeof output);
    close(pipefd[0]);
    return length >= 65 && !memcmp(output, expected, 64) && output[64] == ' ';
}
static int factory_valid(int installed_init) {
    if (!matches(RECOVERY "stock-init.sh", INIT_SHA) ||
        !matches(RECOVERY "stock-devui", UI_SHA) ||
        !matches(RECOVERY "stock-sdk.so", SDK_SHA) ||
        !matches(PROGRAM, UI_SHA) || !matches(SDK, SDK_SHA) ||
        (installed_init && !matches(INIT, INIT_SHA))) {
        fprintf(stderr, "Factory checksum mismatch; no trial is permitted\n");
        return 0;
    }
    return 1;
}
static int sync_recovery(void) {
    int fd = open(RECOVERY, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int ok = fd >= 0 && !fsync(fd);
    if (fd >= 0 && close(fd)) ok = 0;
    if (!ok) perror("Sync recovery state");
    return ok;
}
static int remove_state(const char *path) {
    if (unlink(path) && errno != ENOENT) {perror("Remove recovery state"); return 0;}
    return sync_recovery();
}
static int write_state(const char *path, const char *bytes) {
    char temporary[512];
    if (snprintf(temporary, sizeof temporary, "%s.new.XXXXXX", path) >= (int)sizeof temporary) return 0;
    int fd = mkstemp(temporary);
    if (fd < 0) {perror("Create recovery state"); return 0;}
    size_t length = strlen(bytes), offset = 0;
    int ok = !fchmod(fd, 0600);
    while (ok && offset < length) {
        ssize_t count = write(fd, bytes + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {ok = 0; break;}
        offset += (size_t)count;
    }
    if (ok) ok = !fsync(fd);
    if (close(fd)) ok = 0;
    if (ok) ok = !rename(temporary, path) && sync_recovery();
    if (!ok) {unlink(temporary); perror("Persist recovery state");}
    return ok;
}
static int valid_sha(const char *sha) {
    return strlen(sha) == 64 && strspn(sha, "0123456789abcdef") == 64;
}
static int disarm(void) {return remove_state(ENABLED);}
static int record_outcome(const char *state) {
    char bytes[160];
    int length = snprintf(bytes, sizeof bytes, "{\"state\":\"%s\",\"atBootMs\":%lld}\n", state, monotonic_ms());
    return length > 0 && length < (int)sizeof bytes && write_state(OUTCOME, bytes);
}
static int record_ui_outcome(const char *state, unsigned long long sequence,
                             long long started, long long last_heartbeat) {
    char bytes[256]; long long now = monotonic_ms();
    int length = snprintf(bytes, sizeof bytes,
        "{\"state\":\"%s\",\"atBootMs\":%lld,\"sequence\":%llu,\"runtimeMs\":%lld,\"heartbeatAgeMs\":%lld}\n",
        state, now, sequence, now - started, now - last_heartbeat);
    return length > 0 && length < (int)sizeof bytes && write_state(OUTCOME, bytes);
}
static int atomic_copy_init(void) {
    char temporary[] = INIT ".recover.XXXXXX";
    int source = open(RECOVERY "stock-init.sh", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int target = source < 0 ? -1 : mkstemp(temporary);
    int ok = target >= 0;
    char bytes[4096];
    ssize_t count;
    while (ok && (count = read(source, bytes, sizeof bytes)) != 0) {
        if (count < 0) { if (errno == EINTR) continue; ok = 0; break; }
        for (ssize_t offset = 0; offset < count;) {
            ssize_t n = write(target, bytes + offset, (size_t)(count - offset));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = 0; break; }
            offset += n;
        }
    }
    if (ok) ok = !fchmod(target, 0755) && !fsync(target);
    if (source >= 0) close(source);
    if (target >= 0 && close(target)) ok = 0;
    if (ok) ok = !rename(temporary, INIT);
    if (ok) {
        int directory = open(DEVICE_ROOT "/etc/init.d", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        ok = directory >= 0 && !fsync(directory);
        if (directory >= 0) close(directory);
    }
    if (!ok) { unlink(temporary); perror("Persist factory startup"); }
    return ok;
}
static int service(const char *action) {
    pid_t child = fork();
    if (!child) {
        setpgid(0, 0);
        unsetenv("LD_PRELOAD");
        execl(INIT, INIT, action, (char *)NULL);
        _Exit(127);
    }
    return child < 0 ? 1 : wait_bounded(child, COMMAND_MS);
}
static int screen_processes(int terminate) {
#ifdef __linux__
    DIR *directory = opendir("/proc");
    if (!directory) return -1;
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (!*entry->d_name || strspn(entry->d_name, "0123456789") != strlen(entry->d_name)) continue;
        char path[320], program[512];
        snprintf(path, sizeof path, "/proc/%s/exe", entry->d_name);
        ssize_t length = readlink(path, program, sizeof program - 1);
        if (length < 0) {
            if (errno == ENOENT || errno == ESRCH) continue;
            closedir(directory); return -1;
        }
        program[length] = 0;
        if (!strcmp(program, PROGRAM)) {
            count++;
            if (terminate && kill((pid_t)strtol(entry->d_name, NULL, 10), SIGKILL) && errno != ESRCH) {
                closedir(directory); return -1;
            }
        }
    }
    closedir(directory);
    return count;
#else
    (void)terminate;
    /* Non-Linux builds are used only by the synthetic process tests. */
    return 0;
#endif
}
static int wait_for_screen_exit(void) {
    long long deadline = monotonic_ms() + COMMAND_MS;
    int forced = 0;
    for (;;) {
        int count = screen_processes(0);
        if (!count) return 0;
        if (count < 0 || monotonic_ms() >= deadline) {
            fputs("Factory screen still owns display/input; no trial will start\n", stderr);
            return 1;
        }
        /* A stopped factory instance can ignore TERM. Its pinned executable is
         * the only process this recovery owns; do not leave it holding input
         * or the display after procd has acknowledged the stop. */
        if (!forced && monotonic_ms() >= deadline - COMMAND_MS / 2) {
            if (screen_processes(1) < 0) return 1;
            forced = 1;
        }
        poll_pause();
    }
}
static int restore_factory(void) {
    /* Persist first: an ADB disconnect or a hung restart must not rearm a trial. */
    if (!factory_valid(0) || !atomic_copy_init()) return 1;
    puts("Factory startup is durable; restarting the original screen service");
    fflush(stdout);
    /* procd acknowledges stop asynchronously. A previous candidate can also
     * still be exiting after its parent's SIGKILL. Release display/input before
     * starting stock, including recovery after an unclean guardian exit. */
    if (service("stop") || wait_for_screen_exit()) {
        fprintf(stderr, "Screen ownership could not be released; factory startup remains the boot path\n");
        return 1;
    }
    unlink(HEARTBEAT); unlink(UI_STATUS); unlink(UI_FAULT);
    if (service("start")) {
        fprintf(stderr, "Factory service restart failed; a normal reboot uses the restored startup\n");
        return 1;
    }
    return 0;
}
static int request_restore(int lockfd) {
    if (!flock(lockfd, LOCK_EX | LOCK_NB)) {
        if (!disarm()) return 1;
        unlink(HEARTBEAT); unlink(REQUEST);
        int result = restore_factory();
        if (!remove_state(RUNNING) || !remove_state(REQUEST)) return 1;
        return result;
    }
    if (errno != EWOULDBLOCK) { perror("Recovery lock"); return 1; }
    /* A restore request survives guardian death and reboot until its owner
     * disables the candidate. Only the lock owner writes the enabled state. */
    if (!write_state(REQUEST, "restore\n")) return 1;
    long long deadline = monotonic_ms() + 3 * COMMAND_MS;
    do {
        if (!flock(lockfd, LOCK_EX | LOCK_NB)) {
            if (!disarm()) return 1;
            if (access(REQUEST, F_OK) && errno == ENOENT && factory_valid(1)) return 0;
            int result = restore_factory();
            if (!remove_state(RUNNING) || !remove_state(REQUEST)) return 1;
            return result;
        }
        if (errno != EWOULDBLOCK) break;
        poll_pause();
    } while (monotonic_ms() < deadline);
    fprintf(stderr, "Recovery supervisor did not finish; factory startup remains the boot path\n");
    return 1;
}
static int heartbeat(pid_t child, unsigned long long *previous) {
    FILE *file = fopen(HEARTBEAT, "r");
    if (!file) return 0;
    long reported_pid;
    unsigned long long sequence;
    char extra;
    int fields = fscanf(file, "%ld %llu %c", &reported_pid, &sequence, &extra);
    fclose(file);
    if (fields != 2 || reported_pid != child || sequence <= *previous) return 0;
    *previous = sequence;
    return 1;
}
static const char *reported_fault(pid_t child) {
    int fd = open(UI_FAULT, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NULL;
    char bytes[64]; ssize_t length = read(fd, bytes, sizeof bytes - 1); close(fd);
    if (length <= 0) return NULL;
    bytes[length] = 0;
    long reported_pid; unsigned code; char extra;
    if (sscanf(bytes, "%ld %u %c", &reported_pid, &code, &extra) != 2 || reported_pid != child) return NULL;
    return native_fault_reason(code);
}
static int supervise(const char *candidate_sha, int permanent) {
    if (!valid_sha(candidate_sha) ||
        !factory_valid(1) || !matches(RECOVERY "trial.so", candidate_sha)) {
        fprintf(stderr, "Trial rejected before stopping the factory service\n");
        return 1;
    }
    if (permanent && (!record_outcome("starting") || !write_state(RUNNING, "starting\n"))) return 1;
    unlink(HEARTBEAT);
    unlink(UI_STATUS);
    unlink(UI_FAULT);
    if (service("stop")) { if (permanent) disarm(); restore_factory(); return 1; }
    /* procd can acknowledge stop before its child has closed DRM and input. */
    if (wait_for_screen_exit()) { if (permanent) disarm(); restore_factory(); return 1; }
    if (interrupted) {
        int result = restore_factory();
        if (permanent && !remove_state(RUNNING)) return 1;
        return result;
    }
    pid_t supervisor = getpid();
    pid_t child = fork();
    if (!child) {
        setpgid(0, 0);
#ifdef __linux__
        /* An uncatchable guardian death must not leave the candidate on screen. */
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != supervisor) _Exit(127);
#else
        (void)supervisor;
#endif
        if (setenv("LD_PRELOAD", RECOVERY "trial.so", 1)) _Exit(127);
        struct rlimit core = {0, 0};
        if (setrlimit(RLIMIT_CORE, &core)) _Exit(127);
        /* procd launches the factory UI with all three streams on /dev/null.
         * Preserve that environment; SDK diagnostic text is not trial output. */
        int null = open("/dev/null", O_RDWR | O_CLOEXEC);
        if (null < 0 || dup2(null, STDIN_FILENO) < 0 || dup2(null, STDOUT_FILENO) < 0 || dup2(null, STDERR_FILENO) < 0) _Exit(127);
        if (null > STDERR_FILENO) close(null);
        execl(PROGRAM, PROGRAM, (char *)NULL);
        _Exit(127);
    }
    if (child < 0) { perror("Launch screen candidate"); if (permanent) disarm(); restore_factory(); return 1; }
    long long started = monotonic_ms(), last_heartbeat = started;
    unsigned long long sequence = 0;
    const char *reason;
    int reaped = 0, ordinary_exit = 0;
    for (;;) {
        reason = reported_fault(child);
        if (reason) break;
        int status;
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            reaped = 1; reason = "trial process exited";
            ordinary_exit = (WIFEXITED(status) && WEXITSTATUS(status) == 0) ||
                (WIFSIGNALED(status) && (WTERMSIG(status) == SIGTERM || WTERMSIG(status) == SIGKILL));
            if (WIFEXITED(status)) printf("Trial exit code: %d\n", WEXITSTATUS(status));
            else if (WIFSIGNALED(status)) printf("Trial termination signal: %d\n", WTERMSIG(status));
            fflush(stdout); break;
        }
        if (result < 0 && errno != EINTR) { reason = "trial process state unavailable"; break; }
        long long now = monotonic_ms();
        if (interrupted) { reason = "supervisor interrupted"; break; }
        if (!access(REQUEST, F_OK)) { reason = "manual restore requested"; break; }
        if (!permanent && now - started >= TRIAL_MS) { reason = "trial deadline reached"; break; }
        if (heartbeat(child, &sequence)) {
            if (last_heartbeat == started) {
                if (permanent && !record_outcome("running")) {reason = "cannot persist UI health"; break;}
                puts("UI-thread heartbeat active"); fflush(stdout);
            }
            last_heartbeat = now;
        }
        if (now - last_heartbeat >= (sequence ? HEARTBEAT_MS : STARTUP_MS)) {
            reason = "UI heartbeat stopped"; break;
        }
        poll_pause();
    }
    printf("Restoring factory screen: %s\n", reason);
    fflush(stdout);
    int state_ok = 1;
    /* procd shutdown can reap the UI before the guardian handles TERM. Keep
     * enablement for an ordinary exit in that ordering, but never turn a
     * concurrent crash into a clean stop. */
    int clean_stop = interrupted == SIGTERM && access(REQUEST, F_OK) &&
        ((!reaped && !strcmp(reason, "supervisor interrupted")) || (reaped && ordinary_exit));
    if (permanent && !record_ui_outcome(clean_stop ? "clean-stop" : reason, sequence, started, last_heartbeat)) state_ok = 0;
    if (permanent && !clean_stop && !disarm()) state_ok = 0;
    /* Own a separate process group; descendants must not keep display/input open. */
    kill(-child, SIGKILL);
    if (!reaped) { kill(child, SIGKILL); wait_bounded(child, COMMAND_MS); }
    unlink(HEARTBEAT);
    unlink(UI_STATUS);
    unlink(UI_FAULT);
    int recovered = restore_factory();
    if (permanent && !remove_state(RUNNING)) state_ok = 0;
    if (!recovered && !remove_state(REQUEST)) state_ok = 0;
    if (!state_ok) return 1;
    if (recovered) return recovered;
    if (permanent && clean_stop) return 0;
    return strcmp(reason, "trial deadline reached") && strcmp(reason, "manual restore requested") ? 1 : 0;
}
static int enable(const char *candidate_sha) {
    if (!valid_sha(candidate_sha) || !factory_valid(1) || !matches(RECOVERY "trial.so", candidate_sha)) {
        fputs("Candidate rejected; startup remains unchanged\n", stderr); return 1;
    }
    if (!access(RUNNING, F_OK) || !access(REQUEST, F_OK)) {
        fputs("Restore the original screen before enabling a candidate\n", stderr); return 1;
    }
    if (!write_state(ENABLED, candidate_sha)) return 1;
    puts("Candidate enabled for the supervised screen service"); return 0;
}
static int promote(const char *sha, int guard) {
    const char *source = guard ? RECOVERY "guard.new" : RECOVERY "trial.so.new";
    const char *target = guard ? RECOVERY "guard" : RECOVERY "trial.so";
    if (!guard && (!access(ENABLED, F_OK) || !access(RUNNING, F_OK))) {
        fputs("Restore the enabled screen before replacing its candidate\n", stderr); return 1;
    }
    if (!valid_sha(sha) || !factory_valid(1) || !matches(source, sha)) {
        fputs("Staged screen component failed admission\n", stderr); return 1;
    }
    /* Publication shares the supervisor lock: staging can never replace a
     * running guardian's protocol or an enabled candidate's boot image. */
    if (chmod(source, 0500) || rename(source, target) || !sync_recovery()) {
        perror("Publish screen component"); return 1;
    }
    return 0;
}
static int serve(void) {
    /* A previous guardian that did not clean up may have crashed, been killed,
     * or lost power. Disable this candidate before restoring stock instead of
     * repeatedly loading it on procd respawn or the next boot. */
    if (!access(RUNNING, F_OK) || !access(REQUEST, F_OK)) {
        if (!record_outcome("unclean-session")) return 1;
        if (!disarm()) return 1;
        int result = restore_factory();
        if (!remove_state(RUNNING) || !remove_state(REQUEST)) return 1;
        return result;
    }
    int fd = open(ENABLED, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0 && errno == ENOENT) {puts("Native screen extension is disabled"); return 0;}
    if (fd < 0) {perror("Read enabled candidate"); return 1;}
    char sha[66] = {0}; ssize_t length = read(fd, sha, sizeof sha - 1); int closed = close(fd);
    if (length != 64 || closed || !valid_sha(sha) || !factory_valid(1) || !matches(RECOVERY "trial.so", sha)) {
        if (!record_outcome("admission-rejected")) return 1;
        if (!disarm()) return 1;
        fputs("Enabled candidate failed admission; original screen retained\n", stderr); return 1;
    }
    return supervise(sha, 1);
}
int main(int argc, char **argv) {
#ifndef OPENU60_RECOVERY_TEST
    if (geteuid() != 0) { fputs("Recovery requires root\n", stderr); return 1; }
#endif
    if (argc < 2 || (strcmp(argv[1], "status") && strcmp(argv[1], "restore") &&
                     strcmp(argv[1], "trial") && strcmp(argv[1], "enable") && strcmp(argv[1], "serve") &&
                     strcmp(argv[1], "promote-guard") && strcmp(argv[1], "stage-candidate")) ||
        ((!strcmp(argv[1], "trial") || !strcmp(argv[1], "enable") || !strcmp(argv[1], "promote-guard") ||
          !strcmp(argv[1], "stage-candidate")) ? argc != 3 : argc != 2)) {
        fputs("Usage: openu60-ui-recovery status|restore|serve|enable SHA256|trial SHA256|promote-guard SHA256|stage-candidate SHA256\n", stderr);
        return 2;
    }
    /* The recovery process never inherits a candidate's loader configuration. */
    unsetenv("LD_PRELOAD");
    if (!strcmp(argv[1], "status")) {
        if (!factory_valid(1)) return 1;
        puts("Factory files and recovery backups verified; boot uses the original screen");
        puts(access(ENABLED, F_OK) ? "Native screen extension is disabled" : "Native screen extension is enabled under supervision");
        return 0;
    }
    int lockfd = open(LOCK, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lockfd < 0) { perror("Recovery lock"); return 1; }
    int result;
    if (!strcmp(argv[1], "restore")) result = request_restore(lockfd);
    else if (flock(lockfd, LOCK_EX | LOCK_NB)) {
        fputs("Another recovery or trial is running\n", stderr); result = 1;
    } else {
        struct sigaction action = {.sa_handler = on_signal};
        sigemptyset(&action.sa_mask);
        sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL);
        sigaction(SIGHUP, &action, NULL);
        signal(SIGPIPE, SIG_IGN);
        if (!strcmp(argv[1], "enable")) result = enable(argv[2]);
        else if (!strcmp(argv[1], "serve")) result = serve();
        else if (!strcmp(argv[1], "promote-guard")) result = promote(argv[2], 1);
        else if (!strcmp(argv[1], "stage-candidate")) result = promote(argv[2], 0);
        else if (!access(REQUEST, F_OK) || !access(RUNNING, F_OK) || !access(ENABLED, F_OK)) {
            fputs("Restore the previous screen session before a trial\n", stderr); result = 1;
        } else result = supervise(argv[2], 0);
    }
    close(lockfd);
    return result;
}
