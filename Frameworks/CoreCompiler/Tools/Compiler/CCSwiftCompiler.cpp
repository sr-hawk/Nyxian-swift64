/*
 * MIT License
 *
 * Copyright (c) 2026 Kyle-Ye
 * Copyright (c) 2026 emexlab
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include <CoreCompiler/CCSwiftCompiler.h>
#include <CoreCompiler/CCDiagnostic.h>
#include <cstdio>
#include <cstdlib>
#include <climits>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreCompiler/CCFile.h>
#include <CoreCompiler/CCUtils.h>
#include <CoreCompiler/CCUtilsPrivate.h>
#include <swift/FrontendTool/FrontendTool.h>
#include <swift/Frontend/Frontend.h>
#include <swift/Frontend/PrintingDiagnosticConsumer.h>
#include <swift/Basic/InitializeSwiftModules.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/Path.h>
#include <llvm/Support/ErrorHandling.h>
#include <fcntl.h>
#include <mutex>
#include <unistd.h>

struct CapturedDiag {
    swift::DiagID id;
    swift::DiagnosticKind kind;
    std::string message;
    std::string file;
    unsigned line = 0, column = 0;
};

class CapturingConsumer : public swift::DiagnosticConsumer {
public:
    std::vector<CapturedDiag> diags;

    void handleDiagnostic(swift::SourceManager &SM,
                          const swift::DiagnosticInfo &Info) override
    {
        CapturedDiag d;
        d.id = Info.ID;
        d.kind = Info.Kind;
        
        llvm::SmallString<256> buf;
        {
            llvm::raw_svector_ostream os(buf);
            swift::DiagnosticEngine::formatDiagnosticText(os, Info.FormatString, Info.FormatArgs);
        }
        d.message = std::string(buf);

        if(Info.Loc.isValid())
        {
            auto lc = SM.getPresumedLineAndColumnForLoc(Info.Loc);
            d.line = lc.first;
            d.column = lc.second;
            d.file = SM.getDisplayNameForLoc(Info.Loc).str();
        }
        diags.push_back(std::move(d));
    }
};

class CCSwiftObserver : public swift::FrontendObserver {
public:
    std::string primaryFile;
    CapturingConsumer consumer;
    
    void parsedArgs(swift::CompilerInvocation &invocation) override
    {
        auto &io = invocation.getFrontendOptions().InputsAndOutputs;
        if(io.hasPrimaryInputs())
        {
            io.forEachPrimaryInput([&](const swift::InputFile &f) -> bool
            {
                primaryFile = f.getFileName();
                return true;
            });
        }
        else
        {
            /* TODO: implement wmo support */
            primaryFile = "wmo";
        }
    }
    
    void configuredCompiler(swift::CompilerInstance &CI) override
    {
        CI.addDiagnosticConsumer(&consumer);
    }
};

CC_EXPORT Boolean CCSwiftCompilerJobExecute(CCJobRef job,
                                            CFArrayRef *outDiagnostics,
                                            CFStringRef *outMainSource)
{
    assert(job != nullptr);
    assert(CCJobGetType(job) == kCCJobTypeSwiftCompiler);
    
    CFArrayRef argsArray = CCJobGetArguments(job);
    
    llvm::SmallVector<std::string, 64> argStorage = CCArrayToStringVector(argsArray);
    llvm::SmallVector<const char *, 64> args = StringVectorToCStrings(argStorage);
    
    /* get_-frontend_out_of_my_way type shii */
    if(!args.empty() && std::strcmp(args.front(), "-frontend") == 0)
    {
        args.erase(args.begin());
    }
    
    /*
     * Build trace. os_log/NSLog from this app is not reliably delivered to the
     * unified log (measured 2026-09-17: the process logs through UIKit but no
     * app-level line arrives), so the compiler writes its own trace to
     * Documents/build.log. Always on: a build that fails must be diagnosable
     * from the device alone.
     */
    FILE *trace = nullptr;
    if(const char *home = getenv("HOME"))
    {
        std::string tracePath = std::string(home) + "/Documents/build.log";
        trace = fopen(tracePath.c_str(), "a");
    }
    /*
     * The legacy driver computes -in-process-plugin-server-path from the swift
     * program path. In an in-process compiler that path is empty, so the value
     * it emits is the RELATIVE "lib/swift/host/libSwiftInProcPluginServer.dylib"
     * -- and it emits its own value even when the caller already passed an
     * absolute one (measured 2026-09-17 in Documents/build.log: our absolute
     * path never reached the frontend, the relative one did). The frontend then
     * fails to load the server and exits with status 1 and ZERO diagnostics,
     * before the diagnostic consumer is installed, so nothing explains it.
     *
     * Rewrite it here, where nothing downstream can override it: any relative
     * value becomes the real server inside this app bundle. Same for the
     * -plugin-path search paths the driver derives the same broken way.
     */
    if(CFBundleRef mainBundle = CFBundleGetMainBundle())
    {
        if(CFURLRef bundleURL = CFBundleCopyBundleURL(mainBundle))
        {
            char bundlePath[PATH_MAX] = {0};
            if(CFURLGetFileSystemRepresentation(bundleURL, true, (UInt8 *)bundlePath, sizeof(bundlePath)))
            {
                const std::string frameworks = std::string(bundlePath) + "/Frameworks/CoreCompiler.framework/Frameworks";
                for(size_t i = 0; i + 1 < argStorage.size(); i++)
                {
                    if(argStorage[i] == "-in-process-plugin-server-path" && !argStorage[i + 1].empty() && argStorage[i + 1][0] != '/')
                    {
                        argStorage[i + 1] = frameworks + "/libSwiftInProcPluginServer.dylib";
                    }
                    else if(argStorage[i] == "-plugin-path" && !argStorage[i + 1].empty() && argStorage[i + 1][0] != '/')
                    {
                        argStorage[i + 1] = frameworks;
                    }
                }
                args = StringVectorToCStrings(argStorage);
            }
            CFRelease(bundleURL);
        }
    }
    
    if(trace)
    {
        fprintf(trace, "\n--- swift frontend, %zu args (as passed)\n", argStorage.size());
        for(const auto &a : argStorage) fprintf(trace, "    %s\n", a.c_str());
        fflush(trace);
    }
    
    CCInitializeSwiftModulesOnce();
    
    CCSwiftObserver obs;
    llvm::remove_fatal_error_handler();
    
    /*
     * The frontend prints argument errors, module-load failures and fatal
     * errors to stderr through its own printing consumer, before the
     * CapturingConsumer below is ever installed -- in an iOS app that output
     * goes nowhere, which is why every failure so far arrived with
     * diagnostics=0 and no explanation (measured 2026-09-17). Point both
     * standard streams at the build log for the duration of the call.
     */
    int savedOut = -1, savedErr = -1;
    if(trace)
    {
        fflush(stdout);
        fflush(stderr);
        fprintf(trace, "  --- frontend output ---\n");
        fflush(trace);
        savedOut = dup(1);
        savedErr = dup(2);
        dup2(fileno(trace), 1);
        dup2(fileno(trace), 2);
    }
    
    int status = swift::performFrontend(args, "swift-frontend", nullptr, &obs);
    
    if(trace)
    {
        fflush(stdout);
        fflush(stderr);
        if(savedOut >= 0) { dup2(savedOut, 1); close(savedOut); }
        if(savedErr >= 0) { dup2(savedErr, 2); close(savedErr); }
        fprintf(trace, "  --- end frontend output ---\n");
        fflush(trace);
    }
    
    CCInstallLLVMFatalErrorHandler();
    if(trace)
    {
        fprintf(trace, "  status=%d primaryFile=%s diagnostics=%zu\n", status,
                obs.primaryFile.empty() ? "(none)" : obs.primaryFile.c_str(), obs.consumer.diags.size());
        for(auto &d : obs.consumer.diags)
            fprintf(trace, "    [%d] %s:%u:%u  %s\n", (int)d.kind, d.file.c_str(), d.line, d.column, d.message.c_str());
        fclose(trace);
    }
    
    if(outDiagnostics == nullptr)
    {
        return status == 0;
    }
    
    *outDiagnostics = CFArrayCreateMutable(kCFAllocatorSystemDefault, obs.consumer.diags.size(), &kCFTypeArrayCallBacks);
    if(*outDiagnostics == nullptr)
    {
        return status == 0;
    }
    
    /*
     * A frontend that rejects its arguments never records a primary input, so
     * this used to return here and throw away every diagnostic the consumer
     * collected -- the user saw only "Failed to run project." (measured
     * 2026-09-17). Diagnostics must survive: fall back to the first input file
     * named on the command line, and to a placeholder when there is none.
     */
    if(obs.primaryFile.empty())
    {
        for(const auto &a : argStorage)
        {
            if(a.size() > 6 && a.compare(a.size() - 6, 6, ".swift") == 0)
            {
                obs.primaryFile = a;
                break;
            }
        }
        
        if(obs.primaryFile.empty())
        {
            obs.primaryFile = "<swift-frontend arguments>";
        }
    }
    
    CFStringRef mainSource = CFStringCreateWithCString(kCFAllocatorSystemDefault, obs.primaryFile.c_str(), kCFStringEncodingUTF8);
    if(mainSource == nullptr)
    {
        return status == 0;
    }
    
    for(auto &d : obs.consumer.diags)
    {
        CCDiagnosticLevel level = kCCDiagnosticLevelUnknown;
        
        switch(d.kind)
        {
            case swift::DiagnosticKind::Error:
                level = kCCDiagnosticLevelError;
                break;
            case swift::DiagnosticKind::Warning:
                level = kCCDiagnosticLevelWarning;
                break;
            case swift::DiagnosticKind::Remark:
                level = kCCDiagnosticLevelRemark;
                break;
            case swift::DiagnosticKind::Note:
                level = kCCDiagnosticLevelNote;
                break;
            default:
                break;
        }
        
        if(level == kCCDiagnosticLevelUnknown)
        {
            continue;
        }
        
        CFStringRef messageStr = CFStringCreateWithCString(kCFAllocatorSystemDefault, d.message.c_str(), kCFStringEncodingUTF8);
        if(messageStr == nullptr)
        {
            continue;
        }
        
        CFStringRef fileSource = CFStringCreateWithCString(kCFAllocatorDefault, d.file.c_str(), kCFStringEncodingUTF8);
        if(fileSource == nullptr)
        {
            CFRelease(messageStr);
            continue;
        }
        
        CCFileSourceLocationRef fileSourceLocation = nullptr;
        CCFileRef file = CCFileCreateWithCString(kCFAllocatorSystemDefault, d.file.c_str(), kCFStringEncodingUTF8);
        if(file != nullptr)
        {
            CFURLRef fileURL = CCFileGetFileURL(file);
            fileSourceLocation = CCFileSourceLocationCreate(kCFAllocatorSystemDefault, fileURL, CCSourceLocationMake(d.line, d.column));
            CFRelease(file);
        }
        
        CCDiagnosticRef diagnostic = CCDiagnosticCreate(kCFAllocatorSystemDefault, kCCDiagnosticTypeFile, level, fileSource, fileSourceLocation, messageStr);
        CFRelease(messageStr);
        if(fileSourceLocation != nullptr)
        {
            CFRelease(fileSourceLocation);
        }
        if(diagnostic == nullptr)
        {
            continue;
        }
        
        CFArrayAppendValue((CFMutableArrayRef)*outDiagnostics, diagnostic);
        CFRelease(diagnostic);
    }
    
    if(outMainSource == nullptr)
    {
        CFRelease(mainSource);
    }
    else
    {
        *outMainSource = mainSource;
    }
    
    return status == 0;
}
