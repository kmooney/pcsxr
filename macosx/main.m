//
//  main.m
//
//  Created by Gil Pedersen on Fri Jun 06 2003.
//  Copyright (c) 2003 SoftWorkz. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "EmuThread.h"
#import "PcsxrController.h"
#import "ConfigurationController.h"
#include <dlfcn.h>
//#import <sys/param.h>
#import <unistd.h>
#include "psxcommon.h"
#include "sio.h"
#include <IOKit/pwr_mgt/IOPMLib.h>
#import "hotkeys.h"

static inline void RunOnMainThreadSync(dispatch_block_t block)
{
	if ([NSThread isMainThread]) {
		block();
	} else {
		dispatch_sync(dispatch_get_main_queue(), block);
	}
}

static BOOL sysInited = NO;
//#define EMU_LOG
static IOPMAssertionID powerAssertion = kIOPMNullAssertionID;

void PADhandleKey(int key);

int main(int argc, const char *argv[])
{
    if ( argc >= 2 && strncmp (argv[1], "-psn", 4) == 0 ) {
        char parentdir[MAXPATHLEN];
        char *c;

        strlcpy ( parentdir, argv[0], sizeof(parentdir) );
        c = (char*) parentdir;

        while (*c != '\0')     /* go to end */
               c++;

        while (*c != '/')      /* back up to parent */
               c--;

        *c++ = '\0';           /* cut off last part (binary name) */

        assert ( chdir (parentdir) == 0 );   /* chdir to the binary app's parent */
        assert ( chdir ("../../../") == 0 ); /* chdir to the .app's parent */
    } else {
		for (int i = 1; i < argc; i++) {
			//All the other option will be handled in the app delegate's awakeFromNib
			if (!strcasecmp("--help", argv[i])) {
				fprintf(stdout, "%s\n", argv[0]);
				ShowHelpAndExit(stdout, EXIT_SUCCESS);
			}
		}
	}

    strcpy(Config.BiosDir,    "Bios/");
    strcpy(Config.PatchesDir, "Patches/");

    // Setup the X11 window
    if (getenv("DISPLAY") == NULL)
        setenv("DISPLAY", ":0.0", 0); // Default to first local display

    return NSApplicationMain(argc, argv);
}

int SysInit()
{
	if (!sysInited) {
#ifdef EMU_LOG
#ifndef LOG_STDOUT
		NSFileManager *manager = [NSFileManager defaultManager];
		NSURL *supportURL = [manager URLForDirectory:NSLibraryDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
		NSURL *logFolderURL = [supportURL URLByAppendingPathComponent:@"Logs/PCSXR"];
		if (![logFolderURL checkResourceIsReachableAndReturnError:NULL])
			[manager createDirectoryAtPath:[logFolderURL path] withIntermediateDirectories:YES attributes:nil error:NULL];
		//We use the log extension so that OS X's console app can open it by default.
		NSURL *logFileURL = [logFolderURL URLByAppendingPathComponent:@"emuLog.log"];
		
		emuLog = fopen([[logFileURL path] fileSystemRepresentation],"wb");
#else
		emuLog = stdout;
#endif
		setvbuf(emuLog, NULL, _IONBF, 0);
#endif
		
		if (EmuInit() != 0)
			return -1;
		
		sysInited = YES;
	}
	
	if (LoadPlugins() == -1) {
		return -1;
	}
	
	LoadMcds(Config.Mcd1, Config.Mcd2);
	
	IOReturn success = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelOn, CFSTR("PSX Emu Running"), &powerAssertion);
	if (success != kIOReturnSuccess) {
		NSLog(@"Unable to stop sleep, error code %d", success);
	}
	
	attachHotkeys();
	
	return 0;
}

void SysReset()
{
	[EmuThread resetNow];
	//EmuReset();
}

#ifdef EMU_LOG
#ifndef LOG_STDOUT
static inline NSDateFormatter* debugDateFormatter()
{
	static NSDateFormatter* theFormatter = nil;
	if (theFormatter == nil) {
		theFormatter = [[NSDateFormatter alloc] init];
		[theFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss:SSS"];
	}
	return theFormatter;
}
#endif
#endif

static void AddStringToLogList(const char *themsg)
{
	static NSMutableString *theStr;
	NSRange newlineRange, fullLineRange;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		theStr = [[NSMutableString alloc] init];
	});
	[theStr appendString:@(themsg)];
	while ((newlineRange = [theStr rangeOfString:@"\n"]).location != NSNotFound) {
		NSString *tmpStr = [theStr substringToIndex:newlineRange.location];
		if (tmpStr && ![tmpStr isEqualToString:@""]) {
			NSLog(@"%@", tmpStr);
		}
		fullLineRange.location = 0;
		fullLineRange.length = newlineRange.location + newlineRange.length;
		fullLineRange = [theStr rangeOfComposedCharacterSequencesForRange:fullLineRange];
		[theStr deleteCharactersInRange:fullLineRange];
	}
}

void SysPrintf(const char *fmt, ...)
{
	va_list list;
	char *msg = calloc(sizeof(char), 512);
	
	va_start(list, fmt);
	vsnprintf(msg, 512, fmt, list);
	va_end(list);
		
	RunOnMainThreadSync(^{
		if (Config.PsxOut) AddStringToLogList(msg);
#ifdef EMU_LOG
#ifndef LOG_STDOUT
		if (emuLog) fprintf(emuLog, "%s", msg);
#endif
#endif
	});
	free(msg);
}

void SysMessage(const char *fmt, ...)
{
	va_list list;
	NSString *locFmtString = NSLocalizedString(@(fmt), nil);
	
	va_start(list, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:locFmtString arguments:list];
	va_end(list);
	
	NSDictionary *userInfo = @{NSLocalizedFailureReasonErrorKey: msg};
	
	RunOnMainThreadSync(^{
		[NSApp presentError:[NSError errorWithDomain:@"Unknown Domain" code:-1 userInfo:userInfo]];
	});
}

void *SysLoadLibrary(const char *lib)
{
	NSBundle *bundle = [[NSBundle alloc] initWithPath:[[NSFileManager defaultManager] stringWithFileSystemRepresentation:lib length:strlen(lib)]];
	if (bundle != nil) {
		return dlopen([[bundle executablePath] fileSystemRepresentation], RTLD_LAZY /*RTLD_NOW*/);
	}
	return dlopen(lib, RTLD_LAZY);
}

void *SysLoadSym(void *lib, const char *sym)
{
	return dlsym(lib, sym);
}

const char *SysLibError()
{
#ifdef DEBUG
	const char *theErr = dlerror();
	if (theErr) {
		NSLog(@"Error loading binary: %s.", theErr);
	}
	return theErr;
#else
	return dlerror();
#endif
}

void SysCloseLibrary(void *lib) {
	//dlclose(lib);
}

// Called periodically from the emu thread
void SysUpdate()
{
#if 0
	PADhandleKey(PAD1_keypressed() & 0xffffffff);
	PADhandleKey(PAD2_keypressed() & 0xffffffff);
#else
	PAD1_keypressed();
	PAD2_keypressed();
#endif
	[emuThread handleEvents];
}

// Returns to the Gui
void SysRunGui()
{
	if (powerAssertion != kIOPMNullAssertionID) {
		IOPMAssertionRelease(powerAssertion);
		powerAssertion = kIOPMNullAssertionID;
	}
}

// Close mem and plugins
void SysClose()
{
	EmuShutdown();
	ReleasePlugins();
	
	if (powerAssertion != kIOPMNullAssertionID) {
		IOPMAssertionRelease(powerAssertion);
		powerAssertion = kIOPMNullAssertionID;
	}
	
	if (emuLog != NULL) {
		fclose(emuLog);
		emuLog = NULL;
	}
	
	sysInited = NO;
	detachHotkeys();
	
	if (((PcsxrController *)[NSApp delegate]).endAtEmuClose) {
		[NSApp stop:nil];
	}
	
	//Tell the memory card manager that the memory cards changed.
	//The number three tells the mem card manager to update both cards 1 and 2.
	[[NSNotificationCenter defaultCenter] postNotificationName:memChangeNotifier object:nil userInfo:@{memCardChangeNumberKey: @3}];
}

void OnFile_Exit()
{
    SysClose();
	[NSApp stop:nil];
}

char* Pcsxr_locale_text(char* toloc)
{
	NSBundle *mainBundle = [NSBundle mainBundle];
	NSString *origString = @(toloc), *transString = nil;
	transString = [mainBundle localizedStringForKey:origString value:@"" table:nil];
	return (char*)[transString UTF8String];
}
