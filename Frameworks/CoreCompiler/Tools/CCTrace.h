/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2026 Alec Pixton

 Build trace for Nyxian's in-process toolchain.

 Nothing inside this app reaches the system log: measured 2026-09-17, the
 process emits hundreds of UIKit lines over USB and not one line of its own
 NSLog output. The compiler, the linker and everything else in the toolchain
 therefore write here instead, to Documents/build.log, always on. Two days of
 builds failed with "Failed to run project." and nothing else because the
 frontend's real complaint -- unknown argument: '-frontend' -- went to a
 stderr that goes nowhere in an iOS app.

 Header-only on purpose: no new file needs adding to a target.
*/

#ifndef CORECOMPILER_CCTRACE_H
#define CORECOMPILER_CCTRACE_H

#include <cstdio>
#include <cstdlib>
#include <string>
#include <llvm/ADT/SmallVector.h>
#include <unistd.h>

/* Opens Documents/build.log for append. Returns nullptr if it cannot; every
   caller must tolerate that and simply skip tracing. */
static inline FILE *CCTraceOpen(void)
{
    const char *home = getenv("HOME");
    if(home == nullptr)
    {
        return nullptr;
    }
    
    std::string path = std::string(home) + "/Documents/build.log";
    return fopen(path.c_str(), "a");
}

/* One line per argument, so a long command line stays readable. */
static inline void CCTraceArguments(FILE *trace,
                                    const char *label,
                                    const llvm::SmallVectorImpl<std::string> &args)
{
    if(trace == nullptr)
    {
        return;
    }
    
    fprintf(trace, "\n--- %s, %zu args (as passed)\n", label ? label : "job", (size_t)args.size());
    for(const auto &a : args)
    {
        fprintf(trace, "    %s\n", a.c_str());
    }
    fflush(trace);
}

/* Point stdout and stderr at the trace for the duration of a call: clang, lld
   and the Swift frontend all report through them before, or instead of, any
   diagnostic consumer we install. */
typedef struct
{
    int savedOut;
    int savedErr;
    FILE *trace;
} CCTraceCapture;

static inline CCTraceCapture CCTraceCaptureBegin(FILE *trace)
{
    CCTraceCapture c = { -1, -1, trace };
    if(trace == nullptr)
    {
        return c;
    }
    
    fflush(stdout);
    fflush(stderr);
    fprintf(trace, "  --- output ---\n");
    fflush(trace);
    c.savedOut = dup(1);
    c.savedErr = dup(2);
    dup2(fileno(trace), 1);
    dup2(fileno(trace), 2);
    return c;
}

static inline void CCTraceCaptureEnd(CCTraceCapture *c)
{
    if(c == nullptr || c->trace == nullptr)
    {
        return;
    }
    
    fflush(stdout);
    fflush(stderr);
    if(c->savedOut >= 0) { dup2(c->savedOut, 1); close(c->savedOut); c->savedOut = -1; }
    if(c->savedErr >= 0) { dup2(c->savedErr, 2); close(c->savedErr); c->savedErr = -1; }
    fprintf(c->trace, "  --- end output ---\n");
    fflush(c->trace);
}

#endif /* CORECOMPILER_CCTRACE_H */
