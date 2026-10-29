/* Link the real, pinned TkTextPrintIndex implementation. The only replacement
 * is the B-tree line lookup, avoiding a window and multi-gigabyte allocation.
 * A synthetic non-character segment lets the actual index formatter exercise
 * character positions beyond 32 bits. No Tk_Init or window API is called. */
#include "tkInt.h"
#include "tkText.h"
#include <stdio.h>
#include <string.h>

static int line_number = 0;
int __wrap_TkBTreeLinesTo(const TkText *text, const TkTextLine *line) {
    (void)text; (void)line;
    return line_number;
}

int main(void) {
    if (sizeof(Tcl_Size) != 8) return 2;
    printf("Tcl_Size width=%zu; Tcl printf modifier=%s\n", sizeof(Tcl_Size), TCL_SIZE_MODIFIER);
    static const struct { Tcl_Size position; const char *want; } cases[] = {
        {0, "1.0"},
        {2147483648LL, "1.2147483648"},
        {4294967313LL, "1.4294967313"},
        {9223372036854775807LL, "1.9223372036854775807"}
    };
    TkTextSegment segment = {0};
    TkTextLine line = {0};
    TkTextIndex index = {0};
    segment.size = TCL_SIZE_MAX;
    line.segPtr = &segment;
    index.linePtr = &line;
    int failures = 0;
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        char output[TK_POS_CHARS];
        memset(output, 0x5a, sizeof output);
        index.byteIndex = cases[i].position;
        Tcl_Size length = TkTextPrintIndex(NULL, &index, output);
        int ok = strcmp(output, cases[i].want) == 0 &&
            length == (Tcl_Size)strlen(cases[i].want);
        printf("%s TkTextPrintIndex %s\n", ok ? "ok  " : "FAIL", cases[i].want);
        if (!ok) { fprintf(stderr, "got [%s], length %lld\n", output, (long long)length); failures++; }
    }
    return failures ? 1 : 0;
}
