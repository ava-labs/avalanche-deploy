/*
 * blst_impl.c — pulls in the full blst C implementation via server.c.
 * CGO compiles every .c in the package; this file provides the blst symbols
 * that bridge.c references.
 */
#include "src/server.c"
