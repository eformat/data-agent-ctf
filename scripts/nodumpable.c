#include <sys/prctl.h>
__attribute__((constructor)) void _nodumpable(void) {
    prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
}
